-- =====================================================================================================================
-- PROPUESTA · MÓDULO AUTORIZACIONES COMERCIALES · NO APLICADA. Independiente de V4.29: se aplica sobre la V4.28 publicada (1925c44).
-- Todo con prefijo com_. Tablas con RLS SIN políticas de escritura: se opera SOLO por funciones (validación en el servidor).
-- Reutiliza: roles / permissions / role_permissions / user_permission_overrides / user_has_perm, _is_general_admin (rol REAL ADMIN
-- y ACTIVO), _cuit_valid, profiles, audit_log. NO modifica funciones existentes de OK Despacho.
--  · Padrón comercial: identificador interno + clave estable del sistema de gestión («ID»); documento vinculado; duplicados en REVISIÓN.
--  · Solicitudes: financiación propia (cuotas SEMANALES, último vencimiento ≤ 30 días) y e-cheq; decisión ATÓMICA (una por ciclo).
--  · Suplencia: un Administrador General ACTIVO resuelve lo asignado a otro aprobador; se conserva el aprobador ORIGINAL.
--  · KPI orientativo SOLO desde «Saldo comprobante» CONFIRMADO (nunca del «Saldo» del padrón); snapshot por solicitud.
--  · Avisos internos y correos PREPARADOS (sin envío); trazabilidad de Despacho sin datos financieros fuera de su permiso.
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regclass('public.roles') IS NULL OR to_regprocedure('public.user_has_perm(uuid,text)') IS NULL OR to_regprocedure('public._is_general_admin()') IS NULL
     OR to_regprocedure('public._cuit_valid(text)') IS NULL OR to_regclass('public.audit_log') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE. No se modificó nada.'; END IF;
  IF to_regclass('public.com_requests') IS NOT NULL THEN RAISE EXCEPTION 'YA_APLICADA. No se modificó nada.'; END IF;
END $guard$;

-- ---------- 1) rol y permisos ----------
insert into public.roles(code, name) values ('COMERCIAL', 'Comercial') on conflict (code) do nothing;
insert into public.permissions(code) values ('com.request'), ('com.approve'), ('com.track'), ('com.sources.upload') on conflict do nothing;
insert into public.role_permissions(role_code, permission_code)
select v.r, v.p from (values ('COMERCIAL', 'com.request'), ('ADMIN', 'com.track'), ('ADMIN', 'com.sources.upload'), ('ADMIN', 'com.approve'),
  ('DESPACHO', 'com.track'), ('SUPERVISOR_DESPACHO', 'com.track'), ('OPERARIO_DEPOSITO', 'com.track'), ('OPERARIO_DEPOSITO', 'com.sources.upload')) v(r, p)
where exists (select 1 from public.roles where code = v.r)   -- solo roles existentes en la base
on conflict do nothing;
-- «com.approve» para un aprobador que no es ADMIN (p. ej. Gerencia/Tesorería) se otorga por usuario (user_permission_overrides).

create or replace function public._com_active(p_user uuid default auth.uid()) returns public.profiles language sql stable security definer set search_path = public as $$
  select * from public.profiles where id = p_user and status = 'ACTIVO';
$$;

-- ---------- 2) configuración (solo Administrador General) ----------
create table public.com_settings (
  id text primary key default 'DEFAULT' check (id = 'DEFAULT'),
  kpi_months int not null default 3 check (kpi_months in (1, 2, 3, 6)),
  floor_pct numeric not null default 125 check (floor_pct between 50 and 500),
  ceiling_pct numeric not null default 150 check (ceiling_pct between 50 and 500),
  fin_max_days int not null default 30 check (fin_max_days between 7 and 90),
  cheq_max_days int not null default 30 check (cheq_max_days between 1 and 180),
  email_enabled boolean not null default false,   -- correos PREPARADOS; sin envío hasta autorización
  coverage_gap_days int not null default 4 check (coverage_gap_days between 1 and 15),   -- hueco máximo entre cargas diarias para dar un mes por cubierto
  kpi_partial_rule text not null default 'NO_CALCULAR' check (kpi_partial_rule in ('NO_CALCULAR', 'PROMEDIO_MESES_CUBIERTOS')),
  kpi_source_verified boolean not null default false,   -- hasta verificar si «Saldo comprobante» trae TODAS las operaciones: RECOMENDACIÓN PROVISORIA
  updated_by uuid, updated_at timestamptz not null default now(),
  check (ceiling_pct >= floor_pct));
insert into public.com_settings(id) values ('DEFAULT');
-- canal → aprobador PRINCIPAL (por ID de usuario, nunca por nombre)
create table public.com_routing (
  channel_key text primary key check (channel_key in ('SUCURSAL:MONTECASEROS', 'SUCURSAL:SAN_JUAN', 'CARTERA')),
  approver_user_id uuid references public.profiles(id), updated_by uuid, updated_at timestamptz not null default now());
insert into public.com_routing(channel_key) values ('SUCURSAL:MONTECASEROS'), ('SUCURSAL:SAN_JUAN'), ('CARTERA');
-- asignación de cada usuario COMERCIAL (la define el Administrador General; el vendedor no elige aprobador)
create table public.com_user_assignments (
  user_id uuid primary key references public.profiles(id),
  channel text not null check (channel in ('SUCURSAL', 'CARTERA')),
  branch text check (branch in ('MONTECASEROS', 'SAN_JUAN')),
  cartera_label text,
  updated_by uuid, updated_at timestamptz not null default now(),
  check ((channel = 'SUCURSAL' and branch is not null) or (channel = 'CARTERA' and branch is null)));

-- ---------- 3) PADRÓN COMERCIAL ----------
create table public.com_client_imports (
  id bigint generated always as identity primary key, at timestamptz not null default now(), by_user uuid not null,
  file_name text, file_sha256 text, counts jsonb not null default '{}', rejected jsonb not null default '[]');
create table public.com_clients (
  id uuid primary key default gen_random_uuid(),
  erp_id text not null unique,                                  -- «ID» del sistema de gestión: identidad estable entre importaciones
  razon_social text not null, nombre text, cond_fiscal text,
  doc_type text not null check (doc_type in ('CUIT', 'CUIL', 'DNI', 'OTRO', 'SIN_DOC')),
  doc_number text,                                              -- tal cual (solo dígitos para CUIT/CUIL/DNI); NUNCA se inventa un CUIT
  doc_valid boolean not null default false,
  cuit text,                                                    -- SOLO si el documento es CUIT/CUIL válido
  localidad text, provincia text, email text, vendedor text, zona text, categoria text, cod_interno text,
  status text not null default 'ACTIVO' check (status in ('ACTIVO', 'REVISION', 'BAJA')),
  review_reasons text[] not null default '{}',
  search_text text not null,                                    -- normalizado (sin acentos, mayúsculas) para la búsqueda
  first_import_id bigint references public.com_client_imports(id), last_import_id bigint references public.com_client_imports(id),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create index com_clients_cuit_idx on public.com_clients(cuit);
create index com_clients_doc_idx on public.com_clients(doc_number);
create index com_clients_search_idx on public.com_clients(search_text text_pattern_ops);
create table public.com_client_changes (                        -- historial: cada cambio de una reimportación
  id bigint generated always as identity primary key, client_id uuid not null references public.com_clients(id), import_id bigint not null references public.com_client_imports(id),
  before jsonb not null, after jsonb not null, at timestamptz not null default now());

create or replace function public._com_norm(p text) returns text language sql immutable as $$
  select btrim(regexp_replace(upper(translate(coalesce(p, ''), 'áéíóúüñÁÉÍÓÚÜÑàèìòùÀÈÌÒÙ', 'aeiouunAEIOUUNaeiouAEIOU')), '[^A-Z0-9]+', ' ', 'g'));
$$;
-- revisión del padrón: CUIT/CUIL repetido en clientes DISTINTOS, documento genérico o inválido → no seleccionable
create or replace function public._com_recompute_reviews() returns void language plpgsql security definer set search_path = public as $$
begin
  update public.com_clients c set review_reasons = r.reasons, status = case when c.status = 'BAJA' then 'BAJA' when cardinality(r.reasons) > 0 then 'REVISION' else 'ACTIVO' end, updated_at = now()
  from (select c2.id, array_remove(array[
      case when c2.cuit is not null and (select count(*) from public.com_clients x where x.cuit = c2.cuit and x.status <> 'BAJA') > 1 then 'CUIT DUPLICADO EN EL PADRÓN' end,
      case when c2.doc_type = 'DNI' and c2.doc_number ~ '^(\d)\1{6,7}$' then 'DOCUMENTO GENÉRICO (p. ej. 99999999)' end,
      case when c2.doc_type = 'DNI' and c2.doc_number is not null and c2.doc_number !~ '^\d{7,8}$' then 'DNI CON FORMATO INVÁLIDO' end,
      case when c2.doc_type in ('CUIT', 'CUIL') and not c2.doc_valid then c2.doc_type || ' INVÁLIDO' end,
      case when c2.doc_type = 'SIN_DOC' then 'SIN DOCUMENTO' end], null) reasons
    from public.com_clients c2) r
  where r.id = c.id and (c.review_reasons is distinct from r.reasons or c.status <> case when c.status = 'BAJA' then 'BAJA' when cardinality(r.reasons) > 0 then 'REVISION' else 'ACTIVO' end);
end; $$;

-- importación (Administrador General): filas ya leídas del Excel en el navegador; el SERVIDOR valida y decide. Sin duplicar; con historial.
create or replace function public.com_import_clients(p_file_name text, p_sha256 text, p_rows jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare imp bigint; r jsonb; t text; n text; v boolean; cu text; cur public.com_clients; ins int := 0; upd int := 0; same int := 0; rej jsonb := '[]'; aft jsonb; bef jsonb;
begin
  if not public._is_general_admin() then raise exception 'FORBIDDEN: solo el Administrador General importa el padrón' using errcode = '42501'; end if;
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

-- búsqueda RÁPIDA y paginada en el SERVIDOR (nunca se descarga el padrón): nombre, razón social, CUIT o documento
create or replace function public.com_search_clients(p_q text, p_limit int default 12) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare q text := public._com_norm(p_q); d text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
begin
  if not (public.user_has_perm(auth.uid(), 'com.request') or public.user_has_perm(auth.uid(), 'com.approve') or public.user_has_perm(auth.uid(), 'com.track') or public._is_general_admin()) then
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

-- ---------- 4) INGESTA AUTOMÁTICA de las cargas DIARIAS de Depósito (Constructor) → historial financiero ----------
-- El Operario sigue cargando «Saldo comprobante» y «Saldo cuenta corriente» en el Constructor COMO SIEMPRE. Tras aplicar la carga
-- (válida), el Constructor entrega los registros YA LEÍDOS a estas funciones, en segundo plano y sin bloquear nada.
-- Un COMPROBANTE se cuenta UNA SOLA VEZ (CUIT + comprobante normalizado + cuota) aunque aparezca en cargas de muchos días.
create table public.com_comp_types (                              -- clasificación configurable por prefijo (Normalizer.compType del Constructor)
  prefix text primary key check (prefix ~ '^[A-Z]{3}$'),
  class text not null check (class in ('VENTA', 'NOTA_CREDITO', 'PAGO', 'ANULACION', 'EXCLUIDO')),
  updated_by uuid, updated_at timestamptz not null default now());
insert into public.com_comp_types(prefix, class) values ('FAC', 'VENTA'), ('NDP', 'VENTA'), ('NOC', 'NOTA_CREDITO'), ('NCR', 'NOTA_CREDITO'), ('REC', 'PAGO'), ('RBO', 'PAGO'), ('ANU', 'ANULACION');
create table public.com_ingests (
  id bigint generated always as identity primary key, kind text not null check (kind in ('SC', 'CC')),
  content_hash text not null, file_name text, loaded_at timestamptz, by_user uuid not null, at timestamptz not null default now(),
  batches int not null default 1, batches_done int not null default 0, rows int not null default 0, stats jsonb not null default '{}',
  status text not null default 'EN_PROCESO' check (status in ('EN_PROCESO', 'OK', 'ERROR')), error text, date_min date, date_max date,
  unique nulls not distinct (kind, content_hash, loaded_at, by_user));
create table public.com_ingest_batches (ingest_id bigint not null references public.com_ingests(id), batch int not null, rows int not null, at timestamptz not null default now(), primary key (ingest_id, batch));
create table public.com_sc_documents (
  doc_key text primary key,                                       -- CUIT | comprobante normalizado | cuota
  cuit text not null, client_name text, comp text not null, comp_n text not null, prefix text, class text, cuota text,
  doc_date date, due date, amount numeric,                        -- importe ORIGINAL del comprobante (nunca el saldo)
  last_saldo numeric, first_ingest_id bigint not null references public.com_ingests(id), last_ingest_id bigint not null references public.com_ingests(id),
  first_seen_at timestamptz not null default now(), last_seen_at timestamptz not null default now(), seen_count int not null default 1,
  status text not null default 'OK' check (status in ('OK', 'CONFLICTO', 'SIN_CLASIFICAR', 'SIN_IMPORTE', 'SIN_FECHA')), conflict jsonb);
create index com_sc_documents_cuit_idx on public.com_sc_documents(cuit, doc_date);
create table public.com_cc_balances (                             -- foto de la cuenta corriente POR CARGA (complementaria; nunca es venta)
  ingest_id bigint not null references public.com_ingests(id), cuit text not null, client_name text, saldo numeric, localidad text, primary key (ingest_id, cuit));
create table public.com_reconciliation_issues (                  -- diferencias carga ↔ padrón y comprobantes dudosos: se MUESTRAN, nunca se sobrescribe nada
  id bigint generated always as identity primary key, ingest_id bigint not null references public.com_ingests(id), cuit text, doc_key text,
  kind text not null check (kind in ('CUIT_NO_EN_PADRON', 'NOMBRE_DISTINTO', 'CUIT_EN_REVISION', 'IMPORTE_CAMBIADO', 'TIPO_SIN_CLASIFICAR')),
  detail jsonb, client_id uuid references public.com_clients(id), status text not null default 'ABIERTA' check (status in ('ABIERTA', 'RESUELTA')),
  created_at timestamptz not null default now());
create unique index com_recon_unique on public.com_reconciliation_issues(kind, coalesce(doc_key, ''), coalesce(cuit, '')) where status = 'ABIERTA';

-- lote de una carga (idempotente por contenido y número de lote). Lo llama el Constructor tras aplicar la carga; NUNCA la bloquea.
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
    k := cu || '|' || coalesce(nullif(r->>'n', ''), upper(regexp_replace(coalesce(r->>'comp', ''), '[\s\[\]\-_.()]', '', 'g'))) || '|' || coalesce(nullif(btrim(r->>'q'), ''), '-');
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

create or replace function public.com_ingest_error(p_kind text, p_meta jsonb, p_error text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public._com_active() is null or not public.user_has_perm(auth.uid(), 'com.sources.upload') then return; end if;
  insert into public.com_ingests(kind, content_hash, file_name, loaded_at, by_user, status, error) values (p_kind, coalesce(p_meta->>'hash', 'error-' || gen_random_uuid()), left(p_meta->>'file_name', 200),
    (p_meta->>'loaded_at')::timestamptz, auth.uid(), 'ERROR', left(p_error, 400)) on conflict (kind, content_hash, loaded_at, by_user) do update set error = excluded.error, status = case when com_ingests.status = 'OK' then 'OK' else 'ERROR' end;
end; $$;

-- COBERTURA verificable de un mes: hubo cargas OK de «Saldo comprobante» que lo cubren de punta a punta, sin huecos mayores al tolerado
create or replace function public._com_month_covered(p_month date) returns boolean language sql stable security definer set search_path = public as $$
  with s as (select coverage_gap_days g from public.com_settings where id = 'DEFAULT'),
  i as (select (at at time zone 'America/Argentina/Mendoza')::date d from public.com_ingests where kind = 'SC' and status = 'OK'),
  e as (select p_month a, (p_month + interval '1 month' - interval '1 day')::date z)
  select coalesce((select min(d) <= e.a + s.g and max(d) >= e.z
      and coalesce(max(gap),0) <= s.g
    from (select d, lead(d) over(order by d)-d gap from
      (select distinct d from i where d between e.a-s.g and e.z+s.g) ds) w),false)
    from e,s;
$$;

-- KPI ORIENTATIVO desde el historial automático. Nunca inventa: meses SIN cobertura no se convierten en $0.
create or replace function public._com_kpi_raw(p_client uuid, p_at timestamptz default now()) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.com_settings; c public.com_clients; m0 date; m1 date; months jsonb; cov int; tot numeric; avg_ numeric; excl int; last_sc timestamptz;
begin
  select * into s from public.com_settings where id = 'DEFAULT'; select * into c from public.com_clients where id = p_client;
  if not found then return jsonb_build_object('status', 'SIN_CLIENTE'); end if;
  select max(at) into last_sc from public.com_ingests where kind = 'SC' and status = 'OK';
  m1 := (date_trunc('month', (p_at at time zone 'America/Argentina/Mendoza')) - interval '1 month')::date; m0 := (m1 - make_interval(months => s.kpi_months - 1))::date;
  if c.cuit is null then return jsonb_build_object('status', 'SIN_HISTORIAL', 'detail', 'El cliente no tiene CUIT/CUIL válido en el padrón: no se puede cruzar con las cargas de Depósito.', 'months_cfg', s.kpi_months, 'last_update', last_sc); end if;
  if last_sc is null then return jsonb_build_object('status', 'PENDIENTE_IMPORTACION', 'detail', 'Datos insuficientes / pendiente de importación de «Saldo comprobante».', 'months_cfg', s.kpi_months); end if;
  select jsonb_agg(jsonb_build_object('month', g.m, 'covered', public._com_month_covered(g.m::date),
           'amount', case when public._com_month_covered(g.m::date) then coalesce((select sum(case d.class when 'VENTA' then d.amount when 'NOTA_CREDITO' then -abs(d.amount) else 0 end)
              from public.com_sc_documents d where d.cuit = c.cuit and d.status = 'OK' and d.class in ('VENTA', 'NOTA_CREDITO') and date_trunc('month', d.doc_date) = g.m), 0) end) order by g.m)
    into months from generate_series(m0, m1, interval '1 month') g(m);
  select count(*) filter (where (x->>'covered')::boolean), coalesce(sum((x->>'amount')::numeric) filter (where (x->>'covered')::boolean), 0) into cov, tot from jsonb_array_elements(months) x;
  select count(*) into excl from public.com_sc_documents where cuit = c.cuit and status <> 'OK' and doc_date between m0 and (m1 + interval '1 month' - interval '1 day')::date;
  if cov < s.kpi_months and not (s.kpi_partial_rule = 'PROMEDIO_MESES_CUBIERTOS' and cov > 0) then
    return jsonb_build_object('status', 'SIN_HISTORIAL', 'detail', 'SIN HISTORIAL SUFICIENTE · ' || cov || ' de ' || s.kpi_months || ' meses con cargas', 'coverage', cov, 'months', months, 'months_cfg', s.kpi_months, 'excluded_docs', excl, 'last_update', last_sc); end if;
  if tot <= 0 then return jsonb_build_object('status', 'SIN_HISTORIAL', 'detail', 'Sin compras registradas en los comprobantes disponibles.', 'coverage', cov, 'months', months, 'months_cfg', s.kpi_months, 'excluded_docs', excl, 'last_update', last_sc); end if;
  avg_ := round(tot / cov, 2);
  return jsonb_build_object('status', case when cov < s.kpi_months then 'PARCIAL' else 'OK' end, 'coverage', cov, 'months', months, 'months_cfg', s.kpi_months, 'average', avg_, 'floor_pct', s.floor_pct, 'ceiling_pct', s.ceiling_pct,
    'floor', round(avg_ * s.floor_pct / 100, 2), 'ceiling', round(avg_ * s.ceiling_pct / 100, 2), 'excluded_docs', excl, 'last_update', last_sc, 'computed_at', p_at,
    'source', 'Historial automático de «Saldo comprobante» (cargas diarias de Depósito)', 'scope', 'Comprobantes disponibles en «Saldo comprobante»');
end; $$;

create or replace function public.com_kpi_for_client(p_client uuid, p_at timestamptz default now()) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if (public._com_active()).id is null or not (public._is_general_admin() or public.user_has_perm(auth.uid(),'com.request') or public.user_has_perm(auth.uid(),'com.approve')) then raise exception 'FORBIDDEN' using errcode='42501'; end if;
  if not public._is_general_admin() and not public.user_has_perm(auth.uid(),'com.request') and not exists(select 1 from public.com_requests where client_id=p_client and assigned_approver_id=auth.uid()) then raise exception 'FORBIDDEN_CLIENT' using errcode='42501'; end if;
  return public._com_kpi_raw(p_client,p_at) || (select jsonb_build_object('provisional',not s.kpi_source_verified,'label',case when s.kpi_source_verified then null else 'RECOMENDACIÓN PROVISORIA — BASADA EN COMPROBANTES DISPONIBLES' end) from public.com_settings s where id='DEFAULT');
end; $$;
-- aprobadores posibles (Panel General): ACTIVOS con permiso de aprobación
create or replace function public.com_approvers() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_general_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', public._com_label(p.id)) order by p.full_name) from public.profiles p where p.status = 'ACTIVO' and public.user_has_perm(p.id, 'com.approve')), '[]'::jsonb);
end; $$;
-- despachos por transportista y zona: SOLO con las hojas reales (sin inventar destinos ni métricas)
create or replace function public.com_dispatch_stats(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_general_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'paradas')::int desc) from (
    select jsonb_build_object('transportista', coalesce(ca.name, r.carrier_id), 'zona', coalesce(nullif(s.zone, ''), 'SIN ZONA'), 'hojas', count(distinct r.id), 'paradas', count(*),
      'entregadas', count(*) filter (where s.outcome = 'ENTREGADO')) x
    from public.routes r join public.route_stops s on s.route_id = r.id left join public.carriers ca on ca.id = r.carrier_id
    where coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO' and r.published_at >= p_from and r.published_at < p_to + 1 group by coalesce(ca.name, r.carrier_id), coalesce(nullif(s.zone, ''), 'SIN ZONA')) t), '[]'::jsonb);
end; $$;

-- situación financiera COMPLEMENTARIA para quien decide (aprobador asignado o Administrador General). Nunca es venta.
create or replace function public.com_client_finance(p_client uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.com_clients; i public.com_ingests; b public.com_cc_balances; ls bigint;
begin
  if (public._com_active()).id is null or not (public._is_general_admin() or public.user_has_perm(auth.uid(), 'com.approve')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not public._is_general_admin() and not exists(select 1 from public.com_requests where client_id=p_client and assigned_approver_id=auth.uid()) then raise exception 'FORBIDDEN_CLIENT' using errcode='42501'; end if;
  select * into c from public.com_clients where id = p_client; if not found or c.cuit is null then return jsonb_build_object('status', 'SIN_CUIT'); end if;
  select * into i from public.com_ingests where kind = 'CC' and status = 'OK' order by at desc limit 1;
  if found then select * into b from public.com_cc_balances where ingest_id = i.id and cuit = c.cuit; end if;
  select id into ls from public.com_ingests where kind = 'SC' and status = 'OK' order by at desc, id desc limit 1;   -- la carga MÁS RECIENTE por fecha
  return jsonb_build_object('cc_saldo', b.saldo, 'cc_fecha', i.at, 'cc_disponible', b.cuit is not null,
    'pendientes', coalesce((select jsonb_agg(jsonb_build_object('comprobante', comp, 'fecha', doc_date, 'vence', due, 'saldo', last_saldo) order by due nulls last, doc_date)
       from public.com_sc_documents where cuit = c.cuit and last_ingest_id = ls and coalesce(last_saldo, 0) > 0.004 and class = 'VENTA'), '[]'::jsonb),
    'sc_fecha', (select at from public.com_ingests where id = ls));
end; $$;

-- estado de las fuentes para el Panel General
create or replace function public.com_sources_status() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_general_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object(
    'ultima_sc', (select jsonb_build_object('at', at, 'archivo', file_name, 'filas', rows, 'stats', stats, 'periodo', jsonb_build_array(date_min, date_max)) from public.com_ingests where kind = 'SC' and status = 'OK' order by at desc limit 1),
    'ultima_cc', (select jsonb_build_object('at', at, 'archivo', file_name, 'filas', rows) from public.com_ingests where kind = 'CC' and status = 'OK' order by at desc limit 1),
    'errores', (select coalesce(jsonb_agg(jsonb_build_object('at', at, 'kind', kind, 'archivo', file_name, 'error', error) order by at desc), '[]') from (select * from public.com_ingests where status <> 'OK' order by at desc limit 10) e),
    'meses_cubiertos', (select coalesce(jsonb_agg(m order by m), '[]') from (select g::date m from generate_series(date_trunc('month', now()) - interval '12 month', date_trunc('month', now()) - interval '1 month', interval '1 month') g where public._com_month_covered(g::date)) x),
    'incidencias', (select coalesce(jsonb_object_agg(kind, n), '{}') from (select kind, count(*) n from public.com_reconciliation_issues where status = 'ABIERTA' group by kind) x),
    'tipos', (select jsonb_agg(jsonb_build_object('prefijo', prefix, 'clase', class) order by prefix) from public.com_comp_types),
    'clientes_sin_historial', (select count(*) from public.com_clients c where c.status = 'ACTIVO' and (c.cuit is null or not exists (select 1 from public.com_sc_documents d where d.cuit = c.cuit))));
end; $$;
create or replace function public.com_set_comp_type(p_prefix text, p_class text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public._is_general_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  insert into public.com_comp_types(prefix, class, updated_by) values (upper(p_prefix), p_class, auth.uid()) on conflict (prefix) do update set class = excluded.class, updated_by = auth.uid(), updated_at = now();
  update public.com_sc_documents set class = p_class, status = case when status = 'SIN_CLASIFICAR' then case when amount is null then 'SIN_IMPORTE' when doc_date is null then 'SIN_FECHA' else 'OK' end else status end where prefix = upper(p_prefix);
  update public.com_reconciliation_issues set status = 'RESUELTA' where kind = 'TIPO_SIN_CLASIFICAR' and detail->>'prefijo' = upper(p_prefix) and status = 'ABIERTA';
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_COMP_TYPE', 'com_comp_types', upper(p_prefix), jsonb_build_object('class', p_class));
  return jsonb_build_object('prefix', upper(p_prefix), 'class', p_class);
end; $$;

-- ---------- 5) SOLICITUDES, EVENTOS (inmutables), AVISOS Y CORREOS PREPARADOS ----------
create sequence public.com_request_seq;
create table public.com_requests (
  id uuid primary key default gen_random_uuid(),
  number text not null unique default ('AUT-' || lpad(nextval('public.com_request_seq')::text, 6, '0')),
  kind text not null check (kind in ('FINANCIACION', 'ECHEQ')),
  client_id uuid not null references public.com_clients(id),
  client_snapshot jsonb not null,                                -- nombre + documento VINCULADOS al cliente elegido (no campos sueltos)
  channel text not null, branch text, cartera_label text,
  requested_by uuid not null references public.profiles(id),
  assigned_approver_id uuid references public.profiles(id),      -- aprobador ORIGINAL (nunca se borra)
  order_ref text, notes text,
  original_terms jsonb not null, current_terms jsonb not null, final_terms jsonb,
  kpi_snapshot jsonb not null,
  status text not null default 'PENDIENTE' check (status in ('PENDIENTE', 'APROBADA', 'APROBADA_MOD', 'RECHAZADA', 'DEVUELTA', 'CANCELADA')),
  decided_by uuid references public.profiles(id), decided_at timestamptz, decided_as text check (decided_as in ('APROBADOR', 'SUPLENTE_ADMIN')),
  version int not null default 1, op_id text unique,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create index com_requests_status_idx on public.com_requests(status, assigned_approver_id);
create index com_requests_client_idx on public.com_requests(client_id);
create table public.com_request_events (
  id bigint generated always as identity primary key, request_id uuid not null references public.com_requests(id), seq int not null,
  kind text not null, actor_id uuid, actor_label text, assigned_approver_id uuid, terms_before jsonb, terms_after jsonb, reason text,
  at timestamptz not null default now(), unique (request_id, seq));
create or replace function public.trg_com_events_immutable() returns trigger language plpgsql as $$
begin raise exception 'IMMUTABLE: el historial de autorizaciones no se modifica ni se borra' using errcode = '42501'; end; $$;
create trigger com_request_events_immutable before update or delete on public.com_request_events for each row execute function public.trg_com_events_immutable();
create table public.com_notifications (
  id bigint generated always as identity primary key, user_id uuid not null references public.profiles(id), request_id uuid not null references public.com_requests(id),
  event_seq int not null, kind text not null, title text not null, body text, created_at timestamptz not null default now(), read_at timestamptz,
  unique (user_id, request_id, event_seq));                       -- sin duplicados
create table public.com_email_jobs (
  id bigint generated always as identity primary key, request_id uuid not null references public.com_requests(id), event_seq int not null,
  user_id uuid references public.profiles(id), recipient text, subject text not null, status text not null default 'PREPARADO' check (status in ('PREPARADO', 'SIN_CORREO', 'OMITIDO')),
  idempotency_key text not null unique, created_at timestamptz not null default now());

create or replace function public._com_label(p_user uuid) returns text language sql stable security definer set search_path = public as $$
  select coalesce(full_name, 'Usuario') || case role when 'ADMIN' then ' — Administrador General' when 'COMERCIAL' then ' — Comercial' else '' end from public.profiles where id = p_user;
$$;
create or replace function public._com_event(p_req uuid, p_kind text, p_reason text, p_before jsonb, p_after jsonb) returns int language plpgsql security definer set search_path = public as $$
declare n int; q public.com_requests;
begin
  select * into q from public.com_requests where id = p_req;
  select coalesce(max(seq), 0) + 1 into n from public.com_request_events where request_id = p_req;
  insert into public.com_request_events(request_id, seq, kind, actor_id, actor_label, assigned_approver_id, terms_before, terms_after, reason)
    values (p_req, n, p_kind, auth.uid(), public._com_label(auth.uid()), q.assigned_approver_id, p_before, p_after, p_reason);
  return n;
end; $$;
-- aviso interno + correo PREPARADO (sin envío), una sola vez por usuario y evento
create or replace function public._com_notify(p_req uuid, p_seq int, p_user uuid, p_kind text, p_title text, p_body text) returns void language plpgsql security definer set search_path = public as $$
declare e text;
begin
  if p_user is null then return; end if;
  insert into public.com_notifications(user_id, request_id, event_seq, kind, title, body) values (p_user, p_req, p_seq, p_kind, p_title, p_body) on conflict do nothing;
  select email into e from public.profiles where id = p_user;
  insert into public.com_email_jobs(request_id, event_seq, user_id, recipient, subject, status, idempotency_key)
    values (p_req, p_seq, p_user, e, p_title, case when coalesce(e, '') = '' then 'SIN_CORREO' else 'PREPARADO' end, p_req || '|' || p_seq || '|' || p_user) on conflict do nothing;
exception when others then null;   -- un aviso nunca bloquea la operación
end; $$;

-- términos validados en el SERVIDOR (financiación: cuotas SEMANALES; último vencimiento dentro del plazo máximo; e-cheq: emisor = cliente si vacío)
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

create or replace function public.com_create_request(p_kind text, p_client uuid, p_order_ref text, p_terms jsonb, p_notes text, p_op_id text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles; asg public.com_user_assignments; rt public.com_routing; c public.com_clients; q public.com_requests; t jsonb; n int; ck text;
begin
  me := public._com_active();
  if me.id is null or not public.user_has_perm(me.id, 'com.request') then raise exception 'FORBIDDEN: solo Comercial crea solicitudes' using errcode = '42501'; end if;
  if p_op_id is not null then
    perform pg_advisory_xact_lock(hashtextextended('com-request|'||p_op_id,0));
    select * into q from public.com_requests where op_id = p_op_id;
    if found then
      if q.requested_by <> me.id then raise exception 'OP_ID_REUSED' using errcode='42501'; end if;
      if q.client_id <> p_client or q.kind <> p_kind or q.order_ref is distinct from left(nullif(btrim(p_order_ref),''),60) then raise exception 'OP_ID_MISMATCH' using errcode='23514'; end if;
      return jsonb_build_object('id',q.id,'number',q.number,'status',q.status,'repeated',true);
    end if;
  end if;
  if p_kind not in ('FINANCIACION', 'ECHEQ') then raise exception 'BAD_KIND' using errcode = '23514'; end if;
  select * into asg from public.com_user_assignments where user_id = me.id;
  if not found then raise exception 'NO_ASSIGNMENT: Administración todavía no te asignó sucursal o cartera' using errcode = '23514'; end if;
  ck := case when asg.channel = 'CARTERA' then 'CARTERA' else 'SUCURSAL:' || asg.branch end;
  select * into rt from public.com_routing where channel_key = ck;
  if rt.approver_user_id is null or public._com_active(rt.approver_user_id) is null then raise exception 'NO_APPROVER: no hay aprobador ACTIVO configurado para %', ck using errcode = '23514'; end if;
  select * into c from public.com_clients where id = p_client;
  if not found then raise exception 'CLIENT_NOT_FOUND: CLIENTE NO ENCONTRADO' using errcode = 'P0002'; end if;
  if c.status <> 'ACTIVO' then raise exception 'CLIENT_IN_REVIEW: el cliente está pendiente de revisión (%)', array_to_string(c.review_reasons, ', ') using errcode = '23514'; end if;
  t := public._com_terms(p_kind, p_terms, c, (now() at time zone 'America/Argentina/Mendoza')::date);
  insert into public.com_requests(kind, client_id, client_snapshot, channel, branch, cartera_label, requested_by, assigned_approver_id, order_ref, notes, original_terms, current_terms, kpi_snapshot, op_id)
  values (p_kind, c.id, jsonb_build_object('id', c.id, 'erp_id', c.erp_id, 'razon_social', c.razon_social, 'nombre', c.nombre, 'doc_type', c.doc_type, 'doc_number', c.doc_number, 'cuit', c.cuit),
    asg.channel, asg.branch, asg.cartera_label, me.id, rt.approver_user_id, left(nullif(btrim(p_order_ref), ''), 60), left(nullif(btrim(p_notes), ''), 600), t, t,
    case when p_kind = 'FINANCIACION' then public.com_kpi_for_client(c.id) else jsonb_build_object('status', 'NO_APLICA') end, p_op_id) returning * into q;
  perform public._com_event(q.id, 'ENVIADA', null, null, t);
  n := public._com_event(q.id, 'PENDIENTE', null, null, null);
  perform public._com_notify(q.id, n, rt.approver_user_id, 'NUEVA', 'Autorización ' || q.number || ' pendiente', (case when p_kind = 'FINANCIACION' then 'Financiación propia' else 'Aceptación de e-cheq' end) || ' · ' || c.razon_social || ' · $ ' || to_char((t->>'amount')::numeric, 'FM999G999G999D00'));
  return jsonb_build_object('id', q.id, 'number', q.number, 'status', q.status, 'approver', public._com_label(rt.approver_user_id), 'repeated', false);
end; $$;

-- DECISIÓN ATÓMICA: aprobador asignado (ACTIVO, com.approve) o SUPLENTE = Administrador General ACTIVO. Una sola decisión por ciclo.
create or replace function public.com_decide(p_id uuid, p_version int, p_decision text, p_terms jsonb, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles; q public.com_requests; c public.com_clients; t jsonb; st text; asn text; n int; ev text;
begin
  me := public._com_active();
  select * into q from public.com_requests where id = p_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if q.assigned_approver_id = me.id and public.user_has_perm(me.id, 'com.approve') then asn := 'APROBADOR';
  elsif public._is_general_admin() then asn := case when q.assigned_approver_id = me.id then 'APROBADOR' else 'SUPLENTE_ADMIN' end;
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

-- COMERCIAL responde una DEVOLUCIÓN: acepta las condiciones propuestas (vuelve a PENDIENTE) o retira la solicitud
create or replace function public.com_respond(p_id uuid, p_version int, p_accept boolean, p_comment text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles; q public.com_requests; n int;
begin
  me := public._com_active();
  select * into q from public.com_requests where id = p_id for update;
  if not found or me.id is null or q.requested_by <> me.id or not public.user_has_perm(me.id,'com.request') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_version is null or p_accept is null then raise exception 'BAD_VERSION_OR_RESPONSE' using errcode='23514'; end if;
  if q.status <> 'DEVUELTA' or q.version <> p_version then raise exception 'CONFLICT: la solicitud no está devuelta o cambió' using errcode = '40001'; end if;
  update public.com_requests set status = case when p_accept then 'PENDIENTE' else 'CANCELADA' end, version = version + 1, updated_at = now() where id = q.id;
  n := public._com_event(q.id, case when p_accept then 'CAMBIOS_ACEPTADOS_REENVIADA' else 'RETIRADA_POR_COMERCIAL' end, nullif(btrim(p_comment), ''), null, case when p_accept then q.current_terms end);
  if p_accept then n := public._com_event(q.id, 'PENDIENTE', null, null, null);
    perform public._com_notify(q.id, n, q.assigned_approver_id, 'NUEVA', 'Autorización ' || q.number || ' reenviada con los cambios aceptados', coalesce(p_comment, '')); end if;
  return jsonb_build_object('id', q.id, 'status', case when p_accept then 'PENDIENTE' else 'CANCELADA' end, 'version', q.version + 1);
end; $$;

-- ---------- 6) CONSULTAS (visibilidad en el servidor) ----------
create or replace function public._com_can_see_full(q public.com_requests) returns boolean language sql stable security definer set search_path = public as $$
  select (public._com_active()).id is not null and ((q.requested_by = auth.uid() and public.user_has_perm(auth.uid(),'com.request')) or (q.assigned_approver_id = auth.uid() and public.user_has_perm(auth.uid(),'com.approve')) or public._is_general_admin());
$$;
create or replace function public._com_view(q public.com_requests, p_full boolean) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', q.id, 'number', q.number, 'kind', q.kind, 'status', q.status, 'client', q.client_snapshot, 'order_ref', q.order_ref, 'channel', q.channel, 'branch', q.branch,
    'cartera_label', q.cartera_label, 'requested_by', public._com_label(q.requested_by), 'assigned_approver', public._com_label(q.assigned_approver_id), 'assigned_approver_id', q.assigned_approver_id,
    'decided_by', public._com_label(q.decided_by), 'decided_as', q.decided_as, 'decided_at', q.decided_at, 'created_at', q.created_at, 'updated_at', q.updated_at, 'version', q.version,
    'current_terms', q.current_terms, 'final_terms', q.final_terms, 'original_terms', case when p_full then q.original_terms end, 'notes', case when p_full then q.notes end,
    'kpi', case when p_full then q.kpi_snapshot end,
    'timeline', (select jsonb_agg(jsonb_build_object('seq', e.seq, 'kind', e.kind, 'by', e.actor_label, 'at', e.at, 'reason', case when p_full then e.reason end,
       'assigned', public._com_label(e.assigned_approver_id), 'terms_after', case when p_full then e.terms_after end) order by e.seq) from public.com_request_events e where e.request_id = q.id));
$$;
-- bandejas: MIS (Comercial) · PENDIENTES (aprobador) · TODAS / DE OTRO APROBADOR (Administrador General, para la suplencia)
create or replace function public.com_list(p_scope text, p_status text default null, p_limit int default 30, p_offset int default 0) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); adm boolean := public._is_general_admin();
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
-- TRAZABILIDAD de Despacho: búsqueda por cliente, CUIT o pedido; estado + línea de tiempo + condiciones FINALES (sin KPI ni notas)
create or replace function public.com_track(p_q text, p_open_only boolean default false, p_limit int default 20, p_offset int default 0) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); q text := public._com_norm(p_q); d text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
begin
  if me.id is null or not (public.user_has_perm(me.id, 'com.track') or public._is_general_admin()) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(public._com_view(r, public._com_can_see_full(r)) order by r.updated_at desc) from (
    select * from public.com_requests r where (not p_open_only or r.status in ('PENDIENTE', 'DEVUELTA'))
      and (coalesce(btrim(p_q), '') = '' or public._com_norm(r.client_snapshot->>'razon_social') like '%' || q || '%' or public._com_norm(r.client_snapshot->>'nombre') like '%' || q || '%'
           or (length(d) >= 3 and ((r.client_snapshot->>'cuit') like '%' || d || '%' or (r.client_snapshot->>'doc_number') like '%' || d || '%')) or public._com_norm(r.order_ref) like '%' || q || '%' or r.number ilike '%' || p_q || '%')
    order by r.updated_at desc limit greatest(1, least(coalesce(p_limit, 20), 50)) offset greatest(0, coalesce(p_offset, 0))) r), '[]'::jsonb);
end; $$;
create or replace function public.com_my_notifications() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'request_id', n.request_id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'at', n.created_at, 'read', n.read_at is not null) order by n.created_at desc), '[]'::jsonb)
  from (select * from public.com_notifications where user_id = auth.uid() and (public._com_active()).id is not null and (public._is_general_admin() or public.user_has_perm(auth.uid(),'com.request') or public.user_has_perm(auth.uid(),'com.approve')) order by created_at desc limit 50) n;
$$;

-- ---------- 7) CONFIGURACIÓN (Panel General · solo Administrador General) ----------
create or replace function public.com_set_settings(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.com_settings;
begin
  if not public._is_general_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.com_settings set kpi_months = coalesce((p->>'kpi_months')::int, kpi_months), floor_pct = coalesce((p->>'floor_pct')::numeric, floor_pct), ceiling_pct = coalesce((p->>'ceiling_pct')::numeric, ceiling_pct),
    fin_max_days = coalesce((p->>'fin_max_days')::int, fin_max_days), cheq_max_days = coalesce((p->>'cheq_max_days')::int, cheq_max_days),
    coverage_gap_days = coalesce((p->>'coverage_gap_days')::int, coverage_gap_days), kpi_partial_rule = coalesce(p->>'kpi_partial_rule', kpi_partial_rule),
    kpi_source_verified = coalesce((p->>'kpi_source_verified')::boolean, kpi_source_verified), updated_by = auth.uid(), updated_at = now() where id = 'DEFAULT' returning * into s;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_SETTINGS', 'com_settings', 'DEFAULT', to_jsonb(s));
  return to_jsonb(s);
end; $$;
create or replace function public.com_set_routing(p_channel_key text, p_approver uuid) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public._is_general_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_approver is not null and (public._com_active(p_approver) is null or not public.user_has_perm(p_approver, 'com.approve')) then
    raise exception 'BAD_APPROVER: el aprobador debe estar ACTIVO y tener permiso de aprobación' using errcode = '23514'; end if;
  update public.com_routing set approver_user_id = p_approver, updated_by = auth.uid(), updated_at = now() where channel_key = p_channel_key;
  if not found then raise exception 'BAD_CHANNEL' using errcode = '23514'; end if;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_ROUTING', 'com_routing', p_channel_key, jsonb_build_object('approver', p_approver));
  return jsonb_build_object('channel_key', p_channel_key, 'approver', public._com_label(p_approver));
end; $$;
create or replace function public.com_set_assignment(p_user uuid, p_channel text, p_branch text, p_cartera text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public._is_general_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not exists (select 1 from public.profiles where id = p_user and role = 'COMERCIAL') then raise exception 'NOT_COMERCIAL: el usuario no tiene rol Comercial' using errcode = '23514'; end if;
  insert into public.com_user_assignments(user_id, channel, branch, cartera_label, updated_by) values (p_user, p_channel, case when p_channel = 'SUCURSAL' then p_branch end, case when p_channel = 'CARTERA' then nullif(btrim(p_cartera), '') end, auth.uid())
    on conflict (user_id) do update set channel = excluded.channel, branch = excluded.branch, cartera_label = excluded.cartera_label, updated_by = auth.uid(), updated_at = now();
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_ASSIGNMENT', 'profiles', p_user::text, jsonb_build_object('channel', p_channel, 'branch', p_branch, 'cartera', p_cartera));
  return jsonb_build_object('user_id', p_user, 'channel', p_channel);
end; $$;
create or replace function public.com_config() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active();
begin
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object('settings', (select to_jsonb(s) - 'updated_by' from public.com_settings s where id = 'DEFAULT'),
    'my_assignment', (select to_jsonb(a) || jsonb_build_object('approver', public._com_label(r.approver_user_id)) from public.com_user_assignments a
       left join public.com_routing r on r.channel_key = case when a.channel = 'CARTERA' then 'CARTERA' else 'SUCURSAL:' || a.branch end where a.user_id = me.id),
    'is_admin', public._is_general_admin(), 'can_request', public.user_has_perm(me.id, 'com.request'), 'can_approve', public.user_has_perm(me.id, 'com.approve') or public._is_general_admin(),
    'can_track', public.user_has_perm(me.id, 'com.track') or public._is_general_admin(), 'can_upload', public.user_has_perm(me.id, 'com.sources.upload'),
    'routing', case when public._is_general_admin() then (select jsonb_agg(jsonb_build_object('channel_key', channel_key, 'approver_user_id', approver_user_id, 'approver', public._com_label(approver_user_id)) order by channel_key) from public.com_routing) end,
    'assignments', case when public._is_general_admin() then (select jsonb_agg(jsonb_build_object('user_id', p.id, 'name', p.full_name, 'channel', a.channel, 'branch', a.branch, 'cartera_label', a.cartera_label) order by p.full_name)
       from public.profiles p left join public.com_user_assignments a on a.user_id = p.id where p.role = 'COMERCIAL') end);
end; $$;

-- ---------- 8) INFORMES (Administrador General) ----------
create or replace function public.com_report(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_general_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
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

-- ---------- 9) RLS: sin acceso directo a las tablas; todo por funciones ----------
do $$ declare t text; f text; begin
  foreach t in array array['com_settings', 'com_routing', 'com_user_assignments', 'com_client_imports', 'com_clients', 'com_client_changes', 'com_comp_types', 'com_ingests', 'com_ingest_batches', 'com_sc_documents', 'com_cc_balances',
    'com_reconciliation_issues', 'com_requests', 'com_request_events', 'com_notifications', 'com_email_jobs'] loop
    execute 'alter table public.' || t || ' enable row level security'; execute 'revoke all on public.' || t || ' from anon, authenticated'; end loop;
  foreach f in array array['com_import_clients(text,text,jsonb)', 'com_search_clients(text,integer)', 'com_ingest(text,jsonb,jsonb)', 'com_ingest_error(text,jsonb,text)', 'com_client_finance(uuid)', 'com_sources_status()', 'com_set_comp_type(text,text)', 'com_kpi_for_client(uuid,timestamptz)', 'com_approvers()', 'com_dispatch_stats(date,date)', 'com_create_request(text,uuid,text,jsonb,text,text)', 'com_decide(uuid,integer,text,jsonb,text)',
    'com_respond(uuid,integer,boolean,text)', 'com_list(text,text,integer,integer)', 'com_track(text,boolean,integer,integer)', 'com_my_notifications()', 'com_set_settings(jsonb)',
    'com_set_routing(text,uuid)', 'com_set_assignment(uuid,text,text,text)', 'com_config()', 'com_report(date,date)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon'; execute 'grant execute on function public.' || f || ' to authenticated'; end loop;
  foreach f in array array['_com_active(uuid)', '_com_norm(text)', '_com_recompute_reviews()', '_com_label(uuid)', '_com_event(uuid,text,text,jsonb,jsonb)', '_com_notify(uuid,integer,uuid,text,text,text)',
    '_com_terms(text,jsonb,public.com_clients,date)', '_com_can_see_full(public.com_requests)', '_com_view(public.com_requests,boolean)', 'trg_com_events_immutable()', '_com_month_covered(date)', '_com_kpi_raw(uuid,timestamptz)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated'; end loop;
end $$;
-- Los archivos originales NO se suben: Depósito sigue con su proceso; el servidor recibe solo los registros ya leídos (historial derivado).
COMMIT;
