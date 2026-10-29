// =====================================================================
// "⇄ Cambiar rol": cambia la VISTA entre el perfil habitual del usuario y "Transportista" (Mis rutas).
//  · Solo para usuarios con el permiso "Permitir asignación de hojas de ruta" (routes.receive_internal) cuyo perfil habitual no es
//    de transportista. NO modifica el rol guardado ni concede permisos: cada acción la valida el servidor (solo sus hojas internas).
//  · Misma cuenta, sin cerrar sesión: la vista elegida se recuerda en sessionStorage y se recarga la app en esa vista.
//  · Antes de cambiar se guarda el trabajo con el mecanismo existente (RouteStore.flush del constructor); si hay una ventana con
//    trabajo abierto (publicación, formulario) se ADVIERTE y no se cambia sin confirmación. Nunca se publica nada al cambiar.
// =====================================================================
import { hasPerm, ROLE_LABEL } from '../../supabase/functions/_shared/rules.js';
import { esc } from './util.js';

const key = me => 'okd_view:' + me.id;
export const canSwitch = me => !!me && hasPerm(me, 'routes.receive_internal') && !['TRANSPORTISTA', 'TRANSPORTISTA_INTERNO'].includes(me.role);
export function viewMode(me) {
  try { return canSwitch(me) && sessionStorage.getItem(key(me)) === 'TRANSPORTISTA' ? 'TRANSPORTISTA' : 'PERFIL'; } catch (e) { return 'PERFIL'; }
}
export const profileLabel = me => ROLE_LABEL[me.role] || me.role;
export const viewLabel = me => (viewMode(me) === 'TRANSPORTISTA' ? 'Transportista' : profileLabel(me));
export function setMode(me, mode) { try { if (mode === 'TRANSPORTISTA') sessionStorage.setItem(key(me), mode); else sessionStorage.removeItem(key(me)); } catch (e) { } }

// Bloque "ESTÁS COMO: … ⇄ Cambiar rol" (debajo del nombre del usuario: menú lateral en computadora, encabezado en celular)
export function switcherHtml(me) {
  if (!canSwitch(me)) return '';
  return '<div class="rolesw" data-rolesw-box><span class="rolesw-now">ESTÁS COMO: <b data-rolesw-now>' + esc(viewLabel(me)) + '</b></span>' +
    '<button class="rolesw-btn" type="button" data-rolesw>⇄ Cambiar rol</button></div>';
}

// Guarda el trabajo antes de cambiar de vista. Devuelve false si el usuario prefiere quedarse.
// Trabajo SIN GUARDAR en la pantalla del chofer (vista Transportista o Solo Lectura): paradas nuevas, entregas con datos, firma o foto, km.
// Las operaciones ya guardadas sin conexión NO se cuentan: quedan en la cola del equipo y no se pierden al cambiar de vista.
export function driverPending(doc = document) {
  const has = el => !!el && !el.hidden && el.offsetParent !== null;
  const filled = root => [...root.querySelectorAll('input:not([type=hidden]):not([type=file]):not([type=radio]):not([type=checkbox]), textarea')].some(i => (i.value || '').trim());
  const out = [], add = doc.getElementById('drvAdd');
  if (has(add) && (filled(add) || (add.querySelector('#naLocPick') && add.querySelector('#naLocPick').textContent.trim()))) out.push('una parada nueva sin agregar');
  doc.querySelectorAll('#drv .drv-form').forEach(f => {
    if (!has(f)) return;
    const cv = f.querySelector('[data-sig]'); let ink = false;
    if (cv && cv.width) { try { const px = cv.getContext('2d').getImageData(0, 0, cv.width, cv.height).data; for (let i = 3; i < px.length; i += 16) if (px[i]) { ink = true; break; } } catch (e) { } }
    const prev = f.querySelector('[data-dniprev]'), st = f.querySelector('[data-dnist]');
    const photo = (prev && !prev.hidden) || (st && /Procesando/.test(st.textContent || ''));
    if (filled(f) || ink || photo) out.push('una entrega sin guardar' + (photo ? ' (con foto del DNI)' : ink ? ' (con firma)' : ''));
  });
  if ([...doc.querySelectorAll('#drvKm, #drvKmIni')].some(i => (i.value || '').trim())) out.push('un kilometraje sin confirmar');
  return out;
}
async function saveWork() {
  const pend = driverPending();
  if (pend.length && !confirm('Tenés sin guardar: ' + pend.join(', ') + '.\n\nSi cambiás de vista ahora, eso se descarta (nombre, CUIL y firma de una entrega se recuperan al volver; la foto del DNI no). ' +
      'Tocá CANCELAR para quedarte y guardarlo. ¿Cambiar de vista igual?')) return false;
  const open = document.querySelector('#publishModal, .umodal:not([hidden]) form, .umodal:not([hidden]) input:not([type=hidden])');
  if (open && !confirm('Hay una ventana con trabajo abierto (sin guardar). Si cambiás de vista ahora, se cierra sin publicar ni enviar nada. ¿Cambiar igual?')) return false;
  try {
    // eslint-disable-next-line no-undef
    if (typeof RouteStore !== 'undefined' && RouteStore.flush) { await RouteStore.flush(); await new Promise(r => setTimeout(r, 800)); }   // borrador local + sincronización existente
  } catch (e) {
    return confirm('No se pudo confirmar el guardado del borrador (' + (e.message || e) + '). Los datos quedan en este equipo. ¿Cambiar de vista igual?');
  }
  return true;
}

export async function switchTo(me, mode) {
  if (mode === viewMode(me)) return;
  if (mode === 'TRANSPORTISTA' && !canSwitch(me)) return;
  if (!(await saveWork())) return;
  setMode(me, mode);
  history.replaceState(null, '', location.pathname + (mode === 'TRANSPORTISTA' ? '#/mis-rutas' : ''));
  location.reload();   // misma sesión: la app arranca en la vista elegida
}

function closeMenu() { const m = document.getElementById('roleswMenu'); if (m) m.remove(); }
// Un único manejador global (los paneles se redibujan): abre las dos opciones y cambia de vista
export function wireSwitcher(getMe) {
  if (window.__okdRoleSw) return; window.__okdRoleSw = true;
  document.addEventListener('click', ev => {
    const go = ev.target.closest && ev.target.closest('[data-rolesw-go]');
    if (go) { ev.preventDefault(); const me = getMe(); closeMenu(); if (me) switchTo(me, go.dataset.roleswGo); return; }
    const btn = ev.target.closest && ev.target.closest('[data-rolesw]');
    if (!btn) { if (!(ev.target.closest && ev.target.closest('#roleswMenu'))) closeMenu(); return; }
    ev.preventDefault(); const me = getMe(); if (!me || !canSwitch(me)) return;
    if (document.getElementById('roleswMenu')) return closeMenu();
    const cur = viewMode(me), m = document.createElement('div'); m.id = 'roleswMenu'; m.className = 'rolesw-menu'; m.setAttribute('role', 'menu');
    m.innerHTML = [['PERFIL', profileLabel(me)], ['TRANSPORTISTA', 'Transportista']].map(([k, t]) =>
      '<button type="button" role="menuitem" data-rolesw-go="' + k + '"' + (k === cur ? ' aria-current="true"' : '') + '>' + esc(t) + (k === cur ? ' <small>(vista actual)</small>' : '') + '</button>').join('');
    btn.closest('[data-rolesw-box]').appendChild(m);
  });
}

// Operaciones del chofer guardadas en este equipo y todavía no confirmadas por el servidor (cola sin conexión). Nunca se borran acá.
export function pendingQueue(me) { try { return (JSON.parse(localStorage.getItem('okd_drv_queue:' + me.id) || '[]') || []).length; } catch (e) { return 0; } }

// Permiso quitado en la vista Transportista (tras un rechazo del servidor o detectado por el vigilante): vuelve al perfil habitual.
// La cola sin conexión se CONSERVA (no se borra ni se marca como enviada); el servidor seguirá rechazando esas operaciones.
export async function checkRevoked(api, me, fresh) {
  if (!fresh) { try { fresh = await api.me(); } catch (e) { return false; } }   // sin conexión: se vuelve a verificar más tarde
  if (fresh && canSwitch(fresh)) return false;
  setMode(me, 'PERFIL'); const n = pendingQueue(me);
  alert('Se quitó tu permiso para realizar hojas asignadas. Volvés a tu perfil habitual. Lo que ya registraste se conserva.' +
    (n ? '\n\nQuedan ' + n + ' cambio(s) guardados en este equipo SIN sincronizar: no se enviaron ni se borraron. Consultá con el administrador.' : ''));
  history.replaceState(null, '', location.pathname); location.reload();
  return true;
}

// Vigilante: detecta el permiso quitado con la sesión ABIERTA, aunque el usuario no haga nada (cada 30 s, al volver a la app, al
// recuperar el foco o la conexión). Vista Transportista → vuelve al perfil. Perfil habitual → quita el selector sin recargar ni tocar el
// trabajo en curso. El servidor sigue rechazando cualquier operación no autorizada.
export function watchRevocation(api, getMe, setMe) {
  if (window.__okdRevWatch) return; window.__okdRevWatch = true; let busy = false;
  // firma de los permisos efectivos (online: los del servidor; demo: rol + permisos individuales + módulos)
  const sig = u => JSON.stringify(Array.isArray(u.effective_permissions) ? u.effective_permissions.slice().sort() : [u.role, u.permission_overrides || {}, u.disabled_modules || []]);
  const check = async () => {
    const me = getMe(); if (!me || busy) return;
    busy = true;
    try {
      let fresh; try { fresh = await api.me(); } catch (e) { return; }   // sin conexión o permisos no disponibles: se conserva lo confirmado (no se amplía)
      if (!fresh) return;
      if (!hasPerm(me, 'routes.receive_internal') || canSwitch(fresh)) {   // cambios que no son la revocación del permiso de asignación
        if (sig(fresh) !== sig(me)) { setMe(fresh); if (!canSwitch(fresh)) document.querySelectorAll('[data-rolesw-box]').forEach(b => b.remove());
          if (viewMode(me) !== 'TRANSPORTISTA' && window.OKD_ON_PERMS_CHANGED) window.OKD_ON_PERMS_CHANGED(fresh); }
        return;
      }
      if (viewMode(me) === 'TRANSPORTISTA') { await checkRevoked(api, me, fresh); return; }
      setMe(fresh); closeMenu(); document.querySelectorAll('[data-rolesw-box]').forEach(b => b.remove());
      const n = pendingQueue(me);
      alert('Se quitó tu permiso "Permitir asignación de hojas de ruta". Seguís con tu perfil habitual.' +
        (n ? '\n\nQuedan ' + n + ' cambio(s) de tus rutas guardados en este equipo SIN sincronizar: no se borraron. Consultá con el administrador.' : ''));
    } finally { busy = false; }
  };
  setInterval(check, window.OKD_REVOKE_CHECK_MS || 30000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) check(); });
  window.addEventListener('focus', check); window.addEventListener('online', check);
}
