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
