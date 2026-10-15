// Punto de entrada de la Edge Function en Supabase (Deno).
// Secrets (los inyecta Supabase; NUNCA en el frontend): SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 // Recuperación de contraseña: RESEND_API_KEY + AUTH_FROM (o REPORT_FROM como fallback). Opcional: APP_URL.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { handle, json } from './handler.js';

const url = Deno.env.get('SUPABASE_URL') ?? '';
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const appUrl = Deno.env.get('APP_URL') ?? '';
const resendKey = Deno.env.get('RESEND_API_KEY') ?? '';
const authFrom = Deno.env.get('AUTH_FROM') ?? Deno.env.get('REPORT_FROM') ?? '';
const configError = !url ? 'falta SUPABASE_URL' : !serviceKey ? 'falta SUPABASE_SERVICE_ROLE_KEY' : '';
if (configError) console.error('[admin-users] ' + configError);
const admin = createClient(url || 'http://invalid', serviceKey || 'invalid', { auth: { persistSession: false, autoRefreshToken: false } });

// Toda consulta que falla lanza un error con contexto (el handler lo devuelve como JSON 500 con CORS)
const must = <T>(what: string, res: { data: T; error: any }) => { if (res.error) throw new Error(what + ': ' + res.error.message); return res.data; };
const withCarriers = async (rows: any[]) => {
  const ids = rows.map((r) => r.id);
  if (!ids.length) return rows;
  const data = must('carriers de usuarios', await admin.from('user_carriers').select('user_id, carrier_id').in('user_id', ids)) as any[];
  return rows.map((r) => ({ ...r, carriers: (data ?? []).filter((x: any) => x.user_id === r.id).map((x: any) => x.carrier_id) }));
};
const authOk = (what: string, r: { error: any }) => { if (r.error) throw new Error(what + ': ' + r.error.message); };

const deps = {
  configError,
  redirectTo: (appUrl || 'https://admin-despacho.github.io').replace(/\/$/, '') + '/#/crear-contrasena',
  async getUserFromJwt(jwt: string) { const { data, error } = await admin.auth.getUser(jwt); if (error || !data?.user) return null; return { id: data.user.id }; },
  async getProfile(id: string) { const p = must('perfil', await admin.from('profiles').select('*').eq('id', id).maybeSingle()); return p ? (await withCarriers([p]))[0] : null; },
  // ÚNICA fuente de permisos: la misma función que usan RLS y las RPC (rol − módulos restringidos, usuario ACTIVO)
  async userHasPerm(id: string, perm: string) { return !!must('permiso ' + perm, await admin.rpc('user_has_perm', { p_user: id, p_perm: perm })); },
  async listProfiles() { return withCarriers(must('usuarios', await admin.from('profiles').select('*').order('full_name')) as any[]); },
  async hasHistory(id: string) { return !!must('historial', await admin.rpc('user_has_history', { p_user: id })); },
  async activeRoutes(id: string) { return (must('hojas activas', await admin.rpc('user_active_routes', { p_user: id })) as any[]) ?? []; },
  async inviteUser(email: string, redirectTo?: string) { const r = await admin.auth.admin.inviteUserByEmail(email, { redirectTo }); authOk('invitación', r); return { id: r.data.user!.id }; },
  async resendInvite(email: string, redirectTo?: string) { authOk('reenviar invitación', await admin.auth.admin.inviteUserByEmail(email, { redirectTo })); },
  async deleteAuthUser(id: string) { authOk('borrar usuario de Auth', await admin.auth.admin.deleteUser(id)); },
  async createProfileAtomic(p: any, carriers: string[]) {
    must('alta de perfil', await admin.rpc('admin_create_profile', { p_id: p.id, p_full_name: p.full_name, p_email: p.email, p_phone: p.phone, p_role: p.role, p_status: p.status, p_carriers: carriers, p_created_by: p.created_by }));
  },
  async updateProfileAtomic(id: string, f: any) {
    must('edición de perfil', await admin.rpc('admin_update_profile', { p_user: id, p_full_name: f.full_name, p_phone: f.phone, p_email: f.email, p_role: f.role, p_carriers: f.carriers, p_set_supervisor: f.set_supervisor, p_supervisor: f.supervisor }));
  },
  async setDisabledModules(id: string, mods: string[]) { must('módulos', await admin.rpc('admin_set_disabled_modules', { p_user: id, p_modules: mods })); },
  async updateStatus(id: string, patch: any) { must('estado del usuario', await admin.from('profiles').update(patch).eq('id', id)); },
  async setCarriersAtomic(id: string, carriers: string[]) { must('carriers', await admin.rpc('set_user_carriers', { p_user: id, p_carriers: carriers })); },
  async updateAuthEmail(id: string, email: string) { authOk('email en Auth', await admin.auth.admin.updateUserById(id, { email, email_confirm: true })); },
  async sendPasswordReset(email: string, redirectTo?: string) {
    if (!resendKey || !authFrom) throw new Error('correo de recuperación no configurado (RESEND_API_KEY / AUTH_FROM o REPORT_FROM)');
    const generated = await admin.auth.admin.generateLink({
      type: 'recovery',
      email,
      options: redirectTo ? { redirectTo } : undefined
    });
    authOk('generar link de recuperación', generated);
    const actionLink = generated.data?.properties?.action_link;
    if (!actionLink) throw new Error('Supabase no devolvió el link de recuperación');
    const escHtml = (v: string) => v.replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch] as string));
    const safeLink = escHtml(actionLink);
    const mail = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { authorization: 'Bearer ' + resendKey, 'content-type': 'application/json' },
      body: JSON.stringify({
        from: authFrom,
        to: [email],
        subject: 'Restablecer contraseña · OK Despacho',
        html: '<div style="font-family:Arial,sans-serif;max-width:560px;margin:auto;padding:24px">' +
          '<h2 style="margin:0 0 16px">Restablecer contraseña</h2>' +
          '<p>Recibimos una solicitud para cambiar tu contraseña de OK Despacho.</p>' +
          '<p style="margin:24px 0"><a href="' + safeLink + '" style="display:inline-block;padding:12px 18px;background:#111;color:#fff;text-decoration:none;border-radius:8px">CREAR NUEVA CONTRASEÑA</a></p>' +
          '<p style="font-size:13px;color:#666">Si no solicitaste este cambio, podés ignorar este correo.</p>' +
          '</div>',
        text: 'Restablecer contraseña de OK Despacho: ' + actionLink
      })
    });
    const body = await mail.json().catch(() => ({}));
    if (!mail.ok) throw new Error('Resend ' + mail.status + ': ' + (body.message || 'no se pudo enviar el correo'));
  },
  async revokeSessions(id: string) { return must('cerrar sesiones', await admin.rpc('revoke_user_sessions', { p_user: id })); },
  async reassignRoutes(from: string, to: string) { return must('reasignar hojas', await admin.rpc('reassign_active_routes', { p_from: from, p_to: to })); },
  async banUser(id: string) { authOk('bloquear acceso', await admin.auth.admin.updateUserById(id, { ban_duration: '876000h' })); },
  async unbanUser(id: string) { authOk('desbloquear acceso', await admin.auth.admin.updateUserById(id, { ban_duration: 'none' })); },
  async deleteProfileAndAuth(id: string) { authOk('borrar usuario', await admin.auth.admin.deleteUser(id)); },
  async audit(entry: any) { must('auditoría', await admin.from('audit_log').insert(entry)); }
};

Deno.serve(async (req) => {
  try { return await handle(req, deps); }
  catch (e) { return json(500, { error: String((e as Error).message || e), code: 'SERVER_ERROR' }); } // con CORS
});
