// SOLO PRUEBAS LOCALES · CORREOS DE AUTORIZACIONES V2 (20261202000100_correo_autorizaciones_v2.sql).
// PostgreSQL local con la base equivalente a producción (módulo comercial 000100-001300 + PANEL_SOLO + INSTALL del correo).
// Ejecuta las FUNCIONES REALES (com_create_request, com_decide, com_respond, triggers, toma, guard, finish, ledger SMTP), el
// TRABAJADOR REAL V2 y —para reversión— el TRABAJADOR PUBLICADO (2a8e65b), contra un SERVIDOR SMTP SIMULADO en memoria (STARTTLS).
// Sin red ni envíos reales. Datos 100 % sintéticos (dominio .invalid).
// Uso: node QA/run_correo_autorizaciones.mjs  (PostgreSQL en 127.0.0.1:55447 con la plantilla okd_base; ver README)
import pg from './tooling/node_modules/pg/lib/index.js';   // npm --prefix QA/tooling install pg@8
import {readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {execSync} from 'node:child_process';
import {sendCommercialDecisionEmails} from '../supabase/functions/_shared/commercial-decision-mail.js';
const ROOT = new URL('..', import.meta.url).pathname, CFG = {host: '127.0.0.1', port: 55447, user: 'postgres'};
const MIG = readFileSync(ROOT + 'propuestas/correo_autorizaciones/20261202000100_correo_autorizaciones_v2.sql', 'utf8');
const REV = readFileSync(ROOT + 'propuestas/correo_autorizaciones/REVERSION_CORREO_AUTORIZACIONES_V2.sql', 'utf8');
// trabajador PUBLICADO (commit base) para probar la convivencia tras una reversión
const OLD = '/tmp/okd_worker_publicado/'; mkdirSync(OLD + '_shared', {recursive: true});
for (const f of ['commercial-decision-mail.js', 'corporate-mail.js', 'smtp-transport.js']) writeFileSync(OLD + '_shared/' + f, execSync('git -C ' + ROOT + ' show 2a8e65b:supabase/functions/_shared/' + f));
const {sendCommercialDecisionEmails: oldWorker} = await import(OLD + '_shared/commercial-decision-mail.js');

const results = []; const ok = (name, cond, detail = '') => { results.push({name, ok: !!cond, detail: String(detail).slice(0, 400)}); };
const U = {C: 'c1000000-0000-4000-8000-0000000000c1', A: 'a1000000-0000-4000-8000-0000000000a1', G: 'a2000000-0000-4000-8000-0000000000a2', C2: 'c2000000-0000-4000-8000-0000000000c2', C3: 'c3000000-0000-4000-8000-0000000000c3'};
const S = Object.fromEntries(Object.entries(U).map(([k, v]) => [k, 'd' + v.slice(1)]));
const COPIES = ['copia1@qa.invalid', 'copia2@qa.invalid', 'copia3@qa.invalid', 'copia4@qa.invalid', 'copia5@qa.invalid'];
const SCOPE = 'DETALLE_COMERCIAL_COMPLETO_CC_VISIBLE';

// ---------- servidor SMTP simulado (STARTTLS): registra sobre (RCPT) y mensaje ----------
function smtpServer() {
  const delivered = [], rules = {};   // rules[to] = {rcpt:550|451, lostAfterData:true}
  const connect = async () => {
    let buf = '220 qa.invalid ESMTP\r\n', tls = false, data = false, to = null, closed = false;
    return {
      async read(b) { if (closed) return null; if (!buf) return new Promise(() => {}); const n = Math.min(b.length, buf.length); b.set(new TextEncoder().encode(buf.slice(0, n))); buf = buf.slice(n); return n; },
      async write(bytes) {
        const t = new TextDecoder().decode(bytes);
        if (data) { const r = rules[to] || {}; data = false; delivered.push({to, raw: t, lost: !!r.lostAfterData}); if (r.lostAfterData) { closed = true; throw Error('connection lost'); } buf += '250 OK id=QA' + delivered.length + '\r\n'; return bytes.length; }
        if (t.startsWith('EHLO')) buf += tls ? '250-qa\r\n250 AUTH PLAIN LOGIN\r\n' : '250-qa\r\n250-STARTTLS\r\n250 SIZE 1000000\r\n';
        else if (t === 'STARTTLS\r\n') buf += '220 go\r\n';
        else if (t.startsWith('AUTH PLAIN')) buf += '235 ok\r\n';
        else if (t.startsWith('MAIL FROM')) buf += '250 ok\r\n';
        else if (t.startsWith('RCPT TO')) { if (to !== null) throw Error('SEGUNDO_RCPT_NO_PERMITIDO'); to = /<([^>]+)>/.exec(t)[1]; buf += ((rules[to] || {}).rcpt || 250) + ' rcpt\r\n'; }
        else if (t === 'DATA\r\n') { buf += '354 go\r\n'; data = true; }
        return bytes.length;
      },
      close() { closed = true; }, startTlsNow() { tls = true; },
    };
  };
  return {delivered, rules, opts: {connect, startTls: async c => { c.startTlsNow(); return c; }}};
}
const hdr = (raw, h) => { const head = raw.split('\r\n\r\n')[0].replace(/\r\n[ \t]+/g, ' '); const m = new RegExp('^' + h + ': (.*)$', 'mi').exec(head); return m ? m[1] : null; };
const addrs = v => v ? [...v.matchAll(/<([^>]+)>/g)].map(m => m[1]) : [];
const decodeHtml = raw => { const m = /Content-Type: text\/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n([\s\S]*?)\r\n--/.exec(raw); return m ? Buffer.from(m[1].replace(/\r\n/g, ''), 'base64').toString('utf8') : ''; };
const decodeSubject = raw => { const m = /^Subject: =\?UTF-8\?B\?([^?]+)\?=/m.exec(raw); return m ? Buffer.from(m[1], 'base64').toString('utf8') : ''; };

// ---------- adaptador tipo PostgREST (cada RPC = una sentencia autocommit, como service_role) ----------
function sbFor(pool, hooks = {}) {
  return {rpc: async (name, args = {}) => {
    if (hooks[name]) { const h = hooks[name](args); if (h) return h; }
    const keys = Object.keys(args), call = 'public.' + name + '(' + keys.map((k, i) => k + ' => $' + (i + 1)).join(',') + ')';
    const setof = name === 'comm_decision_mail_claim';   // función SETOF de la versión publicada (PostgREST devuelve un arreglo de filas)
    try { const r = await pool.query(setof ? 'select * from ' + call : 'select ' + call + ' as r', keys.map(k => args[k])); return {data: setof ? r.rows : (r.rows[0].r === '' ? null : r.rows[0].r)}; } catch (e) { return {error: {message: e.message}}; }
  }};
}
async function newDb(name) { const a = new pg.Client({...CFG, database: 'postgres'}); await a.connect(); await a.query('drop database if exists ' + name + ' with (force)'); await a.query('create database ' + name + ' template okd_base'); await a.end(); return {...CFG, database: name}; }
async function asUserOn(c, who, sql, params = []) {
  await c.query('begin');
  try {
    await c.query("select set_config('request.jwt.claims', $1, true), set_config('request.jwt.claim.sub', $2, true), set_config('request.jwt.claim.role','authenticated', true)",
      [JSON.stringify({sub: U[who], role: 'authenticated', session_id: S[who], iat: Math.floor(Date.now() / 1000) + 60}), U[who]]);
    const r = await c.query(sql, params); await c.query('commit'); return r.rows[0] ? Object.values(r.rows[0])[0] : null;
  } catch (e) { await c.query('rollback'); throw e; }
}
let c0, c1, pool, pool2;
const asUser = (who, sql, p) => asUserOn(c0, who, sql, p);
const q1 = async (sql, p = []) => { const r = await c0.query(sql, p); return r.rows[0] ? Object.values(r.rows[0])[0] : null; };
const outbox = async (where = 'true', p = []) => (await c0.query('select * from public.com_decision_mail_outbox where ' + where + ' order by id', p)).rows;
const client = async () => (await c0.query("select id from public.com_clients where erp_id='QA-1'")).rows[0].id;
const today = () => new Date(Date.now() - 3 * 3600e3).toISOString().slice(0, 10), plus = n => new Date(Date.parse(today()) + n * 864e5).toISOString().slice(0, 10);
const fin = (amount, k, freq, first = plus(7)) => ({amount, installments: k, ...(k > 1 ? {frequency: freq} : {}), first_due: first});
let opn = 0;
const create = async (who, kind, terms, notes = 'Observación del comercial QA', order = 'PV 17-000125', op = 'op-' + (++opn)) =>
  asUser(who, 'select public.com_create_request($1,$2,$3,$4,$5,$6)', [kind, await client(), order, JSON.stringify(terms), notes, op]);
const ver = async id => (await c0.query('select version from public.com_requests where id=$1', [id])).rows[0].version;
const decide = async (who, id, d, terms = null, reason = null) => asUser(who, 'select public.com_decide($1,$2,$3,$4,$5)', [id, await ver(id), d, terms && JSON.stringify(terms), reason]);
const respond = async (id, accept, comment) => asUser('C', 'select public.com_respond($1,$2,$3,$4)', [id, await ver(id), accept, comment]);
const tryErr = async f => { try { await f(); return 'OK'; } catch (e) { return e.message; } };
const ledgerAccepted = async () => q1("select count(*)::int from public.comm_smtp_ledger where state='ACCEPTED' and op_key like 'decisiones:%'");

try {
  const db = await newDb('qa_mail_v2');
  c0 = new pg.Client(db); await c0.connect(); c1 = new pg.Client(db); await c1.connect();
  pool = new pg.Pool({...db, max: 4}); pool2 = new pg.Pool({...db, max: 4});
  // ===== estado PREVIO (como producción hoy): usuarios, SMTP activo, 5 copias configuradas con la función publicada =====
  await c0.query(`select set_config('okd.sync','on',false);
    insert into auth.users(id,email) values ('${U.C}','comercial@qa.invalid'),('${U.A}','aprobador@qa.invalid'),('${U.G}','admin@qa.invalid'),('${U.C2}','COPIA1@qa.invalid'),('${U.C3}','Aprobador@QA.invalid');
    insert into public.profiles(id,email,full_name,role,status) values ('${U.C}','comercial@qa.invalid','Asesor Comercial QA','COMERCIAL','ACTIVO'),('${U.A}','aprobador@qa.invalid','Tesorería QA','ADMIN','ACTIVO'),
      ('${U.G}','admin@qa.invalid','Administración General QA','ADMIN','ACTIVO'),('${U.C2}','COPIA1@qa.invalid','Comercial Dos QA','COMERCIAL','ACTIVO'),('${U.C3}','Aprobador@QA.invalid','Comercial Tres QA','COMERCIAL','ACTIVO');
    insert into auth.sessions(id,user_id,not_after) select ('d'||substr(id::text,2))::uuid,id,now()+interval '1 day' from public.profiles where id in ('${U.C}','${U.A}','${U.G}','${U.C2}','${U.C3}');
    insert into public.com_user_assignments(user_id,channel,branch,cartera_label) values ('${U.C}','SUCURSAL','SAN_JUAN',null),('${U.C2}','CARTERA',null,'Cartera Hernán'),('${U.C3}','SUCURSAL','SAN_JUAN',null);
    insert into public.com_routing(channel_key,approver_user_id) values ('SUCURSAL:SAN_JUAN','${U.A}'),('CARTERA','${U.A}') on conflict (channel_key) do update set approver_user_id=excluded.approver_user_id;
    insert into public.com_clients(erp_id,razon_social,doc_type,doc_number,cuit,search_text,status) values ('QA-1','Tecnología del Norte S.A.','CUIT','30712345679','30712345679','TECNOLOGIA DEL NORTE','ACTIVO');
    select vault.create_secret('SMTP-TEST-ONLY-NOT-A-REAL-PASSWORD','comm_smtp_password');
    select public.comm_mail_register(x) from unnest(array['comm-dispatcher','internal-approvals','commercial-reports','password-recovery']) x;
    select public.comm_smtp_probe_result(true,(select updated_at from vault.secrets where name='comm_smtp_password'));
    select public.comm_mail_set_provider('SMTP',100,true);`);
  await asUser('G', 'select public.com_mail_settings_set($1)', [COPIES]);
  // aviso en curso de la versión publicada (como las copias de AUT-000004): una decisión antes de instalar la V2
  const r0 = await create('C', 'FINANCIACION', fin(100000, 1)); await decide('A', r0.id, 'APROBAR');
  ok('PRE-01 versión publicada: aviso pendiente al autor + 5 copias antes de instalar', (await outbox('request_id=$1', [r0.id])).length === 6);

  // ===== INSTALACIÓN =====
  await c0.query(MIG); ok('IN-01 la V2 se instala en una transacción (huellas de producción OK)', true);
  const re = await tryErr(() => c0.query(MIG)); await c0.query('rollback').catch(() => {});
  ok('IN-02 reaplicar se detiene sin cambios (YA_APLICADA)', /YA_APLICADA/.test(re), re);
  ok('IN-03 límite horario intacto (100) y cupo diario 850', (await q1("select hourly_cap||'/'||daily_cap from public.comm_mail_transport")) === '100/850');
  ok('P09-01 copias existentes NO se eliminan: quedan PENDIENTES DE RATIFICACIÓN', (await q1("select count(*)::int from public.com_mail_copy_authorizations where status='PENDIENTE_RATIFICACION'")) === 5
    && JSON.stringify(await q1('select copies from public.com_mail_settings')) === JSON.stringify(COPIES));
  const sb = sbFor(pool), sb2 = sbFor(pool2);
  let smtp = smtpServer();
  // Entre escenarios se «deja pasar el tiempo» del cupo (salvo en las pruebas de límites, que lo controlan explícitamente)
  const run = async (s = sb, opts = {}) => { if (!opts.keepQuota) await c0.query("update public.comm_smtp_rate set at = now() - interval '30 hours' where at > now() - interval '24 hours'"); return sendCommercialDecisionEmails(s, {...smtp.opts, ...opts}); };
  const runAll = async () => { let r, n = 0; do { r = await run(); n++; } while (r.stop === null && n < 10); return r; };   // ciclos sucesivos (máx. 20 por ciclo)
  // aviso pendiente de la versión publicada: autor sí; copias sin ratificar NO
  let s0 = await run(); let rows = await outbox('request_id=$1', [r0.id]);
  ok('P09-02 aviso previo a la V2: el autor recibe; las 5 copias sin ratificar NO (SKIPPED COPY_NOT_RATIFIED)', rows.filter(r => r.kind === 'COPY').every(r => r.state === 'SKIPPED' && r.error_code === 'COPY_NOT_RATIFIED')
    && rows.find(r => r.kind === 'AUTHOR').state === 'SENT' && smtp.delivered.length === 1, JSON.stringify(s0));

  // ===== 9 · nueva solicitud con copias sin ratificar: aprobador + solicitante igual reciben =====
  smtp = smtpServer();
  const n1 = await create('C', 'FINANCIACION', fin(600000, 3, 'SEMANAL'));
  rows = await outbox('request_id=$1', [n1.id]);
  ok('P09-03 copias sin ratificar no bloquean: nueva solicitud → aprobador + solicitante, sin copias', rows.length === 2 && rows[0].kind === 'APPROVER' && rows[1].kind === 'AUTHOR', rows.map(r => r.kind + ':' + r.recipient).join(','));
  await run();
  const d9 = smtp.delivered[0];
  ok('P09-04 sin copias autorizadas el mensaje no lleva CC', smtp.delivered.length === 2 && hdr(d9.raw, 'Cc') === null && JSON.stringify(addrs(hdr(d9.raw, 'To'))) === JSON.stringify(['aprobador@qa.invalid', 'comercial@qa.invalid']));

  // ===== 11 · eludir la autorización desde RPC =====
  let e11 = await tryErr(() => asUser('G', 'select public.com_mail_copy_authorize($1,$2,$3)', [['x@qa.invalid'], SCOPE, false]));
  let e11b = await tryErr(() => asUser('G', 'select public.com_mail_copy_authorize($1,$2,$3)', [['x@qa.invalid'], 'OTRO_ALCANCE', true]));
  let e11c = await tryErr(() => asUser('C', 'select public.com_mail_copy_authorize($1,$2,$3)', [['x@qa.invalid'], SCOPE, true]));
  await asUser('G', 'select public.com_mail_settings_set($1)', [[...COPIES, 'intruso@qa.invalid']]);
  const e11d = await tryErr(async () => { await c0.query('begin'); try { await c0.query('set local role authenticated'); await c0.query("insert into public.com_mail_copy_authorizations(address,status,scope,visible_cc,authorized_by,authorized_at) values ('y@qa.invalid','AUTORIZADA','x',true,$1,now())", [U.G]); } finally { await c0.query('rollback'); } });
  const e11e = await tryErr(async () => { await c0.query('begin'); try { await c0.query('set local role anon'); await c0.query("select public.com_mail_copy_authorize(array['y@qa.invalid'],$1,true)", [SCOPE]); } finally { await c0.query('rollback'); } });
  ok('P11-01 sin confirmación → AUTHORIZATION_CONFIRMATION_REQUIRED', /AUTHORIZATION_CONFIRMATION_REQUIRED/.test(e11), e11);
  ok('P11-02 alcance distinto → rechazado', /AUTHORIZATION_CONFIRMATION_REQUIRED/.test(e11b), e11b);
  ok('P11-03 un Comercial no puede autorizar → FORBIDDEN', /FORBIDDEN/.test(e11c), e11c);
  ok('P11-04 la función publicada de guardado solo deja PENDIENTE (no autoriza)', (await q1("select status from public.com_mail_copy_authorizations where address='intruso@qa.invalid'")) === 'PENDIENTE_RATIFICACION');
  ok('P11-05 escritura directa a la tabla de autorizaciones como usuario → permission denied; anon no puede ejecutar la RPC', /permission denied for table/.test(e11d) && /permission denied for function/.test(e11e), e11d + ' | ' + e11e);
  await asUser('G', 'select public.com_mail_settings_set($1)', [COPIES]);
  ok('P11-06 quitar por la función publicada → REVOCADA y registrado', (await q1("select status from public.com_mail_copy_authorizations where address='intruso@qa.invalid'")) === 'REVOCADA');

  // ===== 10 · ratificación y revocación =====
  await asUser('G', 'select public.com_mail_copy_authorize($1,$2,$3)', [COPIES.slice(0, 3), SCOPE, true]);   // ratificación individual/parcial
  await asUser('G', 'select public.com_mail_copy_authorize($1,$2,$3)', [COPIES, SCOPE, true]);              // conjunta (las ya autorizadas no se duplican)
  const auth = (await c0.query("select * from public.com_mail_copy_authorizations where address = any($1)", [COPIES])).rows;
  ok('P10-01 ratificación: quién (usuario), cuándo, dirección y alcance registrados', auth.every(a => a.status === 'AUTORIZADA' && a.authorized_by === U.G && a.authorized_at && a.scope === SCOPE && a.visible_cc));
  ok('P10-02 bitácora: una RATIFICADA por dirección (sin duplicar)', (await q1("select count(*)::int from public.com_mail_copy_authorization_log where action='RATIFICADA'")) === 5);
  await asUser('G', 'select public.com_mail_copy_revoke($1)', [['copia5@qa.invalid']]);
  ok('P10-03 revocación registrada (usuario, fecha) y efectiva en la lista', (await q1("select status||'|'||(revoked_by='" + U.G + "') from public.com_mail_copy_authorizations where address='copia5@qa.invalid'")) === 'REVOCADA|true'
    && !(await q1('select copies from public.com_mail_settings')).includes('copia5@qa.invalid'));
  await asUser('G', 'select public.com_mail_copy_authorize($1,$2,$3)', [['copia5@qa.invalid'], SCOPE, true]);
  ok('P10-04 reautorización registrada', (await q1("select count(*)::int from public.com_mail_copy_authorization_log where address='copia5@qa.invalid' and action='REAUTORIZADA'")) === 1);
  ok('P10-05 bitácora inmutable', /IMMUTABLE/.test(await tryErr(() => c0.query('delete from public.com_mail_copy_authorization_log'))));

  // ===== 1 · 5 · 6 · nueva solicitud de financiación con aprobador + solicitante + 5 copias =====
  smtp = smtpServer();
  const n2 = await create('C', 'FINANCIACION', fin(600000, 3, 'SEMANAL'));
  rows = await outbox('request_id=$1', [n2.id]);
  ok('P05-01 registro confirmado → notificación automática encolada en la MISMA transacción (7 destinatarios)', rows.length === 7, rows.length);
  ok('P05-02 foto del evento + distribución guardadas al registrar (source EVENTO)', (await q1("select source||'|'||jsonb_array_length(payload->'distribution'->'to')||'|'||jsonb_array_length(payload->'distribution'->'cc') from public.com_decision_mail_payloads where event_id=$1", [rows[0].event_id])) === 'EVENTO|2|5');
  let s6 = await run();
  const raws = smtp.delivered.map(d => d.raw);
  ok('P06-01 los 7 destinatarios en el MISMO ciclo', s6.sent === 7 && smtp.delivered.length === 7, JSON.stringify(s6));
  ok('P06-02 un único mensaje: Para = aprobador + solicitante; CC = 5 copias autorizadas; sin CCO', new Set(raws).size === 1 && JSON.stringify(addrs(hdr(raws[0], 'To'))) === JSON.stringify(['aprobador@qa.invalid', 'comercial@qa.invalid'])
    && JSON.stringify(addrs(hdr(raws[0], 'Cc'))) === JSON.stringify(COPIES) && hdr(raws[0], 'Bcc') === null);
  ok('P06-03 un RCPT por transacción (sobre) y cada destinatario una sola vez', JSON.stringify(smtp.delivered.map(d => d.to).sort()) === JSON.stringify(['aprobador@qa.invalid', 'comercial@qa.invalid', ...COPIES].sort()));
  const h1 = decodeHtml(raws[0]);
  ok('P01-01 asunto y diseño de NUEVA SOLICITUD', decodeSubject(raws[0]) === 'NUEVA SOLICITUD COMERCIAL | ' + n2.number + ' | Tecnología del Norte S.A.' && ['#102631', '#56dce9', '#fff2d9', '#925400', 'Pendiente de aprobación · ' + n2.number, 'PENDIENTE DE APROBACIÓN', 'Esta solicitud todavía no se encuentra autorizada.'].every(x => h1.includes(x)));
  ok('P01-02 detalle completo registrado (financiación: cuotas, frecuencia, 1.er vencimiento, límite, calendario, total, observaciones)', ['Frecuencia', 'Semanal', 'Primer vencimiento', 'Fecha límite', 'Calendario de pagos solicitado', '$ 200.000,00', '$ 600.000,00', 'Observación del comercial QA', 'Tesorería QA — Administrador General', 'San Juan', '30712345679'].every(x => h1.includes(x)));
  ok('P06-04 remitente certificado sin cambios', raws.every(r => /^From: =\?UTF-8\?B\?[^?]+\?= <fgutierrez@okaccesorios\.com>/m.test(r)));
  const s6b = await run(); ok('P06-05 segundo ciclo: nada se reenvía', s6b.sent === 0 && smtp.delivered.length === 7);

  // ===== 2 · e-cheq (autor con correo igual a una copia, en mayúsculas) =====
  smtp = smtpServer();
  const n3 = await asUser('C2', 'select public.com_create_request($1,$2,$3,$4,$5,$6)', ['ECHEQ', await client(), 'PV-ECHEQ-1', JSON.stringify({amount: 1250000.5, due_date: plus(20), issuer_name: 'Distribuidora Andina SRL', issuer_cuit: '30500010912'}), null, 'op-echeq']);
  await run(); const h2 = decodeHtml(smtp.delivered[0].raw);
  ok('P02-01 e-cheq: aviso de nueva solicitud con sus campos propios', ['Aceptación de e-cheq', '$ 1.250.000,50', 'Distribuidora Andina SRL', '30500010912', 'Cartera Hernán', 'NUEVA SOLICITUD COMERCIAL'].every(x => h2.includes(x)) && !h2.includes('Calendario de pagos'));
  ok('P02-02 solicitante igual a una copia → figura solo en Para, entregado una vez', addrs(hdr(smtp.delivered[0].raw, 'To')).includes('copia1@qa.invalid') && !addrs(hdr(smtp.delivered[0].raw, 'Cc')).includes('copia1@qa.invalid') && smtp.delivered.filter(d => d.to === 'copia1@qa.invalid').length === 1);

  // ===== 3 · 4 · borrador / operación no finalizada / validación fallida → sin correo =====
  const before34 = await q1('select count(*)::int from public.com_decision_mail_outbox');
  await c0.query('begin'); await c0.query("select set_config('request.jwt.claims',$1,true)", [JSON.stringify({sub: U.C, role: 'authenticated', session_id: S.C})]);
  await c0.query('select public.com_create_request($1,$2,$3,$4,$5,$6)', ['FINANCIACION', await client(), 'BORRADOR', JSON.stringify(fin(1000, 1)), null, 'op-borrador']); await c0.query('rollback');
  ok('P03-01 operación no finalizada (transacción no confirmada: borrador / cambios sin enviar) → ningún correo ni foto', (await q1('select count(*)::int from public.com_decision_mail_outbox')) === before34 && (await q1("select count(*)::int from public.com_requests where order_ref='BORRADOR'")) === 0);
  const e4 = await tryErr(() => create('C', 'FINANCIACION', {amount: -5, installments: 1, first_due: plus(5)}));
  const e4b = await tryErr(() => create('C', 'FINANCIACION', fin(1000, 3, 'MENSUAL', plus(20))));
  ok('P04-01 rechazadas por validación del servidor (importe, calendario) → ningún correo', /BAD_AMOUNT/.test(e4) && /BAD_SCHEDULE/.test(e4b) && (await q1('select count(*)::int from public.com_decision_mail_outbox')) === before34, e4 + ' | ' + e4b);

  // ===== 7 · 8 · solicitante = aprobador (mayúsculas) · aprobador también copia =====
  smtp = smtpServer();
  const n7 = await create('C3', 'FINANCIACION', fin(70000, 1));
  rows = await outbox('request_id=$1', [n7.id]);
  ok('P07-01 solicitante y aprobador con el mismo correo (normalizado) → un solo destinatario', rows.filter(r => r.recipient === 'aprobador@qa.invalid').length === 1 && rows.filter(r => r.kind !== 'COPY').length === 1, rows.map(r => r.kind + ':' + r.recipient).join(','));
  await run(); ok('P07-02 entregado una sola vez', smtp.delivered.filter(d => d.to === 'aprobador@qa.invalid').length === 1);
  await asUser('G', 'select public.com_mail_copy_authorize($1,$2,$3)', [['Aprobador@qa.invalid'], SCOPE, true]);
  smtp = smtpServer(); const n8 = await create('C', 'FINANCIACION', fin(71000, 1)); rows = await outbox('request_id=$1', [n8.id]);
  ok('P08-01 aprobador también autorizado como copia → solo en Para, sin fila de copia', rows.filter(r => r.recipient === 'aprobador@qa.invalid').length === 1 && rows.find(r => r.recipient === 'aprobador@qa.invalid').kind === 'APPROVER');
  await run(); ok('P08-02 entregado una vez, CC sin el aprobador', smtp.delivered.filter(d => d.to === 'aprobador@qa.invalid').length === 1 && !addrs(hdr(smtp.delivered[0].raw, 'Cc')).includes('aprobador@qa.invalid'));
  await asUser('G', 'select public.com_mail_copy_revoke($1)', [['aprobador@qa.invalid']]);

  // ===== 12 · 13 · doble clic / concurrencia / respuesta perdida tras el registro =====
  const before12 = await q1('select count(*)::int from public.com_decision_mail_outbox');
  const args = async () => ['FINANCIACION', await client(), 'PV-DOBLE', JSON.stringify(fin(50000, 1)), null, 'op-doble-clic'];
  const a12 = await args(), [x1, x2] = await Promise.all([asUserOn(c0, 'C', 'select public.com_create_request($1,$2,$3,$4,$5,$6)', a12), asUserOn(c1, 'C', 'select public.com_create_request($1,$2,$3,$4,$5,$6)', a12)]);
  ok('P12-01 doble clic concurrente (mismo identificador) → UNA solicitud y UN aviso', x1.id === x2.id && [x1.repeated, x2.repeated].filter(Boolean).length === 1 && (await q1("select count(*)::int from public.com_requests where order_ref='PV-DOBLE'")) === 1
    && (await q1('select count(*)::int from public.com_decision_mail_outbox')) - before12 === 7, JSON.stringify([x1.repeated, x2.repeated]));
  const x3 = await asUser('C', 'select public.com_create_request($1,$2,$3,$4,$5,$6)', a12);
  ok('P13-01 respuesta perdida tras el registro: reintento con el mismo identificador → «repetida», sin nuevo aviso', x3.repeated === true && (await q1('select count(*)::int from public.com_decision_mail_outbox')) - before12 === 7);
  smtp = smtpServer(); await run();

  // ===== 15 · 16 · creación + aprobación / rechazo inmediatos =====
  smtp = smtpServer();
  const n15 = await create('C', 'FINANCIACION', fin(300000, 2, 'QUINCENAL')); await decide('A', n15.id, 'APROBAR', null, 'Se autoriza.');
  const n16 = await create('C', 'FINANCIACION', fin(310000, 2, 'QUINCENAL')); await decide('A', n16.id, 'RECHAZAR', null, 'Deuda vencida en cuenta corriente.');
  await runAll();
  const subj = smtp.delivered.map(d => decodeSubject(d.raw));
  const order15 = subj.filter(s => s.includes(n15.number)), order16 = subj.filter(s => s.includes(n16.number));
  ok('P15-01 creación + aprobación inmediata: 7 avisos NUEVA y luego 6 APROBADA (Para = solicitante)', order15.slice(0, 7).every(s => s.startsWith('NUEVA SOLICITUD')) && order15.slice(7).length === 6 && order15.slice(7).every(s => s.startsWith('Solicitud comercial APROBADA')), order15.join(' / '));
  const ap = smtp.delivered.find(d => decodeSubject(d.raw).startsWith('Solicitud comercial APROBADA | ' + n15.number));
  ok('P15-02 aprobación: Para = solicitante; CC = copias; verde; detalle original', JSON.stringify(addrs(hdr(ap.raw, 'To'))) === '["comercial@qa.invalid"]' && addrs(hdr(ap.raw, 'Cc')).length === 5 && decodeHtml(ap.raw).includes('#067647') && decodeHtml(ap.raw).includes('Se autoriza.'));
  const rj = decodeHtml(smtp.delivered.find(d => decodeSubject(d.raw).startsWith('Solicitud comercial RECHAZADA | ' + n16.number)).raw);
  ok('P16-01 creación + rechazo inmediato: MOTIVO DEL RECHAZO textual, rojo, «NO está autorizada»', order16.length === 13 && rj.includes('MOTIVO DEL RECHAZO') && rj.includes('Deuda vencida en cuenta corriente.') && rj.includes('#b42318') && rj.includes('NO está autorizada'));
  // la NUEVA SOLICITUD del pedido aprobado sigue diciendo pendiente (foto del evento)
  const nv15 = decodeHtml(smtp.delivered.find(d => decodeSubject(d.raw).startsWith('NUEVA SOLICITUD COMERCIAL | ' + n15.number)).raw);
  ok('P17-01 el aviso de creación conserva su estado (PENDIENTE) aunque se aprobó antes de enviarse', nv15.includes('PENDIENTE DE APROBACIÓN') && !nv15.includes('SOLICITUD APROBADA'));

  // ===== devuelta → aceptada → aprobada; aprobada con cambios (suplente); retirada =====
  smtp = smtpServer();
  const r3 = await create('C', 'FINANCIACION', fin(600000, 3, 'SEMANAL'), 'Primera observación');
  await decide('A', r3.id, 'DEVOLVER', fin(450000, 2, 'QUINCENAL'), 'Se propone menor importe en dos cuotas quincenales.');
  await respond(r3.id, true, 'Cliente de acuerdo con la propuesta.');
  await decide('A', r3.id, 'APROBAR');
  await c0.query("update public.profiles set full_name='Tesorería QA RENOMBRADA' where id=$1", [U.A]);
  await c0.query("update public.com_requests set notes='NOTAS MODIFICADAS DESPUÉS' where id=$1", [r3.id]);   // modificación posterior (simulada)
  await runAll();
  const by = k => smtp.delivered.filter(d => decodeSubject(d.raw).includes(k) && decodeSubject(d.raw).includes(r3.number));
  const hDev = decodeHtml(by('DEVUELTA')[0].raw), hRe = by('REENVIADA'), hNew = decodeHtml(by('NUEVA')[0].raw);
  ok('P-DV devuelta: naranja, solicitadas vs propuestas, «no constituye aprobación definitiva»', hDev.includes('#b54708') && hDev.includes('Condiciones solicitadas y condiciones propuestas') && hDev.includes('NO constituyen una aprobación definitiva'));
  ok('P-RE reenviada (cambios aceptados): Para = aprobador + solicitante', hRe.length === 7 && JSON.stringify(addrs(hdr(hRe[0].raw, 'To'))) === '["aprobador@qa.invalid","comercial@qa.invalid"]');
  ok('P17-02 modificaciones posteriores (nombre del aprobador, observaciones) NO alteran lo notificado', hNew.includes('Primera observación') && !hNew.includes('NOTAS MODIFICADAS') && !hNew.includes('RENOMBRADA'));
  await c0.query("update public.profiles set full_name='Tesorería QA' where id=$1", [U.A]);
  smtp = smtpServer();
  const r4 = await create('C', 'FINANCIACION', fin(900000, 3, 'SEMANAL')); await decide('G', r4.id, 'APROBAR_CON_CAMBIOS', fin(700000, 2, 'QUINCENAL'), 'Se autoriza menor importe.');
  const r5 = await create('C', 'FINANCIACION', fin(200000, 1)); await decide('A', r5.id, 'DEVOLVER', fin(150000, 1), 'Se propone un importe menor.'); await respond(r5.id, false, 'El cliente no acepta.');
  await runAll();
  const h4 = decodeHtml(smtp.delivered.find(d => decodeSubject(d.raw).startsWith('Solicitud comercial APROBADA CON CAMBIOS | ' + r4.number)).raw);
  const h5 = decodeHtml(smtp.delivered.find(d => decodeSubject(d.raw).startsWith('Solicitud comercial CANCELADA | ' + r5.number)).raw);
  ok('P-AC aprobada con cambios: azul, solicitadas vs autorizadas, suplencia, originales intactas', h4.includes('#175cd3') && h4.includes('En suplencia') && h4.includes('$ 900.000,00') && h4.includes('$ 700.000,00'));
  ok('P-CA cancelada: gris, motivo del comercial, propuesta no aceptada', h5.includes('#475467') && h5.includes('El cliente no acepta.') && h5.includes('Propuestas'));

  // ===== 14 · aceptación SMTP con respuesta perdida / registro perdido =====
  smtp = smtpServer(); smtp.rules['copia4@qa.invalid'] = {lostAfterData: true};
  const n14 = await create('C', 'FINANCIACION', fin(64000, 1)); await run();
  const held = (await outbox("request_id=$1 and recipient='copia4@qa.invalid'", [n14.id]))[0];
  ok('P14-01 SMTP recibió DATA y se perdió la respuesta → HELD; los demás destinatarios salen igual', held.state === 'HELD' && (await outbox("request_id=$1 and state='SENT'", [n14.id])).length === 6);
  smtp = smtpServer(); await c0.query('update public.com_decision_mail_outbox set next_at=now() where id=$1', [held.id]); await run(); await run();
  ok('P14-02 HELD nunca se reintenta automáticamente', (await outbox('id=$1', [held.id]))[0].state === 'HELD' && !smtp.delivered.some(d => d.to === 'copia4@qa.invalid'));
  smtp = smtpServer();
  const n14b = await create('C', 'FINANCIACION', fin(65000, 1));
  let failOnce = true;
  const sbLost = sbFor(pool, {comm_smtp_finish: a => (a.p_state === 'ACCEPTED' && failOnce && a.p_key.includes('copia2')) ? (failOnce = false, {error: {message: 'respuesta perdida'}}) : null});
  await sendCommercialDecisionEmails(sbLost, smtp.opts);
  const lost = (await outbox("request_id=$1 and recipient='copia2@qa.invalid'", [n14b.id]))[0];
  ok('P14-03 SMTP aceptó pero la app perdió la respuesta antes de registrar → HELD (no se cuenta ni se reenvía)', lost.state === 'HELD' && smtp.delivered.filter(d => d.to === 'copia2@qa.invalid').length === 1);
  await c0.query("update public.com_decision_mail_outbox set state='ERROR', next_at=now() where id=$1", [lost.id]);   // aunque alguien lo reencolara a mano…
  smtp = smtpServer(); await run();
  ok('P14-04 …reencolado a mano: el ledger lo detecta (HELD/incierto) y NO se reenvía', !smtp.delivered.some(d => d.to === 'copia2@qa.invalid') && (await outbox('id=$1', [lost.id]))[0].state === 'HELD');

  // ===== 18 · compatibilidad de claves entre versiones =====
  smtp = smtpServer();
  const n18 = await create('C', 'FINANCIACION', fin(66000, 1)); const r18 = await outbox("request_id=$1", [n18.id]);
  const [kA, kB] = [r18.find(r => r.recipient === 'copia1@qa.invalid'), r18.find(r => r.recipient === 'copia3@qa.invalid')];
  await c0.query("insert into public.comm_smtp_ledger(op_key,fingerprint,state,provider_id) values ($1, repeat('a',64),'ACCEPTED','smtp:publicada'), ($2, repeat('b',64),'RETRYABLE',null)",
    ['decisiones:evento:' + kA.event_id + ':copia1@qa.invalid', 'decisiones:evento:' + kB.event_id + ':copia3@qa.invalid']);
  await run();
  ok('P18-01 aceptado antes con la clave PUBLICADA → SENT sin reenviar', (await outbox('id=$1', [kA.id]))[0].provider_id === 'smtp:publicada' && !smtp.delivered.some(d => d.to === 'copia1@qa.invalid'));
  ok('P18-02 clave publicada con OTRO contenido no entregado → se usa la clave V2, una sola entrega', smtp.delivered.filter(d => d.to === 'copia3@qa.invalid').length === 1
    && (await q1("select state from public.comm_smtp_ledger where op_key=$1", ['decisiones:evento:' + kB.event_id + ':copia3@qa.invalid:v2'])) === 'ACCEPTED');

  // ===== 20 · 21 · límites bajo concurrencia, fallo individual =====
  await c0.query("update public.comm_smtp_rate set at = now() - interval '30 hours'");
  await c0.query("insert into public.comm_smtp_rate(at) select now() - interval '5 minutes' from generate_series(1, 97)");
  for (let i = 0; i < 2; i++) await create('C', 'FINANCIACION', fin(10000 + i, 1));
  smtp = smtpServer(); const [w1, w2] = await Promise.all([run(sb, {keepQuota: true}), run(sb2, {keepQuota: true})]);
  ok('P20-01 dos trabajadores simultáneos con 3 cupos horarios → exactamente 3 entregas, nunca más de 100/h', smtp.delivered.length === 3 && (await q1("select count(*)::int from public.comm_smtp_rate where at>now()-interval '1 hour'")) === 100, JSON.stringify({w1, w2}));
  ok('P20-02 lo que no entró queda PENDIENTE sin gastar intentos', (await q1("select count(*)::int from public.com_decision_mail_outbox where state='PENDING' and attempts=0")) === 11);
  await c0.query("update public.comm_smtp_rate set at = now() - interval '2 hours' where at > now() - interval '1 hour'");
  await c0.query("insert into public.comm_smtp_rate(at) select now() - interval '20 hours' from generate_series(1, 848 - (select count(*) from public.comm_smtp_rate where at>now()-interval '24 hours')::int)");
  smtp = smtpServer(); const [w3, w4] = await Promise.all([run(sb, {keepQuota: true}), run(sb2, {keepQuota: true})]);
  ok('P20-03 tope diario 850 bajo concurrencia: 2 cupos → exactamente 2 entregas', smtp.delivered.length === 2 && (await q1("select count(*)::int from public.comm_smtp_rate where at>now()-interval '24 hours'")) === 850, JSON.stringify({w3, w4}));
  ok('P20-04 el tope diario también frena a los demás módulos', (await q1("select public.comm_smtp_claim('otro-modulo:qa', repeat('c',64))->>'state'")) === 'RATE_LIMIT');
  await c0.query("update public.comm_smtp_rate set at = now() - interval '30 hours'");
  smtp = smtpServer(); await run();
  const n21 = await create('C', 'FINANCIACION', fin(80000, 1)); smtp = smtpServer(); smtp.rules['copia2@qa.invalid'] = {rcpt: 550}; await run();
  rows = await outbox('request_id=$1', [n21.id]);
  ok('P21-01 un destinatario rechazado (550) → ERROR solo ese; los otros 6 SENT en el mismo ciclo', rows.filter(r => r.state === 'SENT').length === 6 && rows.find(r => r.recipient === 'copia2@qa.invalid').state === 'ERROR');

  // ===== seguridad: guard en el envío, privilegios, foto inmutable, panel =====
  const n22 = await create('C', 'FINANCIACION', fin(51000, 1));
  await asUser('G', 'select public.com_mail_copy_revoke($1)', [['copia5@qa.invalid']]);
  await c0.query("update public.profiles set status='DESHABILITADO' where id=$1", [U.C]);
  smtp = smtpServer(); await run(); rows = await outbox('request_id=$1', [n22.id]);
  ok('P-SEG-01 revocación efectiva antes del envío → la copia revocada NO recibe (SKIPPED COPY_REMOVED)', rows.find(r => r.recipient === 'copia5@qa.invalid').error_code === 'COPY_REMOVED' && !smtp.delivered.some(d => d.to === 'copia5@qa.invalid'));
  ok('P-SEG-02 solicitante deshabilitado → no recibe; aprobador sí', rows.find(r => r.kind === 'AUTHOR').state === 'SKIPPED' && smtp.delivered.some(d => d.to === 'aprobador@qa.invalid'));
  await c0.query("update public.profiles set status='ACTIVO' where id=$1", [U.C]);
  await asUser('G', 'select public.com_mail_copy_authorize($1,$2,$3)', [['copia5@qa.invalid'], SCOPE, true]);
  const priv = await q1(`select jsonb_build_object('payloads',has_table_privilege('authenticated','public.com_decision_mail_payloads','SELECT'),'auth',has_table_privilege('authenticated','public.com_mail_copy_authorizations','SELECT,INSERT,UPDATE'),
      'log',has_table_privilege('authenticated','public.com_mail_copy_authorization_log','SELECT,INSERT'),'claim',has_function_privilege('authenticated','public.comm_decision_mail_claim_next()','EXECUTE'),
      'release',has_function_privilege('authenticated','public.comm_decision_mail_release(bigint,uuid,text)','EXECUTE'),'cap',has_function_privilege('authenticated','public.comm_mail_set_daily_cap(int)','EXECUTE'),
      'smtp',has_function_privilege('authenticated','public.comm_smtp_claim(text,text)','EXECUTE'),'anon_auth',has_function_privilege('anon','public.com_mail_copy_authorize(text[],text,boolean)','EXECUTE'),
      'anon_get',has_function_privilege('anon','public.com_mail_settings_get()','EXECUTE'),'rls',(select bool_and(relrowsecurity) from pg_class where oid in ('public.com_decision_mail_payloads'::regclass,'public.com_mail_copy_authorizations'::regclass,'public.com_mail_copy_authorization_log'::regclass)))`);
  ok('P-SEG-03 tablas y funciones internas solo para service_role; RLS activo; anon sin acceso', Object.entries(priv).every(([k, v]) => k === 'rls' ? v === true : v === false), JSON.stringify(priv));
  ok('P-SEG-04 Comercial no ve la configuración', /FORBIDDEN/.test(await tryErr(() => asUser('C', 'select public.com_mail_settings_get()'))));
  await c0.query('delete from auth.sessions where id=$1', [S.G]);
  ok('P-SEG-05 Administrador con sesión revocada no autoriza ni ve', /FORBIDDEN/.test(await tryErr(() => asUser('G', 'select public.com_mail_copy_authorize($1,$2,$3)', [['z@qa.invalid'], SCOPE, true]))));
  await c0.query("insert into auth.sessions(id,user_id,not_after) values ($1,$2,now()+interval '1 day')", [S.G, U.G]);
  ok('P-SEG-06 foto inmutable (UPDATE y DELETE rechazados)', /IMMUTABLE/.test(await tryErr(() => c0.query("update public.com_decision_mail_payloads set payload='{}'"))) && /IMMUTABLE/.test(await tryErr(() => c0.query('delete from public.com_decision_mail_payloads'))));
  ok('P-SEG-07 la foto no guarda KPI, documento del cliente ni saldo', (await q1("select bool_and(not (payload->'request' ?| array['kpi','kpi_snapshot','doc_number','doc_type','client_snapshot','saldo'])) from public.com_decision_mail_payloads")) === true);
  const panel = await asUser('G', 'select public.com_mail_settings_get()');
  ok('P-PAN-01 panel: estado real SMTP, cupos, copias con estado de autorización, bitácora e historial con NUEVA SOLICITUD y participación', panel.transport.provider === 'SMTP' && panel.transport.connected && panel.transport.daily_cap === 850
    && panel.recipients.some(r => r.status === 'AUTORIZADA' && r.authorized_by) && panel.authorization_log.length > 0 && panel.history.some(h => h.event_kind === 'ENVIADA' && h.kind === 'APPROVER'), JSON.stringify(panel.transport));

  // ===== 19 · REVERSIÓN y REINSTALACIÓN con datos, sin duplicados ni pérdida de historial =====
  const n19 = await create('C', 'FINANCIACION', fin(77000, 1));               // NUEVA pendiente al revertir (solo-V2)
  const acc19 = (await outbox("request_id=$1 and recipient='copia3@qa.invalid'", [n19.id]))[0];
  await c0.query("insert into public.comm_smtp_ledger(op_key,fingerprint,state,provider_id) values ($1, repeat('d',64),'ACCEPTED','smtp:aceptado-sin-registrar')", ['decisiones:evento:' + acc19.event_id + ':copia3@qa.invalid']);
  const counts = async () => q1(`select jsonb_build_object('payloads',(select count(*) from public.com_decision_mail_payloads),'auth',(select count(*) from public.com_mail_copy_authorizations),'log',(select count(*) from public.com_mail_copy_authorization_log),'outbox',(select count(*) from public.com_decision_mail_outbox),'ledger_ok',(select count(*) from public.comm_smtp_ledger where state='ACCEPTED'))`);
  const c19a = await counts(), accBefore = await ledgerAccepted();
  await c0.query(REV);
  const c19b = await counts();
  ok('RV-01 reversión: se CONSERVAN fotos, autorizaciones, bitácora, bandeja y ledger', JSON.stringify(c19a) === JSON.stringify(c19b), JSON.stringify([c19a, c19b]));
  ok('RV-02 funciones publicadas restauradas exactamente (huellas)', (await q1("select md5(prosrc) from pg_proc where oid='public._com_mail_event()'::regprocedure")) === 'edc79643ef9f5f07f43b40d5cd77af43');
  ok('RV-03 conciliación: lo ya ACEPTADO por SMTP queda SENT (no se reenvía)', (await outbox('id=$1', [acc19.id]))[0].state === 'SENT');
  ok('RV-04 avisos solo-V2 pendientes → SKIPPED VERSION_REVERTIDA (la versión publicada no los envía)', (await outbox("request_id=$1 and state<>'SENT'", [n19.id])).every(r => r.state === 'SKIPPED' && r.error_code === 'VERSION_REVERTIDA'));
  smtp = smtpServer(); const sv = await run();
  ok('RV-05 trabajador V2 contra base revertida: no envía y no lanza', sv.sent === 0 && sv.stop === 'QUEUE_UNAVAILABLE');
  smtp = smtpServer(); await oldWorker(sb, smtp.opts); await oldWorker(sb, smtp.opts);
  ok('RV-06 trabajador PUBLICADO tras revertir: no reenvía NADA de lo ya entregado', smtp.delivered.length === 0 && (await ledgerAccepted()) === accBefore, smtp.delivered.map(d => d.to).join(','));
  // período revertido: la versión publicada sigue funcionando (resolución → autor + copias de la lista)
  const rv = await create('C', 'FINANCIACION', fin(78000, 1)); await decide('A', rv.id, 'APROBAR');
  smtp = smtpServer(); for (let i = 0; i < 8; i++) await oldWorker(sb, smtp.opts);
  ok('RV-07 durante la reversión la versión publicada envía sus avisos breves (sin creación, sin aprobador)', smtp.delivered.length >= 1 && (await outbox("request_id=$1 and event_kind='ENVIADA'", [rv.id])).length === 0);
  const deliveredDuringRevert = new Set(smtp.delivered.map(d => d.to + '|' + decodeSubject(d.raw)));
  // REINSTALACIÓN
  await c0.query(MIG);
  ok('RV-08 reinstalación sobre los datos conservados (segunda instalación)', (await q1("select status||'|'||installs from public.com_mail_v2_install")) === 'INSTALADA|2');
  ok('RV-09 las fotos previas siguen intactas tras reinstalar', (await q1('select count(*)::int from public.com_decision_mail_payloads')) >= c19b.payloads);
  smtp = smtpServer(); const sr = await run(); await run();
  const resent = smtp.delivered.filter(d => deliveredDuringRevert.has(d.to + '|' + decodeSubject(d.raw)));
  ok('RV-10 reinstalada: nada de lo enviado antes o durante la reversión se reenvía (0 entregas en el primer ciclo)', smtp.delivered.length === 0 && resent.length === 0, JSON.stringify(sr) + ' ' + smtp.delivered.map(d => d.to).join(','));
  ok('RV-11 copias autorizadas se conservan autorizadas tras reinstalar', (await q1("select count(*)::int from public.com_mail_copy_authorizations where status='AUTORIZADA'")) === 5);
  smtp = smtpServer(); const nf = await create('C', 'FINANCIACION', fin(79000, 1)); await run();
  ok('RV-12 nueva solicitud después de reinstalar: 7 entregas, Para + CC', smtp.delivered.length === 7 && addrs(hdr(smtp.delivered[0].raw, 'Cc')).length === 5);
  ok('RV-13 sin duplicados globales: cada (evento, destinatario) aceptado una sola vez en el ledger', (await q1(`select count(*)=0 from (select split_part(op_key,':',3) ev, split_part(op_key,':',4) r, count(*) from public.comm_smtp_ledger where op_key like 'decisiones:evento:%' and state='ACCEPTED' group by 1,2 having count(*)>1) x`)) === true);
} catch (e) { ok('XX ERROR INESPERADO', false, e.stack); }
finally { for (const x of [c0, c1]) try { await x?.end(); } catch {} try { await pool?.end(); await pool2?.end(); } catch {} }
const lines = results.map(r => (r.ok ? 'PASS' : 'FAIL') + ' | ' + r.name + (r.ok ? '' : ' | ' + r.detail));
lines.push('CORREO_AUTORIZACIONES_V2 ' + results.filter(r => r.ok).length + ' / ' + results.length);
console.log(lines.join('\n'));
process.exit(results.every(r => r.ok) ? 0 : 1);
