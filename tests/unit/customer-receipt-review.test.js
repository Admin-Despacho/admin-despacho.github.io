import { expect, test, vi } from 'vitest';
import { receiptReviewBcc } from '../../supabase/functions/_shared/customer-receipt-review.js';
import { resendBody } from '../../supabase/functions/_shared/resend-body.js';

test('copia oculta exclusivamente durante el 19 de noviembre en Argentina', () => {
  const message = { customerReceiptReview: true, to: 'cliente@example.org' };
  const end = Date.parse('2026-11-20T03:00:00Z');
  const start = end - 86400000;
  const reviewer = 'fgutierrez@okaccesorios.com';
  expect(receiptReviewBcc(message, start - 1)).toBeNull();
  expect(receiptReviewBcc(message, start)).toBe(reviewer);
  expect(receiptReviewBcc(message, end - 1)).toBe(reviewer);
  expect(receiptReviewBcc(message, end)).toBeNull();
  expect(receiptReviewBcc({to:message.to}, start)).toBeNull();
  expect(receiptReviewBcc({...message,to:reviewer.toUpperCase()}, start)).toBeNull();
  vi.useFakeTimers();
  try {
    vi.setSystemTime(start);
    expect(resendBody(message, 'sender').bcc).toEqual([reviewer]);
    vi.setSystemTime(end);
    expect(resendBody(message, 'sender')).not.toHaveProperty('bcc');
  } finally { vi.useRealTimers(); }
});

import { customerEmail } from '../../supabase/functions/_shared/customer-email.js';

test('solo las salidas de Cristian reciben la copia adicional', () => {
  for (const carrier of ['CT-ALR', 'CT-ESTE', 'OTRO', null]) {
    for (const kind of ['ON_THE_WAY', 'PARTIAL', 'DELIVERED']) {
      const mail = customerEmail({kind, stop:{routes:{carrier_id:carrier}}});
      expect(mail.customerReceiptReview).toBe(kind === 'ON_THE_WAY' && ['CT-ALR', 'CT-ESTE'].includes(carrier));
    }
  }
});
