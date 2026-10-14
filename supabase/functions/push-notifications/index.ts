import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
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
  const auth = req.headers.get('authorization') || '';
  if (!auth.startsWith('Bearer ')) return json(401,{ error:'Sesión inválida' });

  const authClient = createClient(url, anon, { global:{ headers:{ Authorization:auth } }, auth:{ persistSession:false } });
  const { data:who, error:authErr } = await authClient.auth.getUser();
  if (authErr || !who?.user) return json(401,{ error:'Sesión inválida' });

  const admin = createClient(url, service, { auth:{ persistSession:false } });
  const { data:profile } = await admin.from('profiles').select('id,status').eq('id',who.user.id).maybeSingle();
  if (!profile || profile.status !== 'ACTIVO') return json(403,{ error:'Usuario sin acceso' });

  const { data:cfg, error:cfgErr } = await admin.from('push_vapid_config').select('public_key,private_key').eq('id','DEFAULT').single();
  if (cfgErr || !cfg) return json(500,{ error:'Push no configurado' });

  webpush.setVapidDetails('mailto:administracion@okaccesorios.com', cfg.public_key, cfg.private_key);
  const appUrl = (Deno.env.get('APP_URL') || 'https://admin-despacho.github.io').replace(/\/$/, '');

  const { data:jobs, error:jErr } = await admin.from('push_jobs')
    .select('id,notification_id,user_id,status,attempt_count,notification:notifications(id,type,title,body,route_id,route_version)')
    .eq('status','QUEUED').order('created_at',{ascending:true}).limit(100);
  if (jErr) return json(500,{ error:jErr.message });

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
    await admin.from('push_jobs').update({
      status, attempt_count:(j.attempt_count||0)+1, processed_at:new Date().toISOString(),
      last_error: status==='SENT' ? null : (lastError || 'No delivery')
    }).eq('id',j.id);
    results.push({ id:j.id, status, sent });
  }
  return json(200,{ ok:true, processed:results.length, results });
});