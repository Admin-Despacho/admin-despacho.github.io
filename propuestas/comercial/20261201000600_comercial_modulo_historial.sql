-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · V4 · MÓDULO RESTRINGIBLE + HISTORIAL COMPLETO POR VENDEDOR · NO APLICADA. Después de 000100 a 000500.
--  · B-W04: el módulo COMERCIAL se puede RESTRINGIR por usuario como los demás (pantalla de Usuarios, Edge admin-users y SQL alineados):
--    la restricción de profiles se recrea CONSERVANDO los módulos vigentes y agregando COMERCIAL; module_permissions mapea sus 4 permisos
--    (los mismos de rules.js). user_has_perm ya descuenta módulos restringidos: la restricción vale en TODAS las RPC del módulo.
--  · Historial: com_history (paginación por CURSOR estable, filtros, alcance en el servidor) y com_request_detail (misma vista y privacidad
--    que el resto del módulo; «no existe» y «no es tuya» responden IGUAL).
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regclass('public.com_alarm_ops') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: aplicar antes 000100 a 000500. No se modificó nada.'; END IF;
  IF to_regprocedure('public.com_history(text,jsonb,jsonb,integer)') IS NOT NULL THEN RAISE EXCEPTION 'YA_APLICADA. No se modificó nada.'; END IF;
END $guard$;

-- ---------- 1) B-W04 · módulo COMERCIAL restringible ----------
DO $mod$
DECLARE def text; mods text[];
BEGIN
  SELECT pg_get_constraintdef(oid) INTO def FROM pg_constraint WHERE conname = 'profiles_disabled_modules_valid' AND conrelid = 'public.profiles'::regclass;
  IF def IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: profiles_disabled_modules_valid. No se modificó nada.'; END IF;
  SELECT array_agg(DISTINCT m ORDER BY m) INTO mods FROM (
    SELECT (regexp_matches(def, '''([A-Z_]+)''', 'g'))[1] m WHERE def !~ '''\{'
    UNION SELECT btrim(x) FROM unnest(string_to_array((regexp_match(def, '''\{([^}]*)\}'''))[1], ',')) x WHERE def ~ '''\{') y;   -- módulos VIGENTES (no escritos a mano), en cualquiera de los dos formatos
  IF mods IS NULL OR cardinality(mods) < 3 THEN RAISE EXCEPTION 'NO_SE_PUDO_LEER_LA_RESTRICCION: %. No se modificó nada.', def; END IF;   -- nunca una restricción vacía o nula
  IF NOT ('COMERCIAL' = ANY(mods)) THEN mods := mods || 'COMERCIAL'::text; END IF;
  ALTER TABLE public.profiles DROP CONSTRAINT profiles_disabled_modules_valid;
  EXECUTE format('ALTER TABLE public.profiles ADD CONSTRAINT profiles_disabled_modules_valid CHECK (disabled_modules <@ %L::text[])', mods);
END $mod$;
insert into public.module_permissions(module, permission_code) values ('COMERCIAL', 'com.request'), ('COMERCIAL', 'com.approve'), ('COMERCIAL', 'com.track'), ('COMERCIAL', 'com.sources.upload')
  on conflict do nothing;

-- ---------- 2) índices para el historial (orden estable: fecha de creación + id) ----------
create index if not exists com_requests_hist_requester on public.com_requests(requested_by, created_at desc, id desc);
create index if not exists com_requests_hist_approver on public.com_requests(assigned_approver_id, created_at desc, id desc);
create index if not exists com_requests_hist_all on public.com_requests(created_at desc, id desc);

-- ---------- 3) historial paginado ----------
-- p_scope: MIS (solo las PROPIAS · com.request) · BANDEJA (asignadas al aprobador; Administrador General: todas) · TODAS (Administrador General)
-- p_filters: {q (cliente / razón social / CUIT), order_ref, number, from, to (fechas de creación), status: [..], kind}
-- p_cursor: {c: created_at, i: id} del ÚLTIMO ítem recibido. Orden: created_at desc, id desc. Una solicitud nueva queda ANTES del cursor:
--           no desplaza páginas (sin duplicados ni omisiones). Devuelve {items, next_cursor, has_more, page_size}.
create or replace function public.com_history(p_scope text, p_filters jsonb, p_cursor jsonb, p_limit int default 25) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); adm boolean := public._com_admin(); f jsonb := coalesce(p_filters, '{}'::jsonb);
  lim int := greatest(1, least(coalesce(p_limit, 25), 100)); cc timestamptz; ci uuid; rows jsonb; n int;
  qq text := public._com_norm(f->>'q'); qd text := regexp_replace(coalesce(f->>'q', ''), '\D', '', 'g');
  st text[] := (select array_agg(x) from jsonb_array_elements_text(case when jsonb_typeof(f->'status') = 'array' then f->'status' else '[]'::jsonb end) x);
begin
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_scope = 'MIS' and not public.user_has_perm(me.id, 'com.request') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_scope = 'BANDEJA' and not (public.user_has_perm(me.id, 'com.approve') or adm) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_scope = 'TODAS' and not adm then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_scope not in ('MIS', 'BANDEJA', 'TODAS') then raise exception 'BAD_SCOPE' using errcode = '22023'; end if;
  if p_cursor is not null then
    begin cc := (p_cursor->>'c')::timestamptz; ci := (p_cursor->>'i')::uuid; exception when others then raise exception 'BAD_CURSOR' using errcode = '22023'; end;
  end if;
  select coalesce(jsonb_agg(x order by (x->>'created_at')::timestamptz desc, (x->>'id') desc), '[]'::jsonb), count(*) into rows, n from (
    select jsonb_build_object('id', q.id, 'number', q.number, 'kind', q.kind, 'status', q.status, 'order_ref', q.order_ref,
      'client', q.client_snapshot->>'razon_social', 'cuit', q.client_snapshot->>'cuit',
      'amount', coalesce((q.original_terms->>'amount')::numeric, (q.current_terms->>'amount')::numeric),
      'created_at', q.created_at, 'updated_at', q.updated_at, 'assigned_approver', public._com_label(q.assigned_approver_id)) x
    from public.com_requests q
    where ((p_scope = 'MIS' and q.requested_by = me.id) or (p_scope = 'BANDEJA' and (q.assigned_approver_id = me.id or adm)) or (p_scope = 'TODAS' and adm))
      and (p_cursor is null or (q.created_at, q.id) < (cc, ci))
      and (coalesce(f->>'q', '') = '' or public._com_norm(q.client_snapshot->>'razon_social') like '%' || qq || '%' or public._com_norm(q.client_snapshot->>'nombre') like '%' || qq || '%'
           or (length(qd) >= 3 and regexp_replace(coalesce(q.client_snapshot->>'cuit', ''), '\D', '', 'g') like '%' || qd || '%'))
      and (coalesce(f->>'order_ref', '') = '' or upper(btrim(coalesce(q.order_ref, ''))) like '%' || upper(btrim(f->>'order_ref')) || '%')
      and (coalesce(f->>'number', '') = '' or upper(q.number) like '%' || upper(btrim(f->>'number')) || '%')
      and (coalesce(f->>'from', '') = '' or q.created_at >= (f->>'from')::date)
      and (coalesce(f->>'to', '') = '' or q.created_at < (f->>'to')::date + 1)
      and (st is null or q.status = any(st))
      and (coalesce(f->>'kind', '') = '' or q.kind = f->>'kind')
    order by q.created_at desc, q.id desc limit lim + 1) t;
  if n > lim then rows := rows - lim; end if;   -- se pidió una fila de más solo para saber si quedan resultados
  return jsonb_build_object('items', rows, 'has_more', n > lim, 'page_size', lim,
    'next_cursor', case when n > lim then jsonb_build_object('c', rows->(lim - 1)->>'created_at', 'i', rows->(lim - 1)->>'id') end);
end; $$;

-- detalle con la MISMA vista y privacidad del módulo (_com_view). Sin alcance → FORBIDDEN, igual que si no existiera (no revela existencia)
create or replace function public.com_request_detail(p_id uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); q public.com_requests;
begin
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into q from public.com_requests where id = p_id;
  if not found or not ((q.requested_by = me.id and public.user_has_perm(me.id, 'com.request')) or (q.assigned_approver_id = me.id and public.user_has_perm(me.id, 'com.approve')) or public._com_admin()) then
    raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return public._com_view(q, true);
end; $$;

revoke all on function public.com_history(text,jsonb,jsonb,int) from public, anon; grant execute on function public.com_history(text,jsonb,jsonb,int) to authenticated;
revoke all on function public.com_request_detail(uuid) from public, anon; grant execute on function public.com_request_detail(uuid) to authenticated;
COMMIT;
