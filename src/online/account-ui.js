// MI CUENTA (autogestión): cambiar la propia contraseña y cerrar sesión. Separado de Administración.
// No permite cambiar rol, permisos, carriers ni superior.
import { esc } from './util.js';
import { ROLE_LABEL, hasPerm } from '../../supabase/functions/_shared/rules.js';
import { passkeysSupported, createPasskey } from './webauthn.js';

export function openAccount(api, me, onLogout) {
  const m = document.createElement('div'); m.className = 'umodal'; m.id = 'accountModal';
  m.innerHTML = '<div class="udialog" role="dialog" aria-modal="true"><header><b>MI CUENTA</b></header><div class="body">' +
    '<p style="margin:0;font-size:13px"><b>' + esc(me.full_name) + '</b><br><span style="color:var(--muted)">' + esc(me.email) + ' · ' + esc(ROLE_LABEL[me.role] || me.role) + '</span></p>' +
    '<p style="margin:0;font-size:12px;color:var(--muted)">El rol, los permisos y los transportistas los administra Administración.</p>' +
    '<label>Nueva contraseña<input id="acP1" type="password" autocomplete="new-password"></label>' +
    '<label>Repetir contraseña<input id="acP2" type="password" autocomplete="new-password"></label>' +
    '<div class="up-msg err" id="acErr" hidden></div><div class="up-msg ok" id="acOk" hidden></div>' +
    (hasPerm(me, 'routes.view_assigned') ? '<div class="acsec"><b>SEGURIDAD · INGRESO RÁPIDO</b><p>Entrá con huella, Face ID o el bloqueo de tu celular. La app no guarda tu huella ni tu cara.</p><div id="pkList"></div>' +
      (passkeysSupported() ? '<button class="btn go" type="button" id="pkAdd">ACTIVAR INGRESO RÁPIDO</button>' : '<p class="shiperr">Este dispositivo no admite ingreso rápido.</p>') + '</div>' : '') +
    '</div><footer><button class="btn ghost" type="button" id="acLogout">Cerrar sesión</button><span style="flex:1"></span><button class="btn ghost" type="button" id="acClose">Cerrar</button><button class="btn dark" type="button" id="acSave">CAMBIAR CONTRASEÑA</button></footer></div>';
  document.body.appendChild(m);
  const errB = m.querySelector('#acErr'), okB = m.querySelector('#acOk');
  m.querySelector('#acClose').addEventListener('click', () => m.remove());
  m.querySelector('#acLogout').addEventListener('click', () => { m.remove(); onLogout(); });
  const pkRender = async () => {
    const box = m.querySelector('#pkList'); if (!box || !api.myPasskeys) return;
    const list = await api.myPasskeys().catch(() => []);
    box.innerHTML = list.length ? list.map(p => '<div class="pkrow" data-pk="' + p.id + '"><span>' + esc(p.device_name || 'Dispositivo') + ' · ' + new Date(p.created_at).toLocaleDateString('es-AR') + (p.last_used_at ? ' · último uso ' + new Date(p.last_used_at).toLocaleDateString('es-AR') : '') + '</span>' +
      (p.revoked_at ? '<em>REVOCADO</em>' : '<button class="btn soft" type="button" data-rev="' + p.id + '">REVOCAR</button>') + '</div>').join('') : '<p class="pknone">Sin accesos rápidos.</p>';
    box.querySelectorAll('[data-rev]').forEach(b => b.onclick = async () => { if (!confirm('¿Revocar este acceso rápido?')) return; await api.revokePasskey(b.dataset.rev); pkRender(); });
  };
  pkRender();
  const pkAdd = m.querySelector('#pkAdd');
  if (pkAdd) pkAdd.addEventListener('click', async () => {
    errB.hidden = true; okB.hidden = true;
    try {
      const rec = await createPasskey(await api.passkeyRegisterOptions());
      rec.device_name = /Android|iPhone|iPad/i.test(navigator.userAgent) ? (navigator.userAgent.match(/Android|iPhone|iPad/i)[0]) : 'Este dispositivo';
      await api.passkeyRegisterSave(rec);
      try { localStorage.setItem('okd_pk_hint', me.email); } catch (e) { }
      okB.textContent = 'Ingreso rápido activado.'; okB.hidden = false; pkRender();
    } catch (e) { errB.textContent = 'No se pudo activar: ' + e.message; errB.hidden = false; }
  });
  m.querySelector('#acSave').addEventListener('click', async () => {
    errB.hidden = true; okB.hidden = true;
    const a = m.querySelector('#acP1').value, b = m.querySelector('#acP2').value;
    if (a !== b) { errB.textContent = 'Las contraseñas no coinciden.'; errB.hidden = false; return; }
    try { await api.changeOwnPassword(a); okB.textContent = 'Contraseña actualizada.'; okB.hidden = false; m.querySelector('#acP1').value = ''; m.querySelector('#acP2').value = ''; }
    catch (e) { errB.textContent = e.message; errB.hidden = false; }
  });
  return m;
}
