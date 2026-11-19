const reviewer = 'fgutierrez@okaccesorios.com';
const start = Date.parse('2026-11-19T00:00:00-03:00');
const end = Date.parse('2026-11-20T00:00:00-03:00');

export function receiptReviewBcc(message, now = Date.now()) {
  if (message.customerReceiptReview === true && now >= start && now < end &&
      message.to.trim().toLowerCase() !== reviewer) return reviewer;
  return null;
}
