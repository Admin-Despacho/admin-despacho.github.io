// V4.26 · plantilla «Tu pedido está en camino» (Deno): texto correcto para una SALIDA REAL, sin prometer "próxima entrega"; datos escapados.
import { customerEmail } from './customer-email.js';
const assert = (c, m) => { if (!c) throw new Error(m); };
Deno.test('EC-01 asunto y cuerpo de una salida real: «Tu pedido está en camino», ya salió del depósito; NO dice «próxima entrega»', () => {
  const m = customerEmail({ kind: 'ON_THE_WAY', stop: { client_name: 'Cliente <QA>', order_numbers: ['78001', '78002'] } });
  assert(m.subject === 'OK Accesorios · Tu pedido está en camino', 'asunto: ' + m.subject);
  assert(m.text.includes('78001 + 78002') && m.text.includes('ya salió de nuestro depósito y está en camino'), 'cuerpo: ' + m.text);
  assert(!/próxima entrega/i.test(m.html + m.text), 'no debe prometer próxima entrega');
  assert(m.html.includes('Cliente &lt;QA&gt;') && !m.html.includes('<QA>'), 'el nombre del cliente debe ir escapado');
});
Deno.test('EC-02 las otras plantillas de cliente no cambian (entregado / parcial)', () => {
  assert(customerEmail({ kind: 'DELIVERED', stop: { client_name: 'X', order_numbers: ['1'] } }).subject === 'OK Accesorios · Tu pedido fue entregado', 'entregado');
  assert(customerEmail({ kind: 'PARTIAL', stop: { client_name: 'X', order_numbers: ['1'] } }).subject === 'OK Accesorios · Entregamos parte de tu pedido', 'parcial');
});
