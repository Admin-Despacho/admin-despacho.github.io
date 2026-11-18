-- SOLO LECTURA · ejecutar en el SQL Editor ANTES de aplicar 20261202000100. No modifica nada.
-- Resultado esperado: todas las filas con ok = true. Si alguna dice false, NO aplicar y revisar.
SELECT 'objeto ' || x.n AS control, to_regclass(x.n) IS NOT NULL AS ok FROM (VALUES ('public.com_decision_mail_outbox'),('public.comm_mail_transport'),('public.comm_smtp_rate'),('public.com_request_events')) x(n)
UNION ALL SELECT 'no aplicada todavía', to_regclass('public.com_decision_mail_payloads') IS NULL
UNION ALL SELECT 'huella ' || f.sig, to_regprocedure(f.sig) IS NOT NULL AND md5((SELECT prosrc FROM pg_catalog.pg_proc WHERE oid = to_regprocedure(f.sig))) = f.h
  FROM (VALUES ('public.comm_smtp_claim(text,text)', '122468dcb26660ecf0e1499ae0ab75fd'), ('public.com_mail_settings_get()', 'd23a96fb2cf877509b7ed51927e9c11c'),
    ('public.comm_mail_runtime()', '42057332ba3770ef0ed4d05d78e84d28'), ('public.comm_decision_mail_guard(bigint,uuid)', 'd58bb9f9496993769120747f5c0d94be'),
    ('public.comm_decision_mail_finish(bigint,uuid,text,text,text)', '20b3a84c824cab03d79ebee5f2e2f531'), ('public._com_mail_event()', 'edc79643ef9f5f07f43b40d5cd77af43')) f(sig, h)
UNION ALL SELECT 'proveedor SMTP activo', (SELECT provider = 'SMTP' FROM public.comm_mail_transport WHERE id = 1)
UNION ALL SELECT 'límite horario = 100', (SELECT hourly_cap = 100 FROM public.comm_mail_transport WHERE id = 1)
UNION ALL SELECT 'sin correos en PROCESSING', NOT EXISTS (SELECT 1 FROM public.com_decision_mail_outbox WHERE state = 'PROCESSING')
UNION ALL SELECT 'envíos de las últimas 24 h (' || (SELECT count(*) FROM public.comm_smtp_rate WHERE at > now() - interval '24 hours') || ') por debajo de 850', (SELECT count(*) FROM public.comm_smtp_rate WHERE at > now() - interval '24 hours') < 850;
-- Pendientes actuales por estado (informativo):
SELECT state, count(*) FROM public.com_decision_mail_outbox GROUP BY state ORDER BY state;
