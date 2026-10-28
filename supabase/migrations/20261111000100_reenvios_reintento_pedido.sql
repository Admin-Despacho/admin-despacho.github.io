-- =====================================================================================================================
-- PROPUESTA · NO APLICADA · REENVÍOS: volver a cargar un pedido en una hoja nueva cuando el intento anterior no se concretó.
-- Hoy order_reservations tiene UNA reserva por pedido (order_id es la clave) y al publicar queda PUBLICADA para siempre: un pedido
-- con cliente ausente o reprogramado no se puede volver a cargar.
-- Cambio mínimo en reserve_orders: la reserva PUBLICADA de un pedido pasa a la hoja nueva SOLO si en su hoja anterior
--   · todas las paradas que lo contienen quedaron NO_ENTREGADO o REPROGRAMAR, o
--   · esa hoja fue CANCELADA.
-- Sigue BLOQUEADO (mismo error PEDIDO_YA_EN_OTRA_HOJA): pendiente/en curso en otra hoja activa, ENTREGADO o ENTREGA PARCIAL, y
-- cualquier borrador ajeno. Nada se libera automáticamente: solo al cargarlo explícitamente en una hoja nueva.
-- La hoja anterior, sus paradas y resultados NO se tocan. La reserva anterior queda en order_reservation_history (trazabilidad).
-- Sin cambios de permisos: reserve_orders sigue exigiendo routes.create; el historial se lee con la misma regla que las reservas.
-- =====================================================================================================================
create table if not exists public.order_reservation_history (
  id bigint generated always as identity primary key,
  order_id text not null, sheet_key text not null, route_id uuid references public.routes(id), status text not null,
  reserved_by uuid, reserved_at timestamptz, released_at timestamptz not null default now(), released_by uuid,
  released_to_sheet text not null, reason text not null);
create index if not exists order_reservation_history_order_idx on public.order_reservation_history(order_id);
alter table public.order_reservation_history enable row level security;
drop policy if exists order_reservation_history_read on public.order_reservation_history;
create policy order_reservation_history_read on public.order_reservation_history for select to authenticated
  using (public.auth_has_perm('routes.create') or public.auth_has_perm('routes.view_all'));

-- ¿Se puede volver a intentar este pedido? (su hoja publicada fue cancelada, o TODAS sus paradas quedaron no entregadas/reprogramadas)
create or replace function public._order_retryable(p_order text, p_route uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.routes rt where rt.id = p_route and rt.operational_status = 'CANCELADA')
      or (exists (select 1 from public.route_stops s where s.route_id = p_route and p_order = any (s.order_numbers))
          and not exists (select 1 from public.route_stops s where s.route_id = p_route and p_order = any (s.order_numbers)
                          and coalesce(s.outcome, 'PENDIENTE') not in ('NO_ENTREGADO', 'REPROGRAMAR'))) $$;
revoke execute on function public._order_retryable(text, uuid) from public, anon, authenticated;

create or replace function public.reserve_orders(p_sheet_key text, p_orders text[])
returns void language plpgsql security definer set search_path = public as $$
declare msg text; det jsonb;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public._draft(p_sheet_key, true);
  -- NUEVO: reintento. La reserva publicada de un pedido NO ENTREGADO / REPROGRAMADO (o de una hoja cancelada) pasa a esta hoja.
  with mov as (
    delete from public.order_reservations r
     where r.order_id = any (p_orders) and r.sheet_key <> p_sheet_key and r.status = 'PUBLICADA' and r.route_id is not null
       and public._order_retryable(r.order_id, r.route_id)
    returning r.*)
  insert into public.order_reservation_history(order_id, sheet_key, route_id, status, reserved_by, reserved_at, released_by, released_to_sheet, reason)
  select m.order_id, m.sheet_key, m.route_id, m.status, m.reserved_by, m.reserved_at, auth.uid(), p_sheet_key,
         case when rt.operational_status = 'CANCELADA' then 'HOJA_CANCELADA' else 'REINTENTO_NO_ENTREGADO_O_REPROGRAMADO' end
    from mov m left join public.routes rt on rt.id = m.route_id;
  -- (igual que antes)
  insert into public.order_reservations(order_id, sheet_key, reserved_by)
  select distinct o, p_sheet_key, auth.uid() from unnest(p_orders) o where coalesce(o, '') <> ''
  on conflict (order_id) do nothing;
  select string_agg(r.order_id || ' (' || coalesce('hoja ' || rt.number, 'borrador' || coalesce(' "' || d.name || '"', '') || coalesce(' de ' || p.full_name, '')) || ')', ', '),
         jsonb_agg(jsonb_build_object('order', r.order_id, 'sheet_key', r.sheet_key, 'draft_name', d.name, 'owner_id', r.reserved_by, 'owner', p.full_name, 'route_number', rt.number, 'published', rt.id is not null))
    into msg, det
    from public.order_reservations r left join public.routes rt on rt.id = r.route_id left join public.profiles p on p.id = r.reserved_by
    left join public.route_drafts d on d.client_sheet_key = r.sheet_key
   where r.order_id = any(p_orders) and r.sheet_key <> p_sheet_key;
  if msg is not null then raise exception 'PEDIDO_YA_EN_OTRA_HOJA: %', msg using errcode = '23505', detail = det::text; end if;
end; $$;
