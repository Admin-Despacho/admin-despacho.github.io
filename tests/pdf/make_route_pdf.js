import { routePdf, routeHistory } from '../../supabase/functions/_shared/route-pdf.js';
const route = { id: 'r1', number: '03-000007', carrier_id: 'INTERNO', operational_status: 'COMPLETADA', approval_status: 'PENDIENTE', published_at: '2026-10-10T11:00:00Z', started_at: '2026-10-10T12:00:00Z', completed_at: '2026-10-10T18:00:00Z', km_start: 50000, km_end: 50085,
  sheet_snapshot: { stops: [{ client_name: 'Depósito Norte', bultos: 2 }, { client_name: 'Sucursal Centro' }, { client_name: 'Proveedor Sur' }] },
  events: [{ type: 'INTERNAL_STOP_ADDED', at: '2026-10-10T14:00:00Z' }, { type: 'INTERNAL_STOP_REORDERED', at: '2026-10-10T14:10:00Z', offline: true }],
  stops: [{ seq: 1, sequence_number: 1, client_name: 'Depósito Norte', bultos: 2, outcome: 'ENTREGADO', receiver_name: 'Juan Pérez', receiver_cuil: '20123456786', finish_location: { lat: -32.9, lon: -68.8 } },
    { seq: 3, sequence_number: 2, client_name: 'Proveedor Sur', outcome: 'ENTREGADO' }, { seq: 4, sequence_number: 3, client_name: 'Banco', provenance: 'DRIVER', action: 'RETIRO', bultos: 1, outcome: 'ENTREGADO' },
    { seq: 2, sequence_number: 4, client_name: 'Sucursal Centro', outcome: 'NO_ENTREGADO', outcome_reason: 'Cerrado' }] };
await Deno.writeFile(Deno.args[0], await routePdf({ route, driverName: 'Gabriel Figueroa', carrierName: 'TRANSPORTE INTERNO', vehicle: { name: 'Kangoo', plate: 'AB123CD' }, history: routeHistory(route) }));
