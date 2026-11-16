// Auditoría focalizada 14/11 · invocación DIRECTA de DemoCom.comOrderAlerts (mismos casos que la auditoría: B-01 y B-02) — sin pantalla.
import { describe, it, expect } from 'vitest';
import { DemoCom } from '../../src/online/com-api.js';
const T = '2026-11-14T12:00:00.000Z', CUIT = '30717780406';
const req = (number, order_ref, status, requested_by, approver, cuit = CUIT, created_at = T) => ({ id: 'id-' + number, number, kind: 'FINANCIACION', status, order_ref, requested_by, assigned_approver_id: approver,
  client: { razon_social: 'CLIENTE ' + cuit, cuit }, created_at, decided_at: null, final_terms: status.startsWith('APROBADA') ? { amount: 1000, installments: 2 } : null });
const users = [
  { id: 'c1', role: 'COMERCIAL', status: 'ACTIVO' }, { id: 'c2', role: 'COMERCIAL', status: 'ACTIVO' },
  { id: 'w', role: 'SOLO_LECTURA', status: 'ACTIVO', permission_overrides: { 'com.approve': true } }, { id: 'ap', role: 'SOLO_LECTURA', status: 'ACTIVO', permission_overrides: { 'com.approve': true } },
  { id: 'op', role: 'OPERARIO_DEPOSITO', status: 'ACTIVO' }, { id: 'adm', role: 'ADMIN', status: 'ACTIVO' }, { id: 'tr', role: 'TRANSPORTISTA', status: 'ACTIVO' }];
const requests = [req('AUT-000001', 'P-100', 'PENDIENTE', 'c1', 'w'), req('AUT-000002', 'P-100', 'PENDIENTE', 'c1', 'w'),   // mismo pedido, mismo CUIT, MISMO instante
  req('AUT-000003', 'P-200', 'DEVUELTA', 'c1', 'w'), req('AUT-000004', 'P-300', 'APROBADA', 'c1', 'w'), req('AUT-000005', 'P-500', 'PENDIENTE', 'c2', 'w', '30500010912')];
const as = (userId, offline = false) => Object.assign(Object.create(DemoCom), { getSession: async () => ({ userId }), _load: () => ({ users, com: { requests } }), db: {},
  _net: () => { if (offline) throw Object.assign(new Error('Sin conexión'), { code: 'OFFLINE' }); } });
const nums = L => L.map(x => x.number).sort();
describe('DemoCom.comOrderAlerts · auditoría focalizada', () => {
  it('B-01: pedido sin CUIT → 1 (la más reciente)', async () => expect(nums(await as('op').comOrderAlerts(['P-100'], []))).toEqual(['AUT-000002']));
  it('B-01: pedido + CUIT → sigue 1 (no reintroduce la anterior) y marcada como PEDIDO', async () => {
    const L = await as('op').comOrderAlerts(['P-100'], [CUIT]); expect(L.filter(x => x.order_ref === 'P-100').map(x => [x.number, x.match])).toEqual([['AUT-000002', 'PEDIDO']]); });
  it('B-01: otros pedidos del mismo cliente por CUIT → solo EN CURSO, una por pedido', async () => expect(nums(await as('op').comOrderAlerts([], [CUIT]))).toEqual(['AUT-000002', 'AUT-000003']));
  it('B-02: COMERCIAL AJENO (c2) no ve las de c1 aunque conozca pedido y CUIT; ve la propia', async () => expect(nums(await as('c2').comOrderAlerts(['P-100', 'P-300', 'P-500'], [CUIT]))).toEqual(['AUT-000005']));
  it('B-02: COMERCIAL DUEÑO (c1) ve las propias', async () => expect(nums(await as('c1').comOrderAlerts(['P-100', 'P-300', 'P-500'], []))).toEqual(['AUT-000002', 'AUT-000004']));
  it('B-02: APROBADOR AJENO (sin asignaciones) no ve nada; APROBADOR ASIGNADO ve las asignadas', async () => {
    expect(await as('ap').comOrderAlerts(['P-100', 'P-500'], [])).toEqual([]); expect(nums(await as('w').comOrderAlerts(['P-100', 'P-500'], []))).toEqual(['AUT-000002', 'AUT-000005']); });
  it('B-02: DESPACHO y ADMINISTRADOR ven todas (trazabilidad autorizada)', async () => {
    expect(nums(await as('op').comOrderAlerts(['P-100', 'P-500'], []))).toEqual(['AUT-000002', 'AUT-000005']); expect(nums(await as('adm').comOrderAlerts(['P-100', 'P-500'], []))).toEqual(['AUT-000002', 'AUT-000005']); });
  it('T-01: SIN PERMISOS del módulo (transportista) y SIN SESIÓN → FORBIDDEN', async () => {
    await expect(as('tr').comOrderAlerts(['P-100'], [])).rejects.toMatchObject({ code: 'FORBIDDEN' });
    await expect(Object.assign(Object.create(DemoCom), { getSession: async () => null, _load: () => ({ users, com: { requests } }), db: {}, _net() {} }).comOrderAlerts(['P-100'], [])).rejects.toMatchObject({ code: 'FORBIDDEN' }); });
  it('O-01: sin conexión la consulta FALLA (no devuelve una lista vacía que se confunda con «sin solicitudes»)', async () => await expect(as('op', true).comOrderAlerts(['P-100'], [])).rejects.toMatchObject({ code: 'OFFLINE' }));
  it('sin datos internos (KPI, notas, condiciones originales, línea de tiempo)', async () => {
    const L = await as('adm').comOrderAlerts(['P-100', 'P-200', 'P-300'], []); expect(L.every(x => !['kpi', 'notes', 'original_terms', 'timeline', 'reason'].some(k => k in x))).toBe(true); });
});
