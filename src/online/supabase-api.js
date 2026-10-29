// Conexión real con el proyecto Supabase PROPIO de OK Despacho.
// Solo usa la clave pública (anon). Todo lo administrativo pasa por la Edge Function admin-users.
import { createClient } from '@supabase/supabase-js';

// Supabase Auth: la contraseña nueva es igual a la actual (código same_password, o el texto en versiones anteriores)
const isSamePassword = e => !!e && (e.code === 'same_password' || /should be different from the old password/i.test(String(e.message || '')));
const jwtIat = token => { try { return JSON.parse(atob(token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))).iat || 0; } catch (e) { return 0; } };

export class SupabaseApi {
  // sb: cliente inyectable (las pruebas usan uno simulado)
  constructor(url, anonKey, sb) {
    this.mode = 'online';
    this.sb = sb || createClient(url, anonKey, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } });
  }
  async getSession() { const { data } = await this.sb.auth.getSession(); return data.session ? { userId: data.session.user.id, iat: jwtIat(data.session.access_token) } : null; }
  async signIn(email, password) {
    const { data, error } = await this.sb.auth.signInWithPassword({ email: String(email).trim(), password });
    if (error) {
      // Solo las credenciales inválidas se informan como tales; otras causas reales no se disfrazan de "contraseña incorrecta".
      const code = String(error.code || ''), m = String(error.message || '');
      if (/banned/i.test(m) || code === 'user_banned') throw new Error('Usuario sin acceso. Consultá con Administración.');
      if (code === 'email_not_confirmed' || /email not confirmed/i.test(m)) throw Object.assign(new Error('Tu email todavía no está confirmado. Abrí el enlace de invitación que te llegó por correo o pedí a Administración que te la reenvíe.'), { code: 'EMAIL_NOT_CONFIRMED' });
      if (code === 'over_request_rate_limit' || /rate limit|too many/i.test(m)) throw Object.assign(new Error('Demasiados intentos seguidos. Esperá unos minutos y volvé a probar.'), { code: 'RATE_LIMIT' });
      throw Object.assign(new Error('Email o contraseña incorrectos.'), { code: 'INVALID_CREDENTIALS' });
    }
    return { userId: data.user.id };
  }
  async signOut() { await this.sb.auth.signOut(); }
  takeRevokedNotice() { let v = this.revokedNotice; try { v = v || sessionStorage.getItem('okd_revoked') === '1'; sessionStorage.removeItem('okd_revoked'); } catch (e) { } this.revokedNotice = false; return v; }

  // Usuario invitado: guarda la contraseña y activa su usuario. Si la activación falla NO se oculta el error.
  // Olvidé mi contraseña: Supabase Auth envía el correo por el SMTP configurado del proyecto.
  // La respuesta de la UI sigue siendo genérica y no revela si el email existe.
  async requestPasswordReset(email) {
    const base = typeof window !== 'undefined' ? (window.location.origin + window.location.pathname) : 'https://admin-despacho.github.io/';
    const redirectTo = base + (base.includes('?') ? '&' : '?') + 'nueva-contrasena=1';
    try {
      await this.sb.auth.resetPasswordForEmail(String(email || '').trim(), { redirectTo });
    } catch (e) { }
    return { ok: true };
  }
  // Llega desde el enlace de recuperación (Supabase crea una sesión de recuperación): nueva contraseña y cierre de las demás sesiones
  async completePasswordReset(password) {
    if (String(password || '').length < 8) throw new Error('La contraseña debe tener al menos 8 caracteres.');
    const { error } = await this.sb.auth.updateUser({ password });
    if (error && !isSamePassword(error)) throw new Error('No se pudo cambiar la contraseña: ' + error.message);
    // Si el enlace era de un invitado (o "reenviar invitación" mandó un enlace de recuperación), se intenta aceptar la invitación:
    // ya demostró ser dueño del email y definió su contraseña. NO se presenta la cuenta como activada si la activación falló:
    // se devuelve el estado real para que la pantalla lo diga y el próximo ingreso lo reintente (con "Reintentar activación").
    let activation = { pendingInvite: false, activated: false, error: null };
    try {
      const before = await this.me();
      if (before && before.status === 'INVITACION_PENDIENTE') {
        activation.pendingInvite = true;
        try { const after = await this.acceptInvite(); activation.activated = !!after && after.status === 'ACTIVO'; }
        catch (e) { activation.error = e.message; }
      }
    } catch (e) { /* sin perfil legible: el ingreso posterior decide */ }
    await this.sb.auth.signOut({ scope: 'others' }).catch(() => null);
    await this.sb.auth.signOut();
    return { ok: true, passwordSaved: true, pendingInvite: activation.pendingInvite, activated: activation.activated, activationError: activation.error };
  }
  // PDF de la hoja publicada (RC1.2): Storage privado route-pdfs, un PDF por hoja+versión, URL firmada de 60 s
  async dispatchSettings() { const { data } = await this.sb.from('dispatch_settings').select('*').eq('id', 'DEFAULT').maybeSingle(); return data || { pdf_auto_generate: true, pdf_auto_download: true }; }
  async setDispatchSettings(gen, dl) { return this._rpc('set_dispatch_settings', { p_auto_generate: gen, p_auto_download: dl }); }
  async saveRoutePdf(routeId, version, number, bytes) {
    const path = routeId + '/v' + version + '/Hoja_' + number + '_v' + version + '.pdf';
    const { error } = await this.sb.storage.from('route-pdfs').upload(path, new Uint8Array(bytes), { contentType: 'application/pdf', upsert: false });
    if (error && !/exists|Duplicate/i.test(error.message)) throw new Error('No se pudo guardar el PDF: ' + error.message); // si ya estaba subido (reintento), se registra igual
    return this._rpc('register_route_pdf', { p_route: routeId, p_version: version, p_path: path, p_error: null });
  }
  async routePdfError(routeId, version, msg) { return this._rpc('register_route_pdf', { p_route: routeId, p_version: version, p_path: null, p_error: msg }); }
  async routePdfSnapshot(routeId) { return this._rpc('route_pdf_snapshot', { p_route: routeId }); }
  async downloadRoutePdf(routeId, version) {
    const { data: p } = await this.sb.from('route_pdfs').select('storage_path, status').eq('route_id', routeId).eq('route_version', version).maybeSingle();
    if (!p || p.status !== 'OK') throw new Error('El PDF todavía no está generado.');
    const { data, error } = await this.sb.storage.from('route-pdfs').createSignedUrl(p.storage_path, 60); if (error) throw new Error(error.message);
    return await (await fetch(data.signedUrl)).blob();
  }
  async myModules() { return this._rpc('my_modules', {}); }
  async viewerRoutes() {
    const { data, error } = await this.sb.from('routes').select('*, carriers(name), route_stops(*)').order('published_at', { ascending: false }).limit(200);
    if (error) throw this._rpcErr(error);
    return (data || []).map(x => ({ ...x, carrier_name: x.carriers && x.carriers.name, stops: (x.route_stops || []).sort((a, b) => a.seq - b.seq) }));
  }
  async setPassword(password) {
    const { error } = await this.sb.auth.updateUser({ password });
    // "New password should be different from the old password" = esa contraseña YA es la guardada (un intento anterior la guardó).
    // No es un error para el invitado: se continúa con la activación en vez de dejarlo atrapado en un paso ya completado.
    if (error && !isSamePassword(error)) throw Object.assign(new Error('No se pudo guardar la contraseña: ' + error.message), { code: 'PASSWORD_FAILED' });
    await this.acceptInvite();
  }
  async acceptInvite() {
    const me = await this.me();
    if (!me || me.status !== 'INVITACION_PENDIENTE') return me;
    try { await this._fn({ action: 'accept_invite' }); }
    catch (e) {
      throw Object.assign(new Error('Tu contraseña se guardó, pero no se pudo activar tu usuario (' + e.message + '). Tocá "Reintentar activación" o avisá a Administración.'), { code: 'ACCEPT_FAILED' });
    }
    const after = await this.me();
    if (!after || after.status !== 'ACTIVO') throw Object.assign(new Error('Tu usuario todavía figura como invitación pendiente. Tocá "Reintentar activación" o avisá a Administración.'), { code: 'ACCEPT_FAILED' });
    return after;
  }
  // Autogestión: cambiar SU propia contraseña
  async changeOwnPassword(password) {
    if (String(password || '').length < 8) throw new Error('La contraseña debe tener al menos 8 caracteres.');
    const { error } = await this.sb.auth.updateUser({ password });
    if (error) throw new Error('No se pudo cambiar la contraseña: ' + error.message);
  }
  async me() {
    const s = await this.getSession(); if (!s) return null;
    const { data: p } = await this.sb.from('profiles').select('*').eq('id', s.userId).maybeSingle();
    if (!p) return null;
    // Sesiones cerradas por Administración: el token actual quedó sin permisos en el servidor; acá se cierra también en pantalla.
    if (p.sessions_revoked_at && s.iat && s.iat * 1000 < Date.parse(p.sessions_revoked_at)) { this.revokedNotice = true; try { sessionStorage.setItem('okd_revoked', '1'); } catch (e) { } await this.signOut(); return null; }
    const { data: uc } = await this.sb.from('user_carriers').select('carrier_id').eq('user_id', s.userId);
    // Permisos EFECTIVOS del usuario según el servidor (rol + permisos individuales otorgados/revocados + módulos restringidos).
    // Si no se pueden obtener, NO se devuelve un usuario con permisos supuestos: la app muestra el error con REINTENTAR.
    const ep = await this.sb.rpc('user_effective_permissions', { p_user: s.userId });
    if (ep.error || !Array.isArray(ep.data)) throw Object.assign(new Error('No se pudieron cargar tus permisos' + (ep.error && ep.error.message ? ': ' + ep.error.message : '.')), { code: 'PERMISSIONS_UNAVAILABLE' });
    return { ...p, carriers: (uc || []).map(x => x.carrier_id), effective_permissions: ep.data.slice() };
  }
  async listCarriers() { const { data, error } = await this.sb.from('carriers').select('*').order('name'); if (error) throw error; return data; }
  // Sesión estable (RC2): antes de llamar se renueva el token si está por vencer; ante 401 se renueva y se reintenta una vez;
  // si la renovación falla, la sesión realmente expiró → evento okd-session-expired (vuelve al acceso con aviso).
  async _fresh(force) {
    const { data } = await this.sb.auth.getSession(); const s = data && data.session;
    if (!s) return null;
    if (force || !s.expires_at || s.expires_at * 1000 - Date.now() < 60000) { const r = await this.sb.auth.refreshSession(); return r.data && r.data.session; }
    return s;
  }
  _expired() { if (typeof window !== 'undefined') window.dispatchEvent(new CustomEvent('okd-session-expired')); }
  async _invoke(name, opts) {
    await this._fresh(false).catch(() => null);
    let r = await this.sb.functions.invoke(name, opts);
    const st = r.error && r.error.context && r.error.context.status;
    if (st === 401) {
      const s2 = await this._fresh(true).catch(() => null);
      if (!s2) { this._expired(); return r; }
      r = await this.sb.functions.invoke(name, opts);
      if (r.error && r.error.context && r.error.context.status === 401) this._expired();
    }
    return r;
  }
  async _fn(body) {
    const { data, error } = await this._invoke('admin-users', { body });
    if (error) {
      if (error.name === 'FunctionsFetchError' || error.name === 'FunctionsRelayError') throw Object.assign(new Error('No se pudo conectar con el servidor de usuarios (admin-users). Verificá que la función esté desplegada y sus secrets cargados.'), { code: 'OFFLINE' });
      let msg = error.message, code, extra = {};
      try { const j = await error.context.json(); msg = j.error || msg; code = j.code; if (j.routes) extra.routes = j.routes; } catch (e) { }
      throw Object.assign(new Error(msg), { code }, extra);
    }
    return data;
  }
  async listUsers() { return (await this._fn({ action: 'list' })).users; }
  // ===== Fase 2B.1: hojas publicadas y recorrido =====
  _rpcErr(error) { const m = error.message || ''; let details = null; try { details = error.details ? JSON.parse(error.details) : null; } catch (e) { }
    return Object.assign(new Error(m), { code: /fetch|network|Failed/i.test(m) ? 'OFFLINE' : (m.split(':')[0] || 'ERROR'), details }); }
  async _rpc(fn, args) {
    let r; try { r = await this.sb.rpc(fn, args); } catch (e) { throw Object.assign(new Error('Sin conexión'), { code: 'OFFLINE' }); }
    if (r.error && (/JWT expired|jwt/i.test(r.error.message || '') || r.error.code === 'PGRST301')) { // token vencido: renovar y reintentar una vez
      const s2 = await this._fresh(true).catch(() => null); if (!s2) { this._expired(); throw this._rpcErr(r.error); }
      r = await this.sb.rpc(fn, args);
    }
    if (r.error) throw this._rpcErr(r.error); return r.data;
  }
  async publishRoute(p) { const r = await this._rpc('publish_route', { p }); this.flushPushQueue().catch(() => null); return r; }
  async dispatchExternalRoute(p) { return this._rpc('dispatch_external_route', { p }); }
  async beginPostPublishRevision(id) { return this._rpc('begin_post_publish_revision', { p_route: id }); }
  async publishRouteRevision(p) { const r = await this._rpc('publish_route_revision', { p }); this.flushPushQueue().catch(() => null); return r; }
  async reserveOrders(sheetKey, orders) { return this._rpc('reserve_orders', { p_sheet_key: sheetKey, p_orders: orders.map(String) }); }
  async releaseOrders(sheetKey, orders) { return this._rpc('release_orders', { p_sheet_key: sheetKey, p_orders: orders ? orders.map(String) : null }); }
  async routeStatus(id) { const { data } = await this.sb.from('routes').select('id, number, operational_status, dispatch_mode, dispatched_at, published_at, notified_at, viewed_at, started_at, completed_at').eq('id', id).maybeSingle(); return data; }
  async myRoutes() {
    const s = await this.getSession(); if (!s) throw Object.assign(new Error('Sesión inválida.'), { code: 'NO_AUTH' });
    let r; try { r = await this.sb.from('routes').select('*, carriers(name, kind, report_group), route_stops(*)').eq('responsable_id', s.userId).order('published_at', { ascending: false }); } catch (e) { throw Object.assign(new Error('Sin conexión'), { code: 'OFFLINE' }); }
    if (r.error) throw this._rpcErr(r.error);
    return (r.data || []).map(x => ({ ...x, carrier_name: x.carriers && x.carriers.name, carrier_kind: x.carriers && x.carriers.kind, carrier_report_group: x.carriers && x.carriers.report_group, stops: (x.route_stops || []).sort((a, b) => a.seq - b.seq) }));
  }
  async markDelivered(id) { return this._rpc('mark_notification_delivered', { p_route: id }); }
  async markViewed(id) { return this._rpc('mark_route_viewed', { p_route: id }); }
  async startRoute(id, kmStart) { return this._rpc('start_route', { p_route: id, p_km_start: kmStart ?? null }); }
  async setStopOutcome(stop, outcome, note, reason, opId, extra) { const r = await this._rpc('set_stop_outcome', { p_stop: stop, p_outcome: outcome, p_note: note || null, p_reason: reason || null, p_op_id: opId, p_extra: extra || null }); this.sendCustomerQueued().catch(() => null); return r; }
  async finalizeRoute(id, kmEnd) { const r = await this._rpc('finalize_route', { p_route: id, p_km_end: kmEnd ?? null }); this.sendServiceAlerts().catch(() => null); return r; }
  async arriveStop(stop, location, opId) { return this._rpc('arrive_stop', { p_stop: stop, p_location: location, p_op_id: opId }); }
  async deliveryIdentityLookup(stopId, cuil, dni) { return this._rpc('delivery_identity_lookup', { p_stop: stopId, p_cuil: cuil || null, p_dni: dni || null }); }
  async cuilHasDni(cuil) { return this._rpc('cuil_has_dni', { p_cuil: cuil }); }
  // DNI en Storage privado: subir (chofer) y URL firmada de 60 s (solo identity_docs.view). Nunca URL pública.
  async uploadIdentityDoc(cuil, file) {
    if (!['image/jpeg', 'image/png'].includes(file.mime)) throw new Error('La foto del DNI debe ser JPEG o PNG.');
    if (!(file.size > 0) || file.size > 5242880) throw new Error('La foto del DNI supera 5 MB.');
    const path = String(cuil).replace(/\D/g, '') + '/' + crypto.randomUUID() + (file.mime === 'image/png' ? '.png' : '.jpg');
    const bytes = file.blob ? file.blob : Uint8Array.from(atob(file.b64), c => c.charCodeAt(0));   // V4.16: Blob directo, sin copias base64
    const { error } = await this.sb.storage.from('identity-docs').upload(path, bytes, { contentType: file.mime, upsert: false });
    if (error) throw Object.assign(new Error(error.message), { code: /fetch|network/i.test(error.message) ? 'OFFLINE' : 'UPLOAD_FAILED' });
    return path;
  }
  async identityDocUrl(cuil) {
    const { data } = await this.sb.from('customer_identity_docs').select('storage_path').eq('cuil', cuil).maybeSingle();
    if (!data || !data.storage_path) return null;
    const { data: u, error } = await this.sb.storage.from('identity-docs').createSignedUrl(data.storage_path, 60);
    if (error) throw new Error(error.message); return u.signedUrl;
  }
  async sendCustomerQueued(ids) { const { data } = await this._invoke('internal-approvals', { body: ids ? { action: 'retry_customer', job_ids: ids } : { action: 'send_customer_queued' } }); return data && data.results; }
  async sendServiceAlerts() { const { data, error } = await this._invoke('internal-approvals', { body: { action: 'send_service_alerts' } }); if (error) throw error; return data && data.results; }
  async listVehicles() { const { data } = await this.sb.from('vehicle_service_status').select('*').order('name'); return data || []; }
  async upsertVehicle(p) { const r = await this._rpc('upsert_vehicle', { p }); this.sendServiceAlerts().catch(() => null); return r; }
  async correctVehicleKm(id, km, reason) { const r = await this._rpc('correct_vehicle_km', { p_vehicle: id, p_km: km, p_reason: reason }); this.sendServiceAlerts().catch(() => null); return r; }
  async registerService(id, km, date) { const r = await this._rpc('register_vehicle_service', { p_vehicle: id, p_km: km, p_date: date }); this.sendServiceAlerts().catch(() => null); return r; }
  async requestRouteReturn(id, reason) { return this._rpc('request_route_return', { p_route: id, p_reason: reason }); }
  async returnRequests() { const { data } = await this.sb.from('route_return_requests').select('*, routes(number)').order('created_at', { ascending: false }); return (data || []).map(x => ({ ...x, route_number: x.routes && x.routes.number })); }
  async resolveReturn(id, decision, note) { return this._rpc('resolve_route_return', { p_id: id, p_decision: decision, p_note: note }); }
  async activeRoutes() { const { data } = await this.sb.from('routes').select('id, number, operational_status, carriers(name)').in('operational_status', ['PUBLICADA', 'EN_CURSO']); return (data || []).map(r => ({ ...r, carrier_name: r.carriers && r.carriers.name })); }
  async cancelRoute(id, reason) { return this._rpc('cancel_route', { p_route: id, p_reason: reason }); }
  async addInternalStop(id, stop, version, opId, offline) { return this._rpc('add_internal_stop', { p_route: id, p_stop: stop, p_version: version, p_op_id: opId, p_offline: !!offline }); }
  async reorderInternalStops(id, order, version, opId, offline) { return this._rpc('reorder_internal_stops', { p_route: id, p_order: order, p_version: version, p_op_id: opId, p_offline: !!offline }); }
  async _ir(body) { const { data, error } = await this._invoke('internal-approvals', { body }); if (error) { let m = error.message; try { m = (await error.context.json()).error || m; } catch (e) { } throw new Error(m); } return data; }
  async pendingApprovals() {
    const { routeDiff } = await import('../../supabase/functions/_shared/internal-route.js');
    const { data, error } = await this.sb.from('route_approval_requests').select('*, routes(*, route_stops(*))').eq('status', 'PENDING');
    if (error) throw new Error(error.message);
    const ids = [...new Set((data || []).map(a => a.routes.responsable_id))];
    const { data: ps } = ids.length ? await this.sb.from('profiles').select('id, full_name').in('id', ids) : { data: [] };
    return (data || []).map(a => { const r = { ...a.routes, stops: a.routes.route_stops }; return { ...a, route: r, driver_name: ((ps || []).find(p => p.id === r.responsable_id) || {}).full_name, diff: routeDiff(r) }; });
  }
  async reviewApproval(id, decision, note) { await this._rpc('review_route_approval', { p_request: id, p_decision: decision, p_note: note || null }); await this._ir({ action: 'send_queued' }).catch(() => null); }
  async sendQueuedApprovalEmails(ids) { return (await this._ir(ids ? { action: 'retry', job_ids: ids } : { action: 'send_queued' })).results; }
  async customerEmailJobs() { const { data } = await this.sb.from('customer_email_jobs').select('*').order('queued_at', { ascending: false }).limit(100); return data || []; }
  async approvalEmailJobs() { const { data } = await this.sb.from('approval_email_jobs').select('*').order('queued_at', { ascending: false }).limit(100); return data || []; }
  async irSettings() { return (await this._ir({ action: 'settings_get' })).settings; }
  async setIrSettings(s) { return (await this._ir({ action: 'settings_set', settings: s })).settings; }
  // Passkeys (Edge Function passkeys + Supabase Auth)
  async _pk(body) { const { data, error } = await this._invoke('passkeys', { body }); if (error) { let m = error.message; try { m = (await error.context.json()).error || m; } catch (e) { } throw new Error(m); } return data; }
  async passkeyRegisterOptions() { const o = (await this._pk({ action: 'register_options' })).options; this._regCh = o.challenge; const d = x => Uint8Array.from(atob(x.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((x.length + 3) % 4)), c => c.charCodeAt(0));
    return { challenge: d(o.challenge), rp: o.rp, user: { ...o.user, id: d(o.user.id) }, excludeCredentials: [] }; }
  async passkeyRegisterSave(rec) { return (await this._pk({ action: 'register_verify', challenge: this._regCh, response: rec.json, device_name: rec.device_name })).passkey; }
  async passkeyLoginOptions(email) { const o = (await this._pk({ action: 'login_options', email })).options; this._logCh = o.challenge; return { challenge: Uint8Array.from(atob(o.challenge.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((o.challenge.length + 3) % 4)), c => c.charCodeAt(0)), rpId: o.rpId }; }
  async passkeyLogin(assertion) {
    const r = await this._pk({ action: 'login_verify', challenge: this._logCh, response: assertion.json });
    const { error } = await this.sb.auth.verifyOtp({ type: 'magiclink', token_hash: r.session.token_hash });
    if (error) throw new Error(error.message); return { ok: true };
  }
  async myPasskeys() { const { data } = await this.sb.from('user_passkeys').select('id, device_name, created_at, last_used_at, revoked_at'); return data || []; }
  async revokePasskey(id) { return this._rpc('revoke_passkey', { p_id: id }); }
  async pushPublicKey() { return this._rpc('push_public_key', {}); }
  async savePushSubscription(p) { return this._rpc('save_push_subscription', { p }); }
  async driverInternalLocations() { return (await this._rpc('driver_internal_locations', {})) || []; }
  async revokePushSubscription(endpoint) { return this._rpc('revoke_push_subscription', { p_endpoint: endpoint }); }
  async flushPushQueue() { const { data, error } = await this._invoke('push-notifications', { body: { action: 'flush' } }); if (error) throw error; return data; }
  async myNotifications() { const { data } = await this.sb.from('notifications').select('*').order('created_at', { ascending: false }).limit(50); return data || []; }
  // En vivo: Supabase Realtime sobre hojas y notificaciones + sondeo de respaldo (si Realtime falla, igual aparece al reconectar)
  subscribe(cb, onStatus) {
    const ch = this.sb.channel('okd-live').on('postgres_changes', { event: '*', schema: 'public', table: 'routes' }, () => cb())
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'notifications' }, () => cb()).subscribe(st => onStatus && onStatus(st));
    const t = setInterval(() => cb(), 20000);
    return () => { clearInterval(t); this.sb.removeChannel(ch); };
  }
  async shippingConfirm(p) {
    const { data, error } = await this.sb.rpc('confirm_shipping_amount', { p: p });
    if (error) throw new Error(error.message);
    return data;
  }
  async shippingInvalidate(p) { await this.sb.rpc('invalidate_shipping_confirmation', { p_sheet_key: p.sheet_key, p_ship_order: p.ship_order, p_fingerprint: p.fingerprint }); }
  // Informe comercial de Cristian Torres (Edge Function commercial-reports)
  async reports(action, body = {}) {
    const { data, error } = await this._invoke('commercial-reports', { body: { action, ...body } });
    if (error) { let msg = error.message; try { const j = await error.context.json(); msg = j.error || msg; } catch (e) { } throw new Error(msg); }
    return data;
  }
  async action(action, payload = {}) { const r = await this._fn({ action, ...payload }); return r.user || r; }
  async activeRoutes(userId) {
    const { data, error } = await this.sb.rpc('user_active_routes', { p_user: userId });
    if (error) throw new Error(error.message);
    return data || [];
  }
  // Selector de RESPONSABLE: la lista la decide el servidor (RPC responsables_disponibles)
  async responsables(carrierId) {
    const { data, error } = await this.sb.rpc('responsables_disponibles', { p_carrier: carrierId });
    if (error) throw new Error(error.message);
    return data;
  }
}

// RC2: borradores, historial, configuración, auditoría, backup y dashboard
import { SupabaseAdmin } from './supabase-admin.js';
import { SupabaseRC4 } from './supabase-rc4.js';
Object.assign(SupabaseApi.prototype, SupabaseAdmin);
Object.assign(SupabaseApi.prototype, SupabaseRC4);
