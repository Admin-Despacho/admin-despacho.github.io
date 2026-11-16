-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · CUOTAS (WORK-K02) Y RESPALDO PRIVADO DE ORIGINALES (A-09) · NO APLICADA.
-- Se aplica DESPUÉS de 20261201000100 (versión corregida por Work). Generada por tools/gen_cuotas_respaldo.py a partir del TEXTO
-- EXACTO de las funciones de Work, con reemplazos mínimos verificados. Independiente de V4.29.
--  · WORK-K02: la parte de un comprobante se identifica como en el Constructor (cuota o, si no hay, vencimiento). La venta mensual se
--    calcula POR COMPROBANTE con una regla EXPLÍCITA (cuota_rule). Por defecto POR_CONFIRMAR: un comprobante con varias partes NO
--    entra al KPI y se informa como «cuotas por confirmar» (nunca se suma dos veces, nunca se inventa). Con el archivo REAL se elige
--    MONTO_ES_TOTAL (el monto repetido se cuenta una vez) o MONTO_ES_CUOTA (se suman las partes). WORK-K02 sigue ABIERTO hasta entonces.
--  · A-09: respaldo privado de los ORIGINALES (Storage privado «com-sources», ruta por contenido, versiones inmutables). APAGADO por
--    defecto (source_backup_enabled = false). Encendido: cada carga EXIGE su original ya recibido y queda vinculada a él.
--  · La foto del KPI de cada solicitud incluye las fuentes usadas (carga, archivo, versión y hash).
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regclass('public.com_requests') IS NULL OR to_regclass('public.com_sc_documents') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: aplicar antes 20261201000100. No se modificó nada.'; END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'com_settings' AND column_name = 'cuota_rule') THEN RAISE EXCEPTION 'YA_APLICADA. No se modificó nada.'; END IF;
END $guard$;

-- ---------- 1) parámetros ----------
alter table public.com_settings add column cuota_rule text not null default 'POR_CONFIRMAR' check (cuota_rule in ('POR_CONFIRMAR', 'MONTO_ES_TOTAL', 'MONTO_ES_CUOTA'));
alter table public.com_settings add column source_backup_enabled boolean not null default false;   -- APAGADO hasta autorización
alter table public.com_settings add column source_max_mb int not null default 15 check (source_max_mb between 1 and 50);
alter table public.com_settings add column source_retention_days int not null default 1825 check (source_retention_days >= 365);   -- informativa: NO hay borrado automático

-- ---------- 2) parte y grupo por comprobante (WORK-K02) ----------
alter table public.com_sc_documents add column part_key text;
alter table public.com_sc_documents add column comp_group text generated always as (cuit || '|' || comp_n) stored;
create index com_sc_documents_group_idx on public.com_sc_documents(comp_group);
create or replace function public.trg_com_doc_part() returns trigger language plpgsql as $$ begin new.part_key := split_part(new.doc_key, '|', 3); return new; end; $$;
create trigger com_doc_part before insert or update of doc_key on public.com_sc_documents for each row execute function public.trg_com_doc_part();
update public.com_sc_documents set part_key = split_part(doc_key, '|', 3) where part_key is null;

-- venta neta de UN mes para un CUIT, POR COMPROBANTE y con la regla de cuotas vigente; 'pend' = comprobantes en cuotas NO asignables
create or replace function public._com_month_sales(p_cuit text, p_month date) returns jsonb language sql stable security definer set search_path = public as $$
  with s as (select cuota_rule r from public.com_settings where id = 'DEFAULT'),
  d as (select comp_group g, class, doc_date, amount from public.com_sc_documents where cuit = p_cuit and status = 'OK' and class in ('VENTA', 'NOTA_CREDITO')),
  gr as (select g, class, min(doc_date) gd, count(*) n, min(amount) mn, max(amount) mx, sum(amount) tot from d group by g, class)
  select jsonb_build_object(
    'amount', coalesce(sum(case
        when gr.n = 1 or (s.r = 'MONTO_ES_TOTAL' and gr.mn = gr.mx) then case gr.class when 'VENTA' then gr.mx else -abs(gr.mx) end   -- una vez por comprobante
        when s.r = 'MONTO_ES_CUOTA' then case gr.class when 'VENTA' then gr.tot else -abs(gr.tot) end                                  -- partes con importe propio
        else 0 end), 0),                                                                                                                  -- POR_CONFIRMAR: fuera del KPI
    'pend', count(*) filter (where gr.n > 1 and not (s.r = 'MONTO_ES_TOTAL' and gr.mn = gr.mx) and s.r <> 'MONTO_ES_CUOTA'),
    'comprobantes', count(*))
  from gr, s where date_trunc('month', gr.gd) = p_month;
$$;

-- ---------- 3) respaldo privado de ORIGINALES (A-09) ----------
create table public.com_source_files (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('SC', 'CC')), version int not null,
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'), size_bytes bigint not null check (size_bytes > 0),
  original_name text, mime text, storage_path text not null check (storage_path ~ '^(SC|CC)/[0-9a-f]{64}\.(xlsx|xls|csv)$'),
  uploaded_by uuid not null references public.profiles(id), uploaded_at timestamptz not null default now(),
  unique (kind, sha256), unique (kind, version));
create or replace function public.trg_com_source_immutable() returns trigger language plpgsql as $$
begin raise exception 'IMMUTABLE: los originales y sus versiones no se modifican ni se borran' using errcode = '42501'; end; $$;
create trigger com_source_files_immutable before update or delete on public.com_source_files for each row execute function public.trg_com_source_immutable();
alter table public.com_ingests add column source_file_id uuid references public.com_source_files(id);

-- registra el ORIGINAL ya subido al almacenamiento privado (idempotente por contenido; nueva versión si cambia)
create or replace function public.com_register_source_file(p_kind text, p_sha256 text, p_size bigint, p_name text, p_mime text, p_path text) returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.com_settings; f public.com_source_files; v int; ok boolean;
begin
  if public._com_active() is null or not public.user_has_perm(auth.uid(), 'com.sources.upload') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into s from public.com_settings where id = 'DEFAULT';
  if not s.source_backup_enabled then raise exception 'BACKUP_DISABLED: el respaldo de originales no está habilitado' using errcode = '23514'; end if;
  if p_kind not in ('SC', 'CC') or p_sha256 !~ '^[0-9a-f]{64}$' or p_path is distinct from (p_kind || '/' || p_sha256 || '.' || lower(regexp_replace(coalesce(p_name, ''), '^.*\.', ''))) or p_path !~ '\.(xlsx|xls|csv)$' then
    raise exception 'BAD_SOURCE: tipo, hash o ruta inválidos' using errcode = '23514'; end if;
  if p_size is null or p_size <= 0 or p_size > s.source_max_mb::bigint * 1048576 then raise exception 'FILE_TOO_LARGE: supera % MB', s.source_max_mb using errcode = '23514'; end if;
  if to_regclass('storage.objects') is not null then   -- el ORIGINAL debe estar realmente en el almacenamiento privado
    execute 'select exists (select 1 from storage.objects where bucket_id = ''com-sources'' and name = $1)' into ok using p_path;
    if not ok then raise exception 'SOURCE_NOT_UPLOADED: el original todavía no está en el almacenamiento' using errcode = '23514'; end if;
  end if;
  perform pg_advisory_xact_lock(hashtext('com_source_files:' || p_kind));
  select * into f from public.com_source_files where kind = p_kind and sha256 = p_sha256;
  if found then return jsonb_build_object('id', f.id, 'version', f.version, 'repeated', true); end if;
  select coalesce(max(version), 0) + 1 into v from public.com_source_files where kind = p_kind;
  insert into public.com_source_files(kind, version, sha256, size_bytes, original_name, mime, storage_path, uploaded_by) values (p_kind, v, p_sha256, p_size, left(p_name, 200), left(p_mime, 120), p_path, auth.uid()) returning * into f;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_SOURCE_FILE', 'com_source_files', f.id::text, jsonb_build_object('kind', p_kind, 'version', v, 'sha256', p_sha256, 'size', p_size));
  return jsonb_build_object('id', f.id, 'version', f.version, 'repeated', false);
end; $$;
-- vínculo carga → original. Con el respaldo ACTIVO, una carga SIN su original confirmado se RECHAZA (el cliente la conserva y reintenta)
create or replace function public._com_link_source(p_ingest bigint, p_kind text, p_meta jsonb) returns void language plpgsql security definer set search_path = public as $$
declare fid uuid := nullif(p_meta->>'source_file_id', '')::uuid;
begin
  if not (select source_backup_enabled from public.com_settings where id = 'DEFAULT') then
    if fid is not null and exists (select 1 from public.com_source_files where id = fid and kind = p_kind) then update public.com_ingests set source_file_id = fid where id = p_ingest; end if;
    return;
  end if;
  if fid is null then raise exception 'SOURCE_REQUIRED: falta el original de la carga (respaldo activo)' using errcode = '23514'; end if;
  if not exists (select 1 from public.com_source_files where id = fid and kind = p_kind) then raise exception 'BAD_SOURCE: el original no corresponde a esta carga' using errcode = '23514'; end if;
  update public.com_ingests set source_file_id = fid where id = p_ingest;
end; $$;
-- fuentes usadas por el KPI de un cliente (para la foto de cada solicitud): carga, archivo, versión y hash
create or replace function public._com_kpi_sources(p_cuit text, p_from date, p_to date) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(distinct jsonb_build_object('ingest_id', i.id, 'kind', i.kind, 'loaded_at', i.loaded_at, 'content_hash', i.content_hash,
           'file_id', f.id, 'file_version', f.version, 'file_sha256', f.sha256)), '[]'::jsonb)
  from public.com_sc_documents d join public.com_ingests i on i.id = d.first_ingest_id left join public.com_source_files f on f.id = i.source_file_id
  where d.cuit = p_cuit and d.doc_date between p_from and p_to;
$$;

-- ===== funciones corregidas por Work, con reemplazos mínimos verificados =====
create or replace function public._com_kpi_raw(p_client uuid, p_at timestamptz default now()) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.com_settings; c public.com_clients; m0 date; m1 date; months jsonb; cov int; tot numeric; avg_ numeric; excl int; last_sc timestamptz; cpend int := 0;
begin
  select * into s from public.com_settings where id = 'DEFAULT'; select * into c from public.com_clients where id = p_client;
  if not found then return jsonb_build_object('status', 'SIN_CLIENTE'); end if;
  select max(at) into last_sc from public.com_ingests where kind = 'SC' and status = 'OK';
  m1 := (date_trunc('month', (p_at at time zone 'America/Argentina/Mendoza')) - interval '1 month')::date; m0 := (m1 - make_interval(months => s.kpi_months - 1))::date;
  if c.cuit is null then return jsonb_build_object('status', 'SIN_HISTORIAL', 'detail', 'El cliente no tiene CUIT/CUIL válido en el padrón: no se puede cruzar con las cargas de Depósito.', 'months_cfg', s.kpi_months, 'last_update', last_sc); end if;
  if last_sc is null then return jsonb_build_object('status', 'PENDIENTE_IMPORTACION', 'detail', 'Datos insuficientes / pendiente de importación de «Saldo comprobante».', 'months_cfg', s.kpi_months); end if;
  select jsonb_agg(jsonb_build_object('month', g.m, 'covered', public._com_month_covered(g.m::date),
           'amount', case when public._com_month_covered(g.m::date) then ((public._com_month_sales(c.cuit, g.m::date))->>'amount')::numeric end) order by g.m)
    into months from generate_series(m0, m1, interval '1 month') g(m);
  select count(*) filter (where (x->>'covered')::boolean), coalesce(sum((x->>'amount')::numeric) filter (where (x->>'covered')::boolean), 0) into cov, tot from jsonb_array_elements(months) x;
  select count(*) into excl from public.com_sc_documents where cuit = c.cuit and status <> 'OK' and doc_date between m0 and (m1 + interval '1 month' - interval '1 day')::date;
  -- WORK-K02: comprobantes en CUOTAS cuyo importe no se puede asignar con la regla vigente → excluidos y CONTADOS como pendientes
  select coalesce(sum(((public._com_month_sales(c.cuit, gg::date))->>'pend')::int), 0) into cpend from generate_series(m0, m1, interval '1 month') gg;
  excl := excl + cpend;
  if cov < s.kpi_months and not (s.kpi_partial_rule = 'PROMEDIO_MESES_CUBIERTOS' and cov > 0) then
    return jsonb_build_object('status', 'SIN_HISTORIAL', 'detail', 'SIN HISTORIAL SUFICIENTE · ' || cov || ' de ' || s.kpi_months || ' meses con cargas', 'coverage', cov, 'months', months, 'months_cfg', s.kpi_months, 'excluded_docs', excl, 'last_update', last_sc); end if;
  if tot <= 0 then return jsonb_build_object('status', 'SIN_HISTORIAL', 'detail', 'Sin compras registradas en los comprobantes disponibles.', 'coverage', cov, 'months', months, 'months_cfg', s.kpi_months, 'excluded_docs', excl, 'last_update', last_sc); end if;
  avg_ := round(tot / cov, 2);
  return jsonb_build_object('status', case when cov < s.kpi_months then 'PARCIAL' else 'OK' end, 'coverage', cov, 'months', months, 'months_cfg', s.kpi_months, 'average', avg_, 'floor_pct', s.floor_pct, 'ceiling_pct', s.ceiling_pct,
    'floor', round(avg_ * s.floor_pct / 100, 2), 'ceiling', round(avg_ * s.ceiling_pct / 100, 2), 'excluded_docs', excl, 'last_update', last_sc, 'computed_at', p_at,
    'source', 'Historial automático de «Saldo comprobante» (cargas diarias de Depósito)', 'scope', 'Comprobantes disponibles en «Saldo comprobante»',
    'cuota_rule', s.cuota_rule, 'cuotas_por_confirmar', cpend, 'sources', public._com_kpi_sources(c.cuit, m0, (m1 + interval '1 month' - interval '1 day')::date));
end; $$;

create or replace function public.com_ingest(p_kind text, p_meta jsonb, p_rows jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare g public.com_ingests; b int := coalesce((p_meta->>'batch')::int, 1); nb int := greatest(1, coalesce((p_meta->>'batches')::int, 1)); r jsonb; cu text; k text; d public.com_sc_documents;
  amt numeric; pre text; cls text; dt date; st jsonb := '{}'; c public.com_clients; nm text;
  add_ int := 0; seen int := 0; conf int := 0; skip_cuit int := 0; skip_san int := 0; unk int := 0;
begin
  if public._com_active() is null or not public.user_has_perm(auth.uid(), 'com.sources.upload') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_kind not in ('SC', 'CC') or coalesce(p_meta->>'hash', '') = '' then raise exception 'BAD_INGEST' using errcode = '23514'; end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) > 2000 or b < 1 or b > nb or nb > 10000 then raise exception 'BAD_BATCH' using errcode='23514'; end if;
  if p_meta->>'owner_id' is not null and p_meta->>'owner_id' <> auth.uid()::text then raise exception 'FORBIDDEN_OWNER' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('com-ingest|'||p_kind||'|'||(p_meta->>'hash')||'|'||coalesce(p_meta->>'loaded_at','')||'|'||auth.uid()::text,0));
  select * into g from public.com_ingests where kind = p_kind and content_hash = p_meta->>'hash' and loaded_at is not distinct from (p_meta->>'loaded_at')::timestamptz and by_user=auth.uid() for update;
  if found and g.status='ERROR' and g.batches_done=0 then update public.com_ingests set batches=nb where id=g.id; g.batches:=nb; end if;
  if found and g.batches <> nb then raise exception 'BAD_BATCH_METADATA' using errcode='23514'; end if;
  if not found then
    insert into public.com_ingests(kind, content_hash, file_name, loaded_at, by_user, batches) values (p_kind, p_meta->>'hash', left(p_meta->>'file_name', 200), (p_meta->>'loaded_at')::timestamptz, auth.uid(), nb) returning * into g;
    perform public._com_link_source(g.id, p_kind, p_meta);   -- respaldo privado: con el respaldo ACTIVO exige el archivo original ya recibido
  end if;
  if exists (select 1 from public.com_ingest_batches where ingest_id = g.id and batch = b) then
    return jsonb_build_object('ingest_id', g.id, 'batch', b, 'repeated', true, 'status', g.status); end if;   -- reintento o misma carga: no duplica
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    cu := regexp_replace(coalesce(r->>'cuit', ''), '\D', '', 'g'); nm := nullif(btrim(r->>'c'), '');
    if p_kind = 'CC' then
      if not public._cuit_valid(cu) then skip_cuit := skip_cuit + 1; continue; end if;
      insert into public.com_cc_balances(ingest_id, cuit, client_name, saldo, localidad) values (g.id, cu, nm, (r->>'saldo')::numeric, nullif(btrim(r->>'localidad'), ''))
        on conflict (ingest_id, cuit) do update set saldo = excluded.saldo;
      add_ := add_ + 1; continue;
    end if;
    if coalesce((r->>'san')::boolean, false) then skip_san := skip_san + 1; continue; end if;   -- «Saldo Anterior»: NO es venta
    if not public._cuit_valid(cu) then skip_cuit := skip_cuit + 1; continue; end if;            -- sin CUIT verificable: no se cruza
    pre := upper(left(regexp_replace(coalesce(r->>'comp', ''), '^\s+', ''), 3)); select class into cls from public.com_comp_types where prefix = pre;
    amt := coalesce((r->>'m')::numeric, (r->>'ve')::numeric); dt := nullif(r->>'d', '')::date;
    -- WORK-K02: la PARTE se identifica como en el Constructor (financing.js partKey): número de cuota y, si no hay, vencimiento
    k := cu || '|' || coalesce(nullif(r->>'n', ''), upper(regexp_replace(coalesce(r->>'comp', ''), '[\s\[\]\-_.()]', '', 'g'))) || '|'
      || coalesce(nullif(btrim(r->>'q'), ''), case when nullif(btrim(r->>'due'), '') is not null then 'V' || btrim(r->>'due') end, '-');
    perform pg_advisory_xact_lock(hashtextextended('com-doc|'||k,0));
    select * into d from public.com_sc_documents where doc_key = k for update;
    if not found then
      insert into public.com_sc_documents(doc_key, cuit, client_name, comp, comp_n, prefix, class, cuota, doc_date, due, amount, last_saldo, first_ingest_id, last_ingest_id, status)
      values (k, cu, nm, left(r->>'comp', 80), split_part(k, '|', 2), pre, cls, nullif(btrim(r->>'q'), ''), dt, nullif(r->>'due', '')::date, amt, (r->>'s')::numeric, g.id, g.id,
        case when cls is null then 'SIN_CLASIFICAR' when amt is null then 'SIN_IMPORTE' when dt is null then 'SIN_FECHA' else 'OK' end);
      add_ := add_ + 1;
      if cls is null then unk := unk + 1; insert into public.com_reconciliation_issues(ingest_id, cuit, doc_key, kind, detail) values (g.id, cu, k, 'TIPO_SIN_CLASIFICAR', jsonb_build_object('prefijo', pre, 'comprobante', r->>'comp')) on conflict do nothing; end if;
    else
      seen := seen + 1;
      if d.amount is distinct from amt or d.doc_date is distinct from dt then   -- el MISMO comprobante con otro importe/fecha: a conciliación, fuera del KPI
        conf := conf + 1;
        update public.com_sc_documents set status = 'CONFLICTO', conflict = coalesce(conflict, '[]'::jsonb) || jsonb_build_array(jsonb_build_object('ingest', g.id, 'importe', amt, 'fecha', dt)),
          last_ingest_id = g.id, last_seen_at = now(), seen_count = seen_count + 1, last_saldo = (r->>'s')::numeric where doc_key = k;
        insert into public.com_reconciliation_issues(ingest_id, cuit, doc_key, kind, detail) values (g.id, cu, k, 'IMPORTE_CAMBIADO', jsonb_build_object('antes', jsonb_build_object('importe', d.amount, 'fecha', d.doc_date), 'ahora', jsonb_build_object('importe', amt, 'fecha', dt))) on conflict do nothing;
      else
        update public.com_sc_documents set last_ingest_id = g.id, last_seen_at = now(), seen_count = seen_count + 1, last_saldo = (r->>'s')::numeric where doc_key = k;
      end if;
    end if;
  end loop;
  -- conciliación con el padrón (una vez por CUIT y carga; sin sobrescribir)
  if p_kind = 'SC' then
    for r in select jsonb_build_object('cuit', cuit, 'name', max(client_name)) from public.com_sc_documents where last_ingest_id = g.id group by cuit loop
      select * into c from public.com_clients where cuit = r->>'cuit' and status <> 'BAJA' order by status limit 1;
      if not found then insert into public.com_reconciliation_issues(ingest_id, cuit, kind, detail) values (g.id, r->>'cuit', 'CUIT_NO_EN_PADRON', jsonb_build_object('nombre', r->>'name')) on conflict do nothing;
      elsif c.status = 'REVISION' then insert into public.com_reconciliation_issues(ingest_id, cuit, kind, detail, client_id) values (g.id, r->>'cuit', 'CUIT_EN_REVISION', jsonb_build_object('nombre', r->>'name'), c.id) on conflict do nothing;
      elsif coalesce(r->>'name', '') <> '' and public._com_norm(r->>'name') not in (public._com_norm(c.razon_social), public._com_norm(c.nombre)) then
        insert into public.com_reconciliation_issues(ingest_id, cuit, kind, detail, client_id) values (g.id, r->>'cuit', 'NOMBRE_DISTINTO', jsonb_build_object('en_carga', r->>'name', 'en_padron', c.razon_social), c.id) on conflict do nothing; end if;
    end loop;
  end if;
  insert into public.com_ingest_batches(ingest_id, batch, rows) values (g.id, b, jsonb_array_length(coalesce(p_rows, '[]')));
  update public.com_ingests set batches_done = batches_done + 1, rows = rows + jsonb_array_length(coalesce(p_rows, '[]')),
    stats = jsonb_build_object('nuevos', coalesce((stats->>'nuevos')::int, 0) + add_, 'repetidos', coalesce((stats->>'repetidos')::int, 0) + seen, 'conflictos', coalesce((stats->>'conflictos')::int, 0) + conf,
      'sin_cuit', coalesce((stats->>'sin_cuit')::int, 0) + skip_cuit, 'saldo_anterior', coalesce((stats->>'saldo_anterior')::int, 0) + skip_san, 'sin_clasificar', coalesce((stats->>'sin_clasificar')::int, 0) + unk),
    status = case when batches_done + 1 >= batches then 'OK' else 'EN_PROCESO' end,
    date_min = least(date_min, (select min(doc_date) from public.com_sc_documents where last_ingest_id = g.id)), date_max = greatest(date_max, (select max(doc_date) from public.com_sc_documents where last_ingest_id = g.id))
   where id = g.id returning * into g;
  return jsonb_build_object('ingest_id', g.id, 'batch', b, 'status', g.status, 'repeated', false, 'stats', g.stats);
end; $$;

create or replace function public.com_set_settings(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.com_settings;
begin
  if not public._is_general_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.com_settings set kpi_months = coalesce((p->>'kpi_months')::int, kpi_months), floor_pct = coalesce((p->>'floor_pct')::numeric, floor_pct), ceiling_pct = coalesce((p->>'ceiling_pct')::numeric, ceiling_pct),
    fin_max_days = coalesce((p->>'fin_max_days')::int, fin_max_days), cheq_max_days = coalesce((p->>'cheq_max_days')::int, cheq_max_days),
    coverage_gap_days = coalesce((p->>'coverage_gap_days')::int, coverage_gap_days), kpi_partial_rule = coalesce(p->>'kpi_partial_rule', kpi_partial_rule),
    kpi_source_verified = coalesce((p->>'kpi_source_verified')::boolean, kpi_source_verified), cuota_rule = coalesce(p->>'cuota_rule', cuota_rule),
    source_backup_enabled = coalesce((p->>'source_backup_enabled')::boolean, source_backup_enabled), source_max_mb = coalesce((p->>'source_max_mb')::int, source_max_mb),
    updated_by = auth.uid(), updated_at = now() where id = 'DEFAULT' returning * into s;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_SETTINGS', 'com_settings', 'DEFAULT', to_jsonb(s));
  return to_jsonb(s);
end; $$;

-- respuesta MÍNIMA para las políticas del almacenamiento (se evalúan con los permisos de quien sube): ¿puede subir originales ahora?
create or replace function public._com_can_upload_source() returns boolean language sql stable security definer set search_path = public as $$
  select (public._com_active()).id is not null and public.user_has_perm(auth.uid(), 'com.sources.upload')   -- por id: «fila IS NOT NULL» exige TODAS las columnas no nulas
     and coalesce((select source_backup_enabled from public.com_settings where id = 'DEFAULT'), false);
$$;
revoke all on function public._com_can_upload_source() from public, anon; grant execute on function public._com_can_upload_source() to authenticated;

-- ---------- 4) almacenamiento PRIVADO (si existe el esquema de Storage): sin URL pública; sin modificar ni borrar ----------
DO $st$ BEGIN
  IF to_regclass('storage.buckets') IS NOT NULL THEN
    INSERT INTO storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
      VALUES ('com-sources', 'com-sources', false, 15728640, ARRAY['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'application/vnd.ms-excel', 'text/csv', 'application/octet-stream'])
      ON CONFLICT (id) DO UPDATE SET public = false;
    EXECUTE 'drop policy if exists com_sources_insert on storage.objects';
    EXECUTE 'drop policy if exists com_sources_select on storage.objects';
    EXECUTE $p$create policy com_sources_insert on storage.objects for insert to authenticated with check (bucket_id = 'com-sources'
      and public._com_can_upload_source() and name ~ '^(SC|CC)/[0-9a-f]{64}\.(xlsx|xls|csv)$')$p$;
    EXECUTE $p$create policy com_sources_select on storage.objects for select to authenticated using (bucket_id = 'com-sources' and public._is_general_admin())$p$;
    -- sin políticas de UPDATE ni DELETE: nadie modifica ni borra originales
  END IF;
END $st$;

-- ---------- 5) privilegios ----------
do $$ declare f text; begin
  execute 'revoke all on table public.com_source_files from anon, authenticated'; execute 'alter table public.com_source_files enable row level security';
  foreach f in array array['com_register_source_file(text,text,bigint,text,text,text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon'; execute 'grant execute on function public.' || f || ' to authenticated'; end loop;
  foreach f in array array['_com_month_sales(text,date)', '_com_kpi_sources(text,date,date)', '_com_link_source(bigint,text,jsonb)', 'trg_com_doc_part()', 'trg_com_source_immutable()'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated'; end loop;
end $$;
DO $post$ BEGIN
  IF (SELECT source_backup_enabled FROM public.com_settings WHERE id = 'DEFAULT') THEN RAISE EXCEPTION 'EL_RESPALDO_DEBE_QUEDAR_APAGADO'; END IF;
  IF (SELECT cuota_rule FROM public.com_settings WHERE id = 'DEFAULT') <> 'POR_CONFIRMAR' THEN RAISE EXCEPTION 'LA_REGLA_DE_CUOTAS_DEBE_QUEDAR_POR_CONFIRMAR'; END IF;
END $post$;
COMMIT;
