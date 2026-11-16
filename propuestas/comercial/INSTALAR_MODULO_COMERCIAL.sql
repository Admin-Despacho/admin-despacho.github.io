-- =====================================================================================================================
-- INSTALACIÓN ÚNICA · MÓDULO AUTORIZACIONES COMERCIALES + ALARMA (000100 a 001100) · NO APLICAR sin autorización (ver PLAN_PUBLICACION).
-- Generado por tools/gen_instalador.py. UNA transacción: si cualquier paso falla, NO queda ningún objeto del módulo.
-- Al terminar, el módulo queda CERRADO: ninguna función comercial es ejecutable por usuarios hasta correr ACTIVAR_MODULO_COMERCIAL.sql
-- (que verifica el estado y otorga EXACTAMENTE los permisos que dejaron las migraciones). KPI: DESHABILITADO (lo exige 000900).
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '600s';
-- ==============================================================================================================
-- 20261201000100_comercial_autorizaciones.sql
-- ==============================================================================================================
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
-- (BEGIN propio retirado: corre dentro de la transacción única)
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
-- (COMMIT propio retirado)
-- ==============================================================================================================
-- 20261201000200_comercial_cuotas_respaldo.sql
-- ==============================================================================================================
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
-- (BEGIN propio retirado: corre dentro de la transacción única)
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
-- (COMMIT propio retirado)
-- ==============================================================================================================
-- 20261201000300_comercial_consultar_aprobacion.sql
-- ==============================================================================================================
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
-- (BEGIN propio retirado: corre dentro de la transacción única)
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
-- (COMMIT propio retirado)
-- ==============================================================================================================
-- 20261201000400_comercial_alarma_urgente.sql
-- ==============================================================================================================
-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · ALARMA URGENTE DE APROBACIÓN COMERCIAL · NO APLICADA. Se aplica después de 000100 a 000300.
-- Despacho (sección REVISAR de la publicación) pide ATENCIÓN URGENTE de un responsable comercial para un PEDIDO de la hoja:
--  · la alarma va al destinatario inicial (Wilfredo); si nadie presiona ATENDER SOLICITUD en 3 minutos, el SERVIDOR la escala a Franco y
--    Gabriela (pg_cron cada minuto + escalamiento perezoso en cada consulta; no depende de ninguna pestaña abierta);
--  · ATENDER no es APROBAR: la resolución sigue por el circuito comercial (aprobar / rechazar / devolver / aprobar con cambios);
--  · la alarma NO modifica importes, NO aprueba operaciones y NO toca notas de crédito (sin relación con NOC);
--  · avisos por la campana (notifications) y por el push existente (push_jobs → Edge Function push-notifications), sin datos financieros;
--  · historial INMUTABLE (com_alarm_events) y alcance por rol en el servidor.
-- =====================================================================================================================
-- (BEGIN propio retirado: corre dentro de la transacción única)
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regclass('public.com_requests') IS NULL OR to_regprocedure('public.com_order_alerts(text[],text[])') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: aplicar antes 000100 a 000300. No se modificó nada.'; END IF;
  IF to_regclass('public.notifications') IS NULL OR to_regclass('public.push_jobs') IS NULL OR to_regclass('public.order_reservations') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: notifications / push_jobs / order_reservations. No se modificó nada.'; END IF;
  IF to_regclass('public.com_alarms') IS NOT NULL THEN RAISE EXCEPTION 'YA_APLICADA. No se modificó nada.'; END IF;
END $guard$;

-- ---------- 1) configuración (Panel General) ----------
alter table public.com_settings add column alarm_initial_user uuid references public.profiles(id);          -- configuración EXPLÍCITA obligatoria (Wilfredo)
alter table public.com_settings add column alarm_escalation_users uuid[] not null default '{}';             -- configuración EXPLÍCITA obligatoria (Franco y Gabriela); SIN ampliación automática
alter table public.com_settings add column alarm_escalate_seconds int not null default 180 check (alarm_escalate_seconds between 60 and 3600);

-- ---------- 2) alarmas e historial inmutable ----------
create sequence public.com_alarm_seq;
create table public.com_alarms (
  id uuid primary key default gen_random_uuid(),
  number text not null unique default ('ALR-' || lpad(nextval('public.com_alarm_seq')::text, 6, '0')),
  order_ref text not null, sheet_key text not null, route_id uuid references public.routes(id),
  request_id uuid references public.com_requests(id), branch text,
  client_name text, client_cuit text, client_source text not null check (client_source in ('SOLICITUD_COMERCIAL', 'DECLARADO_POR_DESPACHO')),
  reason text not null check (length(btrim(reason)) >= 10),
  raised_by uuid not null references public.profiles(id), raised_at timestamptz not null default now(),
  initial_user uuid not null references public.profiles(id), escalate_at timestamptz not null,
  escalated_at timestamptz, escalated_to uuid[] not null default '{}',
  status text not null default 'PENDIENTE_ATENCION' check (status in ('PENDIENTE_ATENCION', 'ATENDIDA', 'CANCELADA')),
  attended_by uuid references public.profiles(id), attended_at timestamptz, attended_as text, seconds_to_attend int,
  op_id text unique, version int not null default 1);
create unique index com_alarms_one_active on public.com_alarms(upper(btrim(order_ref))) where status = 'PENDIENTE_ATENCION';   -- sin duplicados
create index com_alarms_due on public.com_alarms(escalate_at) where status = 'PENDIENTE_ATENCION' and escalated_at is null;
create table public.com_alarm_events (
  id bigint generated always as identity primary key, alarm_id uuid not null references public.com_alarms(id),
  kind text not null check (kind in ('CREADA', 'DUPLICADA_EXISTENTE', 'NOTIFICADO', 'ESCALADA', 'ESCALAMIENTO_SIN_DESTINATARIOS', 'ATENDIDA', 'INTENTO_ATENDER_RECHAZADO',
    'OP_ID_REUTILIZADO_RECHAZADO', 'CONFLICTO_UNICIDAD', 'CANCELADA', 'ERROR')),
  actor_id uuid references public.profiles(id), recipient_id uuid references public.profiles(id), notification_id uuid, detail jsonb, at timestamptz not null default now());
-- B-W02: REGISTRO PERSISTENTE de cada operación de emisión (op_id → usuario, pedido, hoja, alarma y RESPUESTA dada). Solo alta.
create table public.com_alarm_ops (
  op_id text primary key check (length(btrim(op_id)) between 6 and 120),
  user_id uuid not null references public.profiles(id), order_ref text not null, sheet_key text not null,
  alarm_id uuid references public.com_alarms(id), result jsonb not null, created_at timestamptz not null default now());
create index com_alarm_ops_alarm on public.com_alarm_ops(alarm_id);
create or replace function public.trg_com_alarm_events_immutable() returns trigger language plpgsql as $$
begin raise exception 'IMMUTABLE: el historial de alarmas no se modifica ni se borra' using errcode = '42501'; end; $$;
create trigger com_alarm_events_immutable before update or delete on public.com_alarm_events for each row execute function public.trg_com_alarm_events_immutable();
create trigger com_alarm_ops_immutable before update or delete on public.com_alarm_ops for each row execute function public.trg_com_alarm_events_immutable();

-- ---------- 3) destinatarios: SOLO la configuración EXPLÍCITA del Administrador General (auditoría B-AL-03). Nunca se amplía automáticamente ----------
-- administrador con SESIÓN VIGENTE (auditoría B-AL-04): perfil activo y token posterior a una revocación (_com_active) + Administrador General
create or replace function public._com_admin() returns boolean language sql stable security definer set search_path = public as $$
  select (public._com_active()).id is not null and public._is_general_admin();
$$;
create or replace function public._com_alarm_initial() returns uuid language sql stable security definer set search_path = public as $$
  select p.id from public.com_settings s join public.profiles p on p.id = s.alarm_initial_user
   where s.id = 'DEFAULT' and p.status = 'ACTIVO' and public.user_has_perm(p.id, 'com.approve');
$$;
create or replace function public._com_alarm_escalation() returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(p.id order by p.full_name), '{}') from public.com_settings s, unnest(s.alarm_escalation_users) u join public.profiles p on p.id = u
   where s.id = 'DEFAULT' and p.status = 'ACTIVO' and p.role = 'ADMIN';
$$;
-- aviso por la campana; el disparador existente lo pasa al push (tipos agregados abajo). Sin importes: se ve en la pantalla bloqueada.
create or replace function public._com_alarm_notify(a public.com_alarms, p_user uuid, p_type text, p_title text, p_body text, p_actor uuid) returns void language plpgsql security definer set search_path = public as $$
declare nid uuid;
begin
  insert into public.notifications(user_id, type, title, body) values (p_user, p_type, p_title, p_body) returning id into nid;
  insert into public.com_alarm_events(alarm_id, kind, actor_id, recipient_id, notification_id, detail) values (a.id, 'NOTIFICADO', p_actor, p_user, nid, jsonb_build_object('tipo', p_type, 'canal', 'CAMPANA+PUSH'));
exception when others then
  insert into public.com_alarm_events(alarm_id, kind, actor_id, recipient_id, detail) values (a.id, 'ERROR', p_actor, p_user, jsonb_build_object('tipo', p_type, 'error', sqlerrm));
end; $$;

-- ---------- 4) emitir (Despacho, desde REVISAR) ----------
create or replace function public.com_alarm_raise(p_order_ref text, p_sheet_key text, p_client_name text, p_client_cuit text, p_reason text, p_op_id text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); a public.com_alarms; o public.com_alarm_ops; q public.com_requests; ini uuid; st public.com_settings;
  ref text := upper(btrim(coalesce(p_order_ref, ''))); op text := btrim(coalesce(p_op_id, '')); res jsonb; cname text;
  aviso constant text := 'Ese identificador de operación ya se usó para otra operación. Reintentá desde la pantalla.';
begin
  if me.id is null or not (public.user_has_perm(me.id, 'com.track') or public._com_admin()) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if ref = '' or coalesce(btrim(p_sheet_key), '') = '' then raise exception 'BAD_ORDER: indicá el pedido y la hoja' using errcode = '22023'; end if;
  if length(op) < 6 then raise exception 'BAD_OP: falta el identificador de la operación' using errcode = '22023'; end if;   -- B-W02: obligatorio (sin él no hay idempotencia)
  -- 1) IDEMPOTENCIA (B-AL-06 / B-W02): las llamadas con el mismo op_id se ordenan; una operación YA RESPONDIDA devuelve SIEMPRE la misma respuesta
  --    (también si la alarma ya se atendió o escaló). Reutilizarla para OTRO usuario, pedido u hoja se rechaza sin datos y se registra.
  perform pg_advisory_xact_lock(hashtext('com_alarm_op:' || op));
  select * into o from public.com_alarm_ops where op_id = op;
  if found then
    if o.user_id = me.id and o.order_ref = ref and o.sheet_key = p_sheet_key then return o.result || jsonb_build_object('repeated', true); end if;
    if o.alarm_id is not null then
      insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (o.alarm_id, 'OP_ID_REUTILIZADO_RECHAZADO', me.id,
        jsonb_build_object('op_id', op, 'pedido_pedido', btrim(p_order_ref), 'hoja_pedida', p_sheet_key, 'difiere', array_remove(array[
          case when o.user_id <> me.id then 'usuario' end, case when o.order_ref <> ref then 'pedido' end, case when o.sheet_key <> p_sheet_key then 'hoja' end], null)));
    end if;
    insert into public.audit_log(actor_id, action, target_type, target_id, after) values (me.id, 'COM_ALARM_OP_ID_REUSE', 'com_alarm_ops', op, jsonb_build_object('pedido', btrim(p_order_ref), 'hoja', p_sheet_key));
    return jsonb_build_object('ok', false, 'code', 'OP_ID_CONFLICT', 'message', aviso);
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then raise exception 'REASON_REQUIRED: indicá el motivo (al menos 10 caracteres)' using errcode = '23514'; end if;
  -- 2) ALCANCE (B-W02 / IND-S02): el pedido debe estar reservado en esa hoja Y el usuario debe poder operar esa hoja (misma regla que _draft: dueño,
  --    routes.manage_all_drafts o Administrador General). «Hoja inexistente» y «sin permiso» responden IGUAL (no se revela existencia).
  if not exists (select 1 from public.order_reservations r join public.route_drafts d on d.client_sheet_key = r.sheet_key
                  where upper(btrim(r.order_id)) = ref and r.sheet_key = p_sheet_key
                    and (d.owner_id = me.id or public.user_has_perm(me.id, 'routes.manage_all_drafts') or public._com_admin())) then
    raise exception 'ORDER_NOT_IN_SHEET: el pedido no pertenece a una hoja que puedas operar' using errcode = '23514'; end if;
  -- 3) una sola alarma ACTIVA por pedido
  perform pg_advisory_xact_lock(hashtext('com_alarm:' || ref));
  select * into a from public.com_alarms where upper(btrim(order_ref)) = ref and status = 'PENDIENTE_ATENCION';
  if found then
    insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (a.id, 'DUPLICADA_EXISTENTE', me.id, jsonb_build_object('op_id', op, 'motivo', btrim(p_reason)));
    if a.raised_by = me.id or a.initial_user = me.id or me.id = any(a.escalated_to) or public._com_admin() then
      res := jsonb_build_object('ok', true, 'id', a.id, 'number', a.number, 'status', a.status, 'existing', true);
    else   -- fuera de su alcance: respuesta MÍNIMA, sin número ni identificador de la alarma ajena
      res := jsonb_build_object('ok', true, 'existing', true, 'status', 'PENDIENTE_ATENCION', 'message', 'Ya hay una alarma activa para ese pedido, pedida por otra persona.');
    end if;
    insert into public.com_alarm_ops(op_id, user_id, order_ref, sheet_key, alarm_id, result) values (op, me.id, ref, p_sheet_key, a.id, res);   -- la deduplicación TAMBIÉN queda vinculada
    return res || jsonb_build_object('repeated', false);
  end if;
  -- 4) alta
  ini := public._com_alarm_initial();
  if ini is null then raise exception 'ALARM_NOT_CONFIGURED: falta configurar (o no está activo) el destinatario inicial de la alarma. Avisá al Administrador General.' using errcode = '23514'; end if;
  if cardinality(public._com_alarm_escalation()) = 0 then raise exception 'ALARM_NOT_CONFIGURED: faltan destinatarios de escalamiento activos configurados. Avisá al Administrador General.' using errcode = '23514'; end if;
  select * into st from public.com_settings where id = 'DEFAULT';
  select * into q from public.com_requests where upper(btrim(coalesce(order_ref, ''))) = ref and status <> 'CANCELADA' order by created_at desc, number desc limit 1;
  begin
    insert into public.com_alarms(order_ref, sheet_key, route_id, request_id, branch, client_name, client_cuit, client_source, reason, raised_by, initial_user, escalate_at, op_id)
      values (btrim(p_order_ref), p_sheet_key, (select route_id from public.order_reservations where upper(btrim(order_id)) = ref and sheet_key = p_sheet_key limit 1), q.id,
              coalesce(q.branch, q.cartera_label), coalesce(q.client_snapshot->>'razon_social', left(btrim(p_client_name), 160)), coalesce(q.client_snapshot->>'cuit', nullif(regexp_replace(coalesce(p_client_cuit, ''), '\D', '', 'g'), '')),
              case when q.id is null then 'DECLARADO_POR_DESPACHO' else 'SOLICITUD_COMERCIAL' end, btrim(p_reason), me.id, ini, now() + make_interval(secs => st.alarm_escalate_seconds), op)
      returning * into a;
  exception when unique_violation then
    -- O-W02: última defensa DIFERENCIADA (los bloqueos ya ordenan las llamadas): se identifica la restricción, se AUDITA y se responde sin datos
    get stacked diagnostics cname = constraint_name;
    insert into public.audit_log(actor_id, action, target_type, target_id, after) values (me.id, 'COM_ALARM_UNIQUE_FALLBACK', 'com_alarms', op, jsonb_build_object('restriccion', cname, 'pedido', btrim(p_order_ref), 'hoja', p_sheet_key));
    if cname = 'com_alarms_one_active' then return jsonb_build_object('ok', false, 'code', 'RETRY', 'message', 'Otra alarma para ese pedido se registró en el mismo instante. Reintentá: vas a ver la alarma activa.'); end if;
    return jsonb_build_object('ok', false, 'code', 'OP_ID_CONFLICT', 'message', aviso);
  end;
  insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (a.id, 'CREADA', me.id, jsonb_build_object('op_id', op, 'pedido', a.order_ref, 'hoja', a.sheet_key, 'motivo', a.reason, 'escala_a_las', a.escalate_at));
  perform public._com_alarm_notify(a, ini, 'COM_ALARMA', 'APROBACIÓN COMERCIAL URGENTE', 'Pedido ' || a.order_ref || ' · solicitada por ' || me.full_name || ' · tocá para ATENDER', me.id);
  res := jsonb_build_object('ok', true, 'id', a.id, 'number', a.number, 'status', 'PENDIENTE_ATENCION', 'existing', false, 'escalate_at', a.escalate_at);
  insert into public.com_alarm_ops(op_id, user_id, order_ref, sheet_key, alarm_id, result) values (op, me.id, ref, p_sheet_key, a.id, res);
  return res || jsonb_build_object('repeated', false);
end; $$;

-- ---------- 5) escalamiento del SERVIDOR (pg_cron cada minuto + perezoso). Idempotente: cada alarma se escala UNA vez ----------
create or replace function public.com_alarm_escalate_due() returns int language plpgsql security definer set search_path = public as $$
declare a public.com_alarms; n int := 0; dest uuid[]; u uuid;
begin
  for a in select * from public.com_alarms where status = 'PENDIENTE_ATENCION' and escalated_at is null and escalate_at <= now() order by escalate_at for update skip locked loop
    dest := array(select x from unnest(public._com_alarm_escalation()) x where x <> a.initial_user);
    update public.com_alarms set escalated_at = now(), escalated_to = dest, version = version + 1 where id = a.id returning * into a;
    if cardinality(dest) = 0 then
      -- SIN ampliación automática: se registra el error y se avisa a Wilfredo y a quien la pidió; la alarma SIGUE pendiente (B-AL-03)
      insert into public.com_alarm_events(alarm_id, kind, detail) values (a.id, 'ESCALAMIENTO_SIN_DESTINATARIOS', jsonb_build_object('a_las', a.escalated_at, 'motivo', 'ningún destinatario de escalamiento configurado está ACTIVO'));
      perform public._com_alarm_notify(a, a.initial_user, 'COM_ALARMA_ESCALADA', 'ALARMA COMERCIAL SIN ESCALAMIENTO', 'Pedido ' || a.order_ref || ' · no hay destinatarios de escalamiento activos · atendela', null);
      perform public._com_alarm_notify(a, a.raised_by, 'COM_ALARMA_ESCALADA', 'ALARMA COMERCIAL SIN ESCALAMIENTO', 'Pedido ' || a.order_ref || ' · no se pudo escalar: avisá al Administrador General', null);
      n := n + 1; continue;
    end if;
    insert into public.com_alarm_events(alarm_id, kind, detail) values (a.id, 'ESCALADA', jsonb_build_object('destinatarios', dest, 'a_las', a.escalated_at, 'sin_atender_desde', a.raised_at));
    foreach u in array dest loop
      perform public._com_alarm_notify(a, u, 'COM_ALARMA_ESCALADA', 'APROBACIÓN COMERCIAL URGENTE · ESCALADA', 'Pedido ' || a.order_ref || ' · sin atender en 3 minutos · tocá para ATENDER', null);
    end loop;
    n := n + 1;
  end loop;
  return n;
end; $$;

-- ---------- 6) ATENDER (no es aprobar). Una sola persona la toma: bloqueo de fila + versión ----------
create or replace function public.com_alarm_attend(p_id uuid, p_version int) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); a public.com_alarms; como text; u uuid;
begin
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();
  select * into a from public.com_alarms where id = p_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  como := case when me.id = a.initial_user then 'DESTINATARIO_INICIAL' when me.id = any(a.escalated_to) then 'ESCALAMIENTO'
               when public._com_admin() then 'ADMINISTRADOR_GENERAL' end;
  if como is null then
    -- se REGISTRA el intento y se RESPONDE el rechazo (sin excepción: una excepción desharía también el registro). La alarma no cambia.
    insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (a.id, 'INTENTO_ATENDER_RECHAZADO', me.id, jsonb_build_object('motivo', 'sin autorización'));
    return jsonb_build_object('ok', false, 'code', 'FORBIDDEN', 'message', 'No sos destinatario de esta alarma.'); end if;
  -- O-AL-05: hay conflicto SOLO si la alarma ya NO está pendiente (otra persona la atendió). Un cambio de versión por el ESCALAMIENTO no
  -- bloquea a un destinatario autorizado; la doble toma sigue impedida por el bloqueo de la fila (FOR UPDATE) y el estado.
  if a.status <> 'PENDIENTE_ATENCION' then
    raise exception 'CONFLICT: la alarma ya fue atendida por % (%)', coalesce((select full_name from public.profiles where id = a.attended_by), '—'), a.attended_at using errcode = '40001'; end if;
  update public.com_alarms set status = 'ATENDIDA', attended_by = me.id, attended_at = now(), attended_as = como, seconds_to_attend = extract(epoch from now() - raised_at)::int, version = version + 1
   where id = a.id returning * into a;
  insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (a.id, 'ATENDIDA', me.id, jsonb_build_object('como', como, 'segundos', a.seconds_to_attend, 'escalada', a.escalated_at is not null));
  -- se informa a quien la pidió y a los demás destinatarios (las alertas de la app se detienen al ver ATENDIDA)
  foreach u in array (array[a.raised_by, a.initial_user] || a.escalated_to) loop
    if u is distinct from me.id then perform public._com_alarm_notify(a, u, 'COM_ALARMA_ATENDIDA', 'Alarma comercial ATENDIDA', 'Pedido ' || a.order_ref || ' · atendida por ' || me.full_name, me.id); end if;
  end loop;
  return jsonb_build_object('ok', true, 'id', a.id, 'number', a.number, 'status', a.status, 'attended_as', como, 'seconds_to_attend', a.seconds_to_attend, 'request_id', a.request_id);
end; $$;

-- ---------- 7) consultas por rol ----------
create or replace function public._com_alarm_view(a public.com_alarms, p_me uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', a.id, 'number', a.number, 'order_ref', a.order_ref, 'sheet_key', a.sheet_key, 'client', a.client_name, 'cuit', a.client_cuit, 'client_source', a.client_source,
    'branch', a.branch, 'reason', a.reason, 'raised_by', public._com_label(a.raised_by), 'raised_at', a.raised_at, 'initial_user', public._com_label(a.initial_user), 'escalate_at', a.escalate_at,
    'escalated_at', a.escalated_at, 'escalated_to', (select coalesce(jsonb_agg(public._com_label(x)), '[]') from unnest(a.escalated_to) x), 'status', a.status,
    'attended_by', public._com_label(a.attended_by), 'attended_at', a.attended_at, 'seconds_to_attend', a.seconds_to_attend, 'version', a.version,
    'request', (select jsonb_build_object('id', q.id, 'number', q.number, 'status', q.status) from public.com_requests q where q.id = a.request_id),
    -- ¿le SUENA a este usuario? destinatario inicial mientras esté pendiente; escalados después del escalamiento
    'ring', a.status = 'PENDIENTE_ATENCION' and (p_me = a.initial_user or p_me = any(a.escalated_to)),
    'can_attend', a.status = 'PENDIENTE_ATENCION' and (p_me = a.initial_user or p_me = any(a.escalated_to) or public._com_admin()));
$$;
create or replace function public.com_my_alarms() returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active();
begin
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();   -- perezoso: adelanta el escalamiento si hay alguien conectado (el reloj sigue siendo el del servidor)
  return coalesce((select jsonb_agg(public._com_alarm_view(a, me.id) order by a.raised_at desc) from public.com_alarms a
    where (a.status = 'PENDIENTE_ATENCION' or a.attended_at > now() - interval '12 hours')
      and (a.raised_by = me.id or a.initial_user = me.id or me.id = any(a.escalated_to) or public._com_admin())), '[]'::jsonb);
end; $$;
create or replace function public.com_alarm_history(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;   -- B-AL-04: también rechaza un token REVOCADO
  return coalesce((select jsonb_agg(public._com_alarm_view(a, auth.uid()) || jsonb_build_object(
      'resolucion_comercial', (select jsonb_build_object('estado', q.status, 'resolvio', public._com_label(q.decided_by), 'cuando', q.decided_at) from public.com_requests q where q.id = a.request_id),
      'eventos', (select jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.at, 'actor', public._com_label(e.actor_id), 'destinatario', public._com_label(e.recipient_id),
                   'push', (select j.status || coalesce(' · ' || j.last_error, '') from public.push_jobs j where j.notification_id = e.notification_id), 'detalle', e.detail) order by e.id)
                  from public.com_alarm_events e where e.alarm_id = a.id)) order by a.raised_at desc)
    from public.com_alarms a where a.raised_at >= p_from and a.raised_at < p_to + 1), '[]'::jsonb);
end; $$;
create or replace function public.com_alarm_settings() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st public.com_settings; pr text[] := '{}';
begin
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into st from public.com_settings where id = 'DEFAULT';
  if st.alarm_initial_user is null then pr := pr || 'Falta el destinatario inicial (la alarma no se puede pedir).'::text;
  elsif public._com_alarm_initial() is null then pr := pr || 'El destinatario inicial guardado NO está activo o no tiene permiso de aprobación.'::text; end if;
  if cardinality(st.alarm_escalation_users) = 0 then pr := pr || 'Faltan destinatarios de escalamiento (la alarma no se puede pedir).'::text;
  elsif cardinality(public._com_alarm_escalation()) < cardinality(st.alarm_escalation_users) then pr := pr || 'Algún destinatario de escalamiento guardado NO está activo: no se reemplaza automáticamente.'::text; end if;
  return jsonb_build_object('initial_user', st.alarm_initial_user, 'escalation_users', to_jsonb(st.alarm_escalation_users),
    'efectivos', jsonb_build_object('inicial', public._com_label(public._com_alarm_initial()), 'escalamiento', (select coalesce(jsonb_agg(public._com_label(x)), '[]') from unnest(public._com_alarm_escalation()) x)),
    'guardados', (select coalesce(jsonb_agg(jsonb_build_object('id', x, 'nombre', public._com_label(x), 'activo', exists (select 1 from public.profiles p where p.id = x and p.status = 'ACTIVO'))), '[]') from unnest(st.alarm_escalation_users) x),
    'problemas', to_jsonb(pr), 'escala_en_segundos', st.alarm_escalate_seconds);
end; $$;
create or replace function public.com_set_alarm_settings(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare ini uuid := nullif(p->>'initial_user', '')::uuid; esc uuid[] := (select coalesce(array_agg(distinct x::uuid), '{}') from jsonb_array_elements_text(coalesce(p->'escalation_users', '[]')) x);
  antes jsonb;
begin
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;   -- B-AL-04
  -- B-AL-03: configuración EXPLÍCITA y COMPLETA (no se guarda «vacío» por accidente)
  if ini is null or cardinality(esc) = 0 then raise exception 'INCOMPLETE: elegí el destinatario inicial y al menos un destinatario de escalamiento' using errcode = '23514'; end if;
  if not exists (select 1 from public.profiles where id = ini and status = 'ACTIVO' and public.user_has_perm(id, 'com.approve')) then
    raise exception 'BAD_RECIPIENT: el destinatario inicial debe estar ACTIVO y tener permiso de aprobación' using errcode = '23514'; end if;
  if exists (select 1 from unnest(esc) x where not exists (select 1 from public.profiles where id = x and status = 'ACTIVO' and role = 'ADMIN')) then
    raise exception 'BAD_RECIPIENT: el escalamiento solo puede dirigirse a Administradores Generales ACTIVOS (suplentes por regla)' using errcode = '23514'; end if;
  select jsonb_build_object('initial_user', alarm_initial_user, 'escalation_users', to_jsonb(alarm_escalation_users)) into antes from public.com_settings where id = 'DEFAULT';
  update public.com_settings set alarm_initial_user = ini, alarm_escalation_users = esc where id = 'DEFAULT';
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), 'COM_ALARM_SETTINGS', 'com_settings', 'DEFAULT', antes, jsonb_build_object('initial_user', ini, 'escalation_users', to_jsonb(esc)));
  return public.com_alarm_settings();
end; $$;
-- B-AL-02: el enlace del push (#/autorizaciones?alarma_n=<aviso>) abre ESA alarma. Solo responde al DESTINATARIO de ese aviso.
create or replace function public.com_alarm_by_notification(p_notification uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); a public.com_alarms;
begin
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();
  select al.* into a from public.com_alarm_events e join public.com_alarms al on al.id = e.alarm_id where e.notification_id = p_notification and e.recipient_id = me.id limit 1;
  if not found then return null; end if;
  return public._com_alarm_view(a, me.id);
end; $$;

-- ---------- 8) push: los avisos de la alarma usan la cola EXISTENTE (se conservan los 6 tipos vigentes) ----------
create or replace function public.queue_notification_push()
returns trigger language plpgsql security definer set search_path='public' as $$
begin
  if new.type in ('NUEVA_HOJA_PUBLICADA','HOJA_CORREGIDA','REQUEST_CREATED','REQUEST_APPROVED','REQUEST_REJECTED','REQUEST_OBSERVED',
                  'COM_ALARMA','COM_ALARMA_ESCALADA','COM_ALARMA_ATENDIDA') then   -- Autorizaciones comerciales: alarma urgente
    insert into public.push_jobs(notification_id,user_id)
    values(new.id,new.user_id)
    on conflict(notification_id) do nothing;
  end if;
  return new;
end; $$;

-- ---------- 9) privilegios ----------
do $$ declare f text; begin
  foreach f in array array['com_alarms', 'com_alarm_events', 'com_alarm_ops'] loop
    execute 'alter table public.' || f || ' enable row level security'; execute 'revoke all on public.' || f || ' from anon, authenticated'; end loop;
  foreach f in array array['com_alarm_raise(text,text,text,text,text,text)', 'com_alarm_attend(uuid,int)', 'com_my_alarms()', 'com_alarm_history(date,date)', 'com_set_alarm_settings(jsonb)',
                           'com_alarm_settings()', 'com_alarm_by_notification(uuid)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon'; execute 'grant execute on function public.' || f || ' to authenticated'; end loop;
  foreach f in array array['com_alarm_escalate_due()', '_com_alarm_initial()', '_com_alarm_escalation()', '_com_alarm_notify(public.com_alarms,uuid,text,text,text,uuid)',
                           '_com_alarm_view(public.com_alarms,uuid)', 'trg_com_alarm_events_immutable()'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated'; end loop;
end $$;
-- _com_admin() solo informa sobre el PROPIO usuario; las políticas de almacenamiento (000500) la evalúan con los privilegios de quien consulta
revoke all on function public._com_admin() from public, anon; grant execute on function public._com_admin() to authenticated;
-- (COMMIT propio retirado)
-- ==============================================================================================================
-- 20261201000500_comercial_admin_sesion_vigente.sql
-- ==============================================================================================================
-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · ADMINISTRADOR CON SESIÓN VIGENTE (auditoría B-AL-04) · NO APLICADA. Después de 000100 a 000400.
-- _is_general_admin() de la base verifica rol ADMIN y perfil ACTIVO, pero NO sessions_revoked_at. En las 19 funciones del módulo que lo usan
-- se reemplaza por _com_admin() (= _com_active(): token posterior a la revocación + Administrador General). Ningún otro cambio.
-- Generado por tools/gen_com_admin_sesion.py desde el texto exacto vigente. Funciones: _com_can_see_full, com_approvers, com_client_finance, com_config, com_decide, com_dispatch_stats, com_import_clients, com_kpi_for_client, com_list, com_my_notifications, com_order_alerts, com_report, com_search_clients, com_set_assignment, com_set_comp_type, com_set_routing, com_set_settings, com_sources_status, com_track
-- =====================================================================================================================
-- (BEGIN propio retirado: corre dentro de la transacción única)
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
-- (COMMIT propio retirado)
-- ==============================================================================================================
-- 20261201000600_comercial_modulo_historial.sql
-- ==============================================================================================================
-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · V4 · MÓDULO RESTRINGIBLE + HISTORIAL COMPLETO POR VENDEDOR · NO APLICADA. Después de 000100 a 000500.
--  · B-W04: el módulo COMERCIAL se puede RESTRINGIR por usuario como los demás (pantalla de Usuarios, Edge admin-users y SQL alineados):
--    la restricción de profiles se recrea CONSERVANDO los módulos vigentes y agregando COMERCIAL; module_permissions mapea sus 4 permisos
--    (los mismos de rules.js). user_has_perm ya descuenta módulos restringidos: la restricción vale en TODAS las RPC del módulo.
--  · Historial: com_history (paginación por CURSOR estable, filtros, alcance en el servidor) y com_request_detail (misma vista y privacidad
--    que el resto del módulo; «no existe» y «no es tuya» responden IGUAL).
-- =====================================================================================================================
-- (BEGIN propio retirado: corre dentro de la transacción única)
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
-- (COMMIT propio retirado)
-- ==============================================================================================================
-- 20261201000700_comercial_sesion_vigente_total.sql
-- ==============================================================================================================
-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · V4 · SESIÓN VIGENTE EN TODAS LAS RPC (auditoría B-W01) · NO APLICADA. Después de 000100 a 000600.
-- Cada RPC expuesta del módulo verifica PRIMERO perfil activo y token posterior a la revocación (= _com_active / auth_has_perm de la base), antes de
-- evaluar cualquier permiso alternativo. Ningún otro cambio en las funciones. Generado por tools/gen_com_sesion_guard.py desde el texto final.
-- RPC (32): com_alarm_attend, com_alarm_by_notification, com_alarm_history, com_alarm_raise, com_alarm_settings, com_approvers, com_client_finance, com_config, com_create_request, com_decide, com_dispatch_stats, com_history, com_import_clients, com_ingest, com_ingest_error, com_kpi_for_client, com_list, com_my_alarms, com_my_notifications, com_order_alerts, com_register_source_file, com_report, com_request_detail, com_respond, com_search_clients, com_set_alarm_settings, com_set_assignment, com_set_comp_type, com_set_routing, com_set_settings, com_sources_status, com_track
-- =====================================================================================================================
-- (BEGIN propio retirado: corre dentro de la transacción única)
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regprocedure('public.com_history(text,jsonb,jsonb,integer)') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: aplicar antes 000600. No se modificó nada.'; END IF;
END $guard$;
create or replace function public._com_require_session() returns void language plpgsql stable security definer set search_path = public as $$
begin
  if (public._com_active()).id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
end; $$;
revoke all on function public._com_require_session() from public, anon, authenticated;

-- com_alarm_attend
create or replace function public.com_alarm_attend(p_id uuid, p_version int) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); a public.com_alarms; como text; u uuid;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();
  select * into a from public.com_alarms where id = p_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  como := case when me.id = a.initial_user then 'DESTINATARIO_INICIAL' when me.id = any(a.escalated_to) then 'ESCALAMIENTO'
               when public._com_admin() then 'ADMINISTRADOR_GENERAL' end;
  if como is null then
    -- se REGISTRA el intento y se RESPONDE el rechazo (sin excepción: una excepción desharía también el registro). La alarma no cambia.
    insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (a.id, 'INTENTO_ATENDER_RECHAZADO', me.id, jsonb_build_object('motivo', 'sin autorización'));
    return jsonb_build_object('ok', false, 'code', 'FORBIDDEN', 'message', 'No sos destinatario de esta alarma.'); end if;
  -- O-AL-05: hay conflicto SOLO si la alarma ya NO está pendiente (otra persona la atendió). Un cambio de versión por el ESCALAMIENTO no
  -- bloquea a un destinatario autorizado; la doble toma sigue impedida por el bloqueo de la fila (FOR UPDATE) y el estado.
  if a.status <> 'PENDIENTE_ATENCION' then
    raise exception 'CONFLICT: la alarma ya fue atendida por % (%)', coalesce((select full_name from public.profiles where id = a.attended_by), '—'), a.attended_at using errcode = '40001'; end if;
  update public.com_alarms set status = 'ATENDIDA', attended_by = me.id, attended_at = now(), attended_as = como, seconds_to_attend = extract(epoch from now() - raised_at)::int, version = version + 1
   where id = a.id returning * into a;
  insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (a.id, 'ATENDIDA', me.id, jsonb_build_object('como', como, 'segundos', a.seconds_to_attend, 'escalada', a.escalated_at is not null));
  -- se informa a quien la pidió y a los demás destinatarios (las alertas de la app se detienen al ver ATENDIDA)
  foreach u in array (array[a.raised_by, a.initial_user] || a.escalated_to) loop
    if u is distinct from me.id then perform public._com_alarm_notify(a, u, 'COM_ALARMA_ATENDIDA', 'Alarma comercial ATENDIDA', 'Pedido ' || a.order_ref || ' · atendida por ' || me.full_name, me.id); end if;
  end loop;
  return jsonb_build_object('ok', true, 'id', a.id, 'number', a.number, 'status', a.status, 'attended_as', como, 'seconds_to_attend', a.seconds_to_attend, 'request_id', a.request_id);
end; $$;

-- com_alarm_by_notification
create or replace function public.com_alarm_by_notification(p_notification uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); a public.com_alarms;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();
  select al.* into a from public.com_alarm_events e join public.com_alarms al on al.id = e.alarm_id where e.notification_id = p_notification and e.recipient_id = me.id limit 1;
  if not found then return null; end if;
  return public._com_alarm_view(a, me.id);
end; $$;

-- com_alarm_history
create or replace function public.com_alarm_history(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;   -- B-AL-04: también rechaza un token REVOCADO
  return coalesce((select jsonb_agg(public._com_alarm_view(a, auth.uid()) || jsonb_build_object(
      'resolucion_comercial', (select jsonb_build_object('estado', q.status, 'resolvio', public._com_label(q.decided_by), 'cuando', q.decided_at) from public.com_requests q where q.id = a.request_id),
      'eventos', (select jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.at, 'actor', public._com_label(e.actor_id), 'destinatario', public._com_label(e.recipient_id),
                   'push', (select j.status || coalesce(' · ' || j.last_error, '') from public.push_jobs j where j.notification_id = e.notification_id), 'detalle', e.detail) order by e.id)
                  from public.com_alarm_events e where e.alarm_id = a.id)) order by a.raised_at desc)
    from public.com_alarms a where a.raised_at >= p_from and a.raised_at < p_to + 1), '[]'::jsonb);
end; $$;

-- com_alarm_raise
create or replace function public.com_alarm_raise(p_order_ref text, p_sheet_key text, p_client_name text, p_client_cuit text, p_reason text, p_op_id text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); a public.com_alarms; o public.com_alarm_ops; q public.com_requests; ini uuid; st public.com_settings;
  ref text := upper(btrim(coalesce(p_order_ref, ''))); op text := btrim(coalesce(p_op_id, '')); res jsonb; cname text;
  aviso constant text := 'Ese identificador de operación ya se usó para otra operación. Reintentá desde la pantalla.';
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null or not (public.user_has_perm(me.id, 'com.track') or public._com_admin()) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if ref = '' or coalesce(btrim(p_sheet_key), '') = '' then raise exception 'BAD_ORDER: indicá el pedido y la hoja' using errcode = '22023'; end if;
  if length(op) < 6 then raise exception 'BAD_OP: falta el identificador de la operación' using errcode = '22023'; end if;   -- B-W02: obligatorio (sin él no hay idempotencia)
  -- 1) IDEMPOTENCIA (B-AL-06 / B-W02): las llamadas con el mismo op_id se ordenan; una operación YA RESPONDIDA devuelve SIEMPRE la misma respuesta
  --    (también si la alarma ya se atendió o escaló). Reutilizarla para OTRO usuario, pedido u hoja se rechaza sin datos y se registra.
  perform pg_advisory_xact_lock(hashtext('com_alarm_op:' || op));
  select * into o from public.com_alarm_ops where op_id = op;
  if found then
    if o.user_id = me.id and o.order_ref = ref and o.sheet_key = p_sheet_key then return o.result || jsonb_build_object('repeated', true); end if;
    if o.alarm_id is not null then
      insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (o.alarm_id, 'OP_ID_REUTILIZADO_RECHAZADO', me.id,
        jsonb_build_object('op_id', op, 'pedido_pedido', btrim(p_order_ref), 'hoja_pedida', p_sheet_key, 'difiere', array_remove(array[
          case when o.user_id <> me.id then 'usuario' end, case when o.order_ref <> ref then 'pedido' end, case when o.sheet_key <> p_sheet_key then 'hoja' end], null)));
    end if;
    insert into public.audit_log(actor_id, action, target_type, target_id, after) values (me.id, 'COM_ALARM_OP_ID_REUSE', 'com_alarm_ops', op, jsonb_build_object('pedido', btrim(p_order_ref), 'hoja', p_sheet_key));
    return jsonb_build_object('ok', false, 'code', 'OP_ID_CONFLICT', 'message', aviso);
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then raise exception 'REASON_REQUIRED: indicá el motivo (al menos 10 caracteres)' using errcode = '23514'; end if;
  -- 2) ALCANCE (B-W02 / IND-S02): el pedido debe estar reservado en esa hoja Y el usuario debe poder operar esa hoja (misma regla que _draft: dueño,
  --    routes.manage_all_drafts o Administrador General). «Hoja inexistente» y «sin permiso» responden IGUAL (no se revela existencia).
  if not exists (select 1 from public.order_reservations r join public.route_drafts d on d.client_sheet_key = r.sheet_key
                  where upper(btrim(r.order_id)) = ref and r.sheet_key = p_sheet_key
                    and (d.owner_id = me.id or public.user_has_perm(me.id, 'routes.manage_all_drafts') or public._com_admin())) then
    raise exception 'ORDER_NOT_IN_SHEET: el pedido no pertenece a una hoja que puedas operar' using errcode = '23514'; end if;
  -- 3) una sola alarma ACTIVA por pedido
  perform pg_advisory_xact_lock(hashtext('com_alarm:' || ref));
  select * into a from public.com_alarms where upper(btrim(order_ref)) = ref and status = 'PENDIENTE_ATENCION';
  if found then
    insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (a.id, 'DUPLICADA_EXISTENTE', me.id, jsonb_build_object('op_id', op, 'motivo', btrim(p_reason)));
    if a.raised_by = me.id or a.initial_user = me.id or me.id = any(a.escalated_to) or public._com_admin() then
      res := jsonb_build_object('ok', true, 'id', a.id, 'number', a.number, 'status', a.status, 'existing', true);
    else   -- fuera de su alcance: respuesta MÍNIMA, sin número ni identificador de la alarma ajena
      res := jsonb_build_object('ok', true, 'existing', true, 'status', 'PENDIENTE_ATENCION', 'message', 'Ya hay una alarma activa para ese pedido, pedida por otra persona.');
    end if;
    insert into public.com_alarm_ops(op_id, user_id, order_ref, sheet_key, alarm_id, result) values (op, me.id, ref, p_sheet_key, a.id, res);   -- la deduplicación TAMBIÉN queda vinculada
    return res || jsonb_build_object('repeated', false);
  end if;
  -- 4) alta
  ini := public._com_alarm_initial();
  if ini is null then raise exception 'ALARM_NOT_CONFIGURED: falta configurar (o no está activo) el destinatario inicial de la alarma. Avisá al Administrador General.' using errcode = '23514'; end if;
  if cardinality(public._com_alarm_escalation()) = 0 then raise exception 'ALARM_NOT_CONFIGURED: faltan destinatarios de escalamiento activos configurados. Avisá al Administrador General.' using errcode = '23514'; end if;
  select * into st from public.com_settings where id = 'DEFAULT';
  select * into q from public.com_requests where upper(btrim(coalesce(order_ref, ''))) = ref and status <> 'CANCELADA' order by created_at desc, number desc limit 1;
  begin
    insert into public.com_alarms(order_ref, sheet_key, route_id, request_id, branch, client_name, client_cuit, client_source, reason, raised_by, initial_user, escalate_at, op_id)
      values (btrim(p_order_ref), p_sheet_key, (select route_id from public.order_reservations where upper(btrim(order_id)) = ref and sheet_key = p_sheet_key limit 1), q.id,
              coalesce(q.branch, q.cartera_label), coalesce(q.client_snapshot->>'razon_social', left(btrim(p_client_name), 160)), coalesce(q.client_snapshot->>'cuit', nullif(regexp_replace(coalesce(p_client_cuit, ''), '\D', '', 'g'), '')),
              case when q.id is null then 'DECLARADO_POR_DESPACHO' else 'SOLICITUD_COMERCIAL' end, btrim(p_reason), me.id, ini, now() + make_interval(secs => st.alarm_escalate_seconds), op)
      returning * into a;
  exception when unique_violation then
    -- O-W02: última defensa DIFERENCIADA (los bloqueos ya ordenan las llamadas): se identifica la restricción, se AUDITA y se responde sin datos
    get stacked diagnostics cname = constraint_name;
    insert into public.audit_log(actor_id, action, target_type, target_id, after) values (me.id, 'COM_ALARM_UNIQUE_FALLBACK', 'com_alarms', op, jsonb_build_object('restriccion', cname, 'pedido', btrim(p_order_ref), 'hoja', p_sheet_key));
    if cname = 'com_alarms_one_active' then return jsonb_build_object('ok', false, 'code', 'RETRY', 'message', 'Otra alarma para ese pedido se registró en el mismo instante. Reintentá: vas a ver la alarma activa.'); end if;
    return jsonb_build_object('ok', false, 'code', 'OP_ID_CONFLICT', 'message', aviso);
  end;
  insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (a.id, 'CREADA', me.id, jsonb_build_object('op_id', op, 'pedido', a.order_ref, 'hoja', a.sheet_key, 'motivo', a.reason, 'escala_a_las', a.escalate_at));
  perform public._com_alarm_notify(a, ini, 'COM_ALARMA', 'APROBACIÓN COMERCIAL URGENTE', 'Pedido ' || a.order_ref || ' · solicitada por ' || me.full_name || ' · tocá para ATENDER', me.id);
  res := jsonb_build_object('ok', true, 'id', a.id, 'number', a.number, 'status', 'PENDIENTE_ATENCION', 'existing', false, 'escalate_at', a.escalate_at);
  insert into public.com_alarm_ops(op_id, user_id, order_ref, sheet_key, alarm_id, result) values (op, me.id, ref, p_sheet_key, a.id, res);
  return res || jsonb_build_object('repeated', false);
end; $$;

-- com_alarm_settings
create or replace function public.com_alarm_settings() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st public.com_settings; pr text[] := '{}';
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into st from public.com_settings where id = 'DEFAULT';
  if st.alarm_initial_user is null then pr := pr || 'Falta el destinatario inicial (la alarma no se puede pedir).'::text;
  elsif public._com_alarm_initial() is null then pr := pr || 'El destinatario inicial guardado NO está activo o no tiene permiso de aprobación.'::text; end if;
  if cardinality(st.alarm_escalation_users) = 0 then pr := pr || 'Faltan destinatarios de escalamiento (la alarma no se puede pedir).'::text;
  elsif cardinality(public._com_alarm_escalation()) < cardinality(st.alarm_escalation_users) then pr := pr || 'Algún destinatario de escalamiento guardado NO está activo: no se reemplaza automáticamente.'::text; end if;
  return jsonb_build_object('initial_user', st.alarm_initial_user, 'escalation_users', to_jsonb(st.alarm_escalation_users),
    'efectivos', jsonb_build_object('inicial', public._com_label(public._com_alarm_initial()), 'escalamiento', (select coalesce(jsonb_agg(public._com_label(x)), '[]') from unnest(public._com_alarm_escalation()) x)),
    'guardados', (select coalesce(jsonb_agg(jsonb_build_object('id', x, 'nombre', public._com_label(x), 'activo', exists (select 1 from public.profiles p where p.id = x and p.status = 'ACTIVO'))), '[]') from unnest(st.alarm_escalation_users) x),
    'problemas', to_jsonb(pr), 'escala_en_segundos', st.alarm_escalate_seconds);
end; $$;

-- com_approvers
create or replace function public.com_approvers() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', public._com_label(p.id)) order by p.full_name) from public.profiles p where p.status = 'ACTIVO' and public.user_has_perm(p.id, 'com.approve')), '[]'::jsonb);
end; $$;

-- com_client_finance
create or replace function public.com_client_finance(p_client uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.com_clients; i public.com_ingests; b public.com_cc_balances; ls bigint;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
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

-- com_config
create or replace function public.com_config() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active();
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
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

-- com_create_request
create or replace function public.com_create_request(p_kind text, p_client uuid, p_order_ref text, p_terms jsonb, p_notes text, p_op_id text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles; asg public.com_user_assignments; rt public.com_routing; c public.com_clients; q public.com_requests; t jsonb; n int; ck text;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
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

-- com_decide
create or replace function public.com_decide(p_id uuid, p_version int, p_decision text, p_terms jsonb, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles; q public.com_requests; c public.com_clients; t jsonb; st text; asn text; n int; ev text;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
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

-- com_dispatch_stats
create or replace function public.com_dispatch_stats(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'paradas')::int desc) from (
    select jsonb_build_object('transportista', coalesce(ca.name, r.carrier_id), 'zona', coalesce(nullif(s.zone, ''), 'SIN ZONA'), 'hojas', count(distinct r.id), 'paradas', count(*),
      'entregadas', count(*) filter (where s.outcome = 'ENTREGADO')) x
    from public.routes r join public.route_stops s on s.route_id = r.id left join public.carriers ca on ca.id = r.carrier_id
    where coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO' and r.published_at >= p_from and r.published_at < p_to + 1 group by coalesce(ca.name, r.carrier_id), coalesce(nullif(s.zone, ''), 'SIN ZONA')) t), '[]'::jsonb);
end; $$;

-- com_history
create or replace function public.com_history(p_scope text, p_filters jsonb, p_cursor jsonb, p_limit int default 25) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); adm boolean := public._com_admin(); f jsonb := coalesce(p_filters, '{}'::jsonb);
  lim int := greatest(1, least(coalesce(p_limit, 25), 100)); cc timestamptz; ci uuid; rows jsonb; n int;
  qq text := public._com_norm(f->>'q'); qd text := regexp_replace(coalesce(f->>'q', ''), '\D', '', 'g');
  st text[] := (select array_agg(x) from jsonb_array_elements_text(case when jsonb_typeof(f->'status') = 'array' then f->'status' else '[]'::jsonb end) x);
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
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

-- com_import_clients
create or replace function public.com_import_clients(p_file_name text, p_sha256 text, p_rows jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare imp bigint; r jsonb; t text; n text; v boolean; cu text; cur public.com_clients; ins int := 0; upd int := 0; same int := 0; rej jsonb := '[]'; aft jsonb; bef jsonb;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
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

-- com_ingest
create or replace function public.com_ingest(p_kind text, p_meta jsonb, p_rows jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare g public.com_ingests; b int := coalesce((p_meta->>'batch')::int, 1); nb int := greatest(1, coalesce((p_meta->>'batches')::int, 1)); r jsonb; cu text; k text; d public.com_sc_documents;
  amt numeric; pre text; cls text; dt date; st jsonb := '{}'; c public.com_clients; nm text;
  add_ int := 0; seen int := 0; conf int := 0; skip_cuit int := 0; skip_san int := 0; unk int := 0;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
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

-- com_ingest_error
create or replace function public.com_ingest_error(p_kind text, p_meta jsonb, p_error text) returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if public._com_active() is null or not public.user_has_perm(auth.uid(), 'com.sources.upload') then return; end if;
  insert into public.com_ingests(kind, content_hash, file_name, loaded_at, by_user, status, error) values (p_kind, coalesce(p_meta->>'hash', 'error-' || gen_random_uuid()), left(p_meta->>'file_name', 200),
    (p_meta->>'loaded_at')::timestamptz, auth.uid(), 'ERROR', left(p_error, 400)) on conflict (kind, content_hash, loaded_at, by_user) do update set error = excluded.error, status = case when com_ingests.status = 'OK' then 'OK' else 'ERROR' end;
end; $$;

-- com_kpi_for_client
create or replace function public.com_kpi_for_client(p_client uuid, p_at timestamptz default now()) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if (public._com_active()).id is null or not (public._com_admin() or public.user_has_perm(auth.uid(),'com.request') or public.user_has_perm(auth.uid(),'com.approve')) then raise exception 'FORBIDDEN' using errcode='42501'; end if;
  if not public._com_admin() and not public.user_has_perm(auth.uid(),'com.request') and not exists(select 1 from public.com_requests where client_id=p_client and assigned_approver_id=auth.uid()) then raise exception 'FORBIDDEN_CLIENT' using errcode='42501'; end if;
  return public._com_kpi_raw(p_client,p_at) || (select jsonb_build_object('provisional',not s.kpi_source_verified,'label',case when s.kpi_source_verified then null else 'RECOMENDACIÓN PROVISORIA — BASADA EN COMPROBANTES DISPONIBLES' end) from public.com_settings s where id='DEFAULT');
end; $$;

-- com_list
create or replace function public.com_list(p_scope text, p_status text default null, p_limit int default 30, p_offset int default 0) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); adm boolean := public._com_admin();
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_scope = 'MIS' and not public.user_has_perm(me.id, 'com.request') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_scope = 'BANDEJA' and not (public.user_has_perm(me.id, 'com.approve') or adm) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_scope = 'TODAS' and not adm then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(public._com_view(q, true) order by q.status <> 'PENDIENTE', q.updated_at desc) from (
    select * from public.com_requests q where
      ((p_scope = 'MIS' and q.requested_by = me.id) or (p_scope = 'BANDEJA' and (q.assigned_approver_id = me.id or adm)) or p_scope = 'TODAS')
      and (p_status is null or q.status = p_status) order by q.status <> 'PENDIENTE', q.updated_at desc limit greatest(1, least(coalesce(p_limit, 30), 100)) offset greatest(0, coalesce(p_offset, 0))) q), '[]'::jsonb);
end; $$;

-- com_my_alarms
create or replace function public.com_my_alarms() returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active();
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();   -- perezoso: adelanta el escalamiento si hay alguien conectado (el reloj sigue siendo el del servidor)
  return coalesce((select jsonb_agg(public._com_alarm_view(a, me.id) order by a.raised_at desc) from public.com_alarms a
    where (a.status = 'PENDIENTE_ATENCION' or a.attended_at > now() - interval '12 hours')
      and (a.raised_by = me.id or a.initial_user = me.id or me.id = any(a.escalated_to) or public._com_admin())), '[]'::jsonb);
end; $$;

-- com_my_notifications
create or replace function public.com_my_notifications() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  return (select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'request_id', n.request_id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'at', n.created_at, 'read', n.read_at is not null) order by n.created_at desc), '[]'::jsonb)
  from (select * from public.com_notifications where user_id = auth.uid() and (public._com_active()).id is not null and (public._com_admin() or public.user_has_perm(auth.uid(),'com.request') or public.user_has_perm(auth.uid(),'com.approve')) order by created_at desc limit 50) n);
end; $$;

-- com_order_alerts
create or replace function public.com_order_alerts(p_orders text[], p_cuits text[]) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active();
  o text[] := (select coalesce(array_agg(distinct upper(btrim(x))), '{}') from unnest(coalesce(p_orders, '{}')) x where coalesce(btrim(x), '') <> '');
  c text[] := (select coalesce(array_agg(distinct regexp_replace(x, '\D', '', 'g')), '{}') from unnest(coalesce(p_cuits, '{}')) x where length(regexp_replace(coalesce(x, ''), '\D', '', 'g')) in (7, 8, 11));
  todas boolean; aprob boolean; propias boolean;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
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

-- com_register_source_file
create or replace function public.com_register_source_file(p_kind text, p_sha256 text, p_size bigint, p_name text, p_mime text, p_path text) returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.com_settings; f public.com_source_files; v int; ok boolean;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
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

-- com_report
create or replace function public.com_report(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
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

-- com_request_detail
create or replace function public.com_request_detail(p_id uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); q public.com_requests;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into q from public.com_requests where id = p_id;
  if not found or not ((q.requested_by = me.id and public.user_has_perm(me.id, 'com.request')) or (q.assigned_approver_id = me.id and public.user_has_perm(me.id, 'com.approve')) or public._com_admin()) then
    raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return public._com_view(q, true);
end; $$;

-- com_respond
create or replace function public.com_respond(p_id uuid, p_version int, p_accept boolean, p_comment text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles; q public.com_requests; n int;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
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

-- com_search_clients
create or replace function public.com_search_clients(p_q text, p_limit int default 12) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare q text := public._com_norm(p_q); d text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
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

-- com_set_alarm_settings
create or replace function public.com_set_alarm_settings(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare ini uuid := nullif(p->>'initial_user', '')::uuid; esc uuid[] := (select coalesce(array_agg(distinct x::uuid), '{}') from jsonb_array_elements_text(coalesce(p->'escalation_users', '[]')) x);
  antes jsonb;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;   -- B-AL-04
  -- B-AL-03: configuración EXPLÍCITA y COMPLETA (no se guarda «vacío» por accidente)
  if ini is null or cardinality(esc) = 0 then raise exception 'INCOMPLETE: elegí el destinatario inicial y al menos un destinatario de escalamiento' using errcode = '23514'; end if;
  if not exists (select 1 from public.profiles where id = ini and status = 'ACTIVO' and public.user_has_perm(id, 'com.approve')) then
    raise exception 'BAD_RECIPIENT: el destinatario inicial debe estar ACTIVO y tener permiso de aprobación' using errcode = '23514'; end if;
  if exists (select 1 from unnest(esc) x where not exists (select 1 from public.profiles where id = x and status = 'ACTIVO' and role = 'ADMIN')) then
    raise exception 'BAD_RECIPIENT: el escalamiento solo puede dirigirse a Administradores Generales ACTIVOS (suplentes por regla)' using errcode = '23514'; end if;
  select jsonb_build_object('initial_user', alarm_initial_user, 'escalation_users', to_jsonb(alarm_escalation_users)) into antes from public.com_settings where id = 'DEFAULT';
  update public.com_settings set alarm_initial_user = ini, alarm_escalation_users = esc where id = 'DEFAULT';
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), 'COM_ALARM_SETTINGS', 'com_settings', 'DEFAULT', antes, jsonb_build_object('initial_user', ini, 'escalation_users', to_jsonb(esc)));
  return public.com_alarm_settings();
end; $$;

-- com_set_assignment
create or replace function public.com_set_assignment(p_user uuid, p_channel text, p_branch text, p_cartera text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not exists (select 1 from public.profiles where id = p_user and role = 'COMERCIAL') then raise exception 'NOT_COMERCIAL: el usuario no tiene rol Comercial' using errcode = '23514'; end if;
  insert into public.com_user_assignments(user_id, channel, branch, cartera_label, updated_by) values (p_user, p_channel, case when p_channel = 'SUCURSAL' then p_branch end, case when p_channel = 'CARTERA' then nullif(btrim(p_cartera), '') end, auth.uid())
    on conflict (user_id) do update set channel = excluded.channel, branch = excluded.branch, cartera_label = excluded.cartera_label, updated_by = auth.uid(), updated_at = now();
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_ASSIGNMENT', 'profiles', p_user::text, jsonb_build_object('channel', p_channel, 'branch', p_branch, 'cartera', p_cartera));
  return jsonb_build_object('user_id', p_user, 'channel', p_channel);
end; $$;

-- com_set_comp_type
create or replace function public.com_set_comp_type(p_prefix text, p_class text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  insert into public.com_comp_types(prefix, class, updated_by) values (upper(p_prefix), p_class, auth.uid()) on conflict (prefix) do update set class = excluded.class, updated_by = auth.uid(), updated_at = now();
  update public.com_sc_documents set class = p_class, status = case when status = 'SIN_CLASIFICAR' then case when amount is null then 'SIN_IMPORTE' when doc_date is null then 'SIN_FECHA' else 'OK' end else status end where prefix = upper(p_prefix);
  update public.com_reconciliation_issues set status = 'RESUELTA' where kind = 'TIPO_SIN_CLASIFICAR' and detail->>'prefijo' = upper(p_prefix) and status = 'ABIERTA';
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_COMP_TYPE', 'com_comp_types', upper(p_prefix), jsonb_build_object('class', p_class));
  return jsonb_build_object('prefix', upper(p_prefix), 'class', p_class);
end; $$;

-- com_set_routing
create or replace function public.com_set_routing(p_channel_key text, p_approver uuid) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_approver is not null and (public._com_active(p_approver) is null or not public.user_has_perm(p_approver, 'com.approve')) then
    raise exception 'BAD_APPROVER: el aprobador debe estar ACTIVO y tener permiso de aprobación' using errcode = '23514'; end if;
  update public.com_routing set approver_user_id = p_approver, updated_by = auth.uid(), updated_at = now() where channel_key = p_channel_key;
  if not found then raise exception 'BAD_CHANNEL' using errcode = '23514'; end if;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'COM_ROUTING', 'com_routing', p_channel_key, jsonb_build_object('approver', p_approver));
  return jsonb_build_object('channel_key', p_channel_key, 'approver', public._com_label(p_approver));
end; $$;

-- com_set_settings
create or replace function public.com_set_settings(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.com_settings;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
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

-- com_sources_status
create or replace function public.com_sources_status() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
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

-- com_track
create or replace function public.com_track(p_q text, p_open_only boolean default false, p_limit int default 20, p_offset int default 0) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); q text := public._com_norm(p_q); d text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null or not (public.user_has_perm(me.id, 'com.track') or public._com_admin()) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(public._com_view(r, public._com_can_see_full(r)) order by r.updated_at desc) from (
    select * from public.com_requests r where (not p_open_only or r.status in ('PENDIENTE', 'DEVUELTA'))
      and (coalesce(btrim(p_q), '') = '' or public._com_norm(r.client_snapshot->>'razon_social') like '%' || q || '%' or public._com_norm(r.client_snapshot->>'nombre') like '%' || q || '%'
           or (length(d) >= 3 and ((r.client_snapshot->>'cuit') like '%' || d || '%' or (r.client_snapshot->>'doc_number') like '%' || d || '%')) or public._com_norm(r.order_ref) like '%' || q || '%' or r.number ilike '%' || p_q || '%')
    order by r.updated_at desc limit greatest(1, least(coalesce(p_limit, 20), 50)) offset greatest(0, coalesce(p_offset, 0))) r), '[]'::jsonb);
end; $$;

-- (COMMIT propio retirado)
-- ==============================================================================================================
-- 20261201000800_comercial_v4_alarma_escala_push.sql
-- ==============================================================================================================
-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · V4 · ALARMA: PAGINACIÓN (O-W05) y PUSH POR DESTINATARIO/DISPOSITIVO (O-W04) · NO APLICADA.
-- Después de 000100 a 000700. Agrega funciones de LECTURA, endurece com_config (B-W04) y el modo del KPI (sección 5: columna kpi_mode, predeterminado PROVISORIO = sin cambios). Todas validan la sesión vigente PRIMERO (_com_active).
-- =====================================================================================================================
-- (BEGIN propio retirado: corre dentro de la transacción única)
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regclass('public.com_alarm_ops') IS NULL OR to_regprocedure('public.com_history(text,jsonb,jsonb,integer)') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: aplicar antes 000100 a 000700. No se modificó nada.'; END IF;
END $guard$;

-- O-W05 · mis alarmas con TOPE: las pendientes más recientes primero (máx. p_limit) + el total, para no cargar decenas de tarjetas ni de filas
create or replace function public.com_my_alarms_page(p_limit int default 20) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); lim int := greatest(1, least(coalesce(p_limit, 20), 50)); items jsonb; tot int;
begin
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();
  with vis as (select a.* from public.com_alarms a where (a.status = 'PENDIENTE_ATENCION' or a.attended_at > now() - interval '12 hours')
                 and (a.raised_by = me.id or a.initial_user = me.id or me.id = any(a.escalated_to) or public._com_admin()))
  select (select count(*) from vis where status = 'PENDIENTE_ATENCION'),
         coalesce((select jsonb_agg(public._com_alarm_view(v, me.id) order by (v.status = 'PENDIENTE_ATENCION') desc, v.raised_at desc, v.id desc)
                     from (select * from vis order by (status = 'PENDIENTE_ATENCION') desc, raised_at desc, id desc limit lim) v), '[]'::jsonb)
    into tot, items;
  return jsonb_build_object('items', items, 'total_pending', tot, 'has_more', (select count(*) from public.com_alarms a where (a.status = 'PENDIENTE_ATENCION' or a.attended_at > now() - interval '12 hours')
    and (a.raised_by = me.id or a.initial_user = me.id or me.id = any(a.escalated_to) or public._com_admin())) > lim, 'page_size', lim);
end; $$;

-- O-W05 · historial ADMINISTRATIVO de alarmas por CURSOR estable (raised_at, id)
create or replace function public.com_alarm_history_page(p_from date, p_to date, p_cursor jsonb, p_limit int default 25) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); lim int := greatest(1, least(coalesce(p_limit, 25), 100)); cc timestamptz; ci uuid; rows jsonb; n int;
begin
  if me.id is null or not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_cursor is not null then begin cc := (p_cursor->>'c')::timestamptz; ci := (p_cursor->>'i')::uuid; exception when others then raise exception 'BAD_CURSOR' using errcode = '22023'; end; end if;
  select coalesce(jsonb_agg(x order by (x->>'raised_at')::timestamptz desc, (x->>'id') desc), '[]'::jsonb), count(*) into rows, n from (
    select public._com_alarm_view(a, me.id) || jsonb_build_object(
      'resolucion_comercial', (select jsonb_build_object('estado', q.status, 'resolvio', public._com_label(q.decided_by), 'cuando', q.decided_at) from public.com_requests q where q.id = a.request_id),
      'eventos', (select jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.at, 'actor', public._com_label(e.actor_id), 'destinatario', public._com_label(e.recipient_id),
                   'push', (select j.status || coalesce(' · ' || j.last_error, '') from public.push_jobs j where j.notification_id = e.notification_id), 'detalle', e.detail) order by e.id)
                  from public.com_alarm_events e where e.alarm_id = a.id)) x
    from public.com_alarms a
    where a.raised_at >= coalesce(p_from, '-infinity'::date) and a.raised_at < coalesce(p_to, 'infinity'::date) + 1
      and (p_cursor is null or (a.raised_at, a.id) < (cc, ci))
    order by a.raised_at desc, a.id desc limit lim + 1) t;
  if n > lim then rows := rows - lim; end if;
  return jsonb_build_object('items', rows, 'has_more', n > lim, 'page_size', lim,
    'next_cursor', case when n > lim then jsonb_build_object('c', rows->(lim - 1)->>'raised_at', 'i', rows->(lim - 1)->>'id') end);
end; $$;

-- O-W04 · el sonido NO equivale a una suscripción push: dispositivos con push ACTIVO de cada destinatario configurado (Panel General)
create or replace function public.com_alarm_push_status() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); st public.com_settings;
begin
  if me.id is null or not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into st from public.com_settings where id = 'DEFAULT';
  return coalesce((select jsonb_agg(jsonb_build_object('rol', r.rol, 'usuario', public._com_label(r.uid),
      'dispositivos_activos', (select count(*) from public.push_subscriptions s where s.user_id = r.uid and s.revoked_at is null),
      'ultima_actualizacion', (select max(s.updated_at) from public.push_subscriptions s where s.user_id = r.uid and s.revoked_at is null)) order by r.ord)
    from (select 'INICIAL' rol, st.alarm_initial_user uid, 0 ord where st.alarm_initial_user is not null
          union all select 'ESCALAMIENTO', u, 1 from unnest(st.alarm_escalation_users) u) r), '[]'::jsonb);
end; $$;
-- O-W04 · ¿este usuario tiene push ACTIVO registrado en el servidor? (la alarma ofrece REACTIVAR si el navegador tiene permiso pero no hay registro)
create or replace function public.com_my_push_devices() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active();
begin
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object('activos', (select count(*) from public.push_subscriptions where user_id = me.id and revoked_at is null));
end; $$;

-- Sección 5 · separación segura de los KPI financieros NO verificados (WORK-K02 / Cianbox): modo PROVISORIO (actual, predeterminado) o DESHABILITADO.
-- Con DESHABILITADO el circuito de autorizaciones, el historial y la alarma siguen iguales (el KPI nunca bloqueó), pero no se calcula ni se muestra.
alter table public.com_settings add column kpi_mode text not null default 'PROVISORIO' check (kpi_mode in ('PROVISORIO', 'DESHABILITADO'));
create or replace function public.com_kpi_for_client(p_client uuid, p_at timestamptz default now()) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if (public._com_active()).id is null or not (public._com_admin() or public.user_has_perm(auth.uid(),'com.request') or public.user_has_perm(auth.uid(),'com.approve')) then raise exception 'FORBIDDEN' using errcode='42501'; end if;
  if not public._com_admin() and not public.user_has_perm(auth.uid(),'com.request') and not exists(select 1 from public.com_requests where client_id=p_client and assigned_approver_id=auth.uid()) then raise exception 'FORBIDDEN_CLIENT' using errcode='42501'; end if;
  -- Sección 5 de la orden V4: con el KPI DESHABILITADO no se calcula ni se muestra ninguna cifra no verificada (la solicitud guarda solo esta marca)
  if (select kpi_mode from public.com_settings where id = 'DEFAULT') = 'DESHABILITADO' then
    return jsonb_build_object('status', 'DESHABILITADO', 'provisional', true, 'detail', 'KPI DESHABILITADO — pendiente de verificar los informes de Cianbox. La autorización es manual.');
  end if;
  return public._com_kpi_raw(p_client,p_at) || (select jsonb_build_object('provisional',not s.kpi_source_verified,'label',case when s.kpi_source_verified then null else 'RECOMENDACIÓN PROVISORIA — BASADA EN COMPROBANTES DISPONIBLES' end) from public.com_settings s where id='DEFAULT');
end; $$;
create or replace function public.com_set_kpi_mode(p_mode text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); antes text;
begin
  if me.id is null or not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_mode not in ('PROVISORIO', 'DESHABILITADO') then raise exception 'BAD_MODE' using errcode = '22023'; end if;
  select kpi_mode into antes from public.com_settings where id = 'DEFAULT';
  update public.com_settings set kpi_mode = p_mode where id = 'DEFAULT';
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (me.id, 'COM_KPI_MODE', 'com_settings', 'DEFAULT', jsonb_build_object('kpi_mode', antes), jsonb_build_object('kpi_mode', p_mode));
  return jsonb_build_object('kpi_mode', p_mode);
end; $$;

-- B-W04 · com_config (texto EXACTO de 000700 + exigencia de algún permiso del módulo): un usuario con COMERCIAL restringido no recibe la configuración
create or replace function public.com_config() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active();
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  -- B-W04: con el módulo COMERCIAL restringido (o sin ningún permiso del módulo) no se entrega su configuración interna
  if not (public.user_has_perm(me.id, 'com.request') or public.user_has_perm(me.id, 'com.approve') or public.user_has_perm(me.id, 'com.track')
          or public.user_has_perm(me.id, 'com.sources.upload') or public._com_admin()) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object('settings', (select to_jsonb(s) - 'updated_by' from public.com_settings s where id = 'DEFAULT'),
    'my_assignment', (select to_jsonb(a) || jsonb_build_object('approver', public._com_label(r.approver_user_id)) from public.com_user_assignments a
       left join public.com_routing r on r.channel_key = case when a.channel = 'CARTERA' then 'CARTERA' else 'SUCURSAL:' || a.branch end where a.user_id = me.id),
    'is_admin', public._com_admin(), 'can_request', public.user_has_perm(me.id, 'com.request'), 'can_approve', public.user_has_perm(me.id, 'com.approve') or public._com_admin(),
    'can_track', public.user_has_perm(me.id, 'com.track') or public._com_admin(), 'can_upload', public.user_has_perm(me.id, 'com.sources.upload'),
    'routing', case when public._com_admin() then (select jsonb_agg(jsonb_build_object('channel_key', channel_key, 'approver_user_id', approver_user_id, 'approver', public._com_label(approver_user_id)) order by channel_key) from public.com_routing) end,
    'assignments', case when public._com_admin() then (select jsonb_agg(jsonb_build_object('user_id', p.id, 'name', p.full_name, 'channel', a.channel, 'branch', a.branch, 'cartera_label', a.cartera_label) order by p.full_name)
       from public.profiles p left join public.com_user_assignments a on a.user_id = p.id where p.role = 'COMERCIAL') end);
end; $$;

do $$ declare f text; begin
  foreach f in array array['com_my_alarms_page(integer)', 'com_alarm_history_page(date,date,jsonb,integer)', 'com_alarm_push_status()', 'com_my_push_devices()', 'com_set_kpi_mode(text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon'; execute 'grant execute on function public.' || f || ' to authenticated'; end loop;
end $$;
-- (COMMIT propio retirado)
-- ==============================================================================================================
-- 20261201000900_comercial_v5_permisos_kpi_fechas.sql
-- ==============================================================================================================
-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · V5 (auditoría Work V4, 15/11) · NO APLICADA. Después de 000100 a 000800.
-- Generada por tools/gen_v5.py desde el TEXTO EXACTO vigente de cada función, con reemplazos verificados.
--  · N-V4-01 · PERMISO ACTUAL en alarmas: lectura, enlace directo, atención y respuesta de emisión exigen el permiso efectivo de HOY
--    (user_has_perm descuenta módulos restringidos, también sobre permisos individuales). Una asignación histórica no da acceso.
--    Política de Dirección: la restricción COMERCIAL también rige para el Administrador General (_com_admin).
--    Alarmas e historial se CONSERVAN para auditoría y para los usuarios que siguen autorizados.
--  · N-V4-03 · KPI DESHABILITADO por defecto y DESDE la instalación; las fotos guardadas no se exponen mientras esté deshabilitado
--    (se conservan). Reactivarlo exige una referencia a la autorización de Dirección General, auditada.
--  · N-V4-05 · límites diarios en el horario operativo de Argentina (America/Argentina/Mendoza): historial y, por la revisión anticipatoria,
--    también historial de alarmas, informes y estadísticas de Despacho. No cambia datos ni el timezone global.
--  · N-V4-02 · push_session_valid: el handler de push comprueba la VIGENCIA de la sesión (claims completos, perfil activo, token posterior
--    a sessions_revoked_at y sesión existente) ANTES de reclamar trabajos. Solo para el servicio.
-- =====================================================================================================================
-- (BEGIN propio retirado: corre dentro de la transacción única)
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regprocedure('public.com_my_alarms_page(integer)') IS NULL OR to_regprocedure('public.com_set_kpi_mode(text)') IS NULL THEN
    RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: aplicar antes 000100 a 000800. No se modificó nada.'; END IF;
  IF to_regprocedure('public._com_alarm_role(public.com_alarms,uuid)') IS NOT NULL THEN RAISE EXCEPTION 'YA_APLICADA. No se modificó nada.'; END IF;
END $guard$;

-- ---------- N-V4-01 · administrador con sesión vigente y SIN la restricción COMERCIAL (política de Dirección) ----------
create or replace function public._com_admin() returns boolean language sql stable security definer set search_path = public as $$
  select (public._com_active()).id is not null and public._is_general_admin()
     and not exists (select 1 from public.profiles p where p.id = auth.uid() and 'COMERCIAL' = any(p.disabled_modules));
$$;
-- papel de un usuario frente a una alarma, con su permiso ACTUAL (null = sin acceso)
create or replace function public._com_alarm_role(a public.com_alarms, p_me uuid) returns text language sql stable security definer set search_path = public as $$
  select case
    when p_me = a.initial_user and public.user_has_perm(p_me, 'com.approve') then 'DESTINATARIO_INICIAL'
    when p_me = any(a.escalated_to) and public.user_has_perm(p_me, 'com.approve') then 'ESCALAMIENTO'
    when p_me = auth.uid() and public._com_admin() then 'ADMINISTRADOR_GENERAL'
    when p_me = a.raised_by and public.user_has_perm(p_me, 'com.track') then 'SOLICITANTE' end;
$$;

-- ---------- N-V4-05 · inicio del día ARGENTINO (America/Argentina/Mendoza) para todos los filtros por fecha del módulo ----------
create or replace function public._com_ar_day(p date) returns timestamptz language sql immutable set search_path = public as $$
  select p::timestamp at time zone 'America/Argentina/Mendoza';
$$;

-- ---------- N-V4-03 · KPI DESHABILITADO por defecto y en la instalación ----------
alter table public.com_settings alter column kpi_mode set default 'DESHABILITADO';
update public.com_settings set kpi_mode = 'DESHABILITADO' where id = 'DEFAULT';
drop function public.com_set_kpi_mode(text);
create or replace function public.com_set_kpi_mode(p_mode text, p_autorizacion text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); antes text;
begin
  if me.id is null or not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_mode not in ('PROVISORIO', 'DESHABILITADO') then raise exception 'BAD_MODE' using errcode = '22023'; end if;
  -- reactivar el KPI es una decisión EXPRESA de Dirección General: se exige la referencia escrita y queda auditada
  if p_mode = 'PROVISORIO' and length(btrim(coalesce(p_autorizacion, ''))) < 20 then
    raise exception 'AUTORIZACION_REQUERIDA: indicá la referencia a la autorización expresa de Dirección General para reactivar el KPI' using errcode = '23514'; end if;
  select kpi_mode into antes from public.com_settings where id = 'DEFAULT';
  update public.com_settings set kpi_mode = p_mode where id = 'DEFAULT';
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (me.id, 'COM_KPI_MODE', 'com_settings', 'DEFAULT',
    jsonb_build_object('kpi_mode', antes), jsonb_build_object('kpi_mode', p_mode, 'autorizacion', nullif(btrim(coalesce(p_autorizacion, '')), '')));
  return jsonb_build_object('kpi_mode', p_mode);
end; $$;

-- ---------- N-V4-02 · vigencia de la sesión para el handler de push (SOLO servicio) ----------
create or replace function public.push_session_valid(p_user uuid, p_iat numeric, p_session text) returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare p public.profiles;
begin
  if p_user is null or p_iat is null then return jsonb_build_object('ok', false, 'motivo', 'CLAIMS_INCOMPLETOS'); end if;
  select * into p from public.profiles where id = p_user;
  if not found or p.status <> 'ACTIVO' then return jsonb_build_object('ok', false, 'motivo', 'PERFIL_NO_ACTIVO'); end if;
  if p.sessions_revoked_at is not null and p_iat <= extract(epoch from p.sessions_revoked_at) then return jsonb_build_object('ok', false, 'motivo', 'SESION_REVOCADA'); end if;
  if p_session is not null and to_regclass('auth.sessions') is not null
     and not exists (select 1 from auth.sessions s where s.id::text = p_session and s.user_id = p_user) then return jsonb_build_object('ok', false, 'motivo', 'SESION_INEXISTENTE'); end if;
  return jsonb_build_object('ok', true);
end; $$;

-- _com_view (texto exacto vigente + reemplazos verificados)
create or replace function public._com_view(q public.com_requests, p_full boolean) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', q.id, 'number', q.number, 'kind', q.kind, 'status', q.status, 'client', q.client_snapshot, 'order_ref', q.order_ref, 'channel', q.channel, 'branch', q.branch,
    'cartera_label', q.cartera_label, 'requested_by', public._com_label(q.requested_by), 'assigned_approver', public._com_label(q.assigned_approver_id), 'assigned_approver_id', q.assigned_approver_id,
    'decided_by', public._com_label(q.decided_by), 'decided_as', q.decided_as, 'decided_at', q.decided_at, 'created_at', q.created_at, 'updated_at', q.updated_at, 'version', q.version,
    'current_terms', q.current_terms, 'final_terms', q.final_terms, 'original_terms', case when p_full then q.original_terms end, 'notes', case when p_full then q.notes end,
    'kpi', case when p_full then (case when (select kpi_mode from public.com_settings where id = 'DEFAULT') = 'DESHABILITADO'
      then jsonb_build_object('status', 'DESHABILITADO', 'provisional', true, 'detail', 'KPI DESHABILITADO — pendiente de verificar los informes de Cianbox. La autorización es manual.')
      else q.kpi_snapshot end) end,   -- N-V4-03: con el KPI deshabilitado no se EXPONE la foto guardada (se CONSERVA en la tabla)
    'timeline', (select jsonb_agg(jsonb_build_object('seq', e.seq, 'kind', e.kind, 'by', e.actor_label, 'at', e.at, 'reason', case when p_full then e.reason end,
       'assigned', public._com_label(e.assigned_approver_id), 'terms_after', case when p_full then e.terms_after end) order by e.seq) from public.com_request_events e where e.request_id = q.id));
$$;

-- com_alarm_history (texto exacto vigente + reemplazos verificados)
create or replace function public.com_alarm_history(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;   -- B-AL-04: también rechaza un token REVOCADO
  return coalesce((select jsonb_agg(public._com_alarm_view(a, auth.uid()) || jsonb_build_object(
      'resolucion_comercial', (select jsonb_build_object('estado', q.status, 'resolvio', public._com_label(q.decided_by), 'cuando', q.decided_at) from public.com_requests q where q.id = a.request_id),
      'eventos', (select jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.at, 'actor', public._com_label(e.actor_id), 'destinatario', public._com_label(e.recipient_id),
                   'push', (select j.status || coalesce(' · ' || j.last_error, '') from public.push_jobs j where j.notification_id = e.notification_id), 'detalle', e.detail) order by e.id)
                  from public.com_alarm_events e where e.alarm_id = a.id)) order by a.raised_at desc)
    from public.com_alarms a where a.raised_at >= public._com_ar_day(p_from) and a.raised_at < public._com_ar_day(p_to + 1)), '[]'::jsonb);
end; $$;

-- com_alarm_history_page (texto exacto vigente + reemplazos verificados)
create or replace function public.com_alarm_history_page(p_from date, p_to date, p_cursor jsonb, p_limit int default 25) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); lim int := greatest(1, least(coalesce(p_limit, 25), 100)); cc timestamptz; ci uuid; rows jsonb; n int;
begin
  if me.id is null or not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_cursor is not null then begin cc := (p_cursor->>'c')::timestamptz; ci := (p_cursor->>'i')::uuid; exception when others then raise exception 'BAD_CURSOR' using errcode = '22023'; end; end if;
  select coalesce(jsonb_agg(x order by (x->>'raised_at')::timestamptz desc, (x->>'id') desc), '[]'::jsonb), count(*) into rows, n from (
    select public._com_alarm_view(a, me.id) || jsonb_build_object(
      'resolucion_comercial', (select jsonb_build_object('estado', q.status, 'resolvio', public._com_label(q.decided_by), 'cuando', q.decided_at) from public.com_requests q where q.id = a.request_id),
      'eventos', (select jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.at, 'actor', public._com_label(e.actor_id), 'destinatario', public._com_label(e.recipient_id),
                   'push', (select j.status || coalesce(' · ' || j.last_error, '') from public.push_jobs j where j.notification_id = e.notification_id), 'detalle', e.detail) order by e.id)
                  from public.com_alarm_events e where e.alarm_id = a.id)) x
    from public.com_alarms a
    where a.raised_at >= coalesce(public._com_ar_day(p_from), '-infinity'::timestamptz) and a.raised_at < coalesce(public._com_ar_day(p_to + 1), 'infinity'::timestamptz)
      and (p_cursor is null or (a.raised_at, a.id) < (cc, ci))
    order by a.raised_at desc, a.id desc limit lim + 1) t;
  if n > lim then rows := rows - lim; end if;
  return jsonb_build_object('items', rows, 'has_more', n > lim, 'page_size', lim,
    'next_cursor', case when n > lim then jsonb_build_object('c', rows->(lim - 1)->>'raised_at', 'i', rows->(lim - 1)->>'id') end);
end; $$;

-- com_dispatch_stats (texto exacto vigente + reemplazos verificados)
create or replace function public.com_dispatch_stats(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'paradas')::int desc) from (
    select jsonb_build_object('transportista', coalesce(ca.name, r.carrier_id), 'zona', coalesce(nullif(s.zone, ''), 'SIN ZONA'), 'hojas', count(distinct r.id), 'paradas', count(*),
      'entregadas', count(*) filter (where s.outcome = 'ENTREGADO')) x
    from public.routes r join public.route_stops s on s.route_id = r.id left join public.carriers ca on ca.id = r.carrier_id
    where coalesce(s.stop_type, 'PEDIDO') = 'PEDIDO' and r.published_at >= public._com_ar_day(p_from) and r.published_at < public._com_ar_day(p_to + 1) group by coalesce(ca.name, r.carrier_id), coalesce(nullif(s.zone, ''), 'SIN ZONA')) t), '[]'::jsonb);
end; $$;

-- com_report (texto exacto vigente + reemplazos verificados)
create or replace function public.com_report(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return (with r as (select * from public.com_requests where created_at >= public._com_ar_day(p_from) and created_at < public._com_ar_day(p_to + 1))
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

-- _com_alarm_escalation (texto exacto vigente + reemplazos verificados)
create or replace function public._com_alarm_escalation() returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(p.id order by p.full_name), '{}') from public.com_settings s, unnest(s.alarm_escalation_users) u join public.profiles p on p.id = u
   where s.id = 'DEFAULT' and p.status = 'ACTIVO' and p.role = 'ADMIN' and not ('COMERCIAL' = any(p.disabled_modules));
$$;

-- _com_alarm_view (texto exacto vigente + reemplazos verificados)
create or replace function public._com_alarm_view(a public.com_alarms, p_me uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', a.id, 'number', a.number, 'order_ref', a.order_ref, 'sheet_key', a.sheet_key, 'client', a.client_name, 'cuit', a.client_cuit, 'client_source', a.client_source,
    'branch', a.branch, 'reason', a.reason, 'raised_by', public._com_label(a.raised_by), 'raised_at', a.raised_at, 'initial_user', public._com_label(a.initial_user), 'escalate_at', a.escalate_at,
    'escalated_at', a.escalated_at, 'escalated_to', (select coalesce(jsonb_agg(public._com_label(x)), '[]') from unnest(a.escalated_to) x), 'status', a.status,
    'attended_by', public._com_label(a.attended_by), 'attended_at', a.attended_at, 'seconds_to_attend', a.seconds_to_attend, 'version', a.version,
    'request', (select jsonb_build_object('id', q.id, 'number', q.number, 'status', q.status) from public.com_requests q where q.id = a.request_id),
    -- ¿le SUENA a este usuario? destinatario inicial mientras esté pendiente; escalados después del escalamiento
    'ring', a.status = 'PENDIENTE_ATENCION' and (p_me = a.initial_user or p_me = any(a.escalated_to)) and public.user_has_perm(p_me, 'com.approve'),   -- N-V4-01: permiso ACTUAL
    'can_attend', a.status = 'PENDIENTE_ATENCION' and coalesce(public._com_alarm_role(a, p_me), 'SOLICITANTE') <> 'SOLICITANTE');   -- N-V4-01
$$;

-- com_alarm_raise (texto exacto vigente + reemplazos verificados)
create or replace function public.com_alarm_raise(p_order_ref text, p_sheet_key text, p_client_name text, p_client_cuit text, p_reason text, p_op_id text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); a public.com_alarms; o public.com_alarm_ops; q public.com_requests; ini uuid; st public.com_settings;
  ref text := upper(btrim(coalesce(p_order_ref, ''))); op text := btrim(coalesce(p_op_id, '')); res jsonb; cname text;
  aviso constant text := 'Ese identificador de operación ya se usó para otra operación. Reintentá desde la pantalla.';
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null or not (public.user_has_perm(me.id, 'com.track') or public._com_admin()) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if ref = '' or coalesce(btrim(p_sheet_key), '') = '' then raise exception 'BAD_ORDER: indicá el pedido y la hoja' using errcode = '22023'; end if;
  if length(op) < 6 then raise exception 'BAD_OP: falta el identificador de la operación' using errcode = '22023'; end if;   -- B-W02: obligatorio (sin él no hay idempotencia)
  -- 1) IDEMPOTENCIA (B-AL-06 / B-W02): las llamadas con el mismo op_id se ordenan; una operación YA RESPONDIDA devuelve SIEMPRE la misma respuesta
  --    (también si la alarma ya se atendió o escaló). Reutilizarla para OTRO usuario, pedido u hoja se rechaza sin datos y se registra.
  perform pg_advisory_xact_lock(hashtext('com_alarm_op:' || op));
  select * into o from public.com_alarm_ops where op_id = op;
  if found then
    if o.user_id = me.id and o.order_ref = ref and o.sheet_key = p_sheet_key then return o.result || jsonb_build_object('repeated', true); end if;
    if o.alarm_id is not null then
      insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (o.alarm_id, 'OP_ID_REUTILIZADO_RECHAZADO', me.id,
        jsonb_build_object('op_id', op, 'pedido_pedido', btrim(p_order_ref), 'hoja_pedida', p_sheet_key, 'difiere', array_remove(array[
          case when o.user_id <> me.id then 'usuario' end, case when o.order_ref <> ref then 'pedido' end, case when o.sheet_key <> p_sheet_key then 'hoja' end], null)));
    end if;
    insert into public.audit_log(actor_id, action, target_type, target_id, after) values (me.id, 'COM_ALARM_OP_ID_REUSE', 'com_alarm_ops', op, jsonb_build_object('pedido', btrim(p_order_ref), 'hoja', p_sheet_key));
    return jsonb_build_object('ok', false, 'code', 'OP_ID_CONFLICT', 'message', aviso);
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then raise exception 'REASON_REQUIRED: indicá el motivo (al menos 10 caracteres)' using errcode = '23514'; end if;
  -- 2) ALCANCE (B-W02 / IND-S02): el pedido debe estar reservado en esa hoja Y el usuario debe poder operar esa hoja (misma regla que _draft: dueño,
  --    routes.manage_all_drafts o Administrador General). «Hoja inexistente» y «sin permiso» responden IGUAL (no se revela existencia).
  if not exists (select 1 from public.order_reservations r join public.route_drafts d on d.client_sheet_key = r.sheet_key
                  where upper(btrim(r.order_id)) = ref and r.sheet_key = p_sheet_key
                    and (d.owner_id = me.id or public.user_has_perm(me.id, 'routes.manage_all_drafts') or public._com_admin())) then
    raise exception 'ORDER_NOT_IN_SHEET: el pedido no pertenece a una hoja que puedas operar' using errcode = '23514'; end if;
  -- 3) una sola alarma ACTIVA por pedido
  perform pg_advisory_xact_lock(hashtext('com_alarm:' || ref));
  select * into a from public.com_alarms where upper(btrim(order_ref)) = ref and status = 'PENDIENTE_ATENCION';
  if found then
    insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (a.id, 'DUPLICADA_EXISTENTE', me.id, jsonb_build_object('op_id', op, 'motivo', btrim(p_reason)));
    if public._com_alarm_role(a, me.id) is not null then
      res := jsonb_build_object('ok', true, 'id', a.id, 'number', a.number, 'status', a.status, 'existing', true);
    else   -- fuera de su alcance: respuesta MÍNIMA, sin número ni identificador de la alarma ajena
      res := jsonb_build_object('ok', true, 'existing', true, 'status', 'PENDIENTE_ATENCION', 'message', 'Ya hay una alarma activa para ese pedido, pedida por otra persona.');
    end if;
    insert into public.com_alarm_ops(op_id, user_id, order_ref, sheet_key, alarm_id, result) values (op, me.id, ref, p_sheet_key, a.id, res);   -- la deduplicación TAMBIÉN queda vinculada
    return res || jsonb_build_object('repeated', false);
  end if;
  -- 4) alta
  ini := public._com_alarm_initial();
  if ini is null then raise exception 'ALARM_NOT_CONFIGURED: falta configurar (o no está activo) el destinatario inicial de la alarma. Avisá al Administrador General.' using errcode = '23514'; end if;
  if cardinality(public._com_alarm_escalation()) = 0 then raise exception 'ALARM_NOT_CONFIGURED: faltan destinatarios de escalamiento activos configurados. Avisá al Administrador General.' using errcode = '23514'; end if;
  select * into st from public.com_settings where id = 'DEFAULT';
  select * into q from public.com_requests where upper(btrim(coalesce(order_ref, ''))) = ref and status <> 'CANCELADA' order by created_at desc, number desc limit 1;
  begin
    insert into public.com_alarms(order_ref, sheet_key, route_id, request_id, branch, client_name, client_cuit, client_source, reason, raised_by, initial_user, escalate_at, op_id)
      values (btrim(p_order_ref), p_sheet_key, (select route_id from public.order_reservations where upper(btrim(order_id)) = ref and sheet_key = p_sheet_key limit 1), q.id,
              coalesce(q.branch, q.cartera_label), coalesce(q.client_snapshot->>'razon_social', left(btrim(p_client_name), 160)), coalesce(q.client_snapshot->>'cuit', nullif(regexp_replace(coalesce(p_client_cuit, ''), '\D', '', 'g'), '')),
              case when q.id is null then 'DECLARADO_POR_DESPACHO' else 'SOLICITUD_COMERCIAL' end, btrim(p_reason), me.id, ini, now() + make_interval(secs => st.alarm_escalate_seconds), op)
      returning * into a;
  exception when unique_violation then
    -- O-W02: última defensa DIFERENCIADA (los bloqueos ya ordenan las llamadas): se identifica la restricción, se AUDITA y se responde sin datos
    get stacked diagnostics cname = constraint_name;
    insert into public.audit_log(actor_id, action, target_type, target_id, after) values (me.id, 'COM_ALARM_UNIQUE_FALLBACK', 'com_alarms', op, jsonb_build_object('restriccion', cname, 'pedido', btrim(p_order_ref), 'hoja', p_sheet_key));
    if cname = 'com_alarms_one_active' then return jsonb_build_object('ok', false, 'code', 'RETRY', 'message', 'Otra alarma para ese pedido se registró en el mismo instante. Reintentá: vas a ver la alarma activa.'); end if;
    return jsonb_build_object('ok', false, 'code', 'OP_ID_CONFLICT', 'message', aviso);
  end;
  insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (a.id, 'CREADA', me.id, jsonb_build_object('op_id', op, 'pedido', a.order_ref, 'hoja', a.sheet_key, 'motivo', a.reason, 'escala_a_las', a.escalate_at));
  perform public._com_alarm_notify(a, ini, 'COM_ALARMA', 'APROBACIÓN COMERCIAL URGENTE', 'Pedido ' || a.order_ref || ' · solicitada por ' || me.full_name || ' · tocá para ATENDER', me.id);
  res := jsonb_build_object('ok', true, 'id', a.id, 'number', a.number, 'status', 'PENDIENTE_ATENCION', 'existing', false, 'escalate_at', a.escalate_at);
  insert into public.com_alarm_ops(op_id, user_id, order_ref, sheet_key, alarm_id, result) values (op, me.id, ref, p_sheet_key, a.id, res);
  return res || jsonb_build_object('repeated', false);
end; $$;

-- com_alarm_attend (texto exacto vigente + reemplazos verificados)
create or replace function public.com_alarm_attend(p_id uuid, p_version int) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); a public.com_alarms; como text; u uuid;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();
  select * into a from public.com_alarms where id = p_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  como := nullif(public._com_alarm_role(a, me.id), 'SOLICITANTE');   -- N-V4-01: papel con el permiso ACTUAL (una asignación histórica no alcanza)
  if como is null then
    -- se REGISTRA el intento y se RESPONDE el rechazo (sin excepción: una excepción desharía también el registro). La alarma no cambia.
    insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (a.id, 'INTENTO_ATENDER_RECHAZADO', me.id, jsonb_build_object('motivo', 'sin autorización'));
    return jsonb_build_object('ok', false, 'code', 'FORBIDDEN', 'message', 'No sos destinatario de esta alarma.'); end if;
  -- O-AL-05: hay conflicto SOLO si la alarma ya NO está pendiente (otra persona la atendió). Un cambio de versión por el ESCALAMIENTO no
  -- bloquea a un destinatario autorizado; la doble toma sigue impedida por el bloqueo de la fila (FOR UPDATE) y el estado.
  if a.status <> 'PENDIENTE_ATENCION' then
    raise exception 'CONFLICT: la alarma ya fue atendida por % (%)', coalesce((select full_name from public.profiles where id = a.attended_by), '—'), a.attended_at using errcode = '40001'; end if;
  update public.com_alarms set status = 'ATENDIDA', attended_by = me.id, attended_at = now(), attended_as = como, seconds_to_attend = extract(epoch from now() - raised_at)::int, version = version + 1
   where id = a.id returning * into a;
  insert into public.com_alarm_events(alarm_id, kind, actor_id, detail) values (a.id, 'ATENDIDA', me.id, jsonb_build_object('como', como, 'segundos', a.seconds_to_attend, 'escalada', a.escalated_at is not null));
  -- se informa a quien la pidió y a los demás destinatarios (las alertas de la app se detienen al ver ATENDIDA)
  foreach u in array (array[a.raised_by, a.initial_user] || a.escalated_to) loop
    if u is distinct from me.id then perform public._com_alarm_notify(a, u, 'COM_ALARMA_ATENDIDA', 'Alarma comercial ATENDIDA', 'Pedido ' || a.order_ref || ' · atendida por ' || me.full_name, me.id); end if;
  end loop;
  return jsonb_build_object('ok', true, 'id', a.id, 'number', a.number, 'status', a.status, 'attended_as', como, 'seconds_to_attend', a.seconds_to_attend, 'request_id', a.request_id);
end; $$;

-- com_alarm_by_notification (texto exacto vigente + reemplazos verificados)
create or replace function public.com_alarm_by_notification(p_notification uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); a public.com_alarms;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();
  select al.* into a from public.com_alarm_events e join public.com_alarms al on al.id = e.alarm_id where e.notification_id = p_notification and e.recipient_id = me.id limit 1;
  if not found or public._com_alarm_role(a, me.id) is null then return null; end if;   -- N-V4-01: el enlace previo no da acceso sin el permiso ACTUAL
  return public._com_alarm_view(a, me.id);
end; $$;

-- com_my_alarms (texto exacto vigente + reemplazos verificados)
create or replace function public.com_my_alarms() returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active();
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();   -- perezoso: adelanta el escalamiento si hay alguien conectado (el reloj sigue siendo el del servidor)
  return coalesce((select jsonb_agg(public._com_alarm_view(a, me.id) order by a.raised_at desc) from public.com_alarms a
    where (a.status = 'PENDIENTE_ATENCION' or a.attended_at > now() - interval '12 hours')
      and (public._com_alarm_role(a, me.id) is not null)), '[]'::jsonb);
end; $$;

-- com_my_alarms_page (texto exacto vigente + reemplazos verificados)
create or replace function public.com_my_alarms_page(p_limit int default 20) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); lim int := greatest(1, least(coalesce(p_limit, 20), 50)); items jsonb; tot int;
begin
  if me.id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public.com_alarm_escalate_due();
  with vis as (select a.* from public.com_alarms a where (a.status = 'PENDIENTE_ATENCION' or a.attended_at > now() - interval '12 hours')
                 and (public._com_alarm_role(a, me.id) is not null))
  select (select count(*) from vis where status = 'PENDIENTE_ATENCION'),
         coalesce((select jsonb_agg(public._com_alarm_view(v, me.id) order by (v.status = 'PENDIENTE_ATENCION') desc, v.raised_at desc, v.id desc)
                     from (select * from vis order by (status = 'PENDIENTE_ATENCION') desc, raised_at desc, id desc limit lim) v), '[]'::jsonb)
    into tot, items;
  return jsonb_build_object('items', items, 'total_pending', tot, 'has_more', (select count(*) from public.com_alarms a where (a.status = 'PENDIENTE_ATENCION' or a.attended_at > now() - interval '12 hours')
    and (public._com_alarm_role(a, me.id) is not null)) > lim, 'page_size', lim);
end; $$;

-- com_set_alarm_settings (texto exacto vigente + reemplazos verificados)
create or replace function public.com_set_alarm_settings(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare ini uuid := nullif(p->>'initial_user', '')::uuid; esc uuid[] := (select coalesce(array_agg(distinct x::uuid), '{}') from jsonb_array_elements_text(coalesce(p->'escalation_users', '[]')) x);
  antes jsonb;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;   -- B-AL-04
  -- B-AL-03: configuración EXPLÍCITA y COMPLETA (no se guarda «vacío» por accidente)
  if ini is null or cardinality(esc) = 0 then raise exception 'INCOMPLETE: elegí el destinatario inicial y al menos un destinatario de escalamiento' using errcode = '23514'; end if;
  if not exists (select 1 from public.profiles where id = ini and status = 'ACTIVO' and public.user_has_perm(id, 'com.approve')) then
    raise exception 'BAD_RECIPIENT: el destinatario inicial debe estar ACTIVO y tener permiso de aprobación' using errcode = '23514'; end if;
  if exists (select 1 from unnest(esc) x where not exists (select 1 from public.profiles where id = x and status = 'ACTIVO' and role = 'ADMIN' and not ('COMERCIAL' = any(disabled_modules)))) then
    raise exception 'BAD_RECIPIENT: el escalamiento solo puede dirigirse a Administradores Generales ACTIVOS (suplentes por regla)' using errcode = '23514'; end if;
  select jsonb_build_object('initial_user', alarm_initial_user, 'escalation_users', to_jsonb(alarm_escalation_users)) into antes from public.com_settings where id = 'DEFAULT';
  update public.com_settings set alarm_initial_user = ini, alarm_escalation_users = esc where id = 'DEFAULT';
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (auth.uid(), 'COM_ALARM_SETTINGS', 'com_settings', 'DEFAULT', antes, jsonb_build_object('initial_user', ini, 'escalation_users', to_jsonb(esc)));
  return public.com_alarm_settings();
end; $$;

-- com_history (texto exacto vigente + reemplazos verificados)
create or replace function public.com_history(p_scope text, p_filters jsonb, p_cursor jsonb, p_limit int default 25) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._com_active(); adm boolean := public._com_admin(); f jsonb := coalesce(p_filters, '{}'::jsonb);
  lim int := greatest(1, least(coalesce(p_limit, 25), 100)); cc timestamptz; ci uuid; rows jsonb; n int;
  qq text := public._com_norm(f->>'q'); qd text := regexp_replace(coalesce(f->>'q', ''), '\D', '', 'g');
  st text[] := (select array_agg(x) from jsonb_array_elements_text(case when jsonb_typeof(f->'status') = 'array' then f->'status' else '[]'::jsonb end) x);
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
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
      and (coalesce(f->>'from', '') = '' or q.created_at >= ((f->>'from')::date::timestamp at time zone 'America/Argentina/Mendoza'))   -- N-V4-05: día operativo argentino
      and (coalesce(f->>'to', '') = '' or q.created_at < (((f->>'to')::date + 1)::timestamp at time zone 'America/Argentina/Mendoza'))
      and (st is null or q.status = any(st))
      and (coalesce(f->>'kind', '') = '' or q.kind = f->>'kind')
    order by q.created_at desc, q.id desc limit lim + 1) t;
  if n > lim then rows := rows - lim; end if;   -- se pidió una fila de más solo para saber si quedan resultados
  return jsonb_build_object('items', rows, 'has_more', n > lim, 'page_size', lim,
    'next_cursor', case when n > lim then jsonb_build_object('c', rows->(lim - 1)->>'created_at', 'i', rows->(lim - 1)->>'id') end);
end; $$;

-- ---------- privilegios ----------
revoke all on function public._com_alarm_role(public.com_alarms,uuid) from public, anon, authenticated;
revoke all on function public._com_ar_day(date) from public, anon, authenticated;
revoke all on function public.com_set_kpi_mode(text,text) from public, anon; grant execute on function public.com_set_kpi_mode(text,text) to authenticated;
revoke all on function public.push_session_valid(uuid,numeric,text) from public, anon, authenticated;
DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN EXECUTE 'GRANT EXECUTE ON FUNCTION public.push_session_valid(uuid,numeric,text) TO service_role'; END IF; END $$;
DO $post$ BEGIN IF (SELECT kpi_mode FROM public.com_settings WHERE id = 'DEFAULT') <> 'DESHABILITADO' THEN RAISE EXCEPTION 'EL_KPI_DEBE_QUEDAR_DESHABILITADO'; END IF; END $post$;
-- (COMMIT propio retirado)
-- ==============================================================================================================
-- 20261201001000_comercial_v6_push_instalacion.sql
-- ==============================================================================================================
-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · V6 (auditoría Work V5, 15/11) · NO APLICADA. Después de 000100 a 000900.
--  · N-V5-02 · push_session_valid EXIGE la identidad de sesión (session_id): ausente → SESION_NO_IDENTIFICADA (nunca se omite la comprobación).
--  · N-V5-03 · push_recipient_allowed: antes de ENVIAR un trabajo COM_ALARMA se verifica el acceso ACTUAL del destinatario; si ya no lo tiene,
--    el trabajo se omite y queda AUDITADO. Los demás tipos de aviso no cambian.
--  · Prioridad de alarmas en la cola compartida: claim_com_alarm_push_jobs (misma semántica que claim_push_jobs, SOLO trabajos COM_ALARMA).
--    claim_push_jobs de producción NO se modifica.
--  · N-V5-05 · estado de instalación (INSTALADO_CERRADO / ACTIVO / REVERTIDO) con historial: una instalación revertida no se reactiva.
--  · N-V5-04 · las políticas de Storage del módulo exigen además _com_module_open(): con el módulo cerrado o revertido los originales comerciales
--    quedan cerrados SIN romper la evaluación de políticas de otros buckets (el instalador ya no retira la ejecución de sus funciones auxiliares).
--  · Configuración PRIVILEGIADA antes de abrir (_com_install_configure) y verificación de preparación (_com_install_ready) para ACTIVAR.
-- =====================================================================================================================
-- (BEGIN propio retirado: corre dentro de la transacción única)
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regprocedure('public.push_session_valid(uuid,numeric,text)') IS NULL OR to_regprocedure('public._com_alarm_role(public.com_alarms,uuid)') IS NULL THEN
    RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: aplicar antes 000100 a 000900. No se modificó nada.'; END IF;
  IF to_regclass('public.com_install_state') IS NOT NULL THEN RAISE EXCEPTION 'YA_APLICADA. No se modificó nada.'; END IF;
END $guard$;

-- ---------- N-V5-02 · la identidad de sesión es OBLIGATORIA ----------
create or replace function public.push_session_valid(p_user uuid, p_iat numeric, p_session text) returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare p public.profiles;
begin
  if p_user is null or p_iat is null then return jsonb_build_object('ok', false, 'motivo', 'CLAIMS_INCOMPLETOS'); end if;
  if p_session is null or btrim(p_session) = '' then return jsonb_build_object('ok', false, 'motivo', 'SESION_NO_IDENTIFICADA'); end if;   -- N-V5-02
  select * into p from public.profiles where id = p_user;
  if not found or p.status <> 'ACTIVO' then return jsonb_build_object('ok', false, 'motivo', 'PERFIL_NO_ACTIVO'); end if;
  if p.sessions_revoked_at is not null and p_iat <= extract(epoch from p.sessions_revoked_at) then return jsonb_build_object('ok', false, 'motivo', 'SESION_REVOCADA'); end if;
  if to_regclass('auth.sessions') is null then return jsonb_build_object('ok', false, 'motivo', 'SESIONES_NO_VERIFICABLES'); end if;   -- sin tabla de sesiones: nunca se aprueba a ciegas
  if not exists (select 1 from auth.sessions s where s.id::text = p_session and s.user_id = p_user) then return jsonb_build_object('ok', false, 'motivo', 'SESION_INEXISTENTE'); end if;
  return jsonb_build_object('ok', true);
end; $$;

-- ---------- N-V5-03 · acceso ACTUAL del destinatario de un aviso COM_ALARMA, antes de ENVIARLO ----------
create or replace function public.push_recipient_allowed(p_notification uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare n record; a public.com_alarms; r public.profiles; ok boolean;
begin
  select id, user_id, type into n from public.notifications where id = p_notification;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'AVISO_INEXISTENTE'); end if;
  if n.type is distinct from 'COM_ALARMA' then return jsonb_build_object('ok', true, 'motivo', 'TIPO_SIN_RESTRICCION'); end if;   -- los demás avisos: sin cambios
  select al.* into a from public.com_alarm_events e join public.com_alarms al on al.id = e.alarm_id where e.notification_id = p_notification limit 1;
  select * into r from public.profiles where id = n.user_id;
  ok := a.id is not null and r.id is not null and r.status = 'ACTIVO' and (
        ((r.id = a.initial_user or r.id = any(a.escalated_to)) and public.user_has_perm(r.id, 'com.approve'))
     or (r.id = a.raised_by and public.user_has_perm(r.id, 'com.track'))
     or (r.role = 'ADMIN' and not ('COMERCIAL' = any(r.disabled_modules))));
  if not ok then
    insert into public.audit_log(actor_id, action, target_type, target_id, after) values (null, 'COM_ALARM_PUSH_OMITIDO', 'notifications', p_notification::text,
      jsonb_build_object('destinatario', n.user_id, 'alarma', a.id, 'motivo', case when a.id is null then 'ALARMA_INEXISTENTE' when r.id is null or r.status <> 'ACTIVO' then 'DESTINATARIO_NO_ACTIVO' else 'DESTINATARIO_SIN_ACCESO_ACTUAL' end));
    return jsonb_build_object('ok', false, 'motivo', 'DESTINATARIO_SIN_ACCESO_ACTUAL');
  end if;
  return jsonb_build_object('ok', true);
end; $$;

-- ---------- prioridad de alarmas en la cola compartida (misma semántica que claim_push_jobs; SOLO COM_ALARMA) ----------
create or replace function public.claim_com_alarm_push_jobs(p_limit int default 50) returns setof public.push_jobs language plpgsql security definer set search_path = public as $$
begin
  return query update public.push_jobs j set status = 'SENDING', locked_at = now(), attempt_count = j.attempt_count + 1
   where j.id in (select pj.id from public.push_jobs pj join public.notifications nt on nt.id = pj.notification_id
                   where nt.type = 'COM_ALARMA' and (pj.status = 'QUEUED' or (pj.status = 'ERROR' and pj.attempt_count < 5 and coalesce(pj.next_attempt_at, now()) <= now())
                         or (pj.status = 'SENDING' and pj.locked_at < now() - interval '10 minutes'))
                   order by pj.created_at for update of pj skip locked limit greatest(1, least(coalesce(p_limit, 50), 200)))
  returning j.*;
end; $$;

-- ---------- N-V5-05 · estado de instalación con historial ----------
create table public.com_install_state (id text primary key default 'DEFAULT' check (id = 'DEFAULT'), status text not null check (status in ('INSTALADO_CERRADO', 'ACTIVO', 'REVERTIDO')), updated_at timestamptz not null default now());
create table public.com_install_log (id bigserial primary key, at timestamptz not null default now(), status text not null, detail jsonb not null default '{}'::jsonb);
alter table public.com_install_state enable row level security; alter table public.com_install_log enable row level security;
revoke all on public.com_install_state, public.com_install_log from public, anon, authenticated;
create or replace function public._com_install_log_inmutable() returns trigger language plpgsql as $$ begin raise exception 'INMUTABLE: el historial de instalación no se modifica ni se borra'; end; $$;
create trigger com_install_log_inmutable before update or delete on public.com_install_log for each row execute function public._com_install_log_inmutable();
-- sin fila = migraciones aplicadas una por una (entorno de prueba): se considera ABIERTO; el instalador siempre crea la fila
create or replace function public._com_module_open() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select status = 'ACTIVO' from public.com_install_state where id = 'DEFAULT'), true);
$$;

-- ---------- N-V5-04 · políticas de Storage del módulo: además, módulo ABIERTO ----------
DO $pol$ BEGIN
  IF to_regclass('storage.objects') IS NOT NULL THEN
    EXECUTE 'DROP POLICY IF EXISTS com_sources_select ON storage.objects';
    EXECUTE 'DROP POLICY IF EXISTS com_sources_insert ON storage.objects';
    EXECUTE $p$create policy com_sources_select on storage.objects for select to authenticated using (bucket_id = 'com-sources' and public._com_module_open() and public._com_admin())$p$;
    EXECUTE $p$create policy com_sources_insert on storage.objects for insert to authenticated with check (bucket_id = 'com-sources' and public._com_module_open()
      and public._com_can_upload_source() and name ~ '^(SC|CC)/[0-9a-f]{64}\.(xlsx|xls|csv)$')$p$;
  END IF;
END $pol$;

-- ---------- configuración PRIVILEGIADA antes de abrir (autoridad de instalación; sin sesión de usuario; mismas reglas que el Panel) ----------
create or replace function public._com_install_configure(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare ini uuid := nullif(p->'alarm'->>'initial_user', '')::uuid;
        esc uuid[] := (select coalesce(array_agg(distinct x::uuid), '{}') from jsonb_array_elements_text(coalesce(p->'alarm'->'escalation_users', '[]')) x);
        x jsonb;
begin
  if coalesce((select status from public.com_install_state where id = 'DEFAULT'), '') <> 'INSTALADO_CERRADO' then
    raise exception 'ESTADO_INVALIDO: la configuración privilegiada solo corre con una instalación CERRADA pendiente de activar'; end if;
  if ini is null or cardinality(esc) = 0 then raise exception 'INCOMPLETE: destinatario inicial y al menos un destinatario de escalamiento' using errcode = '23514'; end if;
  if not exists (select 1 from public.profiles where id = ini and status = 'ACTIVO' and public.user_has_perm(id, 'com.approve')) then
    raise exception 'BAD_RECIPIENT: el destinatario inicial debe estar ACTIVO y tener permiso de aprobación' using errcode = '23514'; end if;
  if exists (select 1 from unnest(esc) u where not exists (select 1 from public.profiles where id = u and status = 'ACTIVO' and role = 'ADMIN' and not ('COMERCIAL' = any(disabled_modules)))) then
    raise exception 'BAD_RECIPIENT: el escalamiento solo puede dirigirse a Administradores Generales ACTIVOS sin COMERCIAL restringido' using errcode = '23514'; end if;
  update public.com_settings set alarm_initial_user = ini, alarm_escalation_users = esc where id = 'DEFAULT';
  for x in select * from jsonb_array_elements(coalesce(p->'assignments', '[]')) loop
    if not exists (select 1 from public.profiles where id = (x->>'user_id')::uuid and role = 'COMERCIAL') then raise exception 'NOT_COMERCIAL: %', x->>'user_id' using errcode = '23514'; end if;
    insert into public.com_user_assignments(user_id, channel, branch, cartera_label, updated_by)
      values ((x->>'user_id')::uuid, x->>'channel', case when x->>'channel' = 'SUCURSAL' then x->>'branch' end, case when x->>'channel' = 'CARTERA' then nullif(btrim(x->>'cartera'), '') end, null)
      on conflict (user_id) do update set channel = excluded.channel, branch = excluded.branch, cartera_label = excluded.cartera_label, updated_by = null, updated_at = now();
  end loop;
  for x in select * from jsonb_array_elements(coalesce(p->'routing', '[]')) loop
    if (x->>'approver') is not null and (public._com_active((x->>'approver')::uuid) is null or not public.user_has_perm((x->>'approver')::uuid, 'com.approve')) then
      raise exception 'BAD_APPROVER: %', x->>'approver' using errcode = '23514'; end if;
    update public.com_routing set approver_user_id = (x->>'approver')::uuid, updated_by = null, updated_at = now() where channel_key = x->>'channel_key';
    if not found then raise exception 'BAD_CHANNEL: %', x->>'channel_key' using errcode = '23514'; end if;
  end loop;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (null, 'COM_CONFIGURACION_INSTALACION', 'com_settings', 'DEFAULT', p);
  insert into public.com_install_log(status, detail) values ('INSTALADO_CERRADO', jsonb_build_object('paso', 'CONFIGURACION', 'destinatario_inicial', ini, 'escalamiento', to_jsonb(esc)));
  return public._com_install_ready();
end; $$;

-- ---------- preparación para ACTIVAR (todas las condiciones, con su resultado) ----------
create or replace function public._com_install_ready() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.com_settings; c jsonb := '[]'::jsonb; cron_ok boolean := to_regclass('cron.job') is not null; esc_job boolean := false; push_job boolean := false;
begin
  if cron_ok then   -- consulta DINÁMICA: sin pg_cron la tabla no existe y se informa «no programada» en vez de fallar
    execute $q$select exists (select 1 from cron.job where jobname = 'okd-com-alarma-escalamiento' and active)$q$ into esc_job;
    execute $q$select exists (select 1 from cron.job where jobname = 'okd-push-notificaciones' and active)$q$ into push_job;
  end if;
  select * into s from public.com_settings where id = 'DEFAULT';
  c := c || jsonb_build_object('control', 'ESTADO_INSTALADO_CERRADO', 'ok', coalesce((select status = 'INSTALADO_CERRADO' from public.com_install_state where id = 'DEFAULT'), false));
  c := c || jsonb_build_object('control', 'KPI_DESHABILITADO', 'ok', s.kpi_mode = 'DESHABILITADO');
  c := c || jsonb_build_object('control', 'DESTINATARIO_INICIAL_VALIDO', 'ok', exists (select 1 from public.profiles where id = s.alarm_initial_user and status = 'ACTIVO' and public.user_has_perm(id, 'com.approve')));
  c := c || jsonb_build_object('control', 'ESCALAMIENTO_VALIDO', 'ok', cardinality(coalesce(s.alarm_escalation_users, '{}')) > 0
        and not exists (select 1 from unnest(s.alarm_escalation_users) u where not exists (select 1 from public.profiles where id = u and status = 'ACTIVO' and role = 'ADMIN' and not ('COMERCIAL' = any(disabled_modules)))));
  -- N-V5-01: no se abre la alarma urgente sin su automatización PROGRAMADA (escalamiento SQL y envío push)
  c := c || jsonb_build_object('control', 'TAREA_ESCALAMIENTO_PROGRAMADA', 'ok', esc_job);
  c := c || jsonb_build_object('control', 'TAREA_PUSH_PROGRAMADA', 'ok', push_job);
  return jsonb_build_object('listo', not exists (select 1 from jsonb_array_elements(c) e where not (e->>'ok')::boolean), 'controles', c);
end; $$;

-- ---------- privilegios ----------
revoke all on function public.push_recipient_allowed(uuid) from public, anon, authenticated;
revoke all on function public.claim_com_alarm_push_jobs(int) from public, anon, authenticated;
revoke all on function public._com_install_configure(jsonb) from public, anon, authenticated;
revoke all on function public._com_install_ready() from public, anon, authenticated;
revoke all on function public._com_install_log_inmutable() from public, anon, authenticated;
revoke all on function public._com_module_open() from public, anon;   -- WORK-S06: nada comercial ejecutable por anon (las funciones nuevas nacen ejecutables por PUBLIC)
grant execute on function public._com_module_open() to authenticated;   -- solo devuelve verdadero/falso; lo evalúan las políticas de Storage
DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.push_recipient_allowed(uuid) TO service_role';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.claim_com_alarm_push_jobs(int) TO service_role'; END IF; END $$;
-- (COMMIT propio retirado)
-- ==============================================================================================================
-- 20261201001100_comercial_kpi_facturacion.sql
-- ==============================================================================================================
-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · KPI DE FACTURACIÓN (regla oficial de Dirección General, 15/11) · NO APLICADA. Después de 001000.
-- REGLA: las facturas PERMANECEN en «Saldo comprobante» aunque estén abonadas. Facturación del mes = importe ORIGINAL de las facturas por
-- FECHA DE EMISIÓN (abonadas incluidas); el saldo NO sustituye al original; el pago no reduce la facturación.
-- SIN INVENTAR SEMÁNTICA (WORK-K02 abierto): con varias filas por comprobante el original se toma según cuota_rule (vigente) y el saldo según
-- saldo_rule (nueva); ambas POR_CONFIRMAR por defecto → el comprobante se EXCLUYE de la facturación o su saldo queda «no determinado».
-- USO: SOLO Administrador, rotulado «VALIDACIÓN — NO OPERATIVO» mientras el KPI esté deshabilitado. No modifica cobranzas ni aplica notas de
-- crédito en OK DESPACHO (HOTFIX NOC V5 aparte). Lectura pura: no cambia datos.
-- Punto 4: com_client_finance informa ORIGEN (corte, archivo, carga) y VERIFICACIÓN del saldo importado (NO_VERIFICADO por defecto).
-- =====================================================================================================================
-- (BEGIN propio retirado: corre dentro de la transacción única)
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regclass('public.com_install_state') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: aplicar antes 000100 a 001000. No se modificó nada.'; END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'com_settings' AND column_name = 'saldo_rule') THEN
    RAISE EXCEPTION 'YA_APLICADA. No se modificó nada.'; END IF;
END $guard$;

-- regla EXPLÍCITA del saldo cuando un comprobante tiene varias filas (cuotas): POR_PARTE (cada fila trae el pendiente de su parte → se suman),
-- REPETIDO (cada fila repite el saldo del comprobante → se toma una vez) o POR_CONFIRMAR (predeterminado: saldo no determinado)
alter table public.com_settings add column saldo_rule text not null default 'POR_CONFIRMAR' check (saldo_rule in ('POR_CONFIRMAR', 'POR_PARTE', 'REPETIDO'));

-- ---------- un registro POR COMPROBANTE (clave estable: CUIT | comprobante normalizado) con su trazabilidad ----------
create or replace function public._com_billing_docs(p_from date, p_to date) returns setof jsonb language sql stable security definer set search_path = public as $$
  with s as (select cuota_rule cr, saldo_rule sr from public.com_settings where id = 'DEFAULT'),
  rows_ as (select * from public.com_sc_documents d where d.class in ('VENTA', 'NOTA_CREDITO', 'ANULACION')
              and d.doc_date >= coalesce(p_from, '-infinity'::date) and d.doc_date <= coalesce(p_to, 'infinity'::date)),
  g as (select r.comp_group k, min(r.cuit) cuit, min(r.client_name) cliente, min(r.class) clase, min(r.prefix) prefijo, min(r.comp) comp,
               min(r.doc_date) emision, count(*) partes, count(*) filter (where r.status <> 'OK') malas, array_agg(distinct r.status) filter (where r.status <> 'OK') motivos,
               min(r.amount) mn, max(r.amount) mx, sum(r.amount) tot, count(r.last_saldo) con_saldo, sum(r.last_saldo) saldo_sum, min(r.last_saldo) smn, max(r.last_saldo) smx,
               min(r.first_ingest_id) primera, max(r.last_ingest_id) ultima
          from rows_ r group by r.comp_group),
  c as (select g.*, s.cr, s.sr,
          case when g.malas > 0 then null
               when g.partes = 1 then g.mx
               when s.cr = 'MONTO_ES_TOTAL' and g.mn = g.mx then g.mx
               when s.cr = 'MONTO_ES_CUOTA' then g.tot end original,
          case when g.malas > 0 or g.con_saldo < g.partes then null
               when g.partes = 1 then g.saldo_sum
               when s.sr = 'POR_PARTE' then g.saldo_sum
               when s.sr = 'REPETIDO' and g.smn = g.smx then g.smx end saldo
        from g, s)
  select jsonb_build_object('comprobante', c.k, 'cuit', c.cuit, 'cliente', c.cliente, 'clase', c.clase, 'prefijo', c.prefijo, 'comp', c.comp,
    'emision', c.emision, 'mes', to_char(c.emision, 'YYYY-MM'), 'partes', c.partes, 'original', abs(c.original), 'saldo', c.saldo,
    'estado_pago', case when c.clase <> 'VENTA' then null when c.original is null then null when c.saldo is null then 'SALDO_NO_DETERMINADO'
                        when c.saldo = 0 then 'ABONADA' when c.saldo > 0 and c.saldo < c.original then 'PARCIAL' when c.saldo = c.original then 'PENDIENTE' else 'A_REVISAR' end,
    'abonado', case when c.clase = 'VENTA' and c.original is not null and c.saldo is not null and c.saldo >= 0 and c.saldo <= c.original then c.original - c.saldo end,
    'excluido', case when c.malas > 0 then 'DATOS_DEL_COMPROBANTE: ' || array_to_string(c.motivos, ',') when c.original is null then 'ORIGINAL_POR_CONFIRMAR (varias partes; regla de cuotas ' || c.cr || ')' end,
    'interpretacion', jsonb_build_object('regla_cuotas', case when c.partes > 1 then c.cr end, 'regla_saldo', case when c.partes > 1 then c.sr end),
    'carga_primera', c.primera, 'carga_ultima', c.ultima,
    'archivo', (select jsonb_build_object('carga', i.id, 'archivo', i.file_name, 'huella', left(i.content_hash, 16), 'cargado', i.loaded_at, 'corte', i.date_max) from public.com_ingests i where i.id = c.ultima))
  from c order by c.emision, c.k;
$$;

-- ---------- indicadores por MES (emisión), con fecha de corte y archivos de origen ----------
create or replace function public.com_kpi_billing(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare docs jsonb; meses jsonb; s public.com_settings;
begin
  perform public._com_require_session();
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into s from public.com_settings where id = 'DEFAULT';
  select coalesce(jsonb_agg(x), '[]') into docs from public._com_billing_docs(p_from, p_to) x;
  with d as (select x from jsonb_array_elements(docs) x),
  m as (select x->>'mes' mes,
          sum((x->>'original')::numeric) filter (where x->>'clase' = 'VENTA' and x->>'excluido' is null) bruta,
          sum((x->>'original')::numeric) filter (where x->>'clase' = 'NOTA_CREDITO' and x->>'excluido' is null) nc,
          count(*) filter (where x->>'clase' = 'NOTA_CREDITO' and x->>'excluido' is not null) nc_excl,
          count(*) filter (where x->>'clase' = 'VENTA' and x->>'excluido' is null) facturas,
          count(distinct x->>'cuit') filter (where x->>'clase' = 'VENTA' and x->>'excluido' is null) clientes,
          sum((x->>'saldo')::numeric) filter (where x->>'clase' = 'VENTA' and x->>'excluido' is null and x->>'estado_pago' <> 'SALDO_NO_DETERMINADO') saldo,
          sum((x->>'abonado')::numeric) filter (where x->>'clase' = 'VENTA' and x->>'excluido' is null) abonado,
          count(*) filter (where x->>'estado_pago' = 'ABONADA') abonadas, count(*) filter (where x->>'estado_pago' = 'PARCIAL') parciales,
          count(*) filter (where x->>'estado_pago' = 'PENDIENTE') pendientes, count(*) filter (where x->>'estado_pago' = 'A_REVISAR') a_revisar,
          count(*) filter (where x->>'estado_pago' = 'SALDO_NO_DETERMINADO') saldo_nd,
          count(*) filter (where x->>'clase' = 'ANULACION') anuladas,
          count(*) filter (where x->>'clase' = 'VENTA' and x->>'excluido' is not null) excluidas,
          jsonb_object_agg(coalesce(x->>'prefijo', '?'), 1) filter (where x->>'clase' = 'VENTA' and x->>'excluido' is null) tipos_obj
        from d group by x->>'mes'),
  m2 as (select m.*, lag(m.bruta) over (order by m.mes) prev from m)   -- la variación mensual se calcula ANTES de agregar
  select coalesce(jsonb_agg(jsonb_build_object('mes', m.mes,
      'facturacion_bruta', coalesce(m.bruta, 0), 'notas_credito', coalesce(m.nc, 0),
      'facturacion_neta', case when m.nc_excl = 0 then coalesce(m.bruta, 0) - coalesce(m.nc, 0) end,   -- solo si TODAS las notas de crédito del mes son determinables
      'facturas', m.facturas, 'clientes', m.clientes, 'ticket_promedio', case when m.facturas > 0 then round(coalesce(m.bruta, 0) / m.facturas, 2) end,
      'saldo_pendiente', coalesce(m.saldo, 0), 'abonado_inferido', coalesce(m.abonado, 0),
      'estados', jsonb_build_object('ABONADA', m.abonadas, 'PARCIAL', m.parciales, 'PENDIENTE', m.pendientes, 'A_REVISAR', m.a_revisar, 'SALDO_NO_DETERMINADO', m.saldo_nd),
      'anuladas', m.anuladas, 'facturas_excluidas', m.excluidas,
      'variacion_vs_mes_anterior', case when m.prev > 0 then round((coalesce(m.bruta, 0) / m.prev - 1) * 100, 1) end)
    order by m.mes), '[]') into meses from m2 m;
  return jsonb_build_object(
    'uso', case when s.kpi_mode = 'PROVISORIO' then 'PROVISORIO — NO CERTIFICADO (WORK-K02)' else 'VALIDACIÓN — NO OPERATIVO (KPI deshabilitado; WORK-K02 abierto)' end,
    'regla', 'Facturación = importe ORIGINAL por comprobante y mes de EMISIÓN (facturas abonadas incluidas); el saldo no sustituye al original.',
    'regla_cuotas', s.cuota_rule, 'regla_saldo', s.saldo_rule,
    'corte', (select jsonb_build_object('ultima_carga', max(i.loaded_at), 'fecha_max_datos', max(i.date_max)) from public.com_ingests i where i.kind = 'SC' and i.status = 'OK'),
    'archivos', (select coalesce(jsonb_agg(jsonb_build_object('carga', i.id, 'archivo', i.file_name, 'huella', left(i.content_hash, 16), 'cargado', i.loaded_at, 'filas', i.rows) order by i.id), '[]')
                   from public.com_ingests i where i.kind = 'SC' and i.status = 'OK'),
    'meses', meses,
    'por_cliente', (select coalesce(jsonb_agg(jsonb_build_object('cuit', t.cuit, 'cliente', t.cliente, 'facturado', t.tot, 'facturas', t.n) order by t.tot desc), '[]')
                      from (select x->>'cuit' cuit, min(x->>'cliente') cliente, sum((x->>'original')::numeric) tot, count(*) n from jsonb_array_elements(docs) x
                             where x->>'clase' = 'VENTA' and x->>'excluido' is null group by x->>'cuit') t));
end; $$;

-- ---------- detalle trazable de cada cifra (por mes y, opcionalmente, estado / clase / exclusión) ----------
create or replace function public.com_kpi_billing_detail(p_month text, p_filter jsonb default '{}'::jsonb, p_offset int default 0, p_limit int default 100) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare m0 date; items jsonb; total int;
begin
  perform public._com_require_session();
  if not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  m0 := to_date(p_month || '-01', 'YYYY-MM-DD');
  with d as (select x from public._com_billing_docs(m0, (m0 + interval '1 month' - interval '1 day')::date) x
              where (p_filter->>'estado' is null or x->>'estado_pago' = p_filter->>'estado') and (p_filter->>'clase' is null or x->>'clase' = p_filter->>'clase')
                and (p_filter->>'excluidos' is null or ((p_filter->>'excluidos')::boolean = (x->>'excluido' is not null))))
  select count(*), coalesce(jsonb_agg(x) filter (where rn > greatest(0, p_offset) and rn <= greatest(0, p_offset) + least(greatest(1, p_limit), 500)), '[]')
    into total, items from (select x, row_number() over () rn from d) z;
  return jsonb_build_object('mes', p_month, 'total', total, 'items', items);
end; $$;

-- ---------- configuración de la regla de saldo (Administrador, auditada; documentar la evidencia de Cianbox que la respalda) ----------
create or replace function public.com_set_saldo_rule(p_rule text, p_fundamento text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); antes text;
begin
  if me.id is null or not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_rule not in ('POR_CONFIRMAR', 'POR_PARTE', 'REPETIDO') then raise exception 'BAD_RULE' using errcode = '22023'; end if;
  if p_rule <> 'POR_CONFIRMAR' and length(btrim(coalesce(p_fundamento, ''))) < 20 then
    raise exception 'FUNDAMENTO_REQUERIDO: indicá qué archivo real de Cianbox respalda la interpretación' using errcode = '23514'; end if;
  select saldo_rule into antes from public.com_settings where id = 'DEFAULT';
  update public.com_settings set saldo_rule = p_rule where id = 'DEFAULT';
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (me.id, 'COM_SALDO_RULE', 'com_settings', 'DEFAULT',
    jsonb_build_object('saldo_rule', antes), jsonb_build_object('saldo_rule', p_rule, 'fundamento', nullif(btrim(coalesce(p_fundamento, '')), '')));
  return jsonb_build_object('saldo_rule', p_rule);
end; $$;

-- ---------- punto 4 · saldo de cuenta corriente: origen y estado de verificación (texto EXACTO vigente de com_client_finance + campos nuevos) ----------
alter table public.com_settings add column cc_verificado boolean not null default false;
create or replace function public.com_client_finance(p_client uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.com_clients; i public.com_ingests; b public.com_cc_balances; ls bigint;
begin
  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso
  if (public._com_active()).id is null or not (public._com_admin() or public.user_has_perm(auth.uid(), 'com.approve')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not public._com_admin() and not exists(select 1 from public.com_requests where client_id=p_client and assigned_approver_id=auth.uid()) then raise exception 'FORBIDDEN_CLIENT' using errcode='42501'; end if;
  select * into c from public.com_clients where id = p_client; if not found or c.cuit is null then return jsonb_build_object('status', 'SIN_CUIT'); end if;
  select * into i from public.com_ingests where kind = 'CC' and status = 'OK' order by at desc limit 1;
  if found then select * into b from public.com_cc_balances where ingest_id = i.id and cuit = c.cuit; end if;
  select id into ls from public.com_ingests where kind = 'SC' and status = 'OK' order by at desc, id desc limit 1;   -- la carga MÁS RECIENTE por fecha
  return jsonb_build_object('cc_saldo', b.saldo, 'cc_fecha', i.at, 'cc_disponible', b.cuit is not null,
    -- punto 4 de la orden: el saldo IMPORTADO se presenta con su ORIGEN y su estado de VERIFICACIÓN (nunca como saldo conciliado por defecto)
    'cc_verificacion', case when (select cc_verificado from public.com_settings where id = 'DEFAULT') then 'VERIFICADO' else 'NO_VERIFICADO' end,
    'cc_fecha_corte', coalesce(i.date_max::text, (i.loaded_at at time zone 'America/Argentina/Mendoza')::date::text), 'cc_archivo', i.file_name, 'cc_carga', i.id,
    'pendientes_verificacion', case when (select cc_verificado from public.com_settings where id = 'DEFAULT') then 'VERIFICADO' else 'NO_VERIFICADO' end,
    'pendientes', coalesce((select jsonb_agg(jsonb_build_object('comprobante', comp, 'fecha', doc_date, 'vence', due, 'saldo', last_saldo) order by due nulls last, doc_date)
       from public.com_sc_documents where cuit = c.cuit and last_ingest_id = ls and coalesce(last_saldo, 0) > 0.004 and class = 'VENTA'), '[]'::jsonb),
    'sc_fecha', (select at from public.com_ingests where id = ls));
end; $$;

create or replace function public.com_set_cc_verificacion(p_verificado boolean, p_fundamento text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._com_active(); antes boolean;
begin
  if me.id is null or not public._com_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_verificado and length(btrim(coalesce(p_fundamento, ''))) < 20 then
    raise exception 'FUNDAMENTO_REQUERIDO: indicá la conciliación con Cianbox que respalda presentar el saldo como verificado' using errcode = '23514'; end if;
  select cc_verificado into antes from public.com_settings where id = 'DEFAULT';
  update public.com_settings set cc_verificado = coalesce(p_verificado, false) where id = 'DEFAULT';
  insert into public.audit_log(actor_id, action, target_type, target_id, before, after) values (me.id, 'COM_CC_VERIFICACION', 'com_settings', 'DEFAULT',
    jsonb_build_object('cc_verificado', antes), jsonb_build_object('cc_verificado', coalesce(p_verificado, false), 'fundamento', nullif(btrim(coalesce(p_fundamento, '')), '')));
  return jsonb_build_object('cc_verificado', coalesce(p_verificado, false));
end; $$;
revoke all on function public.com_set_cc_verificacion(boolean, text) from public, anon; grant execute on function public.com_set_cc_verificacion(boolean, text) to authenticated;

revoke all on function public._com_billing_docs(date, date) from public, anon, authenticated;
revoke all on function public.com_kpi_billing(date, date) from public, anon; grant execute on function public.com_kpi_billing(date, date) to authenticated;
revoke all on function public.com_kpi_billing_detail(text, jsonb, int, int) from public, anon; grant execute on function public.com_kpi_billing_detail(text, jsonb, int, int) to authenticated;
revoke all on function public.com_set_saldo_rule(text, text) from public, anon; grant execute on function public.com_set_saldo_rule(text, text) to authenticated;
-- (COMMIT propio retirado)
-- ===================== CIERRE: módulo SIN ejecución para usuarios hasta ACTIVAR, SIN romper Storage =====================
-- N-V5-04: las funciones auxiliares que usan las POLÍTICAS de Storage conservan su ejecución (solo devuelven verdadero/falso); los originales
-- comerciales igual quedan cerrados porque esas políticas exigen _com_module_open(), que es falso con la instalación CERRADA.
create table public.com_install_grants(fn regprocedure not null, grantee text not null, primary key (fn, grantee));
revoke all on public.com_install_grants from public, anon, authenticated;
create temp table _com_storage_helpers on commit drop as
  select p.oid::regprocedure fn from pg_proc p
   where p.pronamespace = 'public'::regnamespace and (left(p.proname, 4) = 'com_' or left(p.proname, 5) = '_com_')
     and exists (select 1 from pg_policies pl where pl.schemaname = 'storage'
                  and (coalesce(pl.qual, '') ~ ('[[:<:]]' || p.proname || '[(]') or coalesce(pl.with_check, '') ~ ('[[:<:]]' || p.proname || '[(]')));
insert into public.com_install_grants(fn, grantee)
  select p.oid::regprocedure, r from pg_proc p cross join unnest(array['authenticated', 'anon']) r
   where p.pronamespace = 'public'::regnamespace and (left(p.proname, 4) = 'com_' or left(p.proname, 5) = '_com_') and has_function_privilege(r, p.oid, 'EXECUTE')
     and p.oid::regprocedure not in (select fn from _com_storage_helpers);
DO $close$ DECLARE f regprocedure; BEGIN
  FOR f IN SELECT p.oid::regprocedure FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND (left(p.proname, 4) = 'com_' OR left(p.proname, 5) = '_com_')
             AND p.oid::regprocedure NOT IN (SELECT fn FROM _com_storage_helpers) LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', f); END LOOP;
  IF (SELECT kpi_mode FROM public.com_settings WHERE id = 'DEFAULT') <> 'DESHABILITADO' THEN RAISE EXCEPTION 'EL_KPI_DEBE_QUEDAR_DESHABILITADO'; END IF;
END $close$;
-- N-V5-05: estado de instalación con historial
insert into public.com_install_state(id, status) values ('DEFAULT', 'INSTALADO_CERRADO');
insert into public.com_install_log(status, detail) values ('INSTALADO_CERRADO', jsonb_build_object('paso', 'INSTALAR',
  'permisos_pendientes', (select count(*) from public.com_install_grants where grantee = 'authenticated'),
  'auxiliares_de_storage', (select coalesce(jsonb_agg(fn::text), '[]'::jsonb) from _com_storage_helpers)));
COMMIT;
