-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · «CONSULTAR APROBACIÓN» · NO APLICADA. Se aplica después de 20261201000100 y 000200.
-- Corrige la auditoría focalizada del 14/11 (B-01, B-02) y agrega el control de SESIÓN REVOCADA a todo el módulo.
--  · com_order_alerts: consulta de SOLO LECTURA para la sección REVISAR de la publicación. INFORMATIVA: no bloquea, no cambia importes, no
--    autoriza descuentos y NO se conecta con NOC. Devuelve solo lo que Despacho ya ve en la trazabilidad.
--  · B-02 ALCANCE POR REGISTRO (servidor): Administrador General y Despacho (com.track) → todas; aprobador (com.approve) → solo las ASIGNADAS
--    a él; Comercial (com.request) → solo las PROPIAS. Con varios permisos se suman los alcances. Crear solicitudes NO da consulta global.
--  · B-01 UNA SOLA política de deduplicación: por número de pedido, SOLO la solicitud más reciente (fecha y, a igual fecha, número
--    correlativo), venga la coincidencia por pedido o por CUIT. Las solicitudes en curso de OTROS pedidos del mismo cliente se muestran
--    (una por pedido); una solicitud sin número de pedido cuenta como propia.
--  · Sesión revocada: _com_active exige, para el usuario de la sesión, que el token sea posterior a sessions_revoked_at (= auth_has_perm).
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regclass('public.com_requests') IS NULL OR to_regprocedure('public._com_active(uuid)') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: aplicar antes 20261201000100. No se modificó nada.'; END IF;
END $guard$;

-- sesión revocada (misma regla que auth_has_perm de la base): solo cuando se evalúa al usuario de la SESIÓN
create or replace function public._com_active(p_user uuid default auth.uid()) returns public.profiles language sql stable security definer set search_path = public as $$
  select p.* from public.profiles p where p.id = p_user and p.status = 'ACTIVO'
     and (p_user is distinct from auth.uid() or p.sessions_revoked_at is null or coalesce((auth.jwt() ->> 'iat')::numeric, 0) > extract(epoch from p.sessions_revoked_at));
$$;

create or replace function public.com_order_alerts(p_orders text[], p_cuits text[]) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active();
  o text[] := (select coalesce(array_agg(distinct upper(btrim(x))), '{}') from unnest(coalesce(p_orders, '{}')) x where coalesce(btrim(x), '') <> '');
  c text[] := (select coalesce(array_agg(distinct regexp_replace(x, '\D', '', 'g')), '{}') from unnest(coalesce(p_cuits, '{}')) x where length(regexp_replace(coalesce(x, ''), '\D', '', 'g')) in (7, 8, 11));
  todas boolean; aprob boolean; propias boolean;
begin
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  todas := public._is_general_admin() or public.user_has_perm(me.id, 'com.track');
  aprob := public.user_has_perm(me.id, 'com.approve'); propias := public.user_has_perm(me.id, 'com.request');
  if not (todas or aprob or propias) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if cardinality(o) > 300 or cardinality(c) > 300 then raise exception 'TOO_MANY: máximo 300 pedidos y 300 clientes por consulta' using errcode = '22023'; end if;
  return coalesce((select jsonb_agg(x order by x->>'created_at' desc, x->>'number' desc) from (
    select jsonb_build_object('number', r.number, 'kind', r.kind, 'status', r.status, 'order_ref', r.order_ref, 'match', case when r.ref = any(o) then 'PEDIDO' else 'CLIENTE' end,
      'client', r.client_snapshot->>'razon_social', 'cuit', r.client_snapshot->>'cuit', 'created_at', r.created_at, 'decided_at', r.decided_at,
      'alert', case when r.status in ('PENDIENTE', 'DEVUELTA', 'RECHAZADA') then 'CONSULTAR APROBACIÓN' end,
      'final_terms', case when r.status in ('APROBADA', 'APROBADA_MOD') then r.final_terms end) x
    from (
      -- 1) alcance por registro; 2) UNA política de deduplicación para ambas coincidencias: la más reciente por número de pedido
      select v.*, row_number() over (partition by coalesce(nullif(v.ref, ''), v.id::text) order by v.created_at desc, v.number desc) rn
        from (select q.*, upper(btrim(coalesce(q.order_ref, ''))) ref from public.com_requests q
               where q.status <> 'CANCELADA'
                 and (todas or (aprob and q.assigned_approver_id = me.id) or (propias and q.requested_by = me.id))) v) r
    where r.rn = 1
      and (r.ref = any(o) or (r.status in ('PENDIENTE', 'DEVUELTA') and regexp_replace(coalesce(r.client_snapshot->>'cuit', ''), '\D', '', 'g') = any(c)))) t), '[]'::jsonb);
end; $$;
revoke all on function public.com_order_alerts(text[],text[]) from public, anon; grant execute on function public.com_order_alerts(text[],text[]) to authenticated;
COMMIT;
