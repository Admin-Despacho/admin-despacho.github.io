// SOLO PRUEBAS LOCALES · CORREOS DE AUTORIZACIONES CON DETALLE (20261202000100).
// PostgreSQL local temporal con la base equivalente a producción (módulo comercial 000100-001300 + PANEL_SOLO + INSTALL del correo),
// + la migración nueva. Ejecuta las FUNCIONES REALES (com_create_request, com_decide, com_respond, triggers, toma, guard, finish,
// ledger SMTP) y el TRABAJADOR REAL (sendCommercialDecisionEmails + corporateMail + smtpTransport) contra un SERVIDOR SMTP SIMULADO
// en memoria (con STARTTLS). No hay red ni envíos reales. Datos 100 % sintéticos (dominio .invalid).
// Uso: node QA/run_correo_autorizaciones.mjs  (requiere PostgreSQL local en 127.0.0.1:55447 con la BD plantilla okd_base)
import pg from './tooling/node_modules/pg/lib/index.js';   // npm --prefix QA/tooling install pg@8 (ver QA/README_CORREO_AUTORIZACIONES.md)
import {readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {sendCommercialDecisionEmails} from '../supabase/functions/_shared/commercial-decision-mail.js';
const ROOT = new URL('..', import.meta.url).pathname, CFG = {host: '127.0.0.1', port: 55447, user: 'postgres'};
const MIG = readFileSync(ROOT + 'propuestas/correo_autorizaciones/20261202000100_correo_autorizaciones_detalle.sql', 'utf8');
const REV = readFileSync(ROOT + 'propuestas/correo_autorizaciones/REVERSION_CORREO_AUTORIZACIONES_DETALLE.sql', 'utf8');
const results = []; const ok = (name, cond, detail = '') => { results.push({name, ok: !!cond, detail: String(detail).slice(0, 300)}); };
const U = {C: 'c1000000-0000-4000-8000-0000000000c1', A: 'a1000000-0000-4000-8000-0000000000a1', G: 'a2000000-0000-4000-8000-0000000000a2', C2: 'c2000000-0000-4000-8000-0000000000c2'};
const S = {C: 'd1000000-0000-4000-8000-0000000000c1', A: 'd1000000-0000-4000-8000-0000000000a1', G: 'd1000000-0000-4000-8000-0000000000a2', C2: 'd1000000-0000-4000-8000-0000000000c2'};
const COPIES = ['copia1@qa.invalid', 'copia2@qa.invalid', 'copia3@qa.invalid', 'copia4@qa.invalid', 'copia5@qa.invalid'];

// ---------- servidor SMTP simulado (STARTTLS) ----------
function smtpServer() {
  const delivered = [], rules = {};   // rules[to] = {rcpt:550|451, lostAfterData:true}
  const connect = async () => {
    let buf = '220 qa.invalid ESMTP\r\n', tls = false, data = false, to = null, login = 0; let closed = false;
    return {
      async read(b) { if (closed) return null; if (!buf) return new Promise(() => {}); const n = Math.min(b.length, buf.length); b.set(new TextEncoder().encode(buf.slice(0, n))); buf = buf.slice(n); return n; },
      async write(bytes) {
        const t = new TextDecoder().decode(bytes);
        if (data) { const r = rules[to] || {}; data = false; if (r.lostAfterData) { closed = true; throw Error('connection lost'); } delivered.push({to, raw: t}); buf += '250 OK id=QA' + delivered.length + '\r\n'; return bytes.length; }
        if (t.startsWith('EHLO')) buf += tls ? '250-qa\r\n250 AUTH PLAIN LOGIN\r\n' : '250-qa\r\n250-STARTTLS\r\n250 SIZE 1000000\r\n';
        else if (t === 'STARTTLS\r\n') buf += '220 go\r\n';
        else if (t.startsWith('AUTH PLAIN')) buf += '235 ok\r\n';
        else if (t.startsWith('MAIL FROM')) buf += '250 ok\r\n';
        else if (t.startsWith('RCPT TO')) { to = /<([^>]+)>/.exec(t)[1]; const r = rules[to] || {}; buf += (r.rcpt || 250) + ' rcpt\r\n'; }
        else if (t === 'DATA\r\n') { buf += '354 go\r\n'; data = true; }
        return bytes.length;
      },
      close() { closed = true; }, startTlsNow() { tls = true; },
    };
  };
  return {delivered, rules, opts: {connect, startTls: async c => { c.startTlsNow(); return c; }}};
}
const decodeHtml = raw => { const m = /Content-Type: text\/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n([\s\S]*?)\r\n--/.exec(raw); return m ? Buffer.from(m[1].replace(/\r\n/g, ''), 'base64').toString('utf8') : ''; };
const decodeSubject = raw => { const m = /^Subject: =\?UTF-8\?B\?([^?]+)\?=/m.exec(raw); return m ? Buffer.from(m[1], 'base64').toString('utf8') : ''; };

// ---------- adaptador tipo PostgREST (cada RPC = una sentencia autocommit, como service_role) ----------
function sbFor(pool) {
  return {rpc: async (name, args = {}) => {
    const keys = Object.keys(args), sql = 'select public.' + name + '(' + keys.map((k, i) => k + ' => $' + (i + 1)).join(',') + ') as r';
    try { const r = await pool.query(sql, keys.map(k => args[k])); return {data: r.rows[0].r === '' ? null : r.rows[0].r}; } catch (e) { return {error: {message: e.message}}; }
  }};
}
async function newDb(name) {
  const a = new pg.Client({...CFG, database: 'postgres'}); await a.connect();
  await a.query('drop database if exists ' + name + ' with (force)'); await a.query('create database ' + name + ' template okd_base'); await a.end();
  return {...CFG, database: name};
}
async function asUser(c, who, sql, params = []) {
  await c.query('begin');
  try {
    await c.query("select set_config('request.jwt.claims', $1, true), set_config('request.jwt.claim.sub', $2, true), set_config('request.jwt.claim.role','authenticated', true)",
      [JSON.stringify({sub: U[who], role: 'authenticated', session_id: S[who], iat: Math.floor(Date.now() / 1000) + 60}), U[who]]);
    const r = await c.query(sql, params); await c.query('commit'); return r.rows[0] ? Object.values(r.rows[0])[0] : null;
  } catch (e) { await c.query('rollback'); throw e; }
}
async function seed(c) {
  await c.query(`select set_config('okd.sync','on',false);
    insert into auth.users(id,email) values ('${U.C}','comercial@qa.invalid'),('${U.A}','aprobador@qa.invalid'),('${U.G}','admin@qa.invalid'),('${U.C2}','comercial2@qa.invalid');
    insert into public.profiles(id,email,full_name,role,status) values ('${U.C}','comercial@qa.invalid','Asesor Comercial QA','COMERCIAL','ACTIVO'),('${U.A}','aprobador@qa.invalid','Tesorería QA','ADMIN','ACTIVO'),
      ('${U.G}','admin@qa.invalid','Administración General QA','ADMIN','ACTIVO'),('${U.C2}','COPIA1@qa.invalid','Comercial Dos QA','COMERCIAL','ACTIVO');
    insert into auth.sessions(id,user_id,not_after) values ('${S.C}','${U.C}',now()+interval '1 day'),('${S.A}','${U.A}',now()+interval '1 day'),('${S.G}','${U.G}',now()+interval '1 day'),('${S.C2}','${U.C2}',now()+interval '1 day');
    insert into public.com_user_assignments(user_id,channel,branch) values ('${U.C}','SUCURSAL','SAN_JUAN'),('${U.C2}','CARTERA',null);
    update public.com_user_assignments set cartera_label='Cartera Hernán' where user_id='${U.C2}';
    insert into public.com_routing(channel_key,approver_user_id) values ('SUCURSAL:SAN_JUAN','${U.A}'),('CARTERA','${U.A}') on conflict (channel_key) do update set approver_user_id=excluded.approver_user_id;
    insert into public.com_clients(erp_id,razon_social,doc_type,doc_number,cuit,search_text,status) values ('QA-1','Tecnología del Norte S.A.','CUIT','30712345679','30712345679','TECNOLOGIA DEL NORTE','ACTIVO');
    select vault.create_secret('SMTP-TEST-ONLY-NOT-A-REAL-PASSWORD','comm_smtp_password');
    select public.comm_mail_register(x) from unnest(array['comm-dispatcher','internal-approvals','commercial-reports','password-recovery']) x;
    select public.comm_smtp_probe_result(true,(select updated_at from vault.secrets where name='comm_smtp_password'));
    select public.comm_mail_set_provider('SMTP',100,true);`);
  await asUser(c, 'G', 'select public.com_mail_settings_set($1)', [[...COPIES, 'Comercial@qa.invalid']]);
}
const client = async () => (await c0.query("select id from public.com_clients where erp_id='QA-1'")).rows[0].id;
const today = () => new Date(Date.now() - 3 * 3600e3).toISOString().slice(0, 10), plus = n => new Date(Date.parse(today()) + n * 864e5).toISOString().slice(0, 10);
const fin = (amount, k, freq, first = plus(7)) => ({amount, installments: k, frequency: k > 1 ? freq : undefined, first_due: first});
async function create(who, kind, terms, notes = 'Observación del comercial QA', order = 'PV 17-000125') {
  return asUser(c0, who, 'select public.com_create_request($1,$2,$3,$4,$5,$6)', [kind, await client(), order, JSON.stringify(terms), notes, 'op-' + Math.random()]);
}
const ver = async id => (await c0.query('select version from public.com_requests where id=$1', [id])).rows[0].version;
const decide = async (who, id, d, terms = null, reason = null) => asUser(c0, who, 'select public.com_decide($1,$2,$3,$4,$5)', [id, await ver(id), d, terms && JSON.stringify(terms), reason]);
const respond = async (id, accept, comment) => asUser(c0, 'C', 'select public.com_respond($1,$2,$3,$4)', [id, await ver(id), accept, comment]);
const outbox = async (where = 'true', p = []) => (await c0.query('select * from public.com_decision_mail_outbox where ' + where + ' order by id', p)).rows;
const q1 = async (sql, p = []) => { const r = await c0.query(sql, p); return r.rows[0] ? Object.values(r.rows[0])[0] : null; };

let c0, pool, pool2;
const out = [];
try {
  const db = await newDb('qa_mail_auth');
  c0 = new pg.Client(db); await c0.connect();
  pool = new pg.Pool({...db, max: 4}); pool2 = new pg.Pool({...db, max: 4});
  // INSTALACIÓN sobre la base equivalente a producción
  await c0.query(MIG); const orig = await q1("select pg_get_functiondef('public._com_decision_mail_payload(bigint)'::regprocedure)"); ok('IN-01 la migración se instala en una transacción sobre la base publicada (huellas OK)', true);
  try { await c0.query(MIG); ok('IN-02 reaplicar se detiene (YA_APLICADA)', false); } catch (e) { await c0.query('rollback'); ok('IN-02 reaplicar se detiene sin cambios (YA_APLICADA)', /YA_APLICADA/.test(e.message), e.message); }
  ok('IN-03 límite horario intacto y cupo diario 850 por defecto', (await q1('select hourly_cap is null and daily_cap=850 from public.comm_mail_transport')) === true);
  await seed(c0);
  ok('IN-04 proveedor SMTP activo en la base de prueba, límite 100/h', (await q1("select public.comm_mail_runtime()->>'provider'||'/'||(public.comm_mail_runtime()->>'hourly_cap')")) === 'SMTP/100');
  const sb = sbFor(pool), sb2 = sbFor(pool2);
  let smtp = smtpServer();
  const run = (s = sb, opts = {}) => sendCommercialDecisionEmails(s, {...smtp.opts, ...opts});

  // ---- 1 + 11 + 12 + 13: aprobada, autor + 5 copias, duplicado del autor, mismo ciclo ----
  const r1 = await create('C', 'FINANCIACION', fin(600000, 3, 'SEMANAL'));
  await decide('A', r1.id, 'APROBAR', null, 'Cliente al día. Se autoriza.');
  let rows = await outbox('request_id=$1', [r1.id]);
  ok('P11-01 aprobada → autor + 5 copias en la bandeja', rows.length === 6 && rows.filter(r => r.kind === 'COPY').length === 5, rows.map(r => r.recipient).join(','));
  ok('P12-01 el correo del solicitante repetido en las copias NO se duplica', rows.filter(r => r.recipient === 'comercial@qa.invalid').length === 1);
  ok('P17-00 foto del evento guardada al registrarse (source EVENTO)', (await q1('select source from public.com_decision_mail_payloads where event_id=$1', [rows[0].event_id])) === 'EVENTO');
  let s1 = await run();
  ok('P13-01 los 6 destinatarios se envían en el MISMO ciclo (antes: 1 por minuto)', s1.sent === 6 && smtp.delivered.length === 6, JSON.stringify(s1));
  rows = await outbox('request_id=$1', [r1.id]);
  ok('P13-02 todos quedan SENT con fecha de envío e intento 1', rows.every(r => r.state === 'SENT' && r.sent_at && r.attempts === 1));
  ok('P11-02 un correo por destinatario: To único, sin Cc/Bcc, nadie ve a los demás', smtp.delivered.every(d => (d.raw.match(/^To:/gmi) || []).length === 1 && !/^(Cc|Bcc):/mi.test(d.raw.split('\r\n\r\n')[0]) && d.raw.includes('To: <' + d.to + '>')));
  const htmls = smtp.delivered.map(d => decodeHtml(d.raw));
  ok('P11-03 todos reciben el MISMO detalle completo', new Set(htmls).size === 1 && htmls[0].includes('Calendario de pagos solicitado'));
  ok('P01-01 aprobada: asunto exacto y color verde', decodeSubject(smtp.delivered[0].raw) === 'Solicitud comercial APROBADA | ' + r1.number + ' | Tecnología del Norte S.A.' && htmls[0].includes('#067647'), decodeSubject(smtp.delivered[0].raw));
  ok('P01-02 aprobada: observaciones del autorizante textuales y aprobador asignado', htmls[0].includes('Cliente al día. Se autoriza.') && htmls[0].includes('Tesorería QA — Administrador General'));
  ok('P11-04 remitente certificado sin cambios', smtp.delivered.every(d => /^From: =\?UTF-8\?B\?[^?]+\?= <fgutierrez@okaccesorios\.com>/m.test(d.raw)));
  const s1b = await run();
  ok('P16-01 segundo ciclo: nada se reenvía (SENT nunca vuelve a la cola)', s1b.sent === 0 && smtp.delivered.length === 6, JSON.stringify(s1b));

  // ---- 2 rechazada ----
  const r2 = await create('C', 'FINANCIACION', fin(300000, 2, 'QUINCENAL'));
  const motivo = 'El cliente registra deuda vencida en cuenta corriente. No se autoriza una nueva financiación hasta regularizar el saldo pendiente.';
  await decide('A', r2.id, 'RECHAZAR', null, motivo); smtp = smtpServer(); await run();
  const h2 = decodeHtml(smtp.delivered[0].raw);
  ok('P02-01 rechazada: MOTIVO DEL RECHAZO exactamente el registrado + "NO está autorizada" + rojo', h2.includes('MOTIVO DEL RECHAZO') && h2.includes(motivo) && h2.includes('La operación solicitada NO está autorizada.') && h2.includes('#b42318'));

  // ---- 3 devuelta, 17 cambio posterior, reenviada, aprobada final ----
  const r3 = await create('C', 'FINANCIACION', fin(600000, 3, 'SEMANAL'), 'Primera observación');
  await decide('A', r3.id, 'DEVOLVER', fin(450000, 2, 'QUINCENAL'), 'Se propone menor importe en dos cuotas quincenales.');
  await respond(r3.id, true, 'Cliente de acuerdo con la propuesta.');
  await decide('A', r3.id, 'APROBAR', null, null);
  await c0.query("update public.profiles set full_name='Tesorería QA RENOMBRADA' where id=$1", [U.A]);   // cambio POSTERIOR al evento
  smtp = smtpServer(); await run();
  const byEvent = {}; for (const d of smtp.delivered) { const s = decodeSubject(d.raw); (byEvent[s] ||= []).push(decodeHtml(d.raw)); }
  const subj = Object.keys(byEvent);
  const hDev = byEvent[subj.find(s => s.includes('DEVUELTA'))][0], hRe = byEvent[subj.find(s => s.includes('REENVIADA'))][0], hAp = byEvent[subj.find(s => s.includes('APROBADA |'))][0];
  ok('P03-01 devuelta: condiciones solicitadas vs propuestas + aclaración de no aprobación definitiva + naranja', hDev.includes('Condiciones solicitadas y condiciones propuestas') && hDev.includes('NO constituyen una aprobación definitiva') && hDev.includes('#b54708') && hDev.includes('$ 450.000,00'));
  ok('P07-01 calendario original y modificado en la devolución', hDev.includes('Calendario de pagos solicitado') && hDev.includes('Propuestas · calendario') && !hDev.includes('Solicitadas · calendario'));
  ok('P05-02 cambios aceptados: estado REENVIADA (no aprobación) con originales vs aceptadas', hRe.includes('CAMBIOS ACEPTADOS') && hRe.includes('Todavía no están autorizadas') && hRe.includes('Cliente de acuerdo con la propuesta.'));
  ok('P07-02 aprobación posterior: originales vs autorizadas (aceptadas) sin alterar las originales', hAp.includes('Condiciones originales y condiciones autorizadas') && hAp.includes('$ 600.000,00') && hAp.includes('$ 450.000,00'));
  ok('P17-01 cada correo muestra el estado de SU evento (la devolución no muestra la aprobación posterior)', hDev.includes('SOLICITUD DEVUELTA') && !hDev.includes('SOLICITUD APROBADA'));
  ok('P17-02 el nombre del aprobador es el del momento del evento (foto), no el renombrado después', hAp.includes('Tesorería QA — Administrador General') && !hAp.includes('RENOMBRADA'));
  await c0.query("update public.profiles set full_name='Tesorería QA' where id=$1", [U.A]);

  // ---- 4 aprobada con cambios por suplente ----
  const r4 = await create('C', 'FINANCIACION', fin(900000, 3, 'SEMANAL'));
  await decide('G', r4.id, 'APROBAR_CON_CAMBIOS', fin(700000, 2, 'QUINCENAL'), 'Se autoriza menor importe en dos quincenas.'); smtp = smtpServer(); await run();
  const h4 = decodeHtml(smtp.delivered[0].raw);
  ok('P04-01 aprobada con cambios: azul, solicitadas vs autorizadas, suplencia, observaciones', h4.includes('#175cd3') && h4.includes('Condiciones solicitadas y condiciones autorizadas') && h4.includes('En suplencia del responsable asignado') && h4.includes('Se autoriza menor importe en dos quincenas.'));
  ok('P04-02 los datos originales se conservan (900.000 y 3 cuotas) junto a los autorizados', h4.includes('$ 900.000,00') && h4.includes('$ 700.000,00'));

  // ---- 5 cancelada (retirada) ----
  const r5 = await create('C', 'FINANCIACION', fin(200000, 1, null));
  await decide('A', r5.id, 'DEVOLVER', fin(150000, 1, null), 'Se propone un importe menor.');
  await respond(r5.id, false, 'El cliente no acepta el importe reducido.'); smtp = smtpServer(); await run();
  const h5 = smtp.delivered.map(d => decodeHtml(d.raw)).find(h => h.includes('SOLICITUD CANCELADA'));
  ok('P05-01 cancelada: gris, motivo del comercial, propuesta no aceptada', !!h5 && h5.includes('#475467') && h5.includes('El cliente no acepta el importe reducido.') && h5.includes('Propuestas'));
  ok('P05-03 asunto CANCELADA', smtp.delivered.some(d => decodeSubject(d.raw).startsWith('Solicitud comercial CANCELADA | ' + r5.number)));

  // ---- 6 e-cheq ----
  const r6 = await asUser(c0, 'C2', 'select public.com_create_request($1,$2,$3,$4,$5,$6)', ['ECHEQ', await client(), 'PV-ECHEQ-1', JSON.stringify({amount: 1250000.5, due_date: plus(20), issuer_name: 'Distribuidora Andina SRL', issuer_cuit: '30500010912'}), null, 'op-echeq']);
  await decide('A', r6.id, 'APROBAR'); smtp = smtpServer(); await run();
  const h6 = decodeHtml(smtp.delivered.find(d => d.to === 'copia1@qa.invalid').raw);
  ok('P06-01 e-cheq: campos propios (importe, vencimiento, emisor, CUIT del emisor) y cartera', h6.includes('Aceptación de e-cheq') && h6.includes('$ 1.250.000,50') && h6.includes('Distribuidora Andina SRL') && h6.includes('30500010912') && h6.includes('Cartera Hernán') && !h6.includes('Calendario de pagos'));
  ok('P12-02 autor de otra solicitud con correo igual a una copia (mayúsculas) → un solo envío', smtp.delivered.filter(d => d.to === 'copia1@qa.invalid').length === 1, smtp.delivered.map(d => d.to).join(','));

  // ---- 8 histórica (evento previo a la migración, formato anterior sin frecuencia) + 10 faltantes ----
  await c0.query('alter table public.com_request_events disable trigger com_corporate_mail_payload');
  const hid = (await c0.query(`insert into public.com_requests(kind,client_id,client_snapshot,channel,branch,requested_by,assigned_approver_id,order_ref,notes,original_terms,current_terms,final_terms,kpi_snapshot,status,created_at)
     values ('FINANCIACION',$1,'{"razon_social":"Cliente Histórico QA","cuit":null}','SUCURSAL',null,$2,$3,null,null,$4,$4,$4,'{}','APROBADA','2026-10-01T12:00:00Z') returning id`,
     [await client(), U.C, U.A, JSON.stringify({amount: 210000, installments: 3, schedule: [{n: 1, due: '2026-10-08', amount: 70000}, {n: 2, due: '2026-10-15', amount: 70000}, {n: 3, due: '2026-10-22', amount: 70000}], last_due: '2026-10-22', days: 21})])).rows[0].id;
  await c0.query("insert into public.com_request_events(request_id,seq,kind,actor_id,actor_label,assigned_approver_id,terms_before,terms_after) select $1,1,'ENVIADA',$2,'Asesor Comercial QA — Comercial',$3,null,original_terms from public.com_requests where id=$1", [hid, U.C, U.A]);
  await c0.query("insert into public.com_request_events(request_id,seq,kind,actor_id,actor_label,assigned_approver_id,terms_before,terms_after,at) select $1,2,'APROBADA',$2,'Tesorería QA — Administrador General',$2,original_terms,original_terms,'2026-10-01T15:00:00Z' from public.com_requests where id=$1", [hid, U.A]);
  await c0.query('alter table public.com_request_events enable trigger com_corporate_mail_payload');
  smtp = smtpServer(); await run();
  const h8 = decodeHtml(smtp.delivered.find(d => decodeSubject(d.raw).includes('Cliente Histórico QA')).raw);
  ok('P08-01 histórica: foto armada al procesar (source HISTORICO) con lo REGISTRADO', (await q1("select source from public.com_decision_mail_payloads p join public.com_request_events e on e.id=p.event_id where e.request_id=$1", [hid])) === 'HISTORICO');
  ok('P08-02 histórica: sin frecuencia registrada → «No registrado»; calendario guardado; sin recalcular', h8.includes('Frecuencia</td><td') && /Frecuencia<\/td><td[^>]*>No registrado/.test(h8) && h8.includes('22/10/2026') && h8.includes('$ 70.000,00') && !h8.includes('Fecha límite'));
  ok('P10-01 opcionales faltantes (CUIT, pedido, sucursal, observaciones) → «No registrado» / «Sin observaciones»', /CUIT<\/td><td[^>]*>No registrado/.test(h8) && /Número de pedido<\/td><td[^>]*>No registrado/.test(h8) && h8.includes('Sin observaciones registradas.'));

  // ---- 9 observaciones extensas y caracteres especiales ----
  const nasty = '<script>alert(1)</script> & "x" \'y\' ñ áéíóú 🙂\r\nBcc: intruso@evil.invalid\n' + 'Texto largo. '.repeat(45);
  const r9 = await create('C', 'FINANCIACION', fin(100000, 1, null), nasty, '"><img src=x onerror=alert(1)>');
  await decide('A', r9.id, 'RECHAZAR', null, nasty); smtp = smtpServer(); await run();
  const d9 = smtp.delivered[0], h9 = decodeHtml(d9.raw);
  const reg9 = await c0.query('select notes from public.com_requests where id=$1', [r9.id]); const expected9 = (nasty.match(/Texto largo\./g) || []).length + (reg9.rows[0].notes.match(/Texto largo\./g) || []).length;
  ok('P09-01 HTML escapado (sin <script>/<img> ejecutables) y texto REGISTRADO completo (motivo íntegro; observación tal como la guardó el sistema)', !/<script|<img/i.test(h9) && h9.includes('&lt;script&gt;') && h9.includes('ñ áéíóú 🙂') && (h9.match(/Texto largo\./g) || []).length === expected9, expected9 + ' vs ' + (h9.match(/Texto largo\./g) || []).length);
  ok('P09-02 sin inyección de cabeceras (una sola línea To, sin Bcc)', !/^Bcc:/mi.test(d9.raw.split('\r\n\r\n')[0]));

  // ---- 14 límites horario y diario ----
  const r14 = await create('C', 'FINANCIACION', fin(50000, 1, null));
  await c0.query('insert into public.comm_smtp_rate(at) select now() - interval \'10 minutes\' from generate_series(1, 100 - (select count(*) from public.comm_smtp_rate where at>now()-interval \'1 hour\')::int - 3)');
  await decide('A', r14.id, 'APROBAR'); smtp = smtpServer(); const s14 = await run();
  rows = await outbox('request_id=$1', [r14.id]);
  ok('P14-01 límite horario: 3 cupos → 3 enviados, 3 quedan PENDIENTES sin gastar intento', s14.sent === 3 && rows.filter(r => r.state === 'PENDING' && r.attempts === 0).length === 3 && s14.stop === 'NO_CAPACITY', JSON.stringify(s14));
  ok('P14-02 nunca se supera 100 en la última hora', (await q1("select count(*)::int from public.comm_smtp_rate where at>now()-interval '1 hour'")) === 100);
  await c0.query("update public.comm_smtp_rate set at = now() - interval '2 hours' where at > now() - interval '1 hour'");   // pasa la hora
  await c0.query('insert into public.comm_smtp_rate(at) select now() - interval \'20 hours\' from generate_series(1, 850 - (select count(*) from public.comm_smtp_rate where at>now()-interval \'24 hours\')::int)');
  smtp = smtpServer(); const s14b = await run();
  ok('P14-03 límite diario (850 en 24 h): hay cupo horario pero no diario → nada sale, siguen PENDIENTES', s14b.sent === 0 && s14b.stop === 'NO_CAPACITY' && (await outbox("request_id=$1 and state='PENDING'", [r14.id])).length === 3, JSON.stringify(s14b));
  ok('P14-04 el cupo diario también frena a los DEMÁS módulos (comm_smtp_claim → RATE_LIMIT)', (await q1("select public.comm_smtp_claim('otro-modulo:qa', repeat('a',64))->>'state'")) === 'RATE_LIMIT');
  await c0.query("update public.comm_smtp_rate set at = now() - interval '30 hours'");
  smtp = smtpServer(); const s14c = await run();
  ok('P14-05 al liberarse el cupo, los pendientes salen en el ciclo siguiente', s14c.sent === 3 && (await outbox("request_id=$1 and state='SENT'", [r14.id])).length === 6, JSON.stringify(s14c));

  // ---- 15 fallo individual ----
  const r15 = await create('C', 'FINANCIACION', fin(80000, 1, null));
  await decide('A', r15.id, 'APROBAR'); smtp = smtpServer(); smtp.rules['copia2@qa.invalid'] = {rcpt: 550};
  const s15 = await run(); rows = await outbox('request_id=$1', [r15.id]);
  ok('P15-01 un destinatario rechazado (550) → ERROR solo ese; los otros 5 SENT en el mismo ciclo', rows.filter(r => r.state === 'SENT').length === 5 && rows.find(r => r.recipient === 'copia2@qa.invalid').state === 'ERROR', JSON.stringify(s15));
  ok('P21-01 error comprensible registrado (código, sin credenciales)', /^SMTP_RECIPIENT_550$/.test(rows.find(r => r.recipient === 'copia2@qa.invalid').error_code));

  // ---- 16 reintento seguro, incierto, concurrencia, idempotencia ----
  const r16 = await create('C', 'FINANCIACION', fin(70000, 1, null));
  await decide('A', r16.id, 'APROBAR'); smtp = smtpServer(); smtp.rules['copia3@qa.invalid'] = {rcpt: 451};
  await run(); rows = await outbox('request_id=$1', [r16.id]);
  const e451 = rows.find(r => r.recipient === 'copia3@qa.invalid');
  ok('P16-02 rechazo transitorio (451) → ERROR con reintento programado (+5 min)', e451.state === 'ERROR' && new Date(e451.next_at) > new Date(Date.now() + 4 * 60e3));
  await c0.query('update public.com_decision_mail_outbox set next_at=now() where id=$1', [e451.id]); smtp = smtpServer();
  await run(); const e451b = (await outbox('id=$1', [e451.id]))[0];
  ok('P16-03 reintento seguro → SENT con intento 2, un solo correo entregado', e451b.state === 'SENT' && e451b.attempts === 2 && smtp.delivered.filter(d => d.to === 'copia3@qa.invalid').length === 1);
  const r16b = await create('C', 'FINANCIACION', fin(60000, 1, null));
  await decide('A', r16b.id, 'APROBAR'); smtp = smtpServer(); smtp.rules['copia4@qa.invalid'] = {lostAfterData: true};
  await run(); let held = (await outbox("request_id=$1 and recipient='copia4@qa.invalid'", [r16b.id]))[0];
  ok('P16-04 respuesta perdida después de DATA → HELD (resultado incierto)', held.state === 'HELD');
  await c0.query('update public.com_decision_mail_outbox set next_at=now() where id=$1', [held.id]); smtp = smtpServer(); await run(); await run();
  ok('P16-05 HELD nunca se reintenta automáticamente', (await outbox('id=$1', [held.id]))[0].state === 'HELD' && smtp.delivered.filter(d => d.to === 'copia4@qa.invalid').length === 0);
  // concurrencia: 3 solicitudes (18 destinatarios), dos trabajadores en paralelo con pools distintos
  for (let i = 0; i < 3; i++) { const r = await create('C', 'FINANCIACION', fin(10000 + i, 1, null)); await decide('A', r.id, 'APROBAR'); }
  smtp = smtpServer(); const [ca, cb] = await Promise.all([run(sb), run(sb2)]);
  const sentKeys = smtp.delivered.map(d => d.to + '|' + decodeSubject(d.raw));
  ok('P16-06 dos trabajadores simultáneos: 18 correos, cada destinatario UNA vez', smtp.delivered.length === 18 && new Set(sentKeys).size === 18 && ca.sent + cb.sent === 18, JSON.stringify({ca, cb, n: smtp.delivered.length}));
  ok('P16-07 unicidad por evento y destinatario en la bandeja (restricción UNIQUE)', (await q1('select count(*)=count(distinct (event_id,recipient)) from public.com_decision_mail_outbox')) === true);
  ok('P16-08 ledger SMTP: una operación por evento+destinatario+versión', (await q1("select count(*)=count(distinct op_key) from public.comm_smtp_ledger where op_key like 'decisiones:evento:%'")) === true);
  // compatibilidad con la clave anterior: ACEPTADO con la clave vieja → no se reenvía
  const r16c = await create('C', 'FINANCIACION', fin(55000, 1, null)); await decide('A', r16c.id, 'APROBAR');
  const auth16 = (await outbox("request_id=$1 and kind='AUTHOR'", [r16c.id]))[0];
  await c0.query("insert into public.comm_smtp_ledger(op_key,fingerprint,state,provider_id) values ($1, repeat('f',64), 'ACCEPTED', 'smtp:anterior')", ['decisiones:evento:' + auth16.event_id + ':' + auth16.recipient]);
  smtp = smtpServer(); await run();
  ok('P16-09 ya aceptado con la clave anterior → SENT sin reenviar', (await outbox('id=$1', [auth16.id]))[0].provider_id === 'smtp:anterior' && !smtp.delivered.some(d => d.to === auth16.recipient));
  // trabajador interrumpido
  const r16d = await create('C', 'FINANCIACION', fin(52000, 1, null)); await decide('A', r16d.id, 'APROBAR');
  await c0.query("update public.com_decision_mail_outbox set state='PROCESSING', token=gen_random_uuid(), claimed_at=now()-interval '3 minutes' where request_id=$1 and kind='AUTHOR'", [r16d.id]);
  smtp = smtpServer(); await run();
  ok('P16-10 reserva abandonada (>2 min) → HELD WORKER_INTERRUPTED, no se reenvía', (await outbox("request_id=$1 and kind='AUTHOR'", [r16d.id]))[0].error_code === 'WORKER_INTERRUPTED' && !smtp.delivered.some(d => d.to === 'comercial@qa.invalid'));

  // ---- 18 permisos y seguridad ----
  const r18 = await create('C', 'FINANCIACION', fin(51000, 1, null)); await decide('A', r18.id, 'APROBAR');
  await asUser(c0, 'G', 'select public.com_mail_settings_set($1)', [COPIES.filter(x => x !== 'copia5@qa.invalid')]);
  await c0.query("update public.profiles set status='DESHABILITADO' where id=$1", [U.C]);
  smtp = smtpServer(); await run(); rows = await outbox('request_id=$1', [r18.id]);
  ok('P18-01 copia quitada antes del envío → SKIPPED COPY_REMOVED', rows.find(r => r.recipient === 'copia5@qa.invalid').state === 'SKIPPED' && rows.find(r => r.recipient === 'copia5@qa.invalid').error_code === 'COPY_REMOVED');
  ok('P18-02 autor deshabilitado → SKIPPED, no recibe', rows.find(r => r.kind === 'AUTHOR').state === 'SKIPPED' && !smtp.delivered.some(d => d.to === 'comercial@qa.invalid'));
  await c0.query("update public.profiles set status='ACTIVO' where id=$1", [U.C]);
  await asUser(c0, 'G', 'select public.com_mail_settings_set($1)', [[...COPIES, 'Comercial@qa.invalid']]);
  const priv = await q1(`select jsonb_build_object(
      'tabla_auth', has_table_privilege('authenticated','public.com_decision_mail_payloads','SELECT'), 'tabla_anon', has_table_privilege('anon','public.com_decision_mail_payloads','SELECT'),
      'claim', has_function_privilege('authenticated','public.comm_decision_mail_claim_next()','EXECUTE'), 'release', has_function_privilege('authenticated','public.comm_decision_mail_release(bigint,uuid,text)','EXECUTE'),
      'cap', has_function_privilege('authenticated','public.comm_mail_capacity()','EXECUTE'), 'daily', has_function_privilege('authenticated','public.comm_mail_set_daily_cap(int)','EXECUTE'),
      'payload', has_function_privilege('authenticated','public._com_decision_mail_payload(bigint)','EXECUTE'), 'smtp_claim', has_function_privilege('authenticated','public.comm_smtp_claim(text,text)','EXECUTE'),
      'get_anon', has_function_privilege('anon','public.com_mail_settings_get()','EXECUTE'), 'rls', (select relrowsecurity from pg_class where oid='public.com_decision_mail_payloads'::regclass))`);
  ok('P18-03 nada nuevo es accesible para usuarios: tabla y funciones solo service_role; RLS activo', Object.entries(priv).every(([k, v]) => k === 'rls' ? v === true : v === false), JSON.stringify(priv));
  let forb = ''; try { await asUser(c0, 'C', 'select public.com_mail_settings_get()'); } catch (e) { forb = e.message; }
  ok('P18-04 un Comercial no puede ver la configuración ni el historial de correos', /FORBIDDEN/.test(forb), forb);
  await c0.query('delete from auth.sessions where id=$1', [S.G]); forb = '';
  try { await asUser(c0, 'G', 'select public.com_mail_settings_get()'); } catch (e) { forb = e.message; }
  ok('P18-05 Administrador con sesión revocada → FORBIDDEN', /FORBIDDEN/.test(forb), forb);
  await c0.query("insert into auth.sessions(id,user_id,not_after) values ($1,$2,now()+interval '1 day')", [S.G, U.G]);
  let imm = ''; try { await c0.query('update public.com_decision_mail_payloads set payload=$1', ['{}']); } catch (e) { imm = e.message; }
  let imm2 = ''; try { await c0.query('delete from public.com_decision_mail_payloads'); } catch (e) { imm2 = e.message; }
  ok('P18-06 foto del correo inmutable (UPDATE y DELETE rechazados)', /IMMUTABLE/.test(imm) && /IMMUTABLE/.test(imm2));
  ok('P18-07 la foto no contiene KPI, documento del cliente, saldo ni copias (claves)', (await q1("select bool_and(not (payload ? 'kpi') and not (payload->'request' ?| array['kpi','kpi_snapshot','doc_number','doc_type','saldo','copies','client_snapshot']) and not (payload ? 'copies')) from public.com_decision_mail_payloads")) === true);
  // la decisión comercial nunca se bloquea si la foto falla: reemplazo temporal y restauración EXACTA
  await c0.query("create or replace function public._com_decision_mail_payload(p_event bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$ begin raise exception 'FALLA_SIMULADA'; end $$");
  const r18c = await create('C', 'FINANCIACION', fin(41000, 1, null));
  let dec2 = 'ok'; try { await decide('A', r18c.id, 'APROBAR'); } catch (e) { dec2 = e.message; }
  const noPayload = (await q1("select count(*)::int from public.com_decision_mail_payloads p join public.com_request_events e on e.id=p.event_id where e.request_id=$1", [r18c.id])) === 0;
  smtp = smtpServer(); await run(); const failRows = await outbox('request_id=$1', [r18c.id]);
  await c0.query(orig);
  ok('P18-08 la foto falla: la decisión comercial se registra igual (no se bloquea)', dec2 === 'ok', dec2);
  ok('P18-09 foto fallida: el correo queda ERROR DETALLE_NO_DISPONIBLE (sin enviar nada incompleto)', dec2 === 'ok' && noPayload && failRows.every(r => r.state === 'ERROR' && r.error_code === 'DETALLE_NO_DISPONIBLE') && smtp.delivered.length === 0, dec2);
  await c0.query("update public.com_decision_mail_outbox set next_at=now() where request_id=$1", [r18c.id]); smtp = smtpServer(); await run();
  const rr = await outbox('request_id=$1', [r18c.id]);
  ok('P18-10 restaurada la función, el reintento seguro arma la foto (HISTORICO) y envía', rr.filter(r => r.state === 'SENT').length === 6, JSON.stringify(rr.map(r => [r.state, r.error_code, r.attempts])));

  // ---- 21 panel ----
  const panel = await asUser(c0, 'G', 'select public.com_mail_settings_get()');
  ok('P21-02 panel: proveedor real SMTP conectado, remitente, cupo horario/diario y uso', panel.transport.provider === 'SMTP' && panel.transport.connected === true && panel.transport.sender === 'fgutierrez@okaccesorios.com' && panel.transport.hourly_cap === 100 && panel.transport.daily_cap === 850 && Number.isInteger(panel.transport.daily_used), JSON.stringify(panel.transport));
  ok('P21-03 panel: historial con estado, intentos, fecha de creación y envío, error', panel.history.length === 30 && ['state', 'attempts', 'created_at', 'sent_at', 'error_code', 'kind', 'next_at'].every(k => k in panel.history[0]));
  ok('P21-04 panel: configuración de copias conservada', JSON.stringify(panel.copies) === JSON.stringify([...COPIES, 'comercial@qa.invalid'].sort()));
  // cupo diario configurable y auditado
  await q1('select public.comm_mail_set_daily_cap(800)');
  let bad = ''; try { await q1('select public.comm_mail_set_daily_cap(1001)'); } catch (e) { bad = e.message; }
  ok('P14-06 cupo diario configurable (1–1000) y auditado', (await q1("select count(*)::int from public.comm_smtp_audit where action='DAILY_CAP_CHANGED'")) === 1 && /INVALID_DAILY_CAP/.test(bad));

  // ---- REVERSIÓN con datos y REINSTALACIÓN ----
  const before = await q1("select jsonb_object_agg(state, n) from (select state, count(*) n from public.com_decision_mail_outbox group by state) x");
  await c0.query(REV);
  const after = await q1("select jsonb_object_agg(state, n) from (select state, count(*) n from public.com_decision_mail_outbox group by state) x");
  ok('RV-01 reversión con datos: bandeja intacta (estados y cantidades), funciones publicadas restauradas', JSON.stringify(before) === JSON.stringify(after) && (await q1("select md5(prosrc) from pg_proc where oid='public.comm_smtp_claim(text,text)'::regprocedure")) === '122468dcb26660ecf0e1499ae0ab75fd', JSON.stringify(after));
  ok('RV-02 tras revertir: sin cupo diario ni foto; la toma anterior sigue disponible', (await q1("select to_regclass('public.com_decision_mail_payloads') is null and to_regprocedure('public.comm_decision_mail_claim()') is not null and not exists(select 1 from information_schema.columns where table_name='comm_mail_transport' and column_name='daily_cap')")) === true);
  smtp = smtpServer(); const sRev = await run();
  ok('RV-03 trabajador NUEVO contra base revertida: no envía y no lanza (no bloquea a los demás módulos)', sRev.sent === 0 && sRev.stop === 'QUEUE_UNAVAILABLE', JSON.stringify(sRev));
  await c0.query(MIG);
  ok('RV-04 reinstalación posterior a la reversión', (await q1("select to_regclass('public.com_decision_mail_payloads') is not null")) === true);
} catch (e) { ok('XX ERROR INESPERADO', false, e.stack); }
finally { try { await c0?.end(); } catch {} try { await pool?.end(); await pool2?.end(); } catch {} }
const lines = results.map(r => (r.ok ? 'PASS' : 'FAIL') + ' | ' + r.name + (r.ok ? '' : ' | ' + r.detail));
lines.push('CORREO_AUTORIZACIONES ' + results.filter(r => r.ok).length + ' / ' + results.length);
console.log(lines.join('\n'));
process.exit(results.every(r => r.ok) ? 0 : 1);
