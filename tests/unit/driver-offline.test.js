import { describe, it, expect } from 'vitest';
import { DriverApp } from '../../src/online/driver-ui.js';

const makeApp = () => {
  const app = new DriverApp({}, { id: 'u-driver', full_name: 'Chofer', role: 'TRANSPORTISTA_INTERNO' }, () => {});
  app.routes = [{
    id: 'r1',
    version: 4,
    carrier_id: 'INTERNO',
    stops: [{ id: 'base', seq: 1, sequence_number: 1, outcome: 'PENDIENTE', stop_type: 'PEDIDO' }]
  }];
  return app;
};

describe('Transportista Interno · paradas agregadas offline', () => {
  it('conserva TAREA, instrucciones y contacto antes de reconectar', () => {
    const app = makeApp();
    const op = {
      kind: 'addStop',
      args: {
        route: 'r1',
        stop: {
          id: 'task-1',
          stop_type: 'TAREA',
          client_name: 'Banco Nación',
          address: 'San Martín 1100',
          instructions: 'Depositar efectivo',
          contact_name: 'Caja',
          contact_phone: '261444'
        }
      }
    };

    app._applyLocal(op);
    app._applyLocal(op); // mismo cambio local/reintento: no duplica por id

    const rows = app.routes[0].stops.filter(s => s.id === 'task-1');
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      provenance: 'DRIVER',
      stop_type: 'TAREA',
      instructions: 'Depositar efectivo',
      contact_name: 'Caja',
      contact_phone: '261444',
      outcome: 'PENDIENTE',
      order_numbers: [],
      merchandise_amount: 0,
      shipping_fee: 0,
      customer_email: null,
      task: 'ENTREGA'
    });
    expect(rows[0].internal_location_key).toBeNull();
  });

  it('conserva UBICACION_INTERNA y clave G2 sin inventar snapshot GPS local', () => {
    const app = makeApp();
    app._applyLocal({
      kind: 'addStop',
      args: {
        route: 'r1',
        stop: {
          id: 'g2-1',
          stop_type: 'UBICACION_INTERNA',
          internal_location_key: 'MONTECASEROS',
          client_name: 'Montecaseros - casa central',
          address: 'Montecaseros 1529, Ciudad Mendoza',
          instructions: 'Retirar documentación'
        }
      }
    });

    const row = app.routes[0].stops.find(s => s.id === 'g2-1');
    expect(row).toMatchObject({
      provenance: 'DRIVER',
      stop_type: 'UBICACION_INTERNA',
      internal_location_key: 'MONTECASEROS',
      client_key: 'MONTECASEROS',
      client_name: 'Montecaseros - casa central',
      address: 'Montecaseros 1529, Ciudad Mendoza',
      instructions: 'Retirar documentación',
      order_numbers: [],
      outcome: 'PENDIENTE'
    });
    expect(row.expected_lat).toBeNull();
    expect(row.expected_lon).toBeNull();
    expect(row.expected_radius_m).toBeNull();
  });
});
