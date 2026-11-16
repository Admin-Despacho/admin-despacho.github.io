"""V5 · genera propuestas/comercial/20261201000900_comercial_v5_permisos_kpi_fechas.sql desde el TEXTO EXACTO vigente (000100 a 000800).
Cada reemplazo verifica que el original aparezca la cantidad esperada de veces; si no, falla sin escribir nada."""
import re, glob, sys
last = {}
for f in sorted(glob.glob('propuestas/comercial/20261201000[1-8]00_*.sql')):
    s = open(f, encoding='utf-8').read()
    for m in re.finditer(r"create or replace function public\.([a-z_]+)\(", s):
        last[m.group(1)] = s[m.start():s.find('$$;', s.find('$$', m.start()) + 2) + 3]
def rep(name, a, b, n=1):
    t = last[name]
    if t.count(a) != n: sys.exit(f'REEMPLAZO FALLIDO en {name}: se esperaban {n} y hay {t.count(a)} · {a[:70]}')
    last[name] = t.replace(a, b); return last[name]
VIS = "a.raised_by = me.id or a.initial_user = me.id or me.id = any(a.escalated_to) or public._com_admin()"
NEW_VIS = "public._com_alarm_role(a, me.id) is not null"
for fn, n in [('com_my_alarms', 1), ('com_my_alarms_page', 2), ('com_alarm_raise', 1)]:
    rep(fn, VIS, NEW_VIS, n)
rep('_com_alarm_view', "'ring', a.status = 'PENDIENTE_ATENCION' and (p_me = a.initial_user or p_me = any(a.escalated_to)),",
    "'ring', a.status = 'PENDIENTE_ATENCION' and (p_me = a.initial_user or p_me = any(a.escalated_to)) and public.user_has_perm(p_me, 'com.approve'),   -- N-V4-01: permiso ACTUAL")
rep('_com_alarm_view', "'can_attend', a.status = 'PENDIENTE_ATENCION' and (p_me = a.initial_user or p_me = any(a.escalated_to) or public._com_admin()));",
    "'can_attend', a.status = 'PENDIENTE_ATENCION' and coalesce(public._com_alarm_role(a, p_me), 'SOLICITANTE') <> 'SOLICITANTE');   -- N-V4-01")
rep('com_alarm_attend', """  como := case when me.id = a.initial_user then 'DESTINATARIO_INICIAL' when me.id = any(a.escalated_to) then 'ESCALAMIENTO'
               when public._com_admin() then 'ADMINISTRADOR_GENERAL' end;""",
    """  como := nullif(public._com_alarm_role(a, me.id), 'SOLICITANTE');   -- N-V4-01: papel con el permiso ACTUAL (una asignación histórica no alcanza)""")
rep('com_alarm_by_notification', """  if not found then return null; end if;
  return public._com_alarm_view(a, me.id);""", """  if not found or public._com_alarm_role(a, me.id) is null then return null; end if;   -- N-V4-01: el enlace previo no da acceso sin el permiso ACTUAL
  return public._com_alarm_view(a, me.id);""")
rep('_com_view', "'kpi', case when p_full then q.kpi_snapshot end,",
    """'kpi', case when p_full then (case when (select kpi_mode from public.com_settings where id = 'DEFAULT') = 'DESHABILITADO'
      then jsonb_build_object('status', 'DESHABILITADO', 'provisional', true, 'detail', 'KPI DESHABILITADO — pendiente de verificar los informes de Cianbox. La autorización es manual.')
      else q.kpi_snapshot end) end,   -- N-V4-03: con el KPI deshabilitado no se EXPONE la foto guardada (se CONSERVA en la tabla)""")
TZ = "'America/Argentina/Mendoza'"
rep('com_history', "q.created_at >= (f->>'from')::date)", f"q.created_at >= ((f->>'from')::date::timestamp at time zone {TZ}))   -- N-V4-05: día operativo argentino")
rep('com_history', "q.created_at < (f->>'to')::date + 1)", f"q.created_at < (((f->>'to')::date + 1)::timestamp at time zone {TZ}))")
# revisión anticipatoria (punto 6): el MISMO defecto de N-V4-05 en Informes, historial de alarmas y estadísticas → día ARGENTINO
def rep_all(name, a, b):
    t = last[name]
    if t.count(a) < 1: sys.exit(f'REEMPLAZO FALLIDO en {name}: {a[:70]}')
    last[name] = t.replace(a, b)
rep_all('com_alarm_history', "a.raised_at >= p_from and a.raised_at < p_to + 1", "a.raised_at >= public._com_ar_day(p_from) and a.raised_at < public._com_ar_day(p_to + 1)")
rep_all('com_alarm_history_page', "a.raised_at >= coalesce(p_from, '-infinity'::date) and a.raised_at < coalesce(p_to, 'infinity'::date) + 1",
        "a.raised_at >= coalesce(public._com_ar_day(p_from), '-infinity'::timestamptz) and a.raised_at < coalesce(public._com_ar_day(p_to + 1), 'infinity'::timestamptz)")
rep_all('com_dispatch_stats', "r.published_at >= p_from and r.published_at < p_to + 1", "r.published_at >= public._com_ar_day(p_from) and r.published_at < public._com_ar_day(p_to + 1)")
rep_all('com_report', "created_at >= p_from and created_at < p_to + 1", "created_at >= public._com_ar_day(p_from) and created_at < public._com_ar_day(p_to + 1)")
rep('_com_alarm_escalation', "and p.role = 'ADMIN'", "and p.role = 'ADMIN' and not ('COMERCIAL' = any(p.disabled_modules))")
rep('com_set_alarm_settings', "status = 'ACTIVO' and role = 'ADMIN')", "status = 'ACTIVO' and role = 'ADMIN' and not ('COMERCIAL' = any(disabled_modules)))")
ORDER = ['_com_view', 'com_alarm_history', 'com_alarm_history_page', 'com_dispatch_stats', 'com_report', '_com_alarm_escalation', '_com_alarm_view', 'com_alarm_raise', 'com_alarm_attend', 'com_alarm_by_notification', 'com_my_alarms', 'com_my_alarms_page', 'com_set_alarm_settings', 'com_history']
head = open('tools/v5_head.sql', encoding='utf-8').read(); tail = open('tools/v5_tail.sql', encoding='utf-8').read()
body = '\n\n'.join('-- ' + n + ' (texto exacto vigente + reemplazos verificados)\n' + last[n] for n in ORDER)
open('propuestas/comercial/20261201000900_comercial_v5_permisos_kpi_fechas.sql', 'w', encoding='utf-8').write(head + '\n' + body + '\n\n' + tail)
print('generada 000900:', len(ORDER), 'funciones redefinidas')
