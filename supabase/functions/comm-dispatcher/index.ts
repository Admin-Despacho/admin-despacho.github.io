// Comunicaciones · despachador. Lo invoca el programador del servidor (pg_cron + pg_net) con el encabezado x-comm-cron.
// Secretos (Supabase → Edge Functions → Secrets): COMM_CRON_SECRET, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET. Nunca se registran.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import { dispatch } from './handler.js';
import { pgStore, gmailProvider } from './adapters.js';

Deno.serve(async (req: Request) => {
  const secret = Deno.env.get('COMM_CRON_SECRET');
  if (!secret || req.headers.get('x-comm-cron') !== secret) return new Response('forbidden', { status: 403 });
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const store = pgStore(sb);
  const provider = gmailProvider(store, { clientId: Deno.env.get('GOOGLE_CLIENT_ID') ?? '', clientSecret: Deno.env.get('GOOGLE_CLIENT_SECRET') ?? '' });
  const sum = await dispatch(store, provider, { limit: Number(Deno.env.get('COMM_BATCH') ?? 25), dailyCap: Number(Deno.env.get('COMM_DAILY_CAP') ?? 400),
    sendWindowHours: Number(Deno.env.get('COMM_SEND_WINDOW_HOURS') ?? 6),
    // cuota de Gmail API aplicable al proyecto (proyectos desde 1/5/2026: 6.000 unidades/min por usuario); control COMPARTIDO en la base
    unitsPerMinute: Number(Deno.env.get('COMM_GMAIL_UNITS_PER_MIN') ?? 6000), unitsPerSecond: Number(Deno.env.get('COMM_GMAIL_UNITS_PER_SEC') ?? 200) });
  if (sum.auth) await store.markGmail(true, sum.note).catch(() => {});
  return new Response(JSON.stringify(sum), { status: 200, headers: { 'Content-Type': 'application/json' } });
});
