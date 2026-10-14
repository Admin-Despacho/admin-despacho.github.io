const ROLES = new Set(['ADMIN','SUPERVISOR_DESPACHO','OPERARIO_DEPOSITO','TRANSPORTISTA','TRANSPORTISTA_INTERNO']);
const b64 = s => {
  const pad = '='.repeat((4 - s.length % 4) % 4);
  const raw = atob((s + pad).replace(/-/g,'+').replace(/_/g,'/'));
  return Uint8Array.from(raw, c => c.charCodeAt(0));
};
const capable = () => 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;

async function subscribe(api) {
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
