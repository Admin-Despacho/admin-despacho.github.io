// Bloqueo local por PIN: NO reemplaza la autenticación de Supabase.
// El PIN solo desbloquea una sesión válida ya autenticada en este dispositivo.
// Se guarda PBKDF2(salt+PIN), nunca el PIN en texto plano.
const POLICY = {
  ADMIN: { mode: 'HOURS', hours: 4, label: 'cada 4 horas' },
  SUPERVISOR_DESPACHO: { mode: 'HOURS', hours: 4, label: 'cada 4 horas' },
  OPERARIO_DEPOSITO: { mode: 'HOURS', hours: 4, label: 'cada 4 horas' },
  TRANSPORTISTA: { mode: 'DAILY', label: 'una vez por día' },
  TRANSPORTISTA_INTERNO: { mode: 'DAILY', label: 'una vez por día' }
};
const MAX_ATTEMPTS = 5;
const enc = new TextEncoder();
const hex = a => [...new Uint8Array(a)].map(x => x.toString(16).padStart(2,'0')).join('');
const unhex = s => new Uint8Array((s.match(/.{1,2}/g)||[]).map(x => parseInt(x,16)));
const key = (id, k) => 'okd_pin_v1_' + id + '_' + k;
const today = () => new Intl.DateTimeFormat('en-CA', { timeZone:'America/Argentina/Mendoza', year:'numeric', month:'2-digit', day:'2-digit' }).format(new Date());

async function verifier(pin, saltHex) {
  const base = await crypto.subtle.importKey('raw', enc.encode(pin), 'PBKDF2', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits({ name:'PBKDF2', salt:unhex(saltHex), iterations:180000, hash:'SHA-256' }, base, 256);
  return hex(bits);
}
function read(id) {
  try {
    const raw = localStorage.getItem(key(id,'cfg'));
    return raw ? JSON.parse(raw) : null;
  } catch(e) { return null; }
}
function write(id, cfg) { localStorage.setItem(key(id,'cfg'), JSON.stringify(cfg)); }
function last(id) {
  try { return JSON.parse(localStorage.getItem(key(id,'last')) || 'null'); } catch(e) { return null; }
}
function mark(id) {
  localStorage.setItem(key(id,'last'), JSON.stringify({ at:Date.now(), day:today() }));
}
function due(me) {
  const p = POLICY[me.role]; if (!p) return false;
  const l = last(me.id); if (!l) return true;
  if (p.mode === 'DAILY') return l.day !== today();
  return Date.now() - Number(l.at || 0) >= p.hours * 3600000;
}
const LOCK_BG = '<div class="pin-lock-bg" aria-hidden="true"><svg viewBox="0 0 1440 1080" preserveAspectRatio="xMidYMid slice">' +
  '<defs><linearGradient id="plg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#e9f0f3"/></linearGradient></defs>' +
  '<rect width="1440" height="1080" fill="url(#plg)"/>' +
  '<g stroke="#dfe8ec" stroke-width="2" fill="none"><path d="M0 820 L420 600 L760 760 L1440 420"/><path d="M180 1080 L560 520 L900 300 L1220 0"/><path d="M0 300 L380 420 L700 200 L1100 360 L1440 260"/><path d="M640 1080 L820 820 L1440 900"/></g>' +
  '<g fill="#d5e1e6"><rect x="30" y="420" width="34" height="90"/><rect x="72" y="460" width="28" height="50"/><rect x="108" y="400" width="30" height="110"/><rect x="146" y="450" width="40" height="60"/><rect x="194" y="470" width="24" height="40"/></g>' +
  '<path d="M0 0 Q300 120 420 -40" stroke="#bdf3f8" stroke-width="70" fill="none" opacity=".6"/><path d="M1440 1080 Q1100 930 900 1100" stroke="#bdf3f8" stroke-width="80" fill="none" opacity=".6"/>' +
  '<g stroke="#10d7e7" stroke-width="4" stroke-dasharray="12 12" fill="none"><path d="M120 780 C260 700 140 600 300 560"/><path d="M1300 200 C1180 260 1320 360 1200 440 C1120 500 1260 560 1180 600"/></g>' +
  '<g fill="#10d7e7"><path d="M120 760 c-26 0-44 20-44 44 0 32 44 70 44 70s44-38 44-70c0-24-18-44-44-44z"/><path d="M1320 150 c-22 0-38 17-38 38 0 28 38 60 38 60s38-32 38-60c0-21-16-38-38-38z"/></g>' +
  '<g fill="#fff"><circle cx="120" cy="804" r="15"/><circle cx="1320" cy="188" r="13"/></g>' +
  '<g fill="none" stroke="#9fb3bc" stroke-width="5" stroke-linejoin="round"><path d="M1240 470h110v70h-110z M1350 490h40l26 30v20h-66z"/><circle cx="1275" cy="548" r="14"/><circle cx="1380" cy="548" r="14"/>' +
  '<path d="M1230 780 l110-60 110 60 v80h-220z M1290 860v-60h100v60"/><path d="M1300 820h80 M1300 840h80"/></g></svg>' +
  '</div><div class="pin-lock-brand"><img src="/brand/ok-accesorios-negro.png" alt="OK Accesorios"><span>DESPACHO ONLINE</span></div>';   // marca EN EL FLUJO, arriba del recuadro
function modalBase(me, title, text) {
  const m=document.createElement('div'); m.className='umodal'; m.id='pinGate';
  m.style.zIndex='999999';
  // V4.24 · SOLO "SESIÓN BLOQUEADA": fondo de logística (blanco/gris, rutas y ubicaciones celestes, logo oficial en negro). El PIN, los botones,
  // la lógica y la autenticación NO cambian; "CONFIGURÁ TU PIN", el inicio de sesión y la recuperación de contraseña tampoco.
  const locked = title === 'SESIÓN BLOQUEADA';
  m.innerHTML='<div class="udialog" role="dialog" aria-modal="true" style="max-width:430px"><header><b>'+title+'</b></header><div class="body">'+
    '<p style="margin:0 0 10px">'+text+'</p>'+
    '<p style="margin:0 0 14px;font-size:12px;color:var(--muted)">Usuario: <b>'+String(me.full_name||'')+'</b></p>'+
    '<div class="auth-err" id="pinErr" hidden></div>'+
    '<label>PIN de 6 dígitos<input id="pinA" type="password" inputmode="numeric" autocomplete="one-time-code" maxlength="6" pattern="[0-9]{6}" style="font-size:24px;letter-spacing:8px;text-align:center"></label>'+
    '<div id="pinConfirmWrap" hidden><label>Repetir PIN<input id="pinB" type="password" inputmode="numeric" autocomplete="one-time-code" maxlength="6" pattern="[0-9]{6}" style="font-size:24px;letter-spacing:8px;text-align:center"></label></div>'+
    '</div><footer><button class="btn ghost" type="button" id="pinPassword">INGRESAR CON CONTRASEÑA</button><span style="flex:1"></span><button class="btn go" type="button" id="pinGo">CONTINUAR</button></footer></div>';
  if (locked) { m.classList.add('pin-lock'); m.insertAdjacentHTML('afterbegin', LOCK_BG); }   // DESPUÉS de armar el modal (si no, se borra)
  document.body.appendChild(m);
  setTimeout(()=>m.querySelector('#pinA')?.focus(),0);
  return m;
}
export function pinPolicy(role) { return POLICY[role] || null; }

export async function ensurePinGate(api, me, opts={}) {
  const policy=POLICY[me && me.role]; if (!policy || !crypto?.subtle) return { enabled:false };
  let cfg=read(me.id);
  const fresh = (()=>{ try { const v=sessionStorage.getItem('okd_fresh_login')==='1'; sessionStorage.removeItem('okd_fresh_login'); return v; } catch(e){ return false; } })();
  if (cfg && fresh) { mark(me.id); return { enabled:true, configured:true, freshLogin:true }; }
  if (cfg && !due(me)) return { enabled:true, configured:true };

  return await new Promise(resolve => {
    const setup=!cfg;
    const m=modalBase(me, setup?'CONFIGURÁ TU PIN':'SESIÓN BLOQUEADA',
      setup
        ? 'Creá un PIN para desbloquear OK Despacho en este dispositivo. Se te pedirá '+policy.label+'.'
        : 'Por seguridad, ingresá tu PIN para continuar. Tu sesión sigue autenticada.');
    const a=m.querySelector('#pinA'), b=m.querySelector('#pinB'), wrap=m.querySelector('#pinConfirmWrap'), er=m.querySelector('#pinErr'), go=m.querySelector('#pinGo');
    if (setup) wrap.hidden=false;
    let attempts=0;
    const fail=t=>{ er.textContent=t; er.hidden=false; a.value=''; if(b)b.value=''; a.focus(); };
    const forceLogin=async()=>{
      try { await api.signOut(); } catch(e){}
      try { localStorage.removeItem(key(me.id,'last')); localStorage.removeItem(key(me.id,'cfg')); } catch(e){}
      m.remove();
      if (opts.onForceLogin) opts.onForceLogin(); else location.reload();
      resolve({ enabled:true, forcedLogin:true });
    };
    m.querySelector('#pinPassword').onclick=forceLogin;
    const submit=async()=>{
      er.hidden=true;
      const pin=String(a.value||'');
      if(!/^\d{6}$/.test(pin)) return fail('El PIN debe tener exactamente 6 números.');
      go.disabled=true;
      try {
        if(setup){
          if(pin!==String(b.value||'')) return fail('Los PIN no coinciden.');
          const salt=crypto.getRandomValues(new Uint8Array(16));
          const saltHex=hex(salt), hash=await verifier(pin,saltHex);
          cfg={ salt:saltHex, hash, created_at:new Date().toISOString(), version:1 };
          write(me.id,cfg); mark(me.id); m.remove(); resolve({ enabled:true, configured:true, created:true });
        } else {
          const hash=await verifier(pin,cfg.salt);
          if(hash!==cfg.hash){
            attempts++;
            if(attempts>=MAX_ATTEMPTS){ await forceLogin(); return; }
            return fail('PIN incorrecto. Te quedan '+(MAX_ATTEMPTS-attempts)+' intento(s).');
          }
          mark(me.id); m.remove(); resolve({ enabled:true, configured:true, unlocked:true });
        }
      } catch(e){ fail('No se pudo validar el PIN. Volvé a intentar.'); }
      finally { if(document.body.contains(go)) go.disabled=false; }
    };
    go.onclick=submit;
    [a,b].filter(Boolean).forEach(x=>x.addEventListener('keydown',e=>{ if(e.key==='Enter') submit(); }));
  });
}

export function startPinLockWatcher(api, me, opts={}) {
  const policy=POLICY[me && me.role]; if(!policy) return ()=>{};
  let busy=false;
  const check=async()=>{
    if(busy || document.getElementById('pinGate') || !due(me)) return;
    busy=true;
    try { await ensurePinGate(api, me, opts); } finally { busy=false; }
  };
  const timer=setInterval(check,30000);
  const vis=()=>{ if(document.visibilityState==='visible') check(); };
  document.addEventListener('visibilitychange',vis);
  return ()=>{ clearInterval(timer); document.removeEventListener('visibilitychange',vis); };
}

export async function resetLocalPin(me) {
  if(!me?.id) return;
  localStorage.removeItem(key(me.id,'cfg')); localStorage.removeItem(key(me.id,'last'));
}
