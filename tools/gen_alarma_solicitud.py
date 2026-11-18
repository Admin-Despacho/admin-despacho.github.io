"""ALARMA URGENTE DESDE LA SOLICITUD COMERCIAL · genera propuestas/comercial/20261201001300_comercial_alarma_solicitud.sql y su reversión
desde el TEXTO EXACTO vigente (000100 a 001200). Cada reemplazo se verifica; si no coincide, falla sin escribir nada."""
import re, glob, sys
files = sorted(glob.glob('propuestas/comercial/2026120100[0-9][0-9]00_*.sql'))
files = [f for f in files if int(re.search(r'20261201(\d{6})', f).group(1)) <= 1200]
last = {}
for f in files:
    s = open(f, encoding='utf-8').read()
    for m in re.finditer(r"create or replace function public\.([a-z_]+)\(", s):
        last[m.group(1)] = s[m.start():s.find('$$;', s.find('$$', m.start()) + 2) + 3]
ORIG = {n: last[n] for n in ('com_alarm_raise', 'com_alarm_attend', 'com_alarm_escalate_due')}
MD5 = {'com_alarm_raise': ('public.com_alarm_raise(text,text,text,text,text,text)', '28e609cc5878f2ebb00e1716462d5437'),
       'com_alarm_attend': ('public.com_alarm_attend(uuid,integer)', '20acc69d602e6c673dae73071f263dc1'),
       'com_alarm_escalate_due': ('public.com_alarm_escalate_due()', '71e22065703488416360c702fca075e6')}
new = dict(ORIG)
def rep(name, a, b, n=1):
    if new[name].count(a) != n: sys.exit(f'REEMPLAZO FALLIDO en {name}: se esperaban {n} y hay {new[name].count(a)} · {a[:70]}')
    new[name] = new[name].replace(a, b)
# REVISAR: una sola alarma ACTIVA por SOLICITUD también entre circuitos (la de su pedido o la de la solicitud vinculada a ese pedido)
# REVISAR (corrección Work 2): la autorización se resuelve UNA sola vez, al principio (regla publicada: la más reciente no cancelada con el pedido);
# la alarma existente se recupera por su request_id; nunca se devuelve la alarma de OTRA autorización por coincidir el pedido.
# la segunda consulta de la autorización se elimina: el vínculo usa la MISMA resuelta arriba
rep('com_alarm_raise', "  select * into q from public.com_requests where upper(btrim(coalesce(order_ref, ''))) = ref and status <> 'CANCELADA' order by created_at desc, number desc limit 1;",
    "  -- (la autorización ya se resolvió UNA vez al principio; el vínculo usa esa misma)")
rep('com_alarm_raise', "  perform pg_advisory_xact_lock(hashtext('com_alarm:' || ref));",
    """  perform pg_advisory_xact_lock(hashtext('com_alarm:' || ref));
  -- la autorización que REVISAR vincula se resuelve UNA sola vez (regla publicada: la más reciente no cancelada con este pedido)
  select * into q from public.com_requests where upper(btrim(coalesce(order_ref, ''))) = ref and status <> 'CANCELADA' order by created_at desc, number desc limit 1;
  -- mismo cerrojo POR AUTORIZACIÓN que la alarma desde Seguimiento
  perform pg_advisory_xact_lock(hashtext('com_alarm_req:' || coalesce(q.id::text, '-')));""")
rep('com_alarm_raise', "    if cname = 'com_alarms_one_active' then return", "    if cname in ('com_alarms_one_active', 'com_alarms_one_active_request') then return")
rep('com_alarm_raise', "  select * into a from public.com_alarms where upper(btrim(order_ref)) = ref and status = 'PENDIENTE_ATENCION';",
    """  -- con autorización: SOLO su alarma (request_id); si no tiene, una alarma de PEDIDO sin autorización (anterior a la solicitud) para no duplicarla.
  -- sin autorización: solo alarmas de pedido sin request_id. NUNCA la alarma de OTRA autorización por coincidir el pedido.
  if q.id is not null then
    select * into a from public.com_alarms where status = 'PENDIENTE_ATENCION' and request_id = q.id order by raised_at limit 1;
    if not found then
      select * into a from public.com_alarms where status = 'PENDIENTE_ATENCION' and request_id is null and upper(btrim(order_ref)) = ref order by raised_at limit 1;
    end if;
  else
    select * into a from public.com_alarms where status = 'PENDIENTE_ATENCION' and request_id is null and upper(btrim(order_ref)) = ref order by raised_at limit 1;
  end if;""")
LBL = "(case when a.sheet_key = 'AUTORIZACION' then 'Autorización ' else 'Pedido ' end) || a.order_ref"
rep('com_alarm_attend', "'Pedido ' || a.order_ref", LBL, 1)
rep('com_alarm_escalate_due', "'Pedido ' || a.order_ref", LBL, 3)
guard = '\n'.join(f"  IF md5(pg_get_functiondef('{sig}'::regprocedure)) <> '{h}' THEN RAISE EXCEPTION 'BASE_CAMBIADA: {n} no coincide con la versión publicada. No se modificó nada.'; END IF;" for n, (sig, h) in MD5.items())
head = open('tools/alarma_solicitud_head.sql', encoding='utf-8').read().replace('__GUARD__', guard)
tail = open('tools/alarma_solicitud_tail.sql', encoding='utf-8').read()
body = '\n\n'.join('-- ' + n + ' (texto EXACTO vigente + reemplazos verificados)\n' + new[n] for n in ('com_alarm_raise', 'com_alarm_attend', 'com_alarm_escalate_due'))
open('propuestas/comercial/20261201001300_comercial_alarma_solicitud.sql', 'w', encoding='utf-8').write(head + '\n' + body + '\n\n' + tail)
rev_head = open('tools/alarma_solicitud_rev_head.sql', encoding='utf-8').read()
rev_post = '\n'.join(f"  IF md5(pg_get_functiondef('{sig}'::regprocedure)) <> '{h}' THEN RAISE EXCEPTION 'REVERSION_INEXACTA: {n}'; END IF;" for n, (sig, h) in MD5.items())
rev = rev_head + '\n\n'.join(ORIG[n] for n in ('com_alarm_raise', 'com_alarm_attend', 'com_alarm_escalate_due')) + "\nDO $post$ BEGIN\n" + rev_post + "\nEND $post$;\nCOMMIT;\n"
open('propuestas/comercial/REVERSION_ALARMA_SOLICITUD.sql', 'w', encoding='utf-8').write(rev)
print('generadas 001300 y su reversión')
