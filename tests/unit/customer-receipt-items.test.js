import { expect, test } from 'vitest';
import { execFileSync } from 'node:child_process';
import { receiptEmail } from '../../supabase/functions/_shared/customer-email.js';
import { routePdf } from '../../supabase/functions/_shared/route-pdf.js';

test('el detalle es exclusivo del correo y el texto completo del PDF de ruta se conserva', async () => {
  const merchandise = [{ order:'45821', code:'XAEA-QA', description:'Artículo exclusivo <mail>', quantity:'12' }];
  const stop = { seq:1, client_key:'QA', client_name:'Cliente QA', order_numbers:['45821'], bultos:2, outcome:'ENTREGADO' };
  const route = { number:'01-QA', carrier_id:'CT-ESTE', operational_status:'COMPLETADA', stops:[stop], sheet_snapshot:{stops:[stop]} };
  const pdfText = async route => execFileSync('pdftotext',['-layout','-','-'],{input:Buffer.from(await routePdf({route})),encoding:'utf8'});
  const before = await pdfText(route);
  expect(before).toContain('Cliente QA');
  const after = await pdfText({...route, sheet_snapshot:{stops:[{...stop, merchandise}]}});
  expect(after).toBe(before);
  const mail = receiptEmail({stop,receipt:{snapshot:{...stop, customer_receipt_version:1, merchandise,
    receipt_number:'RC-01-QA-001',delivered_at:'2026-11-19T18:00:00Z',receiver_name:'Receptor QA'}}});
  expect(mail.html).toContain('Artículo exclusivo &lt;mail&gt;');
  expect(mail.html).toContain('XAEA-QA');
  expect(mail.html).toContain('Total de unidades');
  expect(mail.subject).toContain('45821 entregado');
});
