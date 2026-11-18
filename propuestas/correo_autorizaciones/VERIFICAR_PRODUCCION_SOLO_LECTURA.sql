-- SOLO LECTURA · ejecutar en el SQL Editor ANTES de aplicar 20261202000100_correo_autorizaciones_v3.sql. No modifica nada.
-- Resultado esperado: todas las filas con ok = true. Si alguna dice false, NO aplicar y revisar.
SELECT 'objeto ' || x.n AS control, to_regclass(x.n) IS NOT NULL AS ok FROM (VALUES ('public.com_decision_mail_outbox'),('public.comm_mail_transport'),('public.comm_smtp_rate'),('public.comm_smtp_ledger'),('public.com_request_events'),('public.com_mail_settings')) x(n)
UNION ALL SELECT 'V3 no instalada todavía', to_regclass('public.com_mail_detail_install') IS NULL
UNION ALL SELECT 'huella ' || f.sig, to_regprocedure(f.sig) IS NOT NULL AND (f.h IS NULL OR md5((SELECT prosrc FROM pg_catalog.pg_proc WHERE oid = to_regprocedure(f.sig))) = f.h)
  FROM (VALUES ('public.comm_smtp_claim(text,text)', '122468dcb26660ecf0e1499ae0ab75fd'), ('public.com_mail_settings_get()', 'd23a96fb2cf877509b7ed51927e9c11c'),
    ('public.com_mail_settings_set(text[])', '29c88fb1fdcad74345470ae6a194e676'), ('public._com_mail_event()', 'edc79643ef9f5f07f43b40d5cd77af43'),
    ('public.comm_decision_mail_claim()', '49ba78957e31b18586f08f94d60040a2'), ('public.comm_decision_mail_guard(bigint,uuid)', 'd58bb9f9496993769120747f5c0d94be'),
    ('public.comm_decision_mail_finish(bigint,uuid,text,text,text)', '20b3a84c824cab03d79ebee5f2e2f531'), ('public.comm_mail_runtime()', '42057332ba3770ef0ed4d05d78e84d28'),
    ('public.comm_smtp_lookup(text)', NULL)) f(sig, h)
UNION ALL SELECT 'proveedor SMTP activo', (SELECT provider = 'SMTP' FROM public.comm_mail_transport WHERE id = 1)
UNION ALL SELECT 'límite horario = 100', (SELECT hourly_cap = 100 FROM public.comm_mail_transport WHERE id = 1)
UNION ALL SELECT 'sin correos en curso', NOT EXISTS (SELECT 1 FROM public.com_decision_mail_outbox WHERE state = 'PROCESSING') AND NOT EXISTS (SELECT 1 FROM public.comm_smtp_ledger WHERE state = 'PROCESSING')
UNION ALL SELECT 'envíos de la app en las últimas 24 h (' || (SELECT count(*) FROM public.comm_smtp_rate WHERE at > now() - interval '24 hours') || ') por debajo del tope diario propuesto (850)', (SELECT count(*) FROM public.comm_smtp_rate WHERE at > now() - interval '24 hours') < 850;
-- Informativo: avisos por estado y copias actuales (quedarán PENDIENTES DE RATIFICACIÓN al instalar; no se eliminan).
SELECT state, count(*) FROM public.com_decision_mail_outbox GROUP BY state ORDER BY state;
SELECT unnest(copies) AS copia_actual_a_ratificar FROM public.com_mail_settings WHERE id = 1;
