-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · ADMINISTRADOR CON SESIÓN VIGENTE (auditoría B-AL-04) · NO APLICADA. Después de 000100 a 000400.
-- _is_general_admin() de la base verifica rol ADMIN y perfil ACTIVO, pero NO sessions_revoked_at. En las 19 funciones del módulo que lo usan
-- se reemplaza por _com_admin() (= _com_active(): token posterior a la revocación + Administrador General). Ningún otro cambio.
-- Generado por tools/gen_com_admin_sesion.py desde el texto exacto vigente. Funciones: _com_can_see_full, com_approvers, com_client_finance, com_config, com_decide, com_dispatch_stats, com_import_clients, com_kpi_for_client, com_list, com_my_notifications, com_order_alerts, com_report, com_search_clients, com_set_assignment, com_set_comp_type, com_set_routing, com_set_settings, com_sources_status, com_track
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regprocedure('public._com_admin()') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: aplicar antes 20261201000400. No se modificó nada.'; END IF;
END $guard$;

-- _com_can_see_full (1 reemplazo/s)
create or replace function public._com_can_see_full(q public.com_requests) returns boolean language sql stable security definer set search_path = public as $$
  select (public._com_active()).id is not null and ((q.requested_by = auth.uid() and public.user_has_perm(auth.uid(),'com.request')) or (q.assigned_approver_id = auth.uid() and public.user_has_perm(auth.uid(),'com.approve')) or public._com_admin());
$$;

-- com_approvers (1 reemplazo/s)
create or replace function public.com_approvers() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', public._com_label(p.id)) order by p.full_name) from public.profiles p where p.status = 'ACTIVO' and public.user_has_perm(p.id, 'com.approve')), '[]'::jsonb);
end; $$;

-- com_client_finance (2 reemplazo/s)
create or replace function public.com_client_finance(p_client uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.com_clients; i public.com_ingests; b public.com_cc_balances; ls bigint;
begin
  if (public._com_active()).id is null or not (public._com_admin() or public.user_has_perm(auth.uid(), 'com.approve')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not public._com_admin() and not exists(select 1 from public.com_requests where client_id=p_client and assigned_approver_id=auth.uid()) then raise exception 'FORBIDDEN_CLIENT' using errcode='42501'; end if;
  select * into c from public.com_clients where id = p_client; if not found or c.cuit is null then return jsonb_build_object('status', 'SIN_CUIT'); end if;
  select * into i from public.com_ingests where kind = 'CC' and status = 'OK' order by at desc limit 1;
  if found then select * into b from public.com_cc_balances where ingest_id = i.id and cuit = c.cuit; end if;
  select id into ls from public.com_ingests where kind = 'SC' and status = 'OK' order by at desc, id desc limit 1;   -- la carga MÁS RECIENTE por fecha
  return jsonb_build_object('cc_saldo', b.saldo, 'cc_fecha', i.at, 'cc_disponible', b.cuit is not null,
    'pendientes', coalesce((select jsonb_agg(jsonb_build_object('comprobante', comp, 'fecha', doc_date, 'vence', due, 'saldo', last_saldo) order by due nulls last, doc_date)
       from public.com_sc_documents where cuit = c.cuit and last_ingest_id = ls and coalesce(last_saldo, 0) > 0.004 and class = 'VENTA'), '[]'::jsonb),
    'sc_fecha', (select at from public.com_ingests where id = ls));
end; $$;

-- com_config (5 reemplazo/s)
create or replace function public.com_config() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active();
begin
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object('settings', (select to_jsonb(s) - 'updated_by' from public.com_settings s where id = 'DEFAULT'),
    'my_assignment', (select to_jsonb(a) || jsonb_build_object('approver', public._com_label(r.approver_user_id)) from public.com_user_assignments a
       left join public.com_routing r on r.channel_key = case when a.channel = 'CARTERA' then 'CARTERA' else 'SUCURSAL:' || a.branch end where a.user_id = me.id),
    'is_admin', public._com_admin(), 'can_request', public.user_has_perm(me.id, 'com.request'), 'can_approve', public.user_has_perm(me.id, 'com.approve') or public._com_admin(),
    'can_track', public.user_has_perm(me.id, 'com.track') or public._com_admin(), 'can_upload', public.user_has_perm(me.id, 'com.sources.upload'),
    'routing', case when public._com_admin() then (select jsonb_agg(jsonb_build_object('channel_key', channel_key, 'approver_user_id', approver_user_id, 'approver', public._com_label(approver_user_id)) order by channel_key) from public.com_routing) end,
    'assignments', case when public._com_admin() then (select jsonb_agg(jsonb_build_object('user_id', p.id, 'name', p.full_name, 'channel', a.channel, 'branch', a.branch, 'cartera_label', a.cartera_label) order by p.full_name)
       from public.profiles p left join public.com_user_assignments a on a.user_id = p.id where p.role = 'COMERCIAL') end);
end; $$;

-- com_decide (1 reemplazo/s)
create or replace function public.com_decide(p_id uuid, p_version int, p_decision text, p_terms jsonb, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles; q public.com_requests; c public.com_clients; t jsonb; st text; asn text; n int; ev text;
begin
  me := public._com_active();
  select * into q from public.com_requests where id = p_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if q.assigned_approver_id = me.id and public.user_has_perm(me.id, 'com.approve') then asn := 'APROBADOR';
  elsif public._com_admin() then asn := case when q.assigned_approver_id = me.id then 'APROBADOR' else 'SUPLENTE_ADMIN' end;
  else raise exception 'FORBIDDEN: no sos el aprobador asignado ni Administrador General activo' using errcode = '42501'; end if;
  if p_version is null then raise exception 'BAD_VERSION' using errcode='23514'; end if;
  if q.status <> 'PENDIENTE' or q.version <> p_version then
    raise exception 'CONFLICT: la solicitud ya fue resuelta o cambió (estado %, por %)', q.status, coalesce(public._com_label(q.decided_by), '—') using errcode = '40001'; end if;
  if p_decision not in ('APROBAR', 'APROBAR_CON_CAMBIOS', 'RECHAZAR', 'DEVOLVER') then raise exception 'BAD_DECISION' using errcode = '23514'; end if;
  if p_decision <> 'APROBAR' and length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  select * into c from public.com_clients where id = q.client_id;
  t := case when p_decision in ('APROBAR_CON_CAMBIOS', 'DEVOLVER') then public._com_terms(q.kind, p_terms, c, (q.created_at at time zone 'America/Argentina/Mendoza')::date) else q.current_terms end;
  if p_decision in ('APROBAR_CON_CAMBIOS', 'DEVOLVER') and t = q.current_terms then raise exception 'NO_CHANGES: no hay cambios en importe, cuotas o plazo' using errcode = '23514'; end if;
  st := case p_decision when 'APROBAR' then 'APROBADA' when 'APROBAR_CON_CAMBIOS' then 'APROBADA_MOD' when 'RECHAZAR' then 'RECHAZADA' else 'DEVUELTA' end;
  update public.com_requests set status = st, current_terms = t, final_terms = case when st in ('APROBADA', 'APROBADA_MOD') then t end,
    decided_by = case when st = 'DEVUELTA' then null else me.id end, decided_at = case when st = 'DEVUELTA' then null else now() end, decided_as = case when st = 'DEVUELTA' then null else asn end,
    version = version + 1, updated_at = now() where id = q.id and version = p_version;
  ev := case st when 'APROBADA' then 'APROBADA' when 'APROBADA_MOD' then 'APROBADA_CON_MODIFICACIONES' when 'RECHAZADA' then 'RECHAZADA' else 'DEVUELTA_CON_MODIFICACIONES' end;
  n := public._com_event(q.id, ev, nullif(btrim(p_reason), ''), q.current_terms, t);
  update public.com_notifications set read_at = coalesce(read_at, now()) where request_id = q.id and kind = 'NUEVA';   -- sale de las bandejas pendientes
  perform public._com_notify(q.id, n, q.requested_by, ev, 'Autorización ' || q.number || ' · ' || replace(ev, '_', ' '),
    'Resuelta por ' || public._com_label(me.id) || case when asn = 'SUPLENTE_ADMIN' then ' (asignada a ' || coalesce(public._com_label(q.assigned_approver_id), '—') || ')' else '' end);
  if asn = 'SUPLENTE_ADMIN' then perform public._com_notify(q.id, n, q.assigned_approver_id, 'RESUELTA_POR_SUPLENTE', 'Autorización ' || q.number || ' resuelta por ' || public._com_label(me.id), ev); end if;
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (me.id, 'COM_' || ev, 'com_requests', q.id::text,
    jsonb_build_object('terms', q.current_terms, 'assigned_approver', q.assigned_approver_id), jsonb_build_object('terms', t, 'decided_as', asn, 'reason', p_reason));
  return jsonb_build_object('id', q.id, 'status', st, 'decided_as', asn, 'version', q.version + 1);
end; $$;

-- com_dispatch_stats (1 reemplazo/s)
create or replace function public.com_dispatch_stats(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'paradas')::int desc) from (
    select jsonb_build_object('transportista', coalesce(ca.name, r.carrier_id), 'zona', coalesce(nullif(s.zone, ''), 'SIN ZONA'), 'hojas', count(distinct r.id), 'paradas', count(*),
      'entregadas', count(*) filter (where s.outcome = 'ENTREGADO')) x
    from public.routes r join public.route_stops s on s.route_id = r.id left join public.carriers ca on ca.id = r.carrier_id
    where coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO' and r.published_at >= p_from and r.published_at < p_to + 1 group by coalesce(ca.name, r.carrier_id), coalesce(nullif(s.zone, ''), 'SIN ZONA')) t), '[]'::jsonb);
end; $$;

-- com_import_clients (1 reemplazo/s)
create or replace function public.com_import_clients(p_file_name text, p_sha256 text, p_rows jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare imp bigint; r jsonb; t text; n text; v boolean; cu text; cur public.com_clients; ins int := 0; upd int := 0; same int := 0; rej jsonb := '[]'; aft jsonb; bef jsonb;
begin
  if not public._com_admin() then raise exception 'FORBIDDEN: solo el Administrador General importa el padrón' using errcode = '42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'EMPTY_FILE' using errcode = '23514'; end if;
  insert into public.com_client_imports(by_user, file_name, file_sha256) values (auth.uid(), left(p_file_name, 200), left(p_sha256, 80)) returning id into imp;
  for r in select * from jsonb_array_elements(p_rows) loop
    if coalesce(btrim(r->>'erp_id'), '') = '' or coalesce(btrim(r->>'razon_social'), '') = '' then rej := rej || jsonb_build_object('fila', r->>'_row', 'motivo', 'SIN ID O SIN RAZÓN SOCIAL'); continue; end if;
    t := upper(btrim(coalesce(r->>'doc_type', ''))); n := regexp_replace(coalesce(r->>'doc_number', ''), '\D', '', 'g');
    t := case when n = '' and coalesce(btrim(r->>'doc_number'), '') = '' then 'SIN_DOC' when t in ('CUIT', 'CUIL', 'DNI') then t else 'OTRO' end;   -- sin número = SIN DOCUMENTO (a revisión)
    if t = 'OTRO' then n := nullif(btrim(r->>'doc_number'), ''); end if;
    v := case when t in ('CUIT', 'CUIL') then public._cuit_valid(n) when t = 'DNI' then n ~ '^\d{7,8}$' and n !~ '^(\d)\1{6,7}$' else false end;
    cu := case when t in ('CUIT', 'CUIL') and v then n end;   -- un DNI NUNCA se convierte en CUIT
    aft := jsonb_build_object('razon_social', btrim(r->>'razon_social'), 'nombre', nullif(btrim(r->>'nombre'), ''), 'doc_type', t, 'doc_number', nullif(n, ''), 'cuit', cu,
      'email', nullif(lower(btrim(r->>'email')), ''), 'vendedor', nullif(btrim(r->>'vendedor'), ''), 'localidad', nullif(btrim(r->>'localidad'), ''));
    select * into cur from public.com_clients where erp_id = btrim(r->>'erp_id');
    if not found then
      insert into public.com_clients(erp_id, razon_social, nombre, cond_fiscal, doc_type, doc_number, doc_valid, cuit, localidad, provincia, email, vendedor, zona, categoria, cod_interno, search_text, first_import_id, last_import_id)
      values (btrim(r->>'erp_id'), btrim(r->>'razon_social'), nullif(btrim(r->>'nombre'), ''), nullif(btrim(r->>'cond_fiscal'), ''), t, nullif(n, ''), v, cu, nullif(btrim(r->>'localidad'), ''), nullif(btrim(r->>'provincia'), ''),
        nullif(lower(btrim(r->>'email')), ''), nullif(btrim(r->>'vendedor'), ''), nullif(btrim(r->>'zona'), ''), nullif(btrim(r->>'categoria'), ''), nullif(btrim(r->>'cod_interno'), ''),
        public._com_norm(concat_ws(' ', r->>'razon_social', r->>'nombre', n)), imp, imp);
      ins := ins + 1;
    else
      bef := jsonb_build_object('razon_social', cur.razon_social, 'nombre', cur.nombre, 'doc_type', cur.doc_type, 'doc_number', cur.doc_number, 'cuit', cur.cuit, 'email', cur.email, 'vendedor', cur.vendedor, 'localidad', cur.localidad);
      if bef = aft then same := same + 1; update public.com_clients set last_import_id = imp where id = cur.id; continue; end if;
      insert into public.com_client_changes(client_id, import_id, before, after) values (cur.id, imp, bef, aft);
      update public.com_clients set razon_social = aft->>'razon_social', nombre = aft->>'nombre', cond_fiscal = nullif(btrim(r->>'cond_fiscal'), ''), doc_type = t, doc_number = nullif(n, ''), doc_valid = v, cuit = cu,
        localidad = aft->>'localidad', provincia = nullif(btrim(r->>'provincia'), ''), email = aft->>'email', vendedor = aft->>'vendedor', zona = nullif(btrim(r->>'zona'), ''), categoria = nullif(btrim(r->>'categoria'), ''),
        cod_interno = nullif(btrim(r->>'cod_interno'), ''), search_text = public._com_norm(concat_ws(' ', r->>'razon_social', r->>'nombre', n)), last_import_id = imp, updated_at = now() where id = cur.id;
      upd := upd + 1;
    end if;
  end loop;
  perform public._com_recompute_reviews();
  update public.com_client_imports set counts = jsonb_build_object('filas', jsonb_array_length(p_rows), 'nuevos', ins, 'actualizados', upd, 'sin_cambios', same, 'rechazados', jsonb_array_length(rej),
      'en_revision', (select count(*) from public.com_clients where status = 'REVISION'), 'total', (select count(*) from public.com_clients)), rejected = rej where id = imp;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_CLIENTS_IMPORTED', 'com_client_imports', imp::text, (select counts from public.com_client_imports where id = imp));
  return (select jsonb_build_object('import_id', imp) || counts from public.com_client_imports where id = imp);
end; $$;

-- com_kpi_for_client (2 reemplazo/s)
create or replace function public.com_kpi_for_client(p_client uuid, p_at timestamptz default now()) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if (public._com_active()).id is null or not (public._com_admin() or public.user_has_perm(auth.uid(),'com.request') or public.user_has_perm(auth.uid(),'com.approve')) then raise exception 'FORBIDDEN' using errcode='42501'; end if;
  if not public._com_admin() and not public.user_has_perm(auth.uid(),'com.request') and not exists(select 1 from public.com_requests where client_id=p_client and assigned_approver_id=auth.uid()) then raise exception 'FORBIDDEN_CLIENT' using errcode='42501'; end if;
  return public._com_kpi_raw(p_client,p_at) || (select jsonb_build_object('provisional',not s.kpi_source_verified,'label',case when s.kpi_source_verified then null else 'RECOMENDACIÓN PROVISORIA — BASADA EN COMPROBANTES DISPONIBLES' end) from public.com_settings s where id='DEFAULT');
end; $$;

-- com_list (1 reemplazo/s)
create or replace function public.com_list(p_scope text, p_status text default null, p_limit int default 30, p_offset int default 0) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); adm boolean := public._com_admin();
begin
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_scope = 'MIS' and not public.user_has_perm(me.id, 'com.request') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_scope = 'BANDEJA' and not (public.user_has_perm(me.id, 'com.approve') or adm) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_scope = 'TODAS' and not adm then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(public._com_view(q, true) order by q.status <> 'PENDIENTE', q.updated_at desc) from (
    select * from public.com_requests q where
      ((p_scope = 'MIS' and q.requested_by = me.id) or (p_scope = 'BANDEJA' and (q.assigned_approver_id = me.id or adm)) or p_scope = 'TODAS')
      and (p_status is null or q.status = p_status) order by q.status <> 'PENDIENTE', q.updated_at desc limit greatest(1, least(coalesce(p_limit, 30), 100)) offset greatest(0, coalesce(p_offset, 0))) q), '[]'::jsonb);
end; $$;

-- com_my_notifications (1 reemplazo/s)
create or replace function public.com_my_notifications() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'request_id', n.request_id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'at', n.created_at, 'read', n.read_at is not null) order by n.created_at desc), '[]'::jsonb)
  from (select * from public.com_notifications where user_id = auth.uid() and (public._com_active()).id is not null and (public._com_admin() or public.user_has_perm(auth.uid(),'com.request') or public.user_has_perm(auth.uid(),'com.approve')) order by created_at desc limit 50) n;
$$;

-- com_order_alerts (1 reemplazo/s)
create or replace function public.com_order_alerts(p_orders text[], p_cuits text[]) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active();
  o text[] := (select coalesce(array_agg(distinct upper(btrim(x))), '{}') from unnest(coalesce(p_orders, '{}')) x where coalesce(btrim(x), '') <> '');
  c text[] := (select coalesce(array_agg(distinct regexp_replace(x, '\D', '', 'g')), '{}') from unnest(coalesce(p_cuits, '{}')) x where length(regexp_replace(coalesce(x, ''), '\D', '', 'g')) in (7, 8, 11));
  todas boolean; aprob boolean; propias boolean;
begin
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  todas := public._com_admin() or public.user_has_perm(me.id, 'com.track');
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

-- com_report (1 reemplazo/s)
create or replace function public.com_report(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return (with r as (select * from public.com_requests where created_at >= p_from and created_at < p_to + 1)
  select jsonb_build_object(
    'por_tipo_estado', (select coalesce(jsonb_agg(jsonb_build_object('tipo', kind, 'estado', status, 'cantidad', n, 'solicitado', sol, 'autorizado', aut)), '[]') from
       (select kind, status, count(*) n, sum((original_terms->>'amount')::numeric) sol, sum((final_terms->>'amount')::numeric) aut from r group by 1, 2) x),
    'por_aprobador', (select coalesce(jsonb_agg(jsonb_build_object('asignado', public._com_label(assigned_approver_id), 'resuelto_por', public._com_label(decided_by), 'como', decided_as, 'cantidad', n, 'horas_promedio', h)), '[]') from
       (select assigned_approver_id, decided_by, decided_as, count(*) n, round(avg(extract(epoch from decided_at - created_at) / 3600)::numeric, 1) h from r where decided_at is not null group by 1, 2, 3) x),
    'por_canal', (select coalesce(jsonb_agg(jsonb_build_object('canal', channel, 'sucursal', branch, 'cartera', cartera_label, 'cantidad', n, 'autorizado', aut)), '[]') from
       (select channel, branch, cartera_label, count(*) n, sum((final_terms->>'amount')::numeric) aut from r group by 1, 2, 3) x),
    'por_mes', (select coalesce(jsonb_agg(jsonb_build_object('mes', m, 'cantidad', n, 'solicitado', sol, 'autorizado', aut) order by m), '[]') from
       (select to_char(created_at at time zone 'America/Argentina/Mendoza', 'YYYY-MM') m, count(*) n, sum((original_terms->>'amount')::numeric) sol, sum((final_terms->>'amount')::numeric) aut from r group by 1) x),
    'por_trimestre', (select coalesce(jsonb_agg(jsonb_build_object('trimestre', t, 'cantidad', n, 'autorizado', aut) order by t), '[]') from
       (select to_char(created_at at time zone 'America/Argentina/Mendoza', 'YYYY-"T"Q') t, count(*) n, sum((final_terms->>'amount')::numeric) aut from r group by 1) x),
    'vencimientos', (select coalesce(jsonb_agg(jsonb_build_object('numero', number, 'cliente', client_snapshot->>'razon_social', 'tipo', kind, 'importe', (final_terms->>'amount')::numeric,
       'vence', coalesce(final_terms->>'last_due', final_terms->>'due_date')) order by coalesce(final_terms->>'last_due', final_terms->>'due_date')), '[]') from r where status in ('APROBADA', 'APROBADA_MOD')),
    'score_externo', 'XFact/Veraz: integración FUTURA. No se consulta ningún servicio externo.'));
end; $$;

-- com_search_clients (1 reemplazo/s)
create or replace function public.com_search_clients(p_q text, p_limit int default 12) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare q text := public._com_norm(p_q); d text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
begin
  if not (public.user_has_perm(auth.uid(), 'com.request') or public.user_has_perm(auth.uid(), 'com.approve') or public.user_has_perm(auth.uid(), 'com.track') or public._com_admin()) then
    raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if length(q) < 2 and length(d) < 3 then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(x) from (
    select jsonb_build_object('id', c.id, 'erp_id', c.erp_id, 'razon_social', c.razon_social, 'nombre', c.nombre, 'doc_type', c.doc_type, 'doc_number', c.doc_number, 'cuit', c.cuit,
      'status', c.status, 'review_reasons', c.review_reasons, 'localidad', c.localidad, 'selectable', c.status = 'ACTIVO') x
    from public.com_clients c
    where c.status <> 'BAJA' and ((length(d) >= 3 and (c.doc_number like d || '%' or c.cuit like d || '%')) or (length(q) >= 2 and (c.search_text like q || '%' or c.search_text like '% ' || q || '%')))
    order by (c.status = 'ACTIVO') desc, (length(d) >= 3 and (c.doc_number = d or c.cuit = d)) desc, (c.search_text like q || '%') desc, c.razon_social   -- seleccionables y coincidencias exactas primero
    limit greatest(1, least(coalesce(p_limit, 12), 30))) t), '[]'::jsonb);
end; $$;

-- com_set_assignment (1 reemplazo/s)
create or replace function public.com_set_assignment(p_user uuid, p_channel text, p_branch text, p_cartera text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not exists (select 1 from public.profiles where id = p_user and role = 'COMERCIAL') then raise exception 'NOT_COMERCIAL: el usuario no tiene rol Comercial' using errcode = '23514'; end if;
  insert into public.com_user_assignments(user_id, channel, branch, cartera_label, updated_by) values (p_user, p_channel, case when p_channel = 'SUCURSAL' then p_branch end, case when p_channel = 'CARTERA' then nullif(btrim(p_cartera), '') end, auth.uid())
    on conflict (user_id) do update set channel = excluded.channel, branch = excluded.branch, cartera_label = excluded.cartera_label, updated_by = auth.uid(), updated_at = now();
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_ASSIGNMENT', 'profiles', p_user::text, jsonb_build_object('channel', p_channel, 'branch', p_branch, 'cartera', p_cartera));
  return jsonb_build_object('user_id', p_user, 'channel', p_channel);
end; $$;

-- com_set_comp_type (1 reemplazo/s)
create or replace function public.com_set_comp_type(p_prefix text, p_class text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  insert into public.com_comp_types(prefix, class, updated_by) values (upper(p_prefix), p_class, auth.uid()) on conflict (prefix) do update set class = excluded.class, updated_by = auth.uid(), updated_at = now();
  update public.com_sc_documents set class = p_class, status = case when status = 'SIN_CLASIFICAR' then case when amount is null then 'SIN_IMPORTE' when doc_date is null then 'SIN_FECHA' else 'OK' end else status end where prefix = upper(p_prefix);
  update public.com_reconciliation_issues set status = 'RESUELTA' where kind = 'TIPO_SIN_CLASIFICAR' and detail->>'prefijo' = upper(p_prefix) and status = 'ABIERTA';
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_COMP_TYPE', 'com_comp_types', upper(p_prefix), jsonb_build_object('class', p_class));
  return jsonb_build_object('prefix', upper(p_prefix), 'class', p_class);
end; $$;

-- com_set_routing (1 reemplazo/s)
create or replace function public.com_set_routing(p_channel_key text, p_approver uuid) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_approver is not null and (public._com_active(p_approver) is null or not public.user_has_perm(p_approver, 'com.approve')) then
    raise exception 'BAD_APPROVER: el aprobador debe estar ACTIVO y tener permiso de aprobación' using errcode = '23514'; end if;
  update public.com_routing set approver_user_id = p_approver, updated_by = auth.uid(), updated_at = now() where channel_key = p_channel_key;
  if not found then raise exception 'BAD_CHANNEL' using errcode = '23514'; end if;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_ROUTING', 'com_routing', p_channel_key, jsonb_build_object('approver', p_approver));
  return jsonb_build_object('channel_key', p_channel_key, 'approver', public._com_label(p_approver));
end; $$;

-- com_set_settings (1 reemplazo/s)
create or replace function public.com_set_settings(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.com_settings;
begin
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.com_settings set kpi_months = coalesce((p->>'kpi_months')::int, kpi_months), floor_pct = coalesce((p->>'floor_pct')::numeric, floor_pct), ceiling_pct = coalesce((p->>'ceiling_pct')::numeric, ceiling_pct),
    fin_max_days = coalesce((p->>'fin_max_days')::int, fin_max_days), cheq_max_days = coalesce((p->>'cheq_max_days')::int, cheq_max_days),
    coverage_gap_days = coalesce((p->>'coverage_gap_days')::int, coverage_gap_days), kpi_partial_rule = coalesce(p->>'kpi_partial_rule', kpi_partial_rule),
    kpi_source_verified = coalesce((p->>'kpi_source_verified')::boolean, kpi_source_verified), cuota_rule = coalesce(p->>'cuota_rule', cuota_rule),
    source_backup_enabled = coalesce((p->>'source_backup_enabled')::boolean, source_backup_enabled), source_max_mb = coalesce((p->>'source_max_mb')::int, source_max_mb),
    updated_by = auth.uid(), updated_at = now() where id = 'DEFAULT' returning * into s;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_SETTINGS', 'com_settings', 'DEFAULT', to_jsonb(s));
  return to_jsonb(s);
end; $$;

-- com_sources_status (1 reemplazo/s)
create or replace function public.com_sources_status() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object(
    'ultima_sc', (select jsonb_build_object('at', at, 'archivo', file_name, 'filas', rows, 'stats', stats, 'periodo', jsonb_build_array(date_min, date_max)) from public.com_ingests where kind = 'SC' and status = 'OK' order by at desc limit 1),
    'ultima_cc', (select jsonb_build_object('at', at, 'archivo', file_name, 'filas', rows) from public.com_ingests where kind = 'CC' and status = 'OK' order by at desc limit 1),
    'errores', (select coalesce(jsonb_agg(jsonb_build_object('at', at, 'kind', kind, 'archivo', file_name, 'error', error) order by at desc), '[]') from (select * from public.com_ingests where status <> 'OK' order by at desc limit 10) e),
    'meses_cubiertos', (select coalesce(jsonb_agg(m order by m), '[]') from (select g::date m from generate_series(date_trunc('month', now()) - interval '12 month', date_trunc('month', now()) - interval '1 month', interval '1 month') g where public._com_month_covered(g::date)) x),
    'incidencias', (select coalesce(jsonb_object_agg(kind, n), '{}') from (select kind, count(*) n from public.com_reconciliation_issues where status = 'ABIERTA' group by kind) x),
    'tipos', (select jsonb_agg(jsonb_build_object('prefijo', prefix, 'clase', class) order by prefix) from public.com_comp_types),
    'clientes_sin_historial', (select count(*) from public.com_clients c where c.status = 'ACTIVO' and (c.cuit is null or not exists (select 1 from public.com_sc_documents d where d.cuit = c.cuit))));
end; $$;

-- com_track (1 reemplazo/s)
create or replace function public.com_track(p_q text, p_open_only boolean default false, p_limit int default 20, p_offset int default 0) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); q text := public._com_norm(p_q); d text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
begin
  if me.id is null or not (public.user_has_perm(me.id, 'com.track') or public._com_admin()) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(public._com_view(r, public._com_can_see_full(r)) order by r.updated_at desc) from (
    select * from public.com_requests r where (not p_open_only or r.status in ('PENDIENTE', 'DEVUELTA'))
      and (coalesce(btrim(p_q), '') = '' or public._com_norm(r.client_snapshot->>'razon_social') like '%' || q || '%' or public._com_norm(r.client_snapshot->>'nombre') like '%' || q || '%'
           or (length(d) >= 3 and ((r.client_snapshot->>'cuit') like '%' || d || '%' or (r.client_snapshot->>'doc_number') like '%' || d || '%')) or public._com_norm(r.order_ref) like '%' || q || '%' or r.number ilike '%' || p_q || '%')
    order by r.updated_at desc limit greatest(1, least(coalesce(p_limit, 20), 50)) offset greatest(0, coalesce(p_offset, 0))) r), '[]'::jsonb);
end; $$;

-- política de LECTURA de originales (bucket privado com-sources): misma regla, solo si el almacenamiento existe (como en 000200)
DO $pol$ BEGIN
  IF to_regclass('storage.objects') IS NOT NULL THEN
    EXECUTE 'drop policy if exists com_sources_select on storage.objects';
    EXECUTE $p$create policy com_sources_select on storage.objects for select to authenticated using (bucket_id = 'com-sources' and public._com_admin())$p$;
  END IF;
END $pol$;
COMMIT;
