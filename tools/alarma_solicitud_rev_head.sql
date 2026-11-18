-- =====================================================================================================================
-- REVERSIÓN · ALARMA URGENTE DESDE LA SOLICITUD (001300) · NO APLICAR sin autorización.
-- Elimina SOLO las tres funciones nuevas y el índice por autorización, restaura el índice publicado por pedido, y restaura EXACTAMENTE com_alarm_raise, com_alarm_attend y com_alarm_escalate_due (huellas verificadas).
-- CONSERVA todas las alarmas, sus eventos, el registro de operaciones y los historiales (también las alarmas creadas desde la solicitud, que
-- siguen pudiendo atenderse y escalarse con las funciones restauradas).
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s';
DO $chk$ BEGIN
  IF to_regprocedure('public.com_alarm_raise_request(uuid,text,text)') IS NULL THEN RAISE EXCEPTION 'NADA_QUE_REVERTIR: 001300 no está aplicada. No se modificó nada.'; END IF;
END $chk$;
-- el índice publicado (una activa por PEDIDO, para todas) solo se puede restaurar si no hay dos alarmas activas del mismo pedido.
-- Si las hay (dos autorizaciones que comparten pedido), NO se toca ningún dato: hay que atenderlas antes de revertir.
DO $dup$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM (SELECT 1 FROM public.com_alarms WHERE status = 'PENDIENTE_ATENCION' GROUP BY upper(btrim(order_ref)) HAVING count(*) > 1) x;
  IF n > 0 THEN RAISE EXCEPTION 'REVERSION_BLOQUEADA: % pedido(s) con más de una alarma activa (autorizaciones distintas). Atenderlas antes de revertir. No se modificó nada.', n; END IF;
END $dup$;
drop index if exists public.com_alarms_one_active_request;
drop index public.com_alarms_one_active;
create unique index com_alarms_one_active on public.com_alarms(upper(btrim(order_ref))) where status = 'PENDIENTE_ATENCION';
drop function public.com_alarm_request_detail(uuid);
drop function public.com_request_alarm(uuid);
drop function public.com_alarm_raise_request(uuid, text, text);
