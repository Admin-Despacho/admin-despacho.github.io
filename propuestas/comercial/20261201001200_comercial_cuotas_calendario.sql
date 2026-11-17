-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · FINANCIACIÓN PROPIA CON CALENDARIO DE CUOTAS · NO APLICADA. Después de 000100 a 001100.
-- Reglas (Dirección):
--  · cantidad de cuotas; con 2 o más, frecuencia SEMANAL (cada 7 días), QUINCENAL (cada 15 días) o MENSUAL (mes calendario);
--  · PRIMER vencimiento elegido por el vendedor (con 1 cuota es la única fecha); no puede ser anterior a la creación de la solicitud;
--  · NINGÚN vencimiento puede superar los 30 días corridos desde la CREACIÓN de la solicitud, con fecha ARGENTINA
--    (la fecha base ya la calculan com_create_request y com_decide en America/Argentina/Mendoza);
--  · si una cuota excede el límite, el error dice CUÁL, su fecha y la fecha límite.
-- Compatibilidad: las solicitudes guardadas NO se modifican. Un pedido en el formato anterior (sin first_due: app sin actualizar) se
-- interpreta como antes (semanal, primer vencimiento a los 7 días) con el mismo error BAD_INSTALLMENTS. La rama de e-cheq no cambia.
-- Solo se redefine _com_terms; sus privilegios se conservan (create or replace).
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regprocedure('public._com_terms(text,jsonb,public.com_clients,date)') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: módulo comercial no instalado. No se modificó nada.'; END IF;
  IF coalesce(obj_description('public._com_terms(text,jsonb,public.com_clients,date)'::regprocedure, 'pg_proc'), '') = 'OKD:CUOTAS_CALENDARIO_V1' THEN RAISE EXCEPTION 'YA_APLICADA. No se modificó nada.'; END IF;
  -- la función vigente debe ser EXACTAMENTE la de 000100 (si alguien la cambió, revisar antes de reemplazarla)
  IF md5(pg_get_functiondef('public._com_terms(text,jsonb,public.com_clients,date)'::regprocedure)) <> 'cd4e5a9e0a39ac7bcdd712ef57b25bef' THEN RAISE EXCEPTION 'BASE_CAMBIADA: _com_terms no coincide con la versión publicada. No se modificó nada.'; END IF;
END $guard$;

create or replace function public._com_terms(p_kind text, p_terms jsonb, p_client public.com_clients, p_base date) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.com_settings; a numeric; k int; sched jsonb := '[]'; i int; due date; iname text; icuit text;
        f date; freq text; lim date; maxd int;
begin
  select * into s from public.com_settings where id = 'DEFAULT';
  a := round((p_terms->>'amount')::numeric, 2);
  if a is null or a <= 0 or a > 999999999 then raise exception 'BAD_AMOUNT: importe inválido' using errcode = '23514'; end if;
  if p_kind = 'FINANCIACION' then
    maxd := least(s.fin_max_days, 30);   -- tope de Dirección: 30 días corridos (la configuración solo puede achicarlo)
    lim := p_base + maxd;
    k := case when coalesce(p_terms->>'installments', '') ~ '^[0-9]{1,3}$' then (p_terms->>'installments')::int end;   -- valor manipulado o no numérico → rechazo explicado
    if not (p_terms ? 'first_due') then
      -- FORMATO ANTERIOR (sin primer vencimiento): semanal desde el día 7, mismo error que antes
      if k is null or k < 1 or k * 7 > maxd then raise exception 'BAD_INSTALLMENTS: cuotas semanales; el último vencimiento no puede superar % días', maxd using errcode = '23514'; end if;
      f := p_base + 7; freq := case when k > 1 then 'SEMANAL' end;
    else
      if k is null or k < 1 or k > 31 then raise exception 'BAD_INSTALLMENTS: cantidad de cuotas inválida' using errcode = '23514'; end if;
      begin f := (p_terms->>'first_due')::date; exception when others then f := null; end;
      if f is null then raise exception 'BAD_FIRST_DUE: elegí la fecha del primer vencimiento' using errcode = '23514'; end if;
      if f < p_base then raise exception 'BAD_FIRST_DUE: el primer vencimiento (%) no puede ser anterior a la creación de la solicitud (%)', to_char(f, 'DD/MM/YYYY'), to_char(p_base, 'DD/MM/YYYY') using errcode = '23514'; end if;
      if k > 1 then
        freq := upper(btrim(coalesce(p_terms->>'frequency', '')));
        if freq not in ('SEMANAL', 'QUINCENAL', 'MENSUAL') then raise exception 'BAD_FREQUENCY: con 2 o más cuotas elegí la frecuencia (semanal, quincenal o mensual)' using errcode = '23514'; end if;
      end if;
    end if;
    for i in 1..k loop
      due := case when k = 1 then f when freq = 'QUINCENAL' then f + (i - 1) * 15 when freq = 'MENSUAL' then (f + make_interval(months => i - 1))::date else f + (i - 1) * 7 end;
      if due > lim then raise exception 'BAD_SCHEDULE: la cuota % vence el % y supera el límite del % (% días corridos desde la creación de la solicitud). Corregí la cantidad, la frecuencia o el primer vencimiento.',
        i, to_char(due, 'DD/MM/YYYY'), to_char(lim, 'DD/MM/YYYY'), maxd using errcode = '23514'; end if;
      sched := sched || jsonb_build_object('n', i, 'due', due, 'amount', case when i < k then round(a / k, 2) else a - round(a / k, 2) * (k - 1) end);
    end loop;
    return jsonb_build_object('amount', a, 'installments', k, 'frequency', freq, 'first_due', f, 'schedule', sched, 'last_due', due, 'days', due - p_base, 'limit_date', lim, 'max_days', maxd);
  end if;
  due := (p_terms->>'due_date')::date;
  if due is null or due < p_base or due > p_base + s.cheq_max_days then raise exception 'BAD_DUE_DATE: el vencimiento del e-cheq debe estar entre hoy y % días', s.cheq_max_days using errcode = '23514'; end if;
  iname := nullif(btrim(p_terms->>'issuer_name'), ''); icuit := nullif(regexp_replace(coalesce(p_terms->>'issuer_cuit', ''), '\D', '', 'g'), '');
  if icuit is not null and not public._cuit_valid(icuit) then raise exception 'BAD_ISSUER_CUIT: el CUIT del emisor no es válido' using errcode = '23514'; end if;
  if iname is null and icuit is null then   -- emisor vacío = el MISMO cliente (sin inventar un CUIT que no tenga)
    return jsonb_build_object('amount', a, 'due_date', due, 'days', due - p_base, 'issuer_is_client', true, 'issuer_name', p_client.razon_social, 'issuer_cuit', p_client.cuit);
  end if;
  return jsonb_build_object('amount', a, 'due_date', due, 'days', due - p_base, 'issuer_is_client', false, 'issuer_name', coalesce(iname, '(sin nombre)'), 'issuer_cuit', icuit);
end; $$;
comment on function public._com_terms(text,jsonb,public.com_clients,date) is 'OKD:CUOTAS_CALENDARIO_V1';
COMMIT;
