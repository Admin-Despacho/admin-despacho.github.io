-- =====================================================================================================================
-- REVERSIÓN · FINANCIACIÓN PROPIA CON CALENDARIO DE CUOTAS (001200) · NO APLICAR sin autorización.
-- Restaura EXACTAMENTE _com_terms de 000100 (texto original) y verifica su huella. Las solicitudes ya creadas con calendario
-- se CONSERVAN tal como están guardadas (fechas y cuotas grabadas en sus condiciones); no se modifica ningún dato.
-- Después de revertir, una decisión «con cambios» vuelve a usar la regla anterior (cuotas semanales desde el día 7).
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s';
DO $chk$ BEGIN
  IF coalesce(obj_description('public._com_terms(text,jsonb,public.com_clients,date)'::regprocedure, 'pg_proc'), '') <> 'OKD:CUOTAS_CALENDARIO_V1' THEN
    RAISE EXCEPTION 'NADA_QUE_REVERTIR: _com_terms no tiene la marca de 001200. No se modificó nada.'; END IF;
END $chk$;
create or replace function public._com_terms(p_kind text, p_terms jsonb, p_client public.com_clients, p_base date) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.com_settings; a numeric; k int; sched jsonb := '[]'; i int; due date; iname text; icuit text;
begin
  select * into s from public.com_settings where id = 'DEFAULT';
  a := round((p_terms->>'amount')::numeric, 2);
  if a is null or a <= 0 or a > 999999999 then raise exception 'BAD_AMOUNT: importe inválido' using errcode = '23514'; end if;
  if p_kind = 'FINANCIACION' then
    k := (p_terms->>'installments')::int;
    if k is null or k < 1 or k * 7 > s.fin_max_days then raise exception 'BAD_INSTALLMENTS: cuotas semanales; el último vencimiento no puede superar % días', s.fin_max_days using errcode = '23514'; end if;
    for i in 1..k loop sched := sched || jsonb_build_object('n', i, 'due', p_base + i * 7, 'amount', case when i < k then round(a / k, 2) else a - round(a / k, 2) * (k - 1) end); end loop;
    return jsonb_build_object('amount', a, 'installments', k, 'schedule', sched, 'last_due', p_base + k * 7, 'days', k * 7);
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
comment on function public._com_terms(text,jsonb,public.com_clients,date) is null;
DO $post$ BEGIN
  IF md5(pg_get_functiondef('public._com_terms(text,jsonb,public.com_clients,date)'::regprocedure)) <> 'cd4e5a9e0a39ac7bcdd712ef57b25bef' THEN RAISE EXCEPTION 'REVERSION_INEXACTA'; END IF;
END $post$;
COMMIT;
