// V4.27 · CAMPANA de aprobaciones para quienes aprueban (Superior Despacho con permiso / Administrador General).
// Contador = solicitudes de RUTA INTERNA PENDIENTES que le toca atender, con la MISMA fuente y reglas que «PARA RESOLVER»
// (listOperationalRequests): sin duplicados, baja sola al resolverse y nunca muestra equipos ajenos. Tocar un aviso abre la solicitud.
// Solo lectura y navegación: si algo falla, la campana no se muestra y NADA se bloquea.
import { hasPerm } from '../../supabase/functions/_shared/rules.js';
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
export function initApprovalsBell(api) {
  let items = null, me = null, busy = false, raf = 0;
  const canApprove = u => !!u && u.status === 'ACTIVO' && (u.role === 'ADMIN' || (u.role === 'SUPERVISOR_DESPACHO' && hasPerm(u, 'can_approve_internal_route_changes')));
  const paint = () => {
    raf = 0;
    // SOLO en la barra superior A LA VISTA: la del módulo si #usersPanel está abierto; si no, la del armazón (la otra queda tapada)
    const up = document.getElementById('usersPanel'), upOpen = !!up && getComputedStyle(up).display !== 'none' && !!up.querySelector('.rc4main .topbar .topact');
    document.querySelectorAll('.rc4main .topbar .topact').forEach(act => {
      let b = act.querySelector(':scope > .apb');
      const target = upOpen ? act.closest('#usersPanel') : !act.closest('#usersPanel');
      if (!items || !canApprove(me) || !target) { if (b) b.remove(); return; }
      if (!b) { b = document.createElement('div'); b.className = 'apb'; act.insertBefore(b, act.firstChild); }
      const n = items.length, sig = items.map(q => q.id + ':' + (q.route_number || '')).join('|');
      if (b.dataset.sig === sig && b.firstChild) return;   // sin cambios: NO se redibuja (evita repintados en bucle)
      b.dataset.sig = sig;
      b.innerHTML = '<button type="button" class="apb-btn" aria-haspopup="true" aria-expanded="false" title="Aprobaciones pendientes" aria-label="Aprobaciones pendientes: ' + n + '">' +
        '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.7 21a2 2 0 0 1-3.4 0"/></svg>' +
        (n ? '<span class="apb-n" data-n="' + n + '">' + (n > 99 ? '99+' : n) + '</span>' : '') + '</button>' +
        '<div class="apb-pop" hidden><b>' + (n ? n + ' solicitud' + (n === 1 ? '' : 'es') + ' sin atender' : 'Sin solicitudes pendientes') + '</b>' +
        items.slice(0, 8).map(q => '<a href="#/solicitudes?apr=' + encodeURIComponent(q.id) + '" class="apb-it" data-apr="' + esc(q.id) + '"><span>HOJA ' + esc(q.route_number || '—') + ' · ' + esc(q.requested_by_name || '') + '</span><small>' + esc(q.reason || '') + '</small></a>').join('') +
        '<a href="#/solicitudes" class="apb-all">Ver todas en Solicitudes / Aprobaciones</a></div>';
      const btn = b.querySelector('.apb-btn'), pop = b.querySelector('.apb-pop');
      btn.onclick = e => { e.stopPropagation(); pop.hidden = !pop.hidden; btn.setAttribute('aria-expanded', String(!pop.hidden)); };
      pop.querySelectorAll('a').forEach(a => a.addEventListener('click', () => { pop.hidden = true; }));
    });
  };
  const later = () => { if (!raf) raf = requestAnimationFrame(paint); };
  const refresh = async () => {
    if (busy) return; busy = true;
    try {
      me = api.me ? await api.me() : null;
      if (!canApprove(me)) { items = null; later(); return; }
      const rows = await api.listOperationalRequests(me.role === 'ADMIN' ? 'pendientes' : 'asignadas');
      items = (rows || []).filter(q => q.request_type === 'INTERNAL_ROUTE_CHANGE' && q.status === 'PENDING' && (me.role === 'ADMIN' || q.supervisor_user_id === me.id));
    } catch (e) { items = null; } finally { busy = false; later(); }
  };
  // la barra se redibuja en cada pantalla; se ignoran los cambios DENTRO de la campana (si no, se repintaría en bucle)
  new MutationObserver(ms => { if (ms.some(m => !(m.target.closest && m.target.closest('.apb')))) later(); }).observe(document.body, { childList: true, subtree: true });
  addEventListener('hashchange', refresh); addEventListener('okd:approvals-changed', refresh);
  document.addEventListener('click', e => { if (!e.target.closest || !e.target.closest('.apb')) document.querySelectorAll('.apb-pop').forEach(p => { p.hidden = true; }); });
  setInterval(() => { if (document.visibilityState === 'visible') refresh(); }, 60000);
  refresh();
  return { refresh };
}
