import { corporateMail, mailChannel } from '../_shared/corporate-mail.js';
import { sendCommercialDecisionEmails } from '../_shared/commercial-decision-mail.js';
// Comunicaciones · despachador. Lo invoca el programador del servidor (pg_cron + pg_net) con el encabezado x-comm-cron.
// Secretos (Supabase → Edge Functions → Secrets): COMM_CRON_SECRET, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET. Nunca se registran.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import { dispatch } from './handler.js';
import { pgStore, gmailProvider } from './adapters.js';

Deno.serve(async (req: Request) => {
  const secret = Deno.env.get('COMM_CRON_SECRET');
  if (!secret || req.headers.get('x-comm-cron') !== secret) return new Response('forbidden', { status: 403 });
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  await sb.rpc('comm_mail_register',{p_component:'comm-dispatcher'});
  let store = pgStore(sb);
  const legacyProvider = gmailProvider(store, { clientId: Deno.env.get('GOOGLE_CLIENT_ID') ?? '', clientSecret: Deno.env.get('GOOGLE_CLIENT_SECRET') ?? '' });
  const connectTls = (o: Deno.ConnectTlsOptions) => Deno.connectTls(o);
  if(req.headers.get('x-comm-action') === 'smtp-check') {
    try { const r=await corporateMail(sb,{connectTls}).probe(); return new Response(JSON.stringify(r),{headers:{'Content-Type':'application/json'}}); }
    catch { return new Response(JSON.stringify({authenticated:false,mail_sent:false}),{status:502}); }
  }
  const channel=await mailChannel(sb,{legacyStore:store,legacyProvider,connectTls,scope:'comunicaciones'});
  store=channel.store; const provider=channel.provider;
  const currentMail=await corporateMail(sb,{connectTls}).runtime();
  if(req.headers.get('x-mail-smtp-only')==='1'&&currentMail.provider!=='SMTP')return new Response(JSON.stringify({skipped:true}));
  const commercial=await sendCommercialDecisionEmails(sb,{connectTls});
  const sum = await dispatch(store, provider, { limit: currentMail.provider==='SMTP'?Math.min(2,currentMail.available_slots||0):Number(Deno.env.get('COMM_BATCH') ?? 25), dailyCap: Number(Deno.env.get('COMM_DAILY_CAP') ?? 400),
    sendWindowHours: Number(Deno.env.get('COMM_SEND_WINDOW_HOURS') ?? 6),
    // cuota de Gmail API aplicable al proyecto (proyectos desde 1/5/2026: 6.000 unidades/min por usuario); control COMPARTIDO en la base
    unitsPerMinute: Number(Deno.env.get('COMM_GMAIL_UNITS_PER_MIN') ?? 6000), unitsPerSecond: Number(Deno.env.get('COMM_GMAIL_UNITS_PER_SEC') ?? 200) });
  (sum as any).commercial=commercial;
  if (sum.auth) await store.markGmail(true, sum.note).catch(() => {});
  return new Response(JSON.stringify(sum), { status: 200, headers: { 'Content-Type': 'application/json' } });
});
