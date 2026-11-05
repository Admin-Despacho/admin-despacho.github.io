// MATRIZ DE SEGURIDAD de internal-approvals (Deno): las 9 acciones × sesión / perfil ACTIVO / permisos / cron.
// Las dependencias simuladas REGISTRAN cualquier acceso a datos o efectos (almacenes, proveedor, configuración, alertas, auditoría):
// una prueba negativa exige CERO accesos (solo se permite leer la sesión y el perfil).
import { handle } from './handler.js';
const assert = (c, m) => { if (!c) throw new Error(m); };
const ACTIONS = ['send_queued', 'retry', 'send_customer_queued', 'retry_customer', 'send_sheet_emails', 'send_inspection_emails', 'send_service_alerts', 'settings_get', 'settings_set'];
const P = (role, status) => ({ role, status, extra_perms: [], denied_perms: [] });
const PROFILES = { 'adm': P('ADMIN', 'ACTIVO'), 'adm-off': P('ADMIN', 'DESHABILITADO'), 'adm-arch': P('ADMIN', 'ARCHIVADO'), 'adm-inv': P('ADMIN', 'INVITACION_PENDIENTE'),
  'sup-off': P('SUPERVISOR_DESPACHO', 'DESHABILITADO'), 'drv': P('TRANSPORTISTA', 'ACTIVO'), 'ro': P('SOLO_LECTURA', 'ACTIVO') };
const mk = ({ user = null } = {}) => {
  const log = [];
  const rec = name => new Proxy({}, { get: (_, k) => async () => { log.push(name + '.' + String(k)); return []; } });
  return { log, deps: {
    getUserFromJwt: async t => (t === 'valido' && user ? { id: user } : null),
    getProfile: async id => (PROFILES[id] ? { id, ...PROFILES[id] } : null),
    store: rec('store'), customerStore: rec('customerStore'), sheetStore: rec('sheetStore'), inspStore: rec('inspStore'),
    provider: { async send() { log.push('provider.send'); return { id: 'x' }; } },
    getSettings: async () => { log.push('getSettings'); return { extra_emails: [] }; }, setSettings: async () => { log.push('setSettings'); },
    runServiceAlerts: async () => { log.push('runServiceAlerts'); return []; }, queueSheetEmails: async () => { log.push('queueSheetEmails'); },
    sheetVia: async () => { log.push('sheetVia'); return 'RESEND'; }, audit: async () => { log.push('audit'); },
    cronSecret: 'cron-ok', appUrl: 'https://x' } };
};
const call = (deps, action, headers) => handle(new Request('http://x', { method: 'POST', headers: headers || { authorization: 'Bearer valido' },
  body: JSON.stringify({ action, settings: { extra_emails: [] }, job_ids: ['j1'], request_ids: [1] }) }), deps);

Deno.test('SM-01 Administrador NO ACTIVO (DESHABILITADO / ARCHIVADO / INVITACIÓN PENDIENTE): las 9 acciones → 403 genérico y CERO accesos a datos o efectos', async () => {
  for (const u of ['adm-off', 'adm-arch', 'adm-inv', 'sup-off']) for (const a of ACTIONS) {
    const t = mk({ user: u }); const r = await call(t.deps, a); const b = await r.json();
    assert(r.status === 403 && t.log.length === 0, `${u} · ${a}: status ${r.status}, accesos ${t.log.join(',')}`);
    assert(b.error === 'Sin permiso.' && !JSON.stringify(b).match(/DESHABILITADO|ARCHIVADO|INVITACION|adm|sup/), `${u} · ${a}: cuerpo revela datos ${JSON.stringify(b)}`);
  } });
Deno.test('SM-02 acción DESCONOCIDA con usuario deshabilitado → 403 sin efectos (el control es previo a cualquier acción)', async () => {
  const t = mk({ user: 'adm-off' }); const r = await call(t.deps, 'accion_inexistente'); assert(r.status === 403 && t.log.length === 0, 'debía 403 sin efectos'); });
// Solo lectura puede consultar rutas, pero no ejecutar envíos/reintentos, incluso si tiene routes.view_all.
const ALLOWED = { drv: ['send_service_alerts'], ro: ['send_service_alerts'] };
Deno.test('SM-03 usuario ACTIVO con permisos limitados (Transportista, Solo lectura): lo NO permitido → 403 sin efectos; lo permitido toca SOLO su propio circuito', async () => {
  for (const u of ['drv', 'ro']) for (const a of ACTIONS) {
    const t = mk({ user: u }); const r = await call(t.deps, a);
    if (!ALLOWED[u].includes(a)) { assert(r.status === 403 && t.log.length === 0, `${u} · ${a}: status ${r.status}, accesos ${t.log.join(',')}`); continue; }
    const scope = a === 'send_service_alerts' ? /^runServiceAlerts$/ : /^customerStore\./;
    assert(r.status === 200 && t.log.length > 0 && t.log.every(x => scope.test(x)), `${u} · ${a}: ${r.status} accesos fuera de su circuito: ${t.log.join(',')}`);
  } });
Deno.test('SM-04 SIN JWT o JWT INVÁLIDO: las 9 acciones → 401 sin efectos', async () => {
  for (const a of ACTIONS) for (const h of [{}, { authorization: 'Bearer invalido' }, { authorization: 'Basic x' }]) {
    const t = mk({ user: 'adm' }); const r = await call(t.deps, a, h); assert(r.status === 401 && t.log.length === 0, `${a} ${JSON.stringify(h)}: ${r.status} ${t.log.join(',')}`);
  } });
Deno.test('SM-05 CRON: clave incorrecta → 401 sin efectos en las 9 acciones; clave correcta → las alertas de service se ejecutan', async () => {
  for (const a of ACTIONS) { const t = mk(); const r = await call(t.deps, a, { 'x-cron-secret': 'otra' }); assert(r.status === 401 && t.log.length === 0, `${a}: ${r.status} ${t.log.join(',')}`); }
  const t = mk(); const r = await call(t.deps, 'send_service_alerts', { 'x-cron-secret': 'cron-ok' }); assert(r.status === 200 && t.log.join() === 'runServiceAlerts', 'el cron debía ejecutar las alertas'); });
Deno.test('SM-06 USOS LEGÍTIMOS del Administrador ACTIVO: leer y guardar configuración (con auditoría), alertas de service y envío de hojas', async () => {
  let t = mk({ user: 'adm' }); let r = await call(t.deps, 'settings_get'); assert(r.status === 200 && t.log.includes('getSettings'), 'settings_get');
  t = mk({ user: 'adm' }); r = await call(t.deps, 'settings_set'); assert(r.status === 200 && t.log.includes('setSettings') && t.log.includes('audit'), 'settings_set con auditoría');
  t = mk({ user: 'adm' }); r = await call(t.deps, 'send_service_alerts'); assert(r.status === 200 && t.log.includes('runServiceAlerts'), 'alertas');
  t = mk({ user: 'adm' }); r = await call(t.deps, 'send_sheet_emails'); assert(r.status === 200 && t.log.includes('sheetStore.listJobs'), 'hojas: ' + t.log.join(',')); });

Deno.test('SM-07 cron no puede leer ni modificar configuración; Solo lectura no puede enviar ni reintentar correos', async () => {
  for (const action of ['settings_get', 'settings_set']) {
    const t = mk(); const r = await call(t.deps, action, { 'x-cron-secret': 'cron-ok' });
    assert(r.status === 403 && t.log.length === 0, `cron ${action} debía 403 sin efectos: ${r.status} ${t.log.join(',')}`);
  }
  for (const action of ['send_customer_queued', 'retry_customer']) {
    const t = mk({ user: 'ro' }); const r = await call(t.deps, action);
    assert(r.status === 403 && t.log.length === 0, `Solo lectura ${action} debía 403 sin efectos: ${r.status} ${t.log.join(',')}`);
  }
});
