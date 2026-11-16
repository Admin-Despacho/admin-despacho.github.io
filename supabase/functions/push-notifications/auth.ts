// Autenticación del handler de push (B-W05 + N-V4-02). Se ejecuta ANTES de reclamar cualquier trabajo.
//  · ejecución PROGRAMADA: encabezado x-cron-secret igual a CRON_SECRET (si CRON_SECRET no está configurado, esta vía queda APAGADA);
//  · usuario: JWT válido (getUser) + claims COMPLETOS y coherentes (sub = usuario, iat numérico) + VIGENCIA de la sesión en la base
//    (push_session_valid: perfil activo, token posterior a sessions_revoked_at y sesión IDENTIFICADA existente). Un perfil ACTIVO NO alcanza.
//    Sin session_id → 401 (N-V5-02).
// Sin credenciales → 401 · secreto erróneo sin JWT → 401 · JWT inválido o claims incompletos → 401 · sesión revocada/inexistente → 401 ·
// perfil no activo → 403 · falla de cualquier verificación → nunca acceso.
export type SessionCheck = { ok: boolean; motivo?: string };
export type AuthDeps = {
  getUser: (authorization: string) => Promise<{ id: string } | null>;
  checkSession: (userId: string, iat: number, sessionId: string | null) => Promise<SessionCheck>;
};
export type AuthResult = { ok: true; via: 'CRON' | 'USER'; userId?: string } | { ok: false; status: number; error: string };
export const sameSecret = (a: string, b: string) => {   // tiempo constante (no revela por demora cuántos caracteres coinciden)
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b); let d = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) d |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return d === 0;
};
// claims del JWT (la FIRMA la valida getUser / el gateway; acá solo se leen sub, iat y session_id)
export function readClaims(authorization: string): { sub?: string; iat?: number; session_id?: string } | null {
  try {
    const part = authorization.replace(/^Bearer\s+/, '').split('.')[1]; if (!part) return null;
    const json = atob(part.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((part.length + 3) % 4));
    const c = JSON.parse(json); return c && typeof c === 'object' ? c : null;
  } catch (_e) { return null; }
}
export async function authorize(headers: Headers, cronSecret: string, deps: AuthDeps): Promise<AuthResult> {
  const sent = headers.get('x-cron-secret') || '';
  if (cronSecret && sent && sameSecret(sent, cronSecret)) return { ok: true, via: 'CRON' };
  const auth = headers.get('authorization') || '';
  if (!auth.startsWith('Bearer ')) return { ok: false, status: 401, error: 'Sesión inválida' };
  const user = await deps.getUser(auth).catch(() => null);
  if (!user) return { ok: false, status: 401, error: 'Sesión inválida' };
  const c = readClaims(auth);
  if (!c || c.sub !== user.id || typeof c.iat !== 'number' || !Number.isFinite(c.iat)) return { ok: false, status: 401, error: 'Sesión inválida' };
  // N-V5-02: la identidad de SESIÓN es obligatoria (los tokens de acceso de Supabase la incluyen); sin ella no se omite la comprobación: se rechaza
  if (typeof c.session_id !== 'string' || !c.session_id.trim()) return { ok: false, status: 401, error: 'Sesión inválida' };
  const s = await deps.checkSession(user.id, c.iat, c.session_id).catch(() => ({ ok: false, motivo: 'ERROR_DE_VERIFICACION' }));
  if (!s || s.ok !== true) return s && s.motivo === 'PERFIL_NO_ACTIVO' ? { ok: false, status: 403, error: 'Usuario sin acceso' } : { ok: false, status: 401, error: 'Sesión inválida' };
  return { ok: true, via: 'USER', userId: user.id };
}
