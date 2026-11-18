// DATOS SINTÉTICOS para pruebas y muestras de correo de Autorizaciones Comerciales. Ningún dato real.
const RID = 'a1b2c3d4-0000-4000-8000-000000000004';
const fin = (amount, k, first, freq, extra = {}) => {
  const step = { SEMANAL: 7, QUINCENAL: 15 }[freq] || 7, base = new Date(first + 'T00:00:00Z');
  const schedule = Array.from({ length: k }, (_, i) => { const d = new Date(base); if (freq === 'MENSUAL') d.setUTCMonth(d.getUTCMonth() + i); else d.setUTCDate(d.getUTCDate() + i * step);
    return { n: i + 1, due: d.toISOString().slice(0, 10), amount: i < k - 1 ? Math.round(amount / k * 100) / 100 : Math.round((amount - Math.round(amount / k * 100) / 100 * (k - 1)) * 100) / 100 }; });
  return { amount, installments: k, frequency: k > 1 ? freq : null, first_due: first, schedule, last_due: schedule[k - 1].due, days: 21, limit_date: '2026-12-18', max_days: 30, ...extra };
};
export const ORIGINAL = fin(600000, 3, '2026-11-25', 'SEMANAL');
export const MODIFIED = fin(450000, 2, '2026-11-25', 'QUINCENAL');
const request = (o = {}) => ({ id: RID, number: 'AUT-000004', kind: 'FINANCIACION', created_at: '2026-11-18T13:30:00Z', client_name: 'Tecnología del Norte S.A.', client_cuit: '30-71234567-9',
  order_ref: 'PV 17-000125', channel: 'SUCURSAL', branch: 'SAN_JUAN', cartera_label: null, requester: 'Asesor Comercial QA — Comercial', approver: 'Tesorería QA — Administrador General',
  notes: 'El cliente solicita financiación para concretar la operación comercial y cancelar el saldo en tres cuotas semanales.', original_terms: ORIGINAL, ...o });
const ev = (kind, o = {}) => ({ id: 41, seq: 3, kind, at: '2026-11-18T14:05:00Z', actor: 'Tesorería QA — Administrador General', by_requester: false, substitute: false, reason: null, terms_before: ORIGINAL, terms_after: ORIGINAL, ...o });
const P = (event, req = {}, previous = null) => ({ version: 1, event, request: request(req), previous_proposal: previous });
export const SAMPLES = {
  aprobada: P(ev('APROBADA', { reason: 'Cliente con historial de pagos al día. Se autoriza según lo solicitado.' })),
  rechazada: P(ev('RECHAZADA', { reason: 'El cliente registra deuda vencida en cuenta corriente. No se autoriza una nueva financiación hasta regularizar el saldo pendiente.' })),
  devuelta: P(ev('DEVUELTA_CON_MODIFICACIONES', { reason: 'Se propone reducir el importe y pasar a dos cuotas quincenales.', terms_after: MODIFIED })),
  aprobada_con_cambios: P(ev('APROBADA_CON_MODIFICACIONES', { reason: 'Se autoriza un importe menor en dos cuotas quincenales.', terms_after: MODIFIED, actor: 'Administración General QA — Administrador General', substitute: true })),
  cancelada: P(ev('RETIRADA_POR_COMERCIAL', { seq: 5, actor: 'Asesor Comercial QA — Comercial', by_requester: true, reason: 'El cliente no acepta el importe reducido; se retira la solicitud.', terms_before: null, terms_after: null }), {},
    { terms: MODIFIED, reason: 'Se propone reducir el importe.', by: 'Tesorería QA — Administrador General', at: '2026-11-18T14:05:00Z' }),
  reenviada: P(ev('CAMBIOS_ACEPTADOS_REENVIADA', { seq: 5, actor: 'Asesor Comercial QA — Comercial', by_requester: true, reason: 'Cliente de acuerdo con la propuesta.', terms_before: null, terms_after: MODIFIED }), {},
    { terms: MODIFIED, reason: 'Se propone reducir el importe.', by: 'Tesorería QA — Administrador General', at: '2026-11-18T14:05:00Z' }),
  echeq_aprobada: P(ev('APROBADA', { terms_before: null, terms_after: null }), { kind: 'ECHEQ', number: 'AUT-000005', order_ref: 'PV 17-000126', channel: 'CARTERA', branch: null, cartera_label: 'Cartera Hernán',
    original_terms: { amount: 1250000.5, due_date: '2026-12-10', days: 22, issuer_is_client: false, issuer_name: 'Distribuidora Andina SRL', issuer_cuit: '30-70000001-3' } }),
  echeq_rechazada: P(ev('RECHAZADA', { reason: 'Emisor sin antecedentes verificables.', terms_before: null, terms_after: null }), { kind: 'ECHEQ', number: 'AUT-000006',
    original_terms: { amount: 300000, due_date: '2026-12-01', days: 13, issuer_is_client: true, issuer_name: 'Tecnología del Norte S.A.', issuer_cuit: '30-71234567-9' } }),
  historica: P(ev('APROBADA', { terms_before: { amount: 210000, installments: 3, schedule: [{ n: 1, due: '2026-10-08', amount: 70000 }, { n: 2, due: '2026-10-15', amount: 70000 }, { n: 3, due: '2026-10-22', amount: 70000 }], last_due: '2026-10-22', days: 21 }, terms_after: null }),
    { number: 'AUT-000001', created_at: '2026-10-01T12:00:00Z', original_terms: { amount: 210000, installments: 3, schedule: [{ n: 1, due: '2026-10-08', amount: 70000 }, { n: 2, due: '2026-10-15', amount: 70000 }, { n: 3, due: '2026-10-22', amount: 70000 }], last_due: '2026-10-22', days: 21 } }),
  faltantes: P(ev('APROBADA', { actor: null, terms_before: null, terms_after: null }), { client_cuit: null, order_ref: null, branch: null, notes: null, approver: null, original_terms: { amount: 50000, installments: 1, first_due: '2026-11-30', schedule: [{ n: 1, due: '2026-11-30' }] } }),
  especiales: P(ev('RECHAZADA', { reason: '<script>alert("x")</script> & "comillas" \'simples\'\nLínea 2 con ñ, acentos áéíóú y emoji 🙂\r\nBcc: intruso@evil.invalid\n' + 'Texto extenso. '.repeat(80) }),
    { client_name: 'ACME <b>S.A.</b>\r\nBcc: intruso@evil.invalid', order_ref: '"><img src=x onerror=alert(1)>', notes: 'Observación con <tags> & símbolos % $ # @   separador\n' + 'Detalle largo del comercial. '.repeat(40) }),
};
