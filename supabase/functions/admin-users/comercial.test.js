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


// ===================== Autorizaciones comerciales · rol COMERCIAL (A-10). Se ejecuta con el MISMO handler; sin desplegar nada =====================
const P = (db, id) => db.profiles.find(x => x.id === id);
Deno.test('CA01 el Administrador crea un usuario COMERCIAL (invitación + perfil + auditoría USER_CREATED)', async () => {
  const { deps, db } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'create', email: 'vendedor@ok.test', full_name: 'Vendedor Montecaseros', role: 'COMERCIAL', phone: '261' }));
  ok(r.status < 300, 'estado ' + r.status + ' ' + JSON.stringify(r.body)); const p = db.profiles.find(x => x.email === 'vendedor@ok.test'); ok(p && p.role === 'COMERCIAL', 'perfil COMERCIAL');
  ok(db.audit.some(a => a.action === 'USER_CREATED'), 'auditoría USER_CREATED');
});
Deno.test('CA02 cambio de rol HACIA COMERCIAL queda auditado con antes/después', async () => {
  const { deps, db } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'set_role', user_id: 'des', role: 'COMERCIAL' }));
  ok(r.status < 300, 'estado ' + r.status + ' ' + JSON.stringify(r.body)); eq(P(db, 'des').role, 'COMERCIAL');
  const a = lastAudit(db); ok(JSON.stringify(a).includes('DESPACHO') && JSON.stringify(a).includes('COMERCIAL'), 'auditoría con antes y después: ' + JSON.stringify(a));
});
Deno.test('CA03 cambio de rol DESDE COMERCIAL (a Solo lectura) funciona y se audita', async () => {
  const { deps, db } = fakeDeps(); await call(deps, 'tok-adm', { action: 'set_role', user_id: 'des', role: 'COMERCIAL' });
  const r = await read(await call(deps, 'tok-adm', { action: 'set_role', user_id: 'des', role: 'SOLO_LECTURA' })); ok(r.status < 300, 'estado ' + r.status); eq(P(db, 'des').role, 'SOLO_LECTURA');
});
Deno.test('CA04 edición de un usuario COMERCIAL (nombre y teléfono) conserva el rol', async () => {
  const { deps, db } = fakeDeps(); await call(deps, 'tok-adm', { action: 'set_role', user_id: 'des', role: 'COMERCIAL' });
  const r = await read(await call(deps, 'tok-adm', { action: 'edit', user_id: 'des', full_name: 'Comercial San Juan', phone: '264', email: 'despacho@ok.test' }));
  ok(r.status < 300, 'estado ' + r.status + ' ' + JSON.stringify(r.body)); eq(P(db, 'des').full_name, 'Comercial San Juan'); eq(P(db, 'des').role, 'COMERCIAL');
});
Deno.test('CA05 REVOCACIÓN: restringir el módulo «Autorizaciones comerciales» quita el permiso de solicitar al instante', async () => {
  const { deps, db } = fakeDeps(); await call(deps, 'tok-adm', { action: 'set_role', user_id: 'des', role: 'COMERCIAL' });
  const { hasPerm } = await import('../_shared/rules.js'); ok(hasPerm(P(db, 'des'), 'com.request'), 'antes puede solicitar');
  const r = await read(await call(deps, 'tok-adm', { action: 'edit', user_id: 'des', full_name: 'Depósito', phone: null, email: 'despacho@ok.test', disabled_modules: ['COMERCIAL'] }));
  ok(r.status < 300, 'estado ' + r.status + ' ' + JSON.stringify(r.body)); ok(!hasPerm(P(db, 'des'), 'com.request'), 'después NO puede solicitar');
});
Deno.test('CA06 un usuario SIN users.manage no puede asignar el rol COMERCIAL → 403', async () => {
  const { deps, db } = fakeDeps(); const r = await read(await call(deps, 'tok-gab', { action: 'set_role', user_id: 'des', role: 'COMERCIAL' })); eq(r.status, 403); eq(P(db, 'des').role, 'DESPACHO');
});
Deno.test('CA07 un rol inexistente se rechaza (BAD_ROLE · 400)', async () => {
  const { deps } = fakeDeps(); const r = await read(await call(deps, 'tok-adm', { action: 'set_role', user_id: 'des', role: 'COMERCIAL_X' })); eq(r.status, 400); ok(JSON.stringify(r.body).includes('BAD_ROLE'), JSON.stringify(r.body));
});
Deno.test('CA08 un usuario COMERCIAL se puede archivar (sin historial operativo)', async () => {
  const { deps, db } = fakeDeps(); await call(deps, 'tok-adm', { action: 'set_role', user_id: 'des', role: 'COMERCIAL' });
  const r = await read(await call(deps, 'tok-adm', { action: 'archive', user_id: 'des' })); ok(r.status < 300, 'estado ' + r.status + ' ' + JSON.stringify(r.body)); eq(P(db, 'des').status, 'ARCHIVADO');
});
Deno.test('CA09 las reglas existentes NO cambian: transportista sin carrier y superior para no internos siguen rechazándose', async () => {
  const { deps } = fakeDeps(); const a = await read(await call(deps, 'tok-adm', { action: 'create', email: 't@ok.test', full_name: 'T', role: 'TRANSPORTISTA', carriers: [] })); eq(a.status, 400);
  const { validateUserAction } = await import('../_shared/rules.js');
  // el Superior se valida al EDITAR (payload.supervisor_user_id): solo para transportistas internos, también con COMERCIAL
  const adm = { id: 'adm', role: 'ADMIN', status: 'ACTIVO' }, com = { id: 'c1', role: 'COMERCIAL', status: 'ACTIVO', carriers: [] };
  const v = validateUserAction('edit', { actor: adm, target: com, allUsers: [adm, com], payload: { full_name: 'C', email: 'c@ok.test', role: 'COMERCIAL', supervisor_user_id: 'adm' } });
  ok(v && v.code === 'BAD_SUPERVISOR', 'superior solo para internos: ' + JSON.stringify(v));
});
