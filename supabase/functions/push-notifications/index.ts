import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
const json = (status:number, body:any) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'content-type':'application/json' } });
const urlFor = (n:any, appUrl:string) => {
  const rid = n.route_id ? encodeURIComponent(n.route_id) : '';
  if (n.type === 'REQUEST_CREATED') return appUrl + '/#/solicitudes' + (rid ? '?route=' + rid : '');
  if (String(n.type || '').startsWith('REQUEST_')) return appUrl + '/#/solicitudes' + (rid ? '?route=' + rid : '');
  return appUrl + '/#/mis-hojas' + (rid ? '?route=' + rid : '');
};

Deno.serve(async (req:Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers:cors });
  if (req.method !== 'POST') return json(405, { error:'Método no permitido' });

  const url = Deno.env.get('SUPABASE_URL')!;
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const admin = createClient(url, service, { auth:{ persistSession:false } });
  // Dos formas de vaciar la cola: (a) ejecución PROGRAMADA con x-cron-secret = CRON_SECRET (no depende de que alguien tenga la app abierta);
  // (b) cualquier usuario ACTIVO con sesión (después de publicar o al abrir la app). La toma de trabajos es atómica: no hay envíos duplicados.
  const cron = Deno.env.get('CRON_SECRET') || '';
  const viaCron = !!cron && req.headers.get('x-cron-secret') === cron;
  if (!viaCron) {
    const auth = req.headers.get('authorization') || '';
    if (!auth.startsWith('Bearer ')) return json(401,{ error:'Sesión inválida' });
    const authClient = createClient(url, anon, { global:{ headers:{ Authorization:auth } }, auth:{ persistSession:false } });
    const { data:who, error:authErr } = await authClient.auth.getUser();
    if (authErr || !who?.user) return json(401,{ error:'Sesión inválida' });
    const { data:profile } = await admin.from('profiles').select('id,status').eq('id',who.user.id).maybeSingle();
    if (!profile || profile.status !== 'ACTIVO') return json(403,{ error:'Usuario sin acceso' });
  }

  const { data:cfg, error:cfgErr } = await admin.from('push_vapid_config').select('public_key,private_key').eq('id','DEFAULT').single();
  if (cfgErr || !cfg) return json(500,{ error:'Push no configurado' });

  webpush.setVapidDetails('mailto:administracion@okaccesorios.com', cfg.public_key, cfg.private_key);
  const appUrl = (Deno.env.get('APP_URL') || 'https://admin-despacho.github.io').replace(/\/$/, '');

  // Toma atómica (FOR UPDATE SKIP LOCKED): cada trabajo lo procesa una sola ejecución; incluye reintentos de ERROR con espera
  const { data:claimed, error:jErr } = await admin.rpc('claim_push_jobs', { p_limit: 100 });
  if (jErr) return json(500,{ error:jErr.message });
  const ids = (claimed || []).map((j:any) => j.notification_id);
  const { data:notifs } = ids.length ? await admin.from('notifications').select('id,type,title,body,route_id,route_version').in('id', ids) : { data: [] as any[] };
  const jobs = (claimed || []).map((j:any) => ({ ...j, notification: (notifs || []).find((n:any) => n.id === j.notification_id) || null }));

  const results:any[] = [];
  for (const j of jobs || []) {
    const n:any = Array.isArray(j.notification) ? j.notification[0] : j.notification;
    if (!n) {
      await admin.from('push_jobs').update({ status:'SKIPPED', processed_at:new Date().toISOString(), last_error:'Notification missing' }).eq('id',j.id);
      continue;
    }
    const { data:subs } = await admin.from('push_subscriptions').select('id,endpoint,p256dh,auth').eq('user_id',j.user_id).is('revoked_at',null);
    if (!subs?.length) {
      await admin.from('push_jobs').update({ status:'SKIPPED', processed_at:new Date().toISOString(), last_error:'No active subscription' }).eq('id',j.id);
      results.push({ id:j.id, status:'SKIPPED' }); continue;
    }
    const payload = JSON.stringify({
      title:n.title || 'OK Despacho',
      body:n.body || '',
      icon:'/icons/icon-192.png',
      badge:'/icons/icon-192.png',
      tag:'okd-'+n.id,
      data:{ url:urlFor(n,appUrl), notification_id:n.id, type:n.type, route_id:n.route_id || null }
    });
    let sent=0, hardErrors=0, lastError='';
    for (const s of subs) {
      try {
        await webpush.sendNotification({ endpoint:s.endpoint, keys:{ p256dh:s.p256dh, auth:s.auth } }, payload, { TTL:86400, urgency:'high' });
        sent++;
      } catch (e:any) {
        const status=Number(e?.statusCode || e?.status || 0);
        lastError=String(e?.body || e?.message || e);
        if (status===404 || status===410) {
          await admin.from('push_subscriptions').update({ revoked_at:new Date().toISOString(), updated_at:new Date().toISOString() }).eq('id',s.id);
        } else hardErrors++;
      }
    }
    const status = sent>0 ? 'SENT' : (hardErrors>0 ? 'ERROR' : 'SKIPPED');
    // reintento con espera creciente (1, 2, 4, 8 min) hasta 5 intentos; attempt_count ya lo sumó claim_push_jobs
    const wait = Math.min(60, 2 ** Math.max(0, (j.attempt_count || 1) - 1));
    await admin.from('push_jobs').update({
      status, processed_at:new Date().toISOString(), locked_at:null,
      next_attempt_at: status==='ERROR' ? new Date(Date.now() + wait * 60000).toISOString() : null,
      last_error: status==='SENT' ? null : (lastError || 'No delivery')
    }).eq('id',j.id);
    results.push({ id:j.id, status, sent });
  }
  return json(200,{ ok:true, processed:results.length, results });
});
