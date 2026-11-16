const ROLES = new Set(['ADMIN','SUPERVISOR_DESPACHO','OPERARIO_DEPOSITO','TRANSPORTISTA','TRANSPORTISTA_INTERNO']);
const b64 = s => {
  const pad = '='.repeat((4 - s.length % 4) % 4);
  const raw = atob((s + pad).replace(/-/g,'+').replace(/_/g,'/'));
  return Uint8Array.from(raw, c => c.charCodeAt(0));
};
export const capable = () => 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;   // también la usa la alarma comercial

export async function subscribe(api) {   // también la usa la alarma comercial (misma suscripción; sin cambios de lógica)
  const reg = await navigator.serviceWorker.ready;
  let sub = await reg.pushManager.getSubscription();
  if (!sub) {
    const pub = await api.pushPublicKey();
    if (!pub) throw new Error('Las notificaciones todavía no están configuradas.');
    sub = await reg.pushManager.subscribe({ userVisibleOnly:true, applicationServerKey:b64(pub) });
  }
  const j = sub.toJSON();
  if (!j.endpoint || !j.keys?.p256dh || !j.keys?.auth) throw new Error('Suscripción push incompleta.');
  await api.savePushSubscription({
    endpoint:j.endpoint, p256dh:j.keys.p256dh, auth:j.keys.auth,
    user_agent:navigator.userAgent
  });
  api.flushPushQueue().catch(()=>null);
  return sub;
}

function prompt(api, me) {
  if (document.getElementById('pushPrompt')) return;
  const m=document.createElement('div'); m.className='umodal'; m.id='pushPrompt'; m.style.zIndex='999998';
  m.innerHTML='<div class="udialog" role="dialog" aria-modal="true" style="max-width:460px">'+
    '<header><b>ACTIVAR NOTIFICACIONES</b></header><div class="body">'+
    '<p style="margin:0 0 10px"><b>OK Despacho puede avisarte aunque no estés mirando la app.</b></p>'+
    '<p style="margin:0;color:var(--muted);font-size:13px">'+
    (me.role==='TRANSPORTISTA'||me.role==='TRANSPORTISTA_INTERNO'
      ? 'Vas a recibir avisos cuando te asignen una hoja nueva o publiquen una versión corregida.'
      : me.role==='SUPERVISOR_DESPACHO'||me.role==='ADMIN'
      ? 'Vas a recibir avisos cuando haya solicitudes que necesiten revisión o aprobación.'
      : 'Vas a recibir avisos sobre el resultado de tus solicitudes operativas.')+
    '</p><div class="auth-err" id="pushErr" hidden></div></div>'+
    '<footer><button class="btn ghost" type="button" id="pushLater">MÁS TARDE</button><span style="flex:1"></span><button class="btn go" type="button" id="pushEnable">ACTIVAR</button></footer></div>';
  document.body.appendChild(m);
  m.querySelector('#pushLater').onclick=()=>m.remove();
  m.querySelector('#pushEnable').onclick=async e=>{
    const b=e.currentTarget, er=m.querySelector('#pushErr'); b.disabled=true; er.hidden=true;
    try {
      const p=await Notification.requestPermission();
      if(p!=='granted') throw new Error('Las notificaciones quedaron bloqueadas en este dispositivo. Podés habilitarlas desde la configuración del navegador.');
      await subscribe(api); m.remove();
    } catch(ex) { er.textContent=ex.message||String(ex); er.hidden=false; b.disabled=false; }
  };
}

export async function initPushNotifications(api, me) {
  if (!me || !ROLES.has(me.role) || !capable()) return { supported:false };
  if (Notification.permission==='granted') {
    try { await subscribe(api); return { supported:true, enabled:true }; }
    catch(e) { return { supported:true, enabled:false, error:e.message }; }
  }
  if (Notification.permission==='default') {
    setTimeout(()=>prompt(api,me),700);
    return { supported:true, enabled:false, needsPermission:true };
  }
  return { supported:true, enabled:false, denied:true };
}

// Al CERRAR SESIÓN: el dispositivo deja de recibir avisos de ese usuario (servidor + navegador). Si no hay conexión, igual se
// da de baja en el navegador; el servidor la marcará vencida en el próximo envío (410). Nunca bloquea el cierre de sesión.
// Baja de notificaciones al cerrar sesión, ACOTADA (corrección de cierre): cada operación del navegador y la revocación tienen límite y el
// total no supera ~4 s. Devuelve el resultado REAL (no se presenta como hecha una baja que no se confirmó). Si la baja LOCAL no se confirma,
// queda una marca y se reintenta en la próxima carga (evita avisos de la cuenta saliente en este dispositivo).
const PENDING = 'okd_push_unsub_pending';
const within = (p, ms) => Promise.race([Promise.resolve(p), new Promise((_, rej) => setTimeout(() => rej(new Error('SIN_RESPUESTA')), Math.max(1, ms)))]);
async function confirmUnsubscribe(reg, sub, remaining) {
  if (await within(sub.unsubscribe(), remaining())) return true;
  return (await within(reg.pushManager.getSubscription(), remaining())) === null;
}

export async function revokePushOnLogout(api) {
  const t0 = Date.now(), left = cap => Math.min(cap, Math.max(300, 4000 - (Date.now() - t0)));
  const out = { servidor: 'NO_APLICA', dispositivo: 'NO_APLICA' };
  try {
    if (!capable()) return out;
    const reg = await within(navigator.serviceWorker.getRegistration(), left(1500)); if (!reg) return out;
    const sub = await within(reg.pushManager.getSubscription(), left(1500)); if (!sub) return out;
    out.servidor = 'NO_CONFIRMADA'; out.dispositivo = 'NO_CONFIRMADA';
    if (api.revokePushSubscription) { try { await within(api.revokePushSubscription(sub.endpoint), left(2500)); out.servidor = 'OK'; } catch (_) { } }
    try { if (await confirmUnsubscribe(reg, sub, () => left(1500))) out.dispositivo = 'OK'; } catch (_) { }
  } catch (_) { if (out.dispositivo === 'NO_APLICA') out.dispositivo = 'NO_CONFIRMADA'; }   // nunca impide cerrar sesión
  try { if (out.dispositivo === 'NO_CONFIRMADA') localStorage.setItem(PENDING, '1'); else localStorage.removeItem(PENDING); } catch (_) { }
  return out;
}
// En la próxima carga (antes de ingresar): si la baja local quedó pendiente, se reintenta acotada. Solo operaciones del navegador (unsubscribe puede contactar al servicio push del navegador); no usa la cuenta ni la API de OK DESPACHO; espera acotada.
export async function retryPendingPushUnsubscribe() {
  try {
    if (localStorage.getItem(PENDING) !== '1' || !capable()) return;
    const reg = await within(navigator.serviceWorker.getRegistration(), 1500); const sub = reg && await within(reg.pushManager.getSubscription(), 1500);
    if (sub) {
      const deadline = Date.now() + 1500;
      if (!await confirmUnsubscribe(reg, sub, () => Math.max(1, deadline - Date.now()))) return;
    }
    localStorage.removeItem(PENDING);
  } catch (_) { /* queda la marca para la próxima carga */ }
}
