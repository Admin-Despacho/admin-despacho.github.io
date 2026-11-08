// V4.27 · lógica EN LÍNEA de aprobaciones de ruta interna con un cliente Supabase SIMULADO (sin red). Uso: npx vitest run tests/unit/v427_aprobaciones_online.test.js
import { test, expect } from 'vitest';
import { SupabaseRC4 } from '../../src/online/supabase-rc4.js';
import { SupabaseApi } from '../../src/online/supabase-api.js';
const R = []; const res = (n, ok, d = '') => { R.push([n, ok]); console.log('..', n, '|', ok ? 'PASS' : 'FAIL', '|', JSON.stringify(d).slice(0, 220)); };
const LEO = 'u-leo', OTRO = 'u-otro', GAB = 'u-gab';
const ROUTE = { id: 'r1', number: '03-000019', responsable_id: GAB, published_by: 'u-guillermo', operational_status: 'COMPLETADA', approval_status: 'PENDIENTE', version: 3, completed_at: '2026-11-06T16:00:00Z' };
const STOPS = [{ id: 's1', route_id: 'r1', client_name: 'Depósito Norte', sequence_number: 1, outcome: 'ENTREGADO', provenance: 'PUBLISHED' }, { id: 's2', route_id: 'r1', client_name: 'Banco (retiro)', sequence_number: 2, outcome: 'ENTREGADO', provenance: 'DRIVER', action: 'RETIRO' }];
const REQ = { id: '32e18f59', route_id: 'r1', route_version: 3, request_type: 'INTERNAL_ROUTE_CHANGE', status: 'PENDING', requested_by: GAB, supervisor_user_id: LEO, supervisor_missing: false, escalated: false, modification_count: 2, requested_at: '2026-11-06T16:00:00Z' };
const OP = { id: 'op1', request_type: 'CAMBIO_TRANSPORTISTA', status: 'PENDING', requested_by: 'u-x', supervisor_user_id: OTRO, requested_at: '2026-11-06T10:00:00Z' };
const q = rows => { const o = { _rows: rows, select: () => o, order: () => o, limit: () => o, in: () => o, neq: (c, v) => { o._rows = o._rows.filter(r => r[c] !== v); return o; }, eq: (c, v) => { o._rows = o._rows.filter(r => r[c] === v); return o; },
  then: (ok, ko) => Promise.resolve({ data: o._rows, error: null }).then(ok, ko) }; return o; };
const calls = [];
const sb = rows => ({ from: t => t === 'route_approval_requests' ? q(rows()) : t === 'profiles' ? q([{ id: GAB, full_name: 'Gabriel Figueroa' }]) : q([]),
  rpc: async (fn, args) => { calls.push(fn); return fn === 'review_route_approval' ? { data: null, error: null } : { data: null, error: { message: 'function ' + fn + ' does not exist' } }; }, auth: {} });
// RLS real del caso 03-000019: la hoja la publicó Guillermo (equipo de Leonardo) → el join de la hoja SÍ llega para Leonardo
const rowsLeo = () => [{ ...REQ, requester: { full_name: 'Gabriel Figueroa' }, approver: { full_name: 'Leonardo Cabañez' }, route: { number: '03-000019' }, routes: { ...ROUTE, route_stops: STOPS } },
  { ...OP, requester: { full_name: 'X' }, approver: { full_name: 'Otro' }, route: { number: '01-000050' } }];
const list = (who, filter) => Object.assign(Object.create(SupabaseRC4), { sb: sb(rowsLeo), me: async () => ({ id: who, role: 'SUPERVISOR_DESPACHO' }) }).listOperationalRequests(filter);
const apiFor = rows => new SupabaseApi('http://x', 'k', sb(rows));
test('V4.27 · aprobaciones de ruta interna · lógica EN LÍNEA (sin funciones SQL nuevas)', async () => {
  const leo = await list(LEO, 'asignadas'), otro = await list(OTRO, 'todas');
  const li = leo.find(r => r.request_type === 'INTERNAL_ROUTE_CHANGE');
  res('OL-01 listado: Leonardo ve en PARA RESOLVER la solicitud interna asignada con su NÚMERO DE HOJA (03-000019); OTRO Superior NO ve la interna ajena (sí sus operativas)',
    !!li && li.route_number === '03-000019' && !otro.some(r => r.request_type === 'INTERNAL_ROUTE_CHANGE') && otro.some(r => r.id === 'op1'), { leo: li && li.route_number, otro_internas: otro.filter(r => r.request_type === 'INTERNAL_ROUTE_CHANGE').length });
  const d = await apiFor(rowsLeo).internalApprovalDetail('32e18f59');
  res('OL-02 revisión: hoja, 2 paradas, transportista y diff con la PARADA AGREGADA, con la lectura de siempre (sin RPC nueva)',
    d.route.number === '03-000019' && d.route.stops.length === 2 && d.driver_name === 'Gabriel Figueroa' && JSON.stringify(d.diff).includes('PARADA AGREGADA') && !calls.includes('internal_route_approval_detail'), { hoja: d.route.number, paradas: d.route.stops.length });
  let pend, perr = null; try { pend = await apiFor(() => [{ ...REQ, routes: null }]).pendingApprovals(); } catch (e) { perr = e.message; }
  res('OL-03 si la RLS ocultara la hoja, la pantalla de aprobaciones NO falla: esa fila se omite', !perr && Array.isArray(pend) && pend.length === 0, { error: perr });
  const api = apiFor(rowsLeo); let mailFlushes = 0; api._ir = async () => { mailFlushes++; };
  await api.reviewApproval('32e18f59', 'APPROVED', null);
  res('OL-04 la resolución usa review_route_approval (controles del servidor), sin funciones nuevas ni despacho de correos', calls.includes('review_route_approval') && !calls.includes('internal_route_approval_detail') && mailFlushes === 0, { calls, mailFlushes });
  console.log('TOTAL', R.filter(r => r[1]).length, 'PASS /', R.filter(r => !r[1]).length, 'FAIL');
  expect(R.filter(r => !r[1]).map(r => r[0])).toEqual([]); expect(R.length).toBe(4);
});
