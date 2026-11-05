// V4.25 · send_inspection_emails (Deno) · seguridad: SOLO Superior Despacho ACTIVO; deshabilitados / sin permiso / sin sesión → sin ningún efecto.
// El entorno simulado REGISTRA cada acceso (consultas al almacén, envíos al proveedor, actualizaciones) para probar la ausencia de efectos.
import { handle } from './handler.js';
import { inspectionGmailSender } from './inspection-gmail.js';
const assert = (c, m) => { if (!c) throw new Error(m); };
const PROFILES = {
  'u-sup1': { role: 'SUPERVISOR_DESPACHO', status: 'ACTIVO' }, 'u-sup2': { role: 'SUPERVISOR_DESPACHO', status: 'ACTIVO' },
  'u-supoff': { role: 'SUPERVISOR_DESPACHO', status: 'DESHABILITADO' }, 'u-op1': { role: 'OPERARIO_DEPOSITO', status: 'ACTIVO' },
  'u-opoff': { role: 'OPERARIO_DEPOSITO', status: 'DESHABILITADO' }, 'u-admin': { role: 'ADMIN', status: 'ACTIVO' },
  'u-drv': { role: 'TRANSPORTISTA', status: 'ACTIVO' }, 'u-ro': { role: 'SOLO_LECTURA', status: 'ACTIVO' } };
const REQS = () => [
  { id: 1, requested_by: 'u-sup1', recipients: ['a@ok.test', 'b@ok.test'], subject: 'S1', body: 'Cuerpo <1>', status: 'PENDIENTE_ENVIO', retry_count: 0 },
  { id: 2, requested_by: 'u-sup2', recipients: ['c@ok.test'], subject: 'S2', body: 'x', status: 'PENDIENTE_ENVIO', retry_count: 0 },
  { id: 3, requested_by: 'u-supoff', recipients: ['d@ok.test'], subject: 'S3', body: 'y', status: 'PENDIENTE_ENVIO', retry_count: 0 }];
// user: id del JWT (null = sin JWT válido); storeLeaks: el almacén devuelve TODO sin filtrar (simula un error del almacén)
const mk = ({ user, fail = false, storeLeaks = false } = {}) => {
  const log = { pending: 0, sent: [], upd: [] }; const reqs = REQS();
  const result = { log, deps: {
    getUserFromJwt: async () => (user ? { id: user } : null),
    getProfile: async id => (PROFILES[id] ? { id, ...PROFILES[id], extra_perms: [], denied_perms: [] } : null),
    inspStore: { async pending(by, ids) { log.pending++; return reqs.filter(r => (storeLeaks || !by || r.requested_by === by) && (!ids || ids.includes(r.id))); },
                 async update(id, p) { log.upd.push([id, p]); } },
    provider: { async send(m) { if (fail) throw new Error('proveedor caído'); log.sent.push(m); return { id: 'p' + log.sent.length }; } },
    cronSecret: 'cron-ok', audit: async () => null } };
  result.deps.sendInspectionGmail = inspectionGmailSender({
    claim:async()=>true, authorized:async()=>true, audit:async()=>{},
    finish:async(j,lock,p)=>result.deps.inspStore.update(j.id,p),
    gmailStore:{gmailStatus:async()=>({connected:true,email:'sender@ok.test'}),acquireRate:async()=>({wait_ms:0})},
    provider:{prepare:async()=>{if(fail)throw Error('proveedor caído');return 'token';},
      post:async raw=>{log.sent.push(raw);return {id:'gmail-qa'};},interpret:r=>r}
  });
  return result;
};
const call = (deps, body, headers = { authorization: 'Bearer t' }) => handle(new Request('http://x', { method: 'POST', headers, body: JSON.stringify(body) }), deps);
const noEffects = log => log.pending === 0 && log.sent.length === 0 && log.upd.length === 0;

Deno.test('IE-01 el OPERARIO no puede enviar emails de inspecciones (403, sin ningún efecto)', async () => {
  const t = mk({ user: 'u-op1' }); const r = await call(t.deps, { action: 'send_inspection_emails', request_ids: [1] }); assert(r.status === 403 && noEffects(t.log), 'debía 403 sin efectos'); });
Deno.test('IE-02 el Superior ACTIVO envía SOLO su pedido: un envío por destinatario, Gmail aislado, estado ENVIADO', async () => {
  const t = mk({ user: 'u-sup1' }); const r = await call(t.deps, { action: 'send_inspection_emails', request_ids: [1, 2] }); const j = await r.json();
  assert(r.status === 200 && t.log.sent.length === 2 && t.log.sent.every(m => atob(m.replace(/-/g,'+').replace(/_/g,'/')).includes('Subject: S1')), 'solo el pedido 1 a sus 2 destinatarios');
  assert(j.results.length === 1 && j.results[0].status === 'ENVIADO' && t.log.upd[0][1].status === 'ENVIADO', 'estado'); });
Deno.test('IE-03 falla del proveedor → ERROR con retry_count + 1 (queda para reintentar)', async () => {
  const t = mk({ user: 'u-sup1', fail: true }); const j = await (await call(t.deps, { action: 'send_inspection_emails', request_ids: [1] })).json();
  assert(j.results[0].status === 'ERROR' && t.log.upd[0][1].status === 'ERROR' && t.log.upd[0][1].retry_count === 1, 'debía quedar ERROR'); });
Deno.test('IE-04 Superior Despacho DESHABILITADO → 403 genérico: NO consulta pedidos, NO llama al proveedor, NO actualiza estados, NO revela datos', async () => {
  const t = mk({ user: 'u-supoff' }); const r = await call(t.deps, { action: 'send_inspection_emails', request_ids: [3] }); const b = await r.json();
  assert(r.status === 403 && noEffects(t.log), 'debía 403 sin ningún efecto: ' + JSON.stringify(t.log));
  // no revela nada: respuesta IDÉNTICA a la de cualquier usuario sin permiso (403 estándar del sistema), sin pedidos, destinatarios ni datos del perfil
  const o = mk({ user: 'u-op1' }); const ro = await call(o.deps, { action: 'send_inspection_emails', request_ids: [3] }); const bo = await ro.json();
  assert(JSON.stringify(b) === JSON.stringify(bo) && !/d@ok\.test|S3|DESHABILITADO|u-supoff|request/i.test(JSON.stringify(b)), 'el cuerpo no debe revelar nada: ' + JSON.stringify(b) + ' vs ' + JSON.stringify(bo)); });
Deno.test('IE-05 SIN PERMISO (Administrador, Transportista, Solo lectura, Operario deshabilitado) → 403 sin ningún efecto', async () => {
  for (const u of ['u-admin', 'u-drv', 'u-ro', 'u-opoff']) { const t = mk({ user: u }); const r = await call(t.deps, { action: 'send_inspection_emails', request_ids: [1, 2, 3] });
    assert(r.status === 403 && noEffects(t.log), u + ': debía 403 sin efectos'); } });
Deno.test('IE-06 ENTRE EQUIPOS: el Superior 1 pide pedidos del Superior 2; aunque el almacén los devolviera, no se envían ni se modifican', async () => {
  const t = mk({ user: 'u-sup1', storeLeaks: true }); const j = await (await call(t.deps, { action: 'send_inspection_emails', request_ids: [2, 3] })).json();
  assert(t.log.sent.length === 0 && t.log.upd.length === 0 && j.results.length === 0, 'no debía enviar pedidos ajenos: ' + JSON.stringify(t.log)); });
Deno.test('IE-07 CRON: el pedido de un Superior hoy DESHABILITADO queda intacto (sin enviar ni actualizar); el de un Superior ACTIVO se envía', async () => {
  const t = mk({}); const j = await (await call(t.deps, { action: 'send_inspection_emails' }, { 'x-cron-secret': 'cron-ok' })).json();
  const sentSubjects = t.log.sent.map(m => atob(m.replace(/-/g,'+').replace(/_/g,'/')).match(/Subject: ([^\r]+)/)[1]), updIds = t.log.upd.map(u => u[0]);
  assert(!sentSubjects.includes('S3') && !updIds.includes(3), 'el pedido 3 (deshabilitado) no debía tocarse');
  assert(sentSubjects.includes('S1') && sentSubjects.includes('S2') && j.results.every(x => x.status === 'ENVIADO'), 'los pedidos de Superiores activos se envían'); });
Deno.test('IE-08 SIN JWT o JWT INVÁLIDO → 401 sin acceso al almacén ni al proveedor; cron con clave incorrecta → 401', async () => {
  const a = mk({ user: null }); const r1 = await call(a.deps, { action: 'send_inspection_emails' }, {}); assert(r1.status === 401 && noEffects(a.log), 'sin JWT');
  const b = mk({ user: null }); const r2 = await call(b.deps, { action: 'send_inspection_emails' }, { authorization: 'Bearer invalido' }); assert(r2.status === 401 && noEffects(b.log), 'JWT inválido');
  const c = mk({}); const r3 = await call(c.deps, { action: 'send_inspection_emails' }, { 'x-cron-secret': 'otra' }); assert(r3.status === 401 && noEffects(c.log), 'cron con clave incorrecta'); });
