import { esc } from './util.js';
import { passkeysSupported, getAssertion, verifyAssertion } from './webauthn.js';

const DEMO_USERS = [
  ['Administración', 'admin@okdespacho.demo'],
  ['Despacho', 'despacho@okdespacho.demo'],
  ['Gabriel (interno)', 'gabriel@okdespacho.demo'],
  ['Cristian Torres', 'cristian@okdespacho.demo']
];

const hint = () => { try { return localStorage.getItem('okd_pk_hint'); } catch (e) { return null; } };
export function renderLogin(api, onDone) {
  const card = document.getElementById('authCard');
  card.innerHTML =
    '<h3>INGRESAR</h3>' +
    '<div class="auth-err" id="authErr" hidden></div>' +
    (passkeysSupported() && hint() ? '<button class="btn dark pkbtn" type="button" id="loginPasskey">INGRESAR CON HUELLA / FACE ID</button><p class="pkor">o USAR CONTRASEÑA</p>' : '<p>Usá el email y la contraseña de tu usuario de OK Despacho.</p>') +
    '<form id="loginForm" novalidate>' +
    '<label>Email<input id="loginEmail" type="email" autocomplete="username" required></label>' +
    '<label>Contraseña<input id="loginPass" type="password" autocomplete="current-password" required></label>' +
    '<button class="btn go" id="loginBtn" type="submit">INGRESAR</button></form>' +
    '<button class="linkbtn forgot" type="button" id="forgotOpen">¿OLVIDASTE TU CONTRASEÑA?</button>' +
    '<form id="forgotForm" hidden novalidate><label>Tu email<input id="forgotEmail" type="email" autocomplete="username"></label><button class="btn dark" type="submit" id="forgotGo">ENVIAR ENLACE</button><div class="up-msg ok" id="forgotMsg" hidden></div></form>' +
    (api.mode === 'demo' ? '<div class="demo-users">Modo demo · contraseña <b>demo</b> para todos:<br>' +
      DEMO_USERS.map(([n, e]) => '<button type="button" data-e="' + esc(e) + '">' + esc(n) + '</button>').join('') + '</div>' : '');
  const err = document.getElementById('authErr');
  card.querySelectorAll('[data-e]').forEach(b => b.addEventListener('click', () => {
    document.getElementById('loginEmail').value = b.dataset.e; document.getElementById('loginPass').value = 'demo';
  }));
  document.getElementById('forgotOpen').onclick = () => { document.getElementById('forgotForm').hidden = false; document.getElementById('forgotEmail').value = document.getElementById('loginEmail').value; };
  document.getElementById('forgotForm').addEventListener('submit', async e => {
    e.preventDefault(); await api.requestPasswordReset(document.getElementById('forgotEmail').value);
    const m = document.getElementById('forgotMsg'); m.textContent = 'Si el email está registrado, te enviamos un enlace para crear una nueva contraseña.'; m.hidden = false; // no revela si existe
  });
  const pkb = document.getElementById('loginPasskey');
  if (pkb) pkb.addEventListener('click', async () => {
    err.hidden = true; pkb.disabled = true;
    try { const a = await getAssertion(await api.passkeyLoginOptions(hint())); await api.passkeyLogin(a, verifyAssertion); try { sessionStorage.setItem('okd_fresh_login','1'); } catch (e) {} onDone(); }
    catch (ex) { err.textContent = ex.name === 'NotAllowedError' ? 'Se canceló el ingreso rápido. Podés usar tu contraseña.' : ex.message; err.hidden = false; }
    finally { pkb.disabled = false; }
  });
  document.getElementById('loginForm').addEventListener('submit', async e => {
    e.preventDefault();
    err.hidden = true;
    const btn = document.getElementById('loginBtn'); btn.disabled = true;
    try {
      await api.signIn(document.getElementById('loginEmail').value, document.getElementById('loginPass').value);
      try { sessionStorage.setItem('okd_fresh_login','1'); } catch (e) {}
      onDone();
    } catch (ex) { err.textContent = ex.message; err.hidden = false; }
    finally { btn.disabled = false; }
  });
}

// Usuario invitado: crea su contraseña al entrar desde el email de invitación.
// Si la contraseña se guarda pero la activación falla, se muestra el error y NO se continúa en silencio.
export function renderSetPassword(api, onDone, onLogout) {
  const card = document.getElementById('authCard');
  card.innerHTML =
    '<h3>CREAR CONTRASEÑA</h3><p>Elegí la contraseña para entrar a OK Despacho.</p>' +
    '<div class="auth-err" id="authErr" hidden></div>' +
    '<form id="passForm"><label>Nueva contraseña<input id="p1" type="password" autocomplete="new-password" minlength="8" required></label>' +
    '<label>Repetir contraseña<input id="p2" type="password" autocomplete="new-password" minlength="8" required></label>' +
    '<button class="btn go" type="submit" id="passBtn">GUARDAR Y ENTRAR</button></form>' +
    '<div id="acceptRetry" hidden style="display:flex;gap:8px;margin-top:10px"><button class="btn dark" type="button" id="retryAccept">Reintentar activación</button><button class="btn ghost" type="button" id="retryLogout">Cerrar sesión</button></div>';
  const errBox = document.getElementById('authErr'), retry = document.getElementById('acceptRetry');
  const fail = ex => {
    errBox.textContent = ex.message; errBox.hidden = false;
    if (ex.code === 'ACCEPT_FAILED') { document.getElementById('passForm').hidden = true; retry.hidden = false; retry.style.display = 'flex'; }
  };
  document.getElementById('passForm').addEventListener('submit', async e => {
    e.preventDefault();
    const a = document.getElementById('p1').value, b = document.getElementById('p2').value;
    if (a.length < 8) { errBox.textContent = 'La contraseña debe tener al menos 8 caracteres.'; errBox.hidden = false; return; }
    if (a !== b) { errBox.textContent = 'Las contraseñas no coinciden.'; errBox.hidden = false; return; }
    try { await api.setPassword(a); onDone(); } catch (ex) { fail(ex); }
  });
  document.getElementById('retryAccept').addEventListener('click', async () => {
    errBox.hidden = true;
    try { await api.acceptInvite(); onDone(); } catch (ex) { fail(ex); }
  });
  document.getElementById('retryLogout').addEventListener('click', () => onLogout && onLogout());
}

// Nueva contraseña desde el enlace (recuperación o invitación). Al terminar se cierran las sesiones anteriores y vuelve al acceso.
export function renderNewPassword(api, token, onDone) {
  const card = document.getElementById('authCard');
  card.innerHTML = '<h3>NUEVA CONTRASEÑA</h3><p>Elegí tu nueva contraseña.</p><div class="auth-err" id="authErr" hidden></div>' +
    '<form id="npForm"><label>Nueva contraseña<input id="np1" type="password" autocomplete="new-password"></label><label>Repetir contraseña<input id="np2" type="password" autocomplete="new-password"></label><button class="btn go" type="submit" id="npGo">GUARDAR</button></form>';
  const er = document.getElementById('authErr');
  document.getElementById('npForm').addEventListener('submit', async e => {
    e.preventDefault(); er.hidden = true;
    const a = document.getElementById('np1').value, b = document.getElementById('np2').value;
    if (a.length < 8) { er.textContent = 'La contraseña debe tener al menos 8 caracteres.'; er.hidden = false; return; }
    if (a !== b) { er.textContent = 'Las contraseñas no coinciden.'; er.hidden = false; return; }
    try { await api.completePasswordReset(a, token); onDone(); } catch (ex) { er.textContent = ex.message; er.hidden = false; }
  });
}
