// HOJAS INTERNAS PENDIENTES DE APROBACIÓN + CONFIGURACIÓN → NOTIFICACIONES → RUTAS INTERNAS (Fase 2B.2)
import { esc } from './util.js';
import { hasPerm, ROLE_LABEL } from '../../supabase/functions/_shared/rules.js';

export class ApprovalsPanel {
  constructor(api, me) { this.api = api; this.me = me; this.el = document.getElementById('usersPanel'); this.msg = null; }
  async open() {
    this.el.hidden = false;
    this.el.innerHTML = '<header class="top"><img src="/logo.png" alt="OK Accesorios"><div class="ttl"><b>DESPACHO</b><span>Rutas internas</span></div><div class="sp"></div>' +
      '<span class="who-chip">' + esc(this.me.full_name) + ' · <b>' + esc(ROLE_LABEL[this.me.role] || this.me.role) + '</b></span><button class="tbtn" type="button" id="apClose">Volver al panel</button></header><div class="up-wrap" id="apWrap"></div>';
    this.el.querySelector('#apClose').onclick = () => { if (location.hash) history.replaceState(null, '', location.pathname); this.el.hidden = true; this.el.innerHTML = ''; };
    await this.render();
  }
  async render() {
    const w = this.el.querySelector('#apWrap');
    let list = [], jobs = [], st = null, users = [];
    try { list = hasPerm(this.me, 'can_approve_internal_route_changes') ? await this.api.pendingApprovals() : []; } catch (e) { this.msg = { err: true, text: e.message }; }
    const canCfg = hasPerm(this.me, 'settings.manage');
    if (canCfg) { try { [st, jobs, users] = await Promise.all([this.api.irSettings(), this.api.approvalEmailJobs(), this.api.listUsers()]); } catch (e) { } }
    const mark = m => '<span class="apr-mark' + (m.startsWith('PARADA AGREGADA') ? ' add' : m.startsWith('INCIDENCIA') ? ' inc' : '') + '">' + esc(m) + '</span>';
    w.innerHTML = '<div class="up-head"><h2>HOJAS INTERNAS PENDIENTES DE APROBACIÓN</h2></div>' + (this.msg ? '<div class="up-msg ' + (this.msg.err ? 'err' : 'ok') + '" id="apMsg">' + esc(this.msg.text) + '</div>' : '') +
      (list.length ? list.map(a => { const r = a.route, d = a.diff;
        return '<div class="apr-item" data-ap="' + a.id + '"><b>HOJA ' + esc(r.number) + '</b> · ' + esc(a.driver_name || '') + ' · ' + new Date(r.completed_at).toLocaleString('es-AR') + ' · <b>COMPLETADA · PENDIENTE DE APROBACIÓN</b>' +
          (a.supervisor_missing ? ' <span class="apr-mark inc">SIN SUPERIOR CONFIGURADO</span>' : '') +
          '<div class="apr-cols"><div><h4>RUTA PUBLICADA ORIGINAL</h4><ol>' + d.original.map(o => '<li>' + esc(o.client_name) + (o.bultos ? ' · ' + o.bultos + ' bultos' : '') + '</li>').join('') + '</ol></div>' +
          '<div><h4>RUTA REAL EJECUTADA</h4><ol>' + d.executed.map(x => '<li>' + esc(x.client_name) + (x.action !== 'ENTREGA' ? ' · ' + esc(x.action) : '') + (x.bultos ? ' · ' + x.bultos + ' bultos' : '') + x.marks.map(mark).join('') + '</li>').join('') + '</ol></div></div>' +
          '<p class="rp-note">Agregadas: ' + d.added + ' · Movidas: ' + d.moved + ' · Incidencias: ' + d.incidents + ' · Bultos: ' + d.bultos + '</p>' +
          '<div class="uact"><button class="btn go" type="button" data-ok>APROBAR Y CERRAR HOJA</button><input class="ed" data-note placeholder="Motivo de la aclaración" style="min-width:260px"><button class="btn soft" type="button" data-obs>SOLICITAR ACLARACIÓN</button><span class="shiperr" hidden></span></div></div>'; }).join('')
        : '<p class="rp-empty" id="apEmpty">No hay hojas internas pendientes de aprobación.</p>') +
      (canCfg && st ? '<section class="step rp-step" id="irCfg"><h2><span class="n">@</span>CONFIGURACIÓN → NOTIFICACIONES → RUTAS INTERNAS</h2>' +
        '<div class="ufilters"><label class="rp-lbl">Superior por defecto <select id="irSup"><option value="">— ninguno (se avisa a Administración) —</option>' + users.filter(u => hasPerm(u, 'can_approve_internal_route_changes')).map(u => '<option value="' + u.id + '"' + (st.supervisor_user_id === u.id ? ' selected' : '') + '>' + esc(u.full_name) + '</option>').join('') + '</select></label>' +
        '<label class="rp-lbl chk"><input type="checkbox" id="irAdmin"' + (st.copy_admin !== false ? ' checked' : '') + '> Copiar a Administración</label>' +
        '<label class="rp-lbl" style="flex:1;min-width:280px">Emails adicionales <input id="irExtra" value="' + esc((st.extra_emails || []).join(', ')) + '" style="width:100%"></label>' +
        '<label class="rp-lbl chk"><input type="checkbox" id="irEmail"' + (st.email_enabled !== false ? ' checked' : '') + '> Email</label>' +
        '<label class="rp-lbl chk"><input type="checkbox" id="irPush"' + (st.push_enabled ? ' checked' : '') + '> Push (preparado)</label><button class="btn dark" type="button" id="irSave">GUARDAR</button></div>' +
        '<p class="rp-note">El superior de cada chofer se configura en Usuarios → EDITAR; si no tiene, se usa este.</p>' +
        '<div class="utable-wrap"><table class="utable"><thead><tr><th>HOJA / TIPO</th><th>DESTINATARIO</th><th>ESTADO</th><th>ERROR</th><th></th></tr></thead><tbody>' +
        (jobs.length ? jobs.map(j => '<tr><td>' + esc(j.kind === 'INTERNAL_ROUTE_OBSERVED' ? 'Aclaración' : 'Pendiente de aprobación') + '</td><td>' + esc(j.recipient) + '</td><td><span class="ust ' + (j.status === 'SENT' ? 'ACTIVO' : j.status === 'ERROR' ? 'DESHABILITADO' : 'INVITACION_PENDIENTE') + '">' + j.status + '</span></td><td>' + esc(j.error || '') + '</td><td>' + (j.status !== 'SENT' ? '<button class="btn soft" type="button" data-retry="' + j.id + '">REINTENTAR EMAIL</button>' : '') + '</td></tr>').join('') : '<tr><td colspan="5">Sin emails.</td></tr>') +
        '</tbody></table></div></section>' : '');
    if (hasPerm(this.me, 'routes.manage_all_drafts') || hasPerm(this.me, 'vehicles.manage')) await this.renderOps(w);
    if (canCfg) await this.renderPdfCfg(w);
    w.querySelectorAll('.apr-item').forEach(box => {
      const id = box.dataset.ap, er = box.querySelector('.shiperr');
      box.querySelector('[data-ok]').onclick = async () => { try { await this.api.reviewApproval(id, 'APPROVED', null); this.msg = { text: 'Hoja aprobada: COMPLETADA · APROBADA.' }; } catch (e) { this.msg = { err: true, text: e.message }; } this.render(); };
      box.querySelector('[data-obs]').onclick = async () => {
        const note = box.querySelector('[data-note]').value.trim();
        if (!note) { er.textContent = 'Indicá el motivo de la aclaración.'; er.hidden = false; return; }
        try { await this.api.reviewApproval(id, 'OBSERVED', note); this.msg = { text: 'Aclaración solicitada al chofer: COMPLETADA · OBSERVADA.' }; } catch (e) { this.msg = { err: true, text: e.message }; } this.render();
      };
    });
    const sv = w.querySelector('#irSave');
    if (sv) sv.onclick = async () => {
      try { await this.api.setIrSettings({ supervisor_user_id: w.querySelector('#irSup').value || null, copy_admin: w.querySelector('#irAdmin').checked, extra_emails: w.querySelector('#irExtra').value.split(',').map(x => x.trim()).filter(Boolean), email_enabled: w.querySelector('#irEmail').checked, push_enabled: w.querySelector('#irPush').checked }); this.msg = { text: 'Configuración guardada.' }; }
      catch (e) { this.msg = { err: true, text: e.message }; } this.render();
    };
    w.querySelectorAll('[data-retry]').forEach(b => b.onclick = async () => { const r = await this.api.sendQueuedApprovalEmails([b.dataset.retry]); this.msg = { err: r.some(x => x.status !== 'SENT'), text: 'Reintento: ' + r.map(x => x.status).join(', ') }; this.render(); });
  }
  // Operación (Fase 2B.3): devoluciones, cancelar hoja activa, vehículos/km/service y emails a clientes
  async renderOps(w) {
    const [rets, act, veh, cj] = await Promise.all([this.api.returnRequests().catch(() => []), this.api.activeRoutes().catch(() => []), this.api.listVehicles().catch(() => []), this.api.customerEmailJobs().catch(() => [])]);
    const sec = document.createElement('div');
    sec.innerHTML = '<section class="step rp-step" id="opsRet"><h2><span class="n">↩</span>SOLICITUDES DE DEVOLUCIÓN DE HOJA</h2>' +
      (rets.filter(x => x.status === 'PENDING').map(x => '<div class="pkrow" data-rr="' + x.id + '"><span>Hoja ' + esc(x.route_number || '') + ' · ' + esc(x.reason) + '</span><span class="uact"><input class="ed" data-rnote placeholder="Resolución"><button class="btn soft" type="button" data-rres="RESOLVED">RESOLVER</button><button class="btn soft" type="button" data-rres="REJECTED">RECHAZAR</button></span></div>').join('') || '<p class="rp-empty">Sin solicitudes pendientes.</p>') + '</section>' +
      '<section class="step rp-step" id="opsCancel"><h2><span class="n">✕</span>CANCELAR HOJA ACTIVA</h2><div class="ufilters"><select id="cxRoute">' + act.map(r => '<option value="' + r.id + '">Hoja ' + esc(r.number) + ' · ' + esc(r.carrier_name || '') + ' · ' + r.operational_status + '</option>').join('') + '</select><input class="ed" id="cxWhy" placeholder="Motivo (obligatorio)"><button class="btn danger" type="button" id="cxGo"' + (act.length ? '' : ' disabled') + '>CANCELAR HOJA</button></div><p class="rp-note">Libera los pedidos; el correlativo no se reutiliza.</p></section>' +
      '<section class="step rp-step" id="opsVeh"><h2><span class="n">🚐</span>VEHÍCULOS · KM · SERVICE</h2><div class="utable-wrap"><table class="utable"><thead><tr><th>VEHÍCULO</th><th>PATENTE</th><th>KM</th><th>DESDE SERVICE</th><th>ESTADO</th><th>ACCIONES</th></tr></thead><tbody>' +
      veh.map(v => '<tr data-veh="' + v.id + '"><td>' + esc(v.name) + (v.active ? '' : ' (inactivo)') + '</td><td>' + esc(v.plate) + '</td><td>' + v.current_km + '</td><td>' + v.km_since_service + ' / ' + v.service_interval_km + '</td><td>' + (v.service_due ? '<span class="ust DESHABILITADO">SERVICE VENCIDO</span>' : '<span class="ust ACTIVO">OK</span>') + '</td>' +
        '<td><div class="uact"><input class="ed" data-vkm placeholder="Km" size="7"><button class="btn soft" type="button" data-vsvc>REGISTRAR SERVICE REALIZADO</button><input class="ed" data-vwhy placeholder="Motivo corrección"><button class="btn soft" type="button" data-vfix>CORREGIR KM</button></div></td></tr>').join('') + '</tbody></table></div>' +
      '<div class="ufilters" style="margin-top:8px"><input class="ed" id="nvName" placeholder="Nombre"><input class="ed" id="nvPlate" placeholder="Patente"><input class="ed" id="nvKm" placeholder="Km actual" size="8"><input class="ed" id="nvInt" placeholder="Intervalo service (10000)" size="10"><button class="btn dark" type="button" id="nvSave">AGREGAR VEHÍCULO</button></div></section>' +
      '<section class="step rp-step" id="opsCust"><h2><span class="n">@</span>EMAILS A CLIENTES</h2><div class="utable-wrap"><table class="utable"><thead><tr><th>TIPO</th><th>DESTINATARIO</th><th>ESTADO</th><th>ERROR</th><th></th></tr></thead><tbody>' +
      (cj.length ? cj.map(j => '<tr><td>' + ({ ON_THE_WAY: 'Va en camino', DELIVERED: 'Entregado', PARTIAL: 'Entrega parcial' })[j.kind] + '</td><td>' + esc(j.recipient) + '</td><td>' + j.status + '</td><td>' + esc(j.error || '') + '</td><td>' + (j.status !== 'SENT' ? '<button class="btn soft" type="button" data-cretry="' + j.id + '">REINTENTAR EMAIL</button>' : '') + '</td></tr>').join('') : '<tr><td colspan="5">Sin emails.</td></tr>') + '</tbody></table></div></section>';
    w.appendChild(sec);
    const run = async (fn, ok) => { try { await fn(); this.msg = { text: ok }; } catch (e) { this.msg = { err: true, text: e.message }; } this.render(); };
    sec.querySelectorAll('[data-rres]').forEach(b => b.onclick = () => { const row = b.closest('[data-rr]'); run(() => this.api.resolveReturn(row.dataset.rr, b.dataset.rres, row.querySelector('[data-rnote]').value), 'Solicitud de devolución ' + (b.dataset.rres === 'RESOLVED' ? 'resuelta' : 'rechazada') + '.'); });
    const cx = sec.querySelector('#cxGo'); cx.onclick = () => { if (confirm('¿Cancelar la hoja? Se liberan sus pedidos.')) run(() => this.api.cancelRoute(sec.querySelector('#cxRoute').value, sec.querySelector('#cxWhy').value), 'Hoja cancelada. Pedidos liberados.'); };
    sec.querySelectorAll('[data-vsvc]').forEach(b => b.onclick = () => { const row = b.closest('[data-veh]'); run(() => this.api.registerService(row.dataset.veh, Number(row.querySelector('[data-vkm]').value), new Date().toISOString().slice(0, 10)), 'Service registrado.'); });
    sec.querySelectorAll('[data-vfix]').forEach(b => b.onclick = () => { const row = b.closest('[data-veh]'); run(() => this.api.correctVehicleKm(row.dataset.veh, Number(row.querySelector('[data-vkm]').value), row.querySelector('[data-vwhy]').value), 'Kilometraje corregido (auditado).'); });
    sec.querySelector('#nvSave').onclick = () => run(() => this.api.upsertVehicle({ name: sec.querySelector('#nvName').value, plate: sec.querySelector('#nvPlate').value, current_km: Number(sec.querySelector('#nvKm').value) || 0, service_interval_km: Number(sec.querySelector('#nvInt').value) || 10000 }), 'Vehículo guardado.');
    sec.querySelectorAll('[data-cretry]').forEach(b => b.onclick = () => run(() => this.api.sendCustomerQueued([b.dataset.cretry]), 'Reintento enviado.'));
  }
  // CONFIGURACIÓN → DESPACHO → PDF (RC1.2)
  async renderPdfCfg(w) {
    const c = await this.api.dispatchSettings().catch(() => null); if (!c) return;
    const sec = document.createElement('section'); sec.className = 'step rp-step'; sec.id = 'pdfCfg';
    sec.innerHTML = '<h2><span class="n">PDF</span>CONFIGURACIÓN → DESPACHO → PDF</h2>' +
      '<label class="rp-lbl chk"><input type="checkbox" id="pcGen"' + (c.pdf_auto_generate ? ' checked' : '') + '> GENERAR PDF AUTOMÁTICAMENTE AL PUBLICAR <em>(recomendado)</em></label>' +
      '<label class="rp-lbl chk"><input type="checkbox" id="pcDl"' + (c.pdf_auto_download ? ' checked' : '') + '> DESCARGAR PDF AUTOMÁTICAMENTE AL PUBLICAR</label>' +
      '<p class="rp-note">Al publicar una hoja, OK Despacho genera y guarda el PDF. Si esta opción está activa, también intenta descargarlo en este dispositivo.</p><button class="btn dark" type="button" id="pcSave">GUARDAR</button>';
    w.appendChild(sec);
    sec.querySelector('#pcSave').onclick = async () => { try { await this.api.setDispatchSettings(sec.querySelector('#pcGen').checked, sec.querySelector('#pcDl').checked); this.msg = { text: 'Configuración de PDF guardada.' }; } catch (e) { this.msg = { err: true, text: e.message }; } this.render(); };
  }
}
