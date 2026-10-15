import { createClient } from 'npm:@supabase/supabase-js@2';

const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const resendKey = Deno.env.get('RESEND_API_KEY') ?? '';
const authFrom = Deno.env.get('AUTH_FROM') ?? Deno.env.get('REPORT_FROM') ?? 'fgutierrez@okaccesorios.com';
const appBase = (Deno.env.get('APP_URL') || 'https://admin-despacho.github.io').replace(/\/$/, '');
const admin = createClient(supabaseUrl || 'http://invalid', serviceKey || 'invalid', {
  auth: { persistSession: false, autoRefreshToken: false }
});

const allowedOrigins = new Set([
  'https://admin-despacho.github.io',
  appBase,
  'http://localhost:5173'
]);

function cors(req: Request) {
  const origin = req.headers.get('origin') || '';
  return {
    'content-type': 'application/json',
    'access-control-allow-origin': allowedOrigins.has(origin) ? origin : 'https://admin-despacho.github.io',
    'access-control-allow-headers': 'authorization, apikey, x-client-info, content-type',
    'access-control-allow-methods': 'POST, OPTIONS',
    'vary': 'Origin'
  };
}
const ok = (req: Request) => new Response(JSON.stringify({ ok: true }), { status: 200, headers: cors(req) });

async function digest(value: string) {
  const salt = serviceKey || 'ok-despacho-recovery';
  const bytes = new TextEncoder().encode(salt + '|' + value);
  const out = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  return [...out].map(x => x.toString(16).padStart(2, '0')).join('');
}
const esc = (v: string) => v.replace(/[&<>"']/g, ch => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[ch] as string));

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { status: 200, headers: cors(req) });
  if (req.method !== 'POST') return ok(req);

  let body: any = {};
  try { body = await req.json(); } catch { return ok(req); }

  const email = String(body?.email || '').trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return ok(req);
  if (!supabaseUrl || !serviceKey || !resendKey || !authFrom) {
    console.error('[password-recovery] missing required server configuration');
    return ok(req);
  }

  const ip = (req.headers.get('x-forwarded-for') || req.headers.get('cf-connecting-ip') || 'unknown').split(',')[0].trim();
  try {
    const [emailHash, ipHash] = await Promise.all([digest(email), digest(ip)]);
    const [byEmail, byIp] = await Promise.all([
      admin.rpc('consume_password_recovery_limit', { p_scope:'EMAIL', p_key_hash:emailHash, p_window_seconds:60, p_max_count:1 }),
      admin.rpc('consume_password_recovery_limit', { p_scope:'IP', p_key_hash:ipHash, p_window_seconds:600, p_max_count:8 })
    ]);
    if (byEmail.error || byIp.error || byEmail.data !== true || byIp.data !== true) return ok(req);

    // No revelar si la cuenta existe: cualquier caso devuelve exactamente la misma respuesta.
    const { data: profile } = await admin.from('profiles')
      .select('id,email,status')
      .eq('email', email)
      .maybeSingle();
    if (!profile || profile.status !== 'ACTIVO') return ok(req);

    const generated = await admin.auth.admin.generateLink({
      type: 'recovery',
      email,
      options: { redirectTo: appBase + '/?nueva-contrasena=1' }
    });
    if (generated.error) {
      console.error('[password-recovery] generateLink failed', generated.error.message);
      return ok(req);
    }
    const actionLink = generated.data?.properties?.action_link;
    if (!actionLink) return ok(req);

    const safeLink = esc(actionLink);
    const mail = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        authorization: 'Bearer ' + resendKey,
        'content-type': 'application/json'
      },
      body: JSON.stringify({
        from: authFrom,
        to: [email],
        subject: 'Restablecer contraseña · OK Despacho',
        html: '<div style="font-family:Arial,sans-serif;max-width:560px;margin:auto;padding:24px;color:#07151b">' +
          '<h2 style="margin:0 0 16px">Restablecer contraseña</h2>' +
          '<p>Recibimos una solicitud para cambiar tu contraseña de OK Despacho.</p>' +
          '<p style="margin:24px 0"><a href="' + safeLink + '" style="display:inline-block;padding:12px 18px;background:#07151b;color:#fff;text-decoration:none;border-radius:8px;font-weight:bold">CREAR NUEVA CONTRASEÑA</a></p>' +
          '<p style="font-size:13px;color:#667680">Si no solicitaste este cambio, podés ignorar este correo.</p>' +
          '</div>',
        text: 'Restablecer contraseña de OK Despacho: ' + actionLink
      })
    });
    const response = await mail.json().catch(() => ({}));
    if (!mail.ok) {
      console.error('[password-recovery] Resend failed', mail.status, response?.message || 'error');
      return ok(req);
    }

    await admin.from('audit_log').insert({
      actor_id: null,
      action: 'PASSWORD_RECOVERY_EMAIL_SENT',
      target_type: 'user',
      target_id: profile.id,
      after: { channel: 'RESEND' }
    }).catch(() => null);
  } catch (e) {
    console.error('[password-recovery] unexpected', String((e as Error)?.message || e));
  }
  return ok(req);
});
