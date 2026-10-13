// deno test --allow-read supabase/functions
import { handle } from './handler.js';

const eq = (a, b, msg) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error((msg || 'distinto') + ': ' + JSON.stringify(a) + ' ≠ ' + JSON.stringify(b)); };
const ok = (c, msg) => { if (!c) throw new Error(msg || 'falló'); };

function fakeDeps(extra = {}) {
  const db = {
    profiles: [
      { id: 'adm', full_name: 'Admin OK', email: 'admin@ok.test', phone: null, role: 'ADMIN', status: 'ACTIVO', carriers: [] },
      { id: 'des', full_name: 'Depósito', email: 'despacho@ok.test', phone: null, role: 'DESPACHO', status: 'ACTIVO', carriers: [] },
      { id: 'gab', full_name: 'Gabriel Figueroa', email: 'gabriel@ok.test', phone: null, role: 'TRANSPORTISTA_INTERNO', status: 'ACTIVO', carriers: [] },
      { id: 'cri', full_name: 'Cristian Torres', email: 'cristian@ok.test', phone: null, role: 'TRANSPORTISTA', status: 'ACTIVO', carriers: ['CT-ESTE', 'CT-ALR'] },
      { id: 'inv', full_name: 'Invitado', email: 'inv@ok.test', phone: null, role: 'DESPACHO', status: 'INVITACION_PENDIENTE', carriers: [] }
    ],
    authEmails: { adm: 'admin@ok.test', des: 'despacho@ok.test', gab: 'gabriel@ok.test', cri: 'cristian@ok.test', inv: 'inv@ok.test' },
    history: new Set(['gab', 'cri']), active: { gab: [{ id: 'r1', number: '03-02', carrier_id: 'INTERNO', operational_status: 'PUBLICADA' }] },
    banned: new Set(), revoked: [], audit: [], invited: [], resent: [], resets: [], deleted: [], authDeleted: []
  };
  const tokens = { 'tok-adm': 'adm', 'tok-des': 'des', 'tok-gab': 'gab', 'tok-inv': 'inv' };
  const P = id => db.profiles.find(x => x.id === id);
  const deps = {
    redirectTo: 'https://okdespacho.example/#/crear-contrasena',
    getUserFromJwt: async t => tokens[t] ? { id: tokens[t] } : null,
    getProfile: async id => { const p = P(id); return p ? { ...p, carriers: [...p.carriers] } : null; },
    listProfiles: async () => db.profiles.map(p => ({ ...p, carriers: [...p.carriers] })),
    hasHistory: async id => db.history.has(id),
    activeRoutes: async id => db.active[id] || [],
    inviteUser: async (email) => { const id = 'u' + (db.invited.length + 1); db.invited.push({ id, email }); db.authEmails[id] = email; return { id }; },
    resendInvite: async (email) => { db.resent.push(email); },
    deleteAuthUser: async id => { db.authDeleted.push(id); delete db.authEmails[id]; },
    createProfileAtomic: async (p, carriers) => { db.profiles.push({ ...p, carriers: [...carriers] }); },
    updateProfileAtomic: async (id, f) => {
      if (f.role === 'TRANSPORTISTA' && !(f.carriers ?? P(id).carriers).length) throw new Error('CARRIER_REQUIRED: un TRANSPORTISTA debe tener al menos un carrier externo');
      Object.assign(P(id), { full_name: f.full_name, phone: f.phone, email: f.email, role: f.role }, f.carriers ? { carriers: [...f.carriers] } : {}, f.set_supervisor ? { supervisor_user_id: f.supervisor } : {});
    },
    updateStatus: async (id, patch) => { Object.assign(P(id), patch); },
    setCarriersAtomic: async (id, c) => { P(id).carriers = [...c]; },
    updateAuthEmail: async (id, email) => { db.authEmails[id] = email; },
    sendPasswordReset: async (email) => { db.resets.push(email); },
    revokeSessions: async id => { db.revoked.push(id); return '2026-10-09T12:00:00Z'; },
    reassignRoutes: async (from, to) => { const n = (db.active[from] || []).length; db.active[to] = (db.active[to] || []).concat(db.active[from] || []); db.active[from] = []; return n; },
    banUser: async id => { db.banned.add(id); },
    unbanUser: async id => { db.banned.delete(id); },
    deleteProfileAndAuth: async id => { db.deleted.push(id); db.profiles = db.profiles.filter(p => p.id !== id); },
    audit: async e => { db.audit.push(e); },
    setDisabledModules: async (id, m) => { P(id).disabled_modules = [...m]; },
    userHasPerm: async (id, perm) => { const { hasPerm } = await import('../_shared/rules.js'); return hasPerm(P(id), perm); }, // en la base: user_has_perm
    ...extra
  };
  return { db, deps };
}
const call = (deps, token, body, method = 'POST') => handle(new Request('https://x/functions/v1/admin-users', {
  method, headers: token ? { authorization: 'Bearer ' + token, 'content-type': 'application/json' } : { 'content-type': 'application/json' },
  body: method === 'POST' ? JSON.stringify(body) : undefined
}), deps);
const read = async r => ({ status: r.status, body: await r.json() });
const lastAudit = db => db.audit.at(-1) || {};

// ===================== Fase 1 (se mantienen) =====================
Deno.test('F01 sin token → 401', async () => { const { deps } = fakeDeps(); eq((await read(await call(deps, null, { action: 'list' }))).status, 401); });
Deno.test('F02 token inválido → 401', async () => { const { deps } = fakeDeps(); eq((await read(await call(deps, 'trucho', { action: 'list' }))).status, 401); });
Deno.test('F03 usuario sin users.manage no puede crear → 403', async () => {
  const { deps, db } = fakeDeps(); const r = await read(await call(deps, 'tok-des', { action: 'create', email: 'n@ok.test', full_name: 'N', role: 'DESPACHO' }));
  eq(r.status, 403); eq(db.invited.length, 0, 'no debe invitar');
});
Deno.test('F04 transportista no puede listar usuarios → 403', async () => { const { deps } = fakeDeps(); eq((await read(await call(deps, 'tok-gab', { action: 'list' }))).status, 403); });
Deno.test('F05 admin crea usuario por invitación + perfil + auditoría USER_CREATED', async () => {
  const { deps, db } = fakeDeps();
  const r = await read(await call(deps, 'tok-adm', { action: 'create', email: 'Nuevo@OK.test', full_name: 'Nuevo Interno', role: 'TRANSPORTISTA_INTERNO', phone: '261' }));
  eq(r.status, 200); eq(db.invited[0].email, 'nuevo@ok.test'); eq(r.body.user.status, 'INVITACION_PENDIENTE');
  ok(db.profiles.some(p => p.email === 'nuevo@ok.test')); eq(lastAudit(db).action, 'USER_CREATED');
});
Deno.test('F06 email duplicado → 409', async () => { const { deps } = fakeDeps(); eq((await read(await call(deps, 'tok-adm', { action: 'create', email: 'gabriel@ok.test', full_name: 'X', role: 'DESPACHO' }))).status, 409); });
Deno.test('F07 transportista externo sin carrier → 400', async () => {
  const { deps } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'create', email: 'z@ok.test', full_name: 'Z', role: 'TRANSPORTISTA', carriers: [] })); eq(r.status, 400); eq(r.body.code, 'CARRIER_REQUIRED');
});
Deno.test('F08 deshabilitar (sin hojas activas): bloquea acceso, cierra sesiones y conserva historial', async () => {
  const { deps, db } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'disable', user_id: 'cri' }));
  eq(r.status, 200); ok(db.banned.has('cri')); ok(db.revoked.includes('cri')); eq(db.profiles.find(p => p.id === 'cri').status, 'DESHABILITADO'); ok(db.history.has('cri'));
});
Deno.test('F09 reactivar: mismo id, vuelve a ACTIVO y se quita el bloqueo', async () => {
  const { deps, db } = fakeDeps(); await call(deps, 'tok-adm', { action: 'disable', user_id: 'cri' });
  const r = await read(await call(deps, 'tok-adm', { action: 'reactivate', user_id: 'cri' }));
  eq(r.status, 200); eq(r.body.user.id, 'cri'); eq(r.body.user.status, 'ACTIVO'); ok(!db.banned.has('cri'));
});
Deno.test('F10 eliminar usuario CON historial → 409 (se archiva)', async () => {
  const { deps, db } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'delete', user_id: 'cri' })); eq(r.status, 409); eq(r.body.code, 'HAS_HISTORY'); eq(db.deleted.length, 0);
});
Deno.test('F11 eliminar usuario SIN historial → borra Auth y perfil, y recién ahí audita USER_DELETED', async () => {
  const { deps, db } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'delete', user_id: 'des' }));
  eq(r.status, 200); eq(db.deleted, ['des']); eq(lastAudit(db).action, 'USER_DELETED');
});
Deno.test('F12 archivar (sin hojas activas): no ingresa, conserva id y nombre', async () => {
  const { deps, db } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'archive', user_id: 'cri' }));
  eq(r.status, 200); eq(r.body.user.status, 'ARCHIVADO'); eq(r.body.user.full_name, 'Cristian Torres'); ok(db.banned.has('cri'));
});
Deno.test('F13 nadie cambia su propio rol', async () => { const { deps } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'set_role', user_id: 'adm', role: 'DESPACHO' })); eq(r.status, 400); eq(r.body.code, 'SELF_ROLE'); });
Deno.test('F14 admin DESHABILITADO no puede operar', async () => {
  const { deps, db } = fakeDeps(); db.profiles.push({ id: 'adm2', full_name: 'Otro Admin', email: 'a2@ok.test', role: 'ADMIN', status: 'DESHABILITADO', carriers: [] });
  deps.getUserFromJwt = async t => t === 'tok-adm2' ? { id: 'adm2' } : null;
  eq((await read(await call(deps, 'tok-adm2', { action: 'disable', user_id: 'des' }))).status, 403);
});
Deno.test('F15 cambio de rol queda auditado con antes/después', async () => {
  const { deps, db } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'set_role', user_id: 'des', role: 'SOLO_LECTURA' }));
  eq(r.status, 200); const a = lastAudit(db); eq(a.action, 'USER_ROLE_CHANGED'); eq(a.before.role, 'DESPACHO'); eq(a.after.role, 'SOLO_LECTURA');
});
Deno.test('F16 método GET rechazado y JSON inválido rechazado', async () => {
  const { deps } = fakeDeps(); eq((await call(deps, 'tok-adm', null, 'GET')).status, 405);
  eq((await handle(new Request('https://x', { method: 'POST', headers: { authorization: 'Bearer tok-adm' }, body: '{nope' }), deps)).status, 400);
});
Deno.test('F17 el service_role no aparece en el código del frontend', async () => {
  const walk = async (dir) => { let out = []; for await (const e of Deno.readDir(dir)) { const p = dir + '/' + e.name; if (e.isDirectory) out = out.concat(await walk(p)); else if (/\.(js|ts|html)$/.test(e.name)) out.push(p); } return out; };
  for (const f of await walk(new URL('../../../src', import.meta.url).pathname)) ok(!/service_role|SERVICE_ROLE/.test(await Deno.readTextFile(f)), 'service_role en ' + f);
});
Deno.test('F18 el invitado acepta su invitación (pasa a ACTIVO) solo una vez', async () => {
  const { deps } = fakeDeps();
  const r = await read(await call(deps, 'tok-inv', { action: 'accept_invite' })); eq(r.status, 200); eq(r.body.user.status, 'ACTIVO');
  const again = await read(await call(deps, 'tok-inv', { action: 'accept_invite' })); eq(again.status, 200); eq(again.body.user.status, 'ACTIVO'); // RC1.3: idempotente
});

// ===================== Fase 1.1 =====================
Deno.test('F1.1-01 Admin solicita restablecer contraseña → link al email y PASSWORD_RESET_REQUESTED auditado', async () => {
  const { deps, db } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'reset_password', user_id: 'gab' }));
  eq(r.status, 200); eq(db.resets, ['gabriel@ok.test']);
  const a = lastAudit(db); eq(a.action, 'PASSWORD_RESET_REQUESTED'); eq(a.actor_id, 'adm'); eq(a.target_id, 'gab'); eq(a.after.result, 'ENVIADO');
});
Deno.test('F1.1-02 Restablecer contraseña no revela ni devuelve contraseñas, tokens ni links', async () => {
  const { deps, db } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'reset_password', user_id: 'gab' }));
  const keys = JSON.stringify(r.body) + JSON.stringify(db.audit);
  ok(!/"password"|"token"|access_token|refresh_token|https?:\/\/[^"]*recovery|"link"/i.test(keys), 'filtró datos sensibles: ' + keys);
  eq(Object.keys(r.body).sort(), ['message', 'ok']);
});
Deno.test('F1.1-02b Restablecer falla → queda auditado con resultado ERROR', async () => {
  const { deps, db } = fakeDeps({ sendPasswordReset: async () => { throw new Error('SMTP caído'); } });
  const r = await read(await call(deps, 'tok-adm', { action: 'reset_password', user_id: 'gab' })); eq(r.status, 502); eq(lastAudit(db).after.result, 'ERROR');
});
Deno.test('F1.1-03 Cerrar sesiones abiertas queda auditado (SESSIONS_REVOKED)', async () => {
  const { deps, db } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'revoke_sessions', user_id: 'gab' }));
  eq(r.status, 200); ok(db.revoked.includes('gab')); eq(lastAudit(db).action, 'SESSIONS_REVOKED');
});
Deno.test('F1.1-03b Sin users.manage no se cierran sesiones de otros', async () => {
  const { deps, db } = fakeDeps(); eq((await read(await call(deps, 'tok-des', { action: 'revoke_sessions', user_id: 'gab' }))).status, 403); eq(db.revoked.length, 0);
});
Deno.test('F1.1-05 Admin edita nombre y teléfono (auditoría antes/después)', async () => {
  const { deps, db } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'edit', user_id: 'gab', full_name: 'Gabriel A. Figueroa', phone: '261 555-0999' }));
  eq(r.status, 200); eq(r.body.user.full_name, 'Gabriel A. Figueroa'); eq(r.body.user.phone, '261 555-0999');
  const a = lastAudit(db); eq(a.action, 'USER_UPDATED'); eq(a.before.full_name, 'Gabriel Figueroa'); eq(a.after.full_name, 'Gabriel A. Figueroa');
});
Deno.test('F1.1-06 Admin cambia email: Auth y profile quedan iguales', async () => {
  const { deps, db } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'edit', user_id: 'gab', email: 'G.Figueroa@OK.test' }));
  eq(r.status, 200); eq(db.authEmails.gab, 'g.figueroa@ok.test'); eq(db.profiles.find(p => p.id === 'gab').email, 'g.figueroa@ok.test');
});
Deno.test('F1.1-06b Si falla el perfil después de cambiar Auth, Auth vuelve al email anterior', async () => {
  const { deps, db } = fakeDeps({ updateProfileAtomic: async () => { throw new Error('fallo de red'); } });
  const r = await read(await call(deps, 'tok-adm', { action: 'edit', user_id: 'gab', email: 'otro@ok.test' }));
  eq(r.status, 409); eq(db.authEmails.gab, 'gabriel@ok.test'); eq(db.profiles.find(p => p.id === 'gab').email, 'gabriel@ok.test');
});
Deno.test('F1.1-07 DESPACHO → TRANSPORTISTA sin carrier: RECHAZADO', async () => {
  const { deps, db } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'edit', user_id: 'des', role: 'TRANSPORTISTA' }));
  eq(r.status, 400); eq(r.body.code, 'CARRIER_REQUIRED'); eq(db.profiles.find(p => p.id === 'des').role, 'DESPACHO');
  eq((await read(await call(deps, 'tok-adm', { action: 'set_role', user_id: 'des', role: 'TRANSPORTISTA' }))).body.code, 'CARRIER_REQUIRED');
});
Deno.test('F1.1-08 DESPACHO → TRANSPORTISTA con CT-ESTE: ACEPTADO', async () => {
  const { deps } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'edit', user_id: 'des', role: 'TRANSPORTISTA', carriers: ['CT-ESTE'] }));
  eq(r.status, 200); eq(r.body.user.role, 'TRANSPORTISTA'); eq(r.body.user.carriers, ['CT-ESTE']);
});
Deno.test('F1.1-09 Cambio de carriers falla → responde error y conserva los anteriores', async () => {
  const { deps, db } = fakeDeps({ setCarriersAtomic: async () => { throw new Error('BAD_CARRIER'); } });
  const r = await read(await call(deps, 'tok-adm', { action: 'set_carriers', user_id: 'cri', carriers: ['CT-ESTE', 'NO-EXISTE'] }));
  eq(r.status, 409); eq(db.profiles.find(p => p.id === 'cri').carriers, ['CT-ESTE', 'CT-ALR']); ok(!db.audit.some(a => a.action === 'USER_CARRIERS_CHANGED'));
});
Deno.test('F1.1-10 Falla el perfil después de invitar → se borra el usuario de Auth (sin huérfano) y no hay USER_CREATED', async () => {
  const { deps, db } = fakeDeps({ createProfileAtomic: async () => { throw new Error('insert profile falló'); } });
  const r = await read(await call(deps, 'tok-adm', { action: 'create', email: 'nuevo@ok.test', full_name: 'Nuevo', role: 'DESPACHO' }));
  eq(r.status, 500); eq(db.authDeleted, ['u1']); ok(!('u1' in db.authEmails));
  ok(!db.audit.some(a => a.action === 'USER_CREATED')); eq(lastAudit(db).action, 'USER_CREATE_FAILED'); eq(lastAudit(db).after.auth_cleanup, 'ok');
});
Deno.test('F1.1-11 Falla el borrado en Auth → no queda un evento USER_DELETED', async () => {
  const { deps, db } = fakeDeps({ deleteProfileAndAuth: async () => { throw new Error('Auth no respondió'); } });
  const r = await read(await call(deps, 'tok-adm', { action: 'delete', user_id: 'des' }));
  eq(r.status, 409); ok(!db.audit.some(a => a.action === 'USER_DELETED')); eq(lastAudit(db).action, 'USER_DELETE_FAILED');
});
Deno.test('F1.1-12 Falla la activación de la invitación → error claro y sigue INVITACION_PENDIENTE', async () => {
  const { deps, db } = fakeDeps({ updateStatus: async () => { throw new Error('timeout'); } });
  const r = await read(await call(deps, 'tok-inv', { action: 'accept_invite' }));
  eq(r.status, 500); eq(r.body.code, 'ACCEPT_FAILED'); eq(db.profiles.find(p => p.id === 'inv').status, 'INVITACION_PENDIENTE'); ok(!db.audit.some(a => a.action === 'INVITE_ACCEPTED'));
});
Deno.test('F1.1-13 Usuario con hoja activa no se DESHABILITA en silencio (409 + lista de hojas)', async () => {
  const { deps, db } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'disable', user_id: 'gab' }));
  eq(r.status, 409); eq(r.body.code, 'ACTIVE_ROUTES'); eq(r.body.routes[0].number, '03-02'); eq(db.profiles.find(p => p.id === 'gab').status, 'ACTIVO'); ok(!db.banned.has('gab'));
});
Deno.test('F1.1-14 Usuario con hoja activa no se ARCHIVA en silencio', async () => {
  const { deps, db } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'archive', user_id: 'gab' }));
  eq(r.status, 409); eq(r.body.code, 'ACTIVE_ROUTES'); eq(db.profiles.find(p => p.id === 'gab').status, 'ACTIVO');
});
Deno.test('F1.1-14b Reasignar las hojas y después deshabilitar', async () => {
  const { deps, db } = fakeDeps(); db.profiles.push({ id: 'g2', full_name: 'Otro Interno', email: 'g2@ok.test', role: 'TRANSPORTISTA_INTERNO', status: 'ACTIVO', carriers: [] });
  const r = await read(await call(deps, 'tok-adm', { action: 'reassign_routes', user_id: 'gab', to_user: 'g2' })); eq(r.status, 200); eq(r.body.count, 1); eq(lastAudit(db).action, 'ROUTES_REASSIGNED');
  eq((await read(await call(deps, 'tok-adm', { action: 'disable', user_id: 'gab' }))).status, 200);
});
Deno.test('F1.1-15 Reenviar invitación no crea otro usuario', async () => {
  const { deps, db } = fakeDeps(); const n = db.profiles.length;
  const r = await read(await call(deps, 'tok-adm', { action: 'resend_invite', user_id: 'inv' }));
  eq(r.status, 200); eq(db.resent, ['inv@ok.test']); eq(db.invited.length, 0); eq(db.profiles.length, n); eq(lastAudit(db).action, 'INVITE_RESENT');
  eq((await read(await call(deps, 'tok-adm', { action: 'resend_invite', user_id: 'gab' }))).body.code, 'NO_INVITE');
});
Deno.test('F1.1-16 Cancelar invitación bloquea el acceso (ban + sesiones cerradas)', async () => {
  const { deps, db } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'cancel_invite', user_id: 'inv' }));
  eq(r.status, 200); ok(db.banned.has('inv')); ok(db.revoked.includes('inv')); eq(db.profiles.find(p => p.id === 'inv').status, 'DESHABILITADO'); eq(lastAudit(db).action, 'INVITE_CANCELLED');
});
Deno.test('F1.1-22 Superior configurable para un transportista interno (solo con permiso de aprobación)', async () => {
  const { deps, db } = fakeDeps();
  eq((await read(await call(deps, 'tok-adm', { action: 'edit', user_id: 'gab', supervisor_user_id: 'des' }))).body.code, 'BAD_SUPERVISOR');
  const r = await read(await call(deps, 'tok-adm', { action: 'edit', user_id: 'gab', supervisor_user_id: 'adm' }));
  eq(r.status, 200); eq(db.profiles.find(p => p.id === 'gab').supervisor_user_id, 'adm');
  eq((await read(await call(deps, 'tok-adm', { action: 'edit', user_id: 'cri', supervisor_user_id: 'adm' }))).body.code, 'BAD_SUPERVISOR');
});
Deno.test('F1.1-AG El usuario no se cambia su propio rol ni sus carriers', async () => {
  const { deps } = fakeDeps();
  eq((await read(await call(deps, 'tok-adm', { action: 'edit', user_id: 'adm', role: 'DESPACHO' }))).body.code, 'SELF_ROLE');
  eq((await read(await call(deps, 'tok-gab', { action: 'edit', user_id: 'gab', carriers: ['CT-ESTE'] }))).status, 403);
});

Deno.test('USR-13 (función) Admin restringe módulos; valida módulos; no se bloquea Usuarios a sí mismo', async () => {
  const { deps, db } = fakeDeps();
  eq((await read(await call(deps, 'tok-adm', { action: 'edit', user_id: 'des', disabled_modules: ['NO_EXISTE'] }))).body.code, 'BAD_MODULES');
  eq((await read(await call(deps, 'tok-adm', { action: 'edit', user_id: 'adm', disabled_modules: ['USUARIOS'] }))).body.code, 'SELF_LOCKOUT');
  eq((await read(await call(deps, 'tok-adm', { action: 'edit', user_id: 'des', disabled_modules: ['DESPACHO'] }))).status, 200);
  eq(db.profiles.find(p => p.id === 'des').disabled_modules, ['DESPACHO']); eq(lastAudit(db).after.disabled_modules, ['DESPACHO']);
  const { hasPerm, userModules } = await import('../_shared/rules.js');
  const d = db.profiles.find(p => p.id === 'des'); ok(!hasPerm(d, 'routes.publish'), 'sin permiso por módulo restringido'); eq(userModules(d), []);
});

// ===================== HOTFIX RC1.3 =====================
Deno.test('HOTUSR-01 OPTIONS: 200 y CORS acepta authorization, apikey, x-client-info, content-type', async () => {
  const { deps } = fakeDeps(); const r = await handle(new Request('https://x', { method: 'OPTIONS' }), deps);
  eq(r.status, 200); const h = r.headers.get('access-control-allow-headers'); ['authorization', 'apikey', 'x-client-info', 'content-type'].forEach(k => ok(h.includes(k), k));
  eq(r.headers.get('access-control-allow-origin'), '*');
});
Deno.test('HOTUSR-02 ADMIN ACTIVO con users.view lista usuarios (permiso desde user_has_perm)', async () => {
  const { deps } = fakeDeps(); const calls = []; const base = deps.userHasPerm; deps.userHasPerm = async (id, p) => { calls.push(p); return base(id, p); };
  const r = await read(await call(deps, 'tok-adm', { action: 'list' })); eq(r.status, 200); ok(r.body.users.length >= 4); ok(calls.includes('users.view'), 'usó user_has_perm');
});
Deno.test('HOTUSR-02b el permiso lo decide la base aunque el rol JS diga otra cosa', async () => {
  const { deps } = fakeDeps(); deps.userHasPerm = async () => true; eq((await call(deps, 'tok-des', { action: 'list' })).status, 200);
  deps.userHasPerm = async () => false; eq((await call(deps, 'tok-adm', { action: 'list' })).status, 403);
});
Deno.test('HOTUSR-03 usuario sin users.view recibe 403 (con CORS)', async () => {
  const { deps } = fakeDeps(); const r = await call(deps, 'tok-des', { action: 'list' }); eq(r.status, 403); eq(r.headers.get('access-control-allow-origin'), '*');
});
Deno.test('HOTUSR-04 ADMIN con el módulo USUARIOS deshabilitado recibe 403', async () => {
  const { deps, db } = fakeDeps(); db.profiles.find(p => p.id === 'adm').disabled_modules = ['USUARIOS'];
  eq((await call(deps, 'tok-adm', { action: 'list' })).status, 403);
});
Deno.test('HOTUSR-05/06 invitación pendiente → accept_invite → ACTIVO; reintento 200 idempotente', async () => {
  const { deps, db } = fakeDeps();
  const r1 = await read(await call(deps, 'tok-inv', { action: 'accept_invite' })); eq(r1.status, 200); eq(db.profiles.find(p => p.id === 'inv').status, 'ACTIVO');
  const r2 = await read(await call(deps, 'tok-inv', { action: 'accept_invite' })); eq(r2.status, 200); eq(r2.body.already, true);
  eq(db.audit.filter(a => a.action === 'INVITE_ACCEPTED').length, 1);
});
Deno.test('HOTUSR-07 excepción interna → 500 JSON legible con CORS', async () => {
  const { deps } = fakeDeps({ listProfiles: async () => { throw new Error('usuarios: relation "profiles" does not exist'); } });
  const r = await call(deps, 'tok-adm', { action: 'list' }); const b = await r.json();
  eq(r.status, 500); eq(b.code, 'SERVER_ERROR'); ok(b.error.includes('profiles')); eq(r.headers.get('access-control-allow-origin'), '*');
  const p = await call(fakeDeps({ userHasPerm: async () => { throw new Error('permiso users.view: function user_has_perm does not exist'); } }).deps, 'tok-adm', { action: 'list' });
  eq(p.status, 500); ok((await p.json()).error.includes('user_has_perm'));
});
Deno.test('HOTUSR-07b falta configuración → 500 CONFIG_ERROR con CORS', async () => {
  const { deps } = fakeDeps({ configError: 'falta SUPABASE_SERVICE_ROLE_KEY' }); const r = await call(deps, 'tok-adm', { action: 'list' });
  eq(r.status, 500); eq((await r.json()).code, 'CONFIG_ERROR'); eq(r.headers.get('access-control-allow-origin'), '*');
});
