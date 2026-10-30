// =====================================================================================================================
// COMUNICACIONES · adaptadores del servidor: almacenamiento sobre Postgres (funciones de servicio) y proveedor Gmail API.
// El token de Gmail se lee de Vault mediante una función SOLO de servicio y nunca se registra ni se devuelve.
// =====================================================================================================================
const unwrap = ({ data, error }, what) => { if (error) throw Object.assign(new Error(what + ': ' + error.message), { code: error.code }); return data; };

export function pgStore(sb) {
  return {
    async gmailStatus() { return unwrap(await sb.from('comm_gmail_status').select('connected,email,needs_reconnect').eq('id', 1).single(), 'estado de Gmail'); },
    async listActiveMessages() { return unwrap(await sb.rpc('comm_list_active_messages'), 'comunicados activos') || []; },
    async listCollaborators() { return unwrap(await sb.rpc('comm_list_collaborators_all'), 'colaboradores') || []; },
    async createRun(r) { return unwrap(await sb.rpc('comm_create_run', { p_message: r.message_id, p_scheduled_for: r.scheduled_for, p_kind: r.kind, p_missed: !!r.missed,
      p_recipients: r.recipients || [], p_skipped: r.skipped || [], p_snapshot: r.snapshot }), 'crear ejecución'); },
    async advanceCursor(id, prev, next) { return unwrap(await sb.rpc('comm_advance_cursor', { p_message: id, p_prev: prev, p_next: next }), 'cursor'); },
    async sentLast24h(now) { return unwrap(await sb.rpc('comm_sent_last24h', { p_now: new Date(now).toISOString() }), 'enviados 24 h') || 0; },
    async claim(limit, worker, now, o = {}) { return unwrap(await sb.rpc('comm_claim', { p_limit: limit, p_worker: worker, p_now: new Date(now).toISOString(), p_daily_cap: o.dailyCap ?? 400, p_window_hours: o.windowHours ?? 6 }), 'reservar') || []; },
    async check(id, token) { return unwrap(await sb.rpc('comm_check', { p_id: id, p_token: token }), 'verificar'); },
    async release(id, token) { unwrap(await sb.rpc('comm_release', { p_id: id, p_token: token }), 'liberar'); },
    async finish(id, token, r) { return unwrap(await sb.rpc('comm_finish', { p_id: id, p_token: token, p_outcome: r.outcome, p_gmail_id: r.gmail_id || null,
      p_error_code: r.error_code || null, p_error: r.error || null }), 'registrar resultado'); },
    async fetchAttachment(a) { const { data, error } = await sb.storage.from('comm-attachments').download(a.storage_path);
      if (error) throw Object.assign(new Error('No se pudo leer el adjunto ' + a.name), { code: 'ATTACHMENT_MISSING' }); return new Uint8Array(await data.arrayBuffer()); },
    async recordDispatch(s) { unwrap(await sb.rpc('comm_record_dispatch', { p: s }), 'registrar ejecución'); },
    async refreshToken() { return unwrap(await sb.rpc('comm_gmail_secret'), 'token'); },
    async acquireRate(units, perMin, perSec) { return unwrap(await sb.rpc('comm_rate_acquire', { p_units: units, p_per_min: perMin, p_per_sec: perSec }), 'cupo de velocidad'); },   // { wait_ms, event_id }
    async refundRate(eventId) { unwrap(await sb.rpc('comm_rate_refund', { p_event_id: eventId }), 'devolver cupo'); },
    // (sin limpieza automática de adjuntos: ver LIMITES_Y_COSTOS.md)
    async markGmail(needsReconnect, error) { unwrap(await sb.rpc('comm_gmail_mark', { p_needs_reconnect: needsReconnect, p_error: error }), 'estado Gmail'); },
  };
}

// Proveedor Gmail API (users.messages.send) con OAuth. Permiso mínimo: gmail.send.
export function gmailProvider(store, { clientId, clientSecret, fetch: f = fetch, timeoutMs = 30000, now = () => Date.now() }) {
  const TOKEN_MARGIN_MS = 60e3;   // un token con menos de 60 s de vida se renueva antes de usarlo
  let cached = null;
  const accessToken = async force => {
    if (!force && cached && cached.exp > now() + TOKEN_MARGIN_MS) return cached.token;
    const refresh = await store.refreshToken();
    if (!refresh) throw Object.assign(new Error('Gmail no está conectado'), { status: 401, reason: 'invalid_grant' });
    let res;
    try { res = await f('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ client_id: clientId, client_secret: clientSecret, refresh_token: refresh, grant_type: 'refresh_token' }) }); }
    catch (e) { throw Object.assign(new Error('Sin conexión con Google'), { reason: 'network' }); }   // antes de enviar: recuperable
    const j = await res.json().catch(() => ({}));
    if (!res.ok) throw Object.assign(new Error(j.error_description || j.error || 'token'), { status: res.status, reason: j.error || 'token_error' });
    cached = { token: j.access_token, exp: now() + (Number(j.expires_in) || 3000) * 1000 };
    return cached.token;
  };
  const httpPost = async (raw, token) => {
    const ctl = new AbortController(), t = setTimeout(() => ctl.abort(), timeoutMs);
    try {
      return await f('https://gmail.googleapis.com/gmail/v1/users/me/messages/send', { method: 'POST', signal: ctl.signal,
        headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' }, body: JSON.stringify({ raw }) });
    } catch (e) {
      // el pedido ya salió hacia Gmail: pudo haberlo aceptado → AMBIGUO ("Por verificar"), nunca reenvío automático
      throw Object.assign(new Error('Sin respuesta de Gmail (' + (e && e.name === 'AbortError' ? 'tiempo agotado' : 'red') + ')'), { phase: 'AFTER_SEND' });
    } finally { clearTimeout(t); }
  };
  const interpret = ({ status, ok, json: j }) => {
    if (ok && j.id) return { id: j.id };
    if (ok) throw Object.assign(new Error('Gmail respondió sin identificador'), { phase: 'AFTER_SEND' });
    const er = j.error || {};
    throw Object.assign(new Error(er.message || 'Gmail ' + status), { status, reason: (er.errors && er.errors[0] && er.errors[0].reason) || er.status || er.message || '' });
  };
  const post = async (raw, token) => { const res = await httpPost(raw, token); return { status: res.status, ok: res.ok, json: await res.json().catch(() => ({})) }; };
  return {
    // El DESPACHADOR orquesta cada llamada: cupo → prepare (token) → verificación final → post. Así nada espera entre verificar y llamar.
    prepare: force => accessToken(!!force),
    // ¿el token sigue vigente con margen? (lo consulta el despachador DESPUÉS de esperar el cupo)
    tokenFresh: () => !!(cached && cached.exp > now() + TOKEN_MARGIN_MS),
    post,
    interpret,
    // envío simple (sin orquestación externa): mismo orden, con beforeHttp antes de cada llamada
    async send(raw, { beforeHttp } = {}) {
      if (beforeHttp) await beforeHttp();
      let r = await post(raw, await accessToken(false));
      if (r.status === 401) { if (beforeHttp) await beforeHttp(); r = await post(raw, await accessToken(true)); }
      return interpret(r);
    },
  };
}
