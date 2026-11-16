// CORS y respuestas JSON comunes a TODAS las Edge Functions (OPTIONS, 2xx, 4xx, 5xx y catch global).
export const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, apikey, x-client-info, content-type, x-cron-secret',
  'access-control-allow-methods': 'POST, OPTIONS'
};
const CODE = { 400: 'BAD_REQUEST', 401: 'NO_AUTH', 403: 'FORBIDDEN', 404: 'NOT_FOUND', 405: 'METHOD', 409: 'CONFLICT', 429: 'RATE_LIMIT' };
// Todo error sale como { error, code } (si el handler no puso código, se deduce del estado HTTP)
export const json = (status, body) => {
  if (body && body.error && !body.code) body = { ...body, code: CODE[status] || (status >= 500 ? 'SERVER_ERROR' : 'ERROR') };
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', ...CORS } });
};
export const preflight = () => new Response('ok', { status: 200, headers: CORS });
// Envuelve un handler: OPTIONS → 200; cualquier excepción → { error, code: 'SERVER_ERROR' } con CORS
export const withCors = handler => async (req, deps) => {
  if (req.method === 'OPTIONS') return preflight();
  try { return await handler(req, deps); } catch (e) { return json(500, { error: String((e && e.message) || e), code: 'SERVER_ERROR' }); }
};
