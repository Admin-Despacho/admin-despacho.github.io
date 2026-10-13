-- OK DESPACHO ONLINE — RC1.2 (incremental): PDF automático al publicar, versionado y privado.

-- ---------- Configuración CONFIGURACIÓN → DESPACHO → PDF ----------
create table if not exists public.dispatch_settings (
  id text primary key default 'DEFAULT',
  pdf_auto_generate boolean not null default true,
  pdf_auto_download boolean not null default true
);
insert into public.dispatch_settings(id) values ('DEFAULT') on conflict do nothing;
alter table public.dispatch_settings enable row level security;
create policy dispatch_settings_read on public.dispatch_settings for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('settings.manage'));
grant select on public.dispatch_settings to authenticated;
create or replace function public.set_dispatch_settings(p_auto_generate boolean, p_auto_download boolean) returns public.dispatch_settings language plpgsql security definer set search_path = public as $$
declare s public.dispatch_settings;
begin
  if not public.auth_has_perm('settings.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.dispatch_settings set pdf_auto_generate = coalesce(p_auto_generate, pdf_auto_generate), pdf_auto_download = coalesce(p_auto_download, pdf_auto_download) where id = 'DEFAULT' returning * into s;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'DISPATCH_PDF_SETTINGS', 'settings', 'DEFAULT', to_jsonb(s));
  return s;
end; $$;
grant execute on function public.set_dispatch_settings(boolean, boolean) to authenticated;

-- ---------- PDF de cada versión publicada (uno lógico por hoja + versión; nunca se sobrescribe un OK) ----------
create table if not exists public.route_pdfs (
  id uuid primary key default gen_random_uuid(),
  route_id uuid not null references public.routes(id), route_version int not null, route_number text not null,
  file_name text not null, storage_path text,
  status text not null default 'PENDING' check (status in ('PENDING','OK','PDF_ERROR')), error text, attempts int not null default 0,
  generated_at timestamptz, generated_by uuid,
  unique (route_id, route_version)
);
alter table public.route_pdfs enable row level security;
create policy route_pdfs_read on public.route_pdfs for select to authenticated
  using (public.auth_has_perm('routes.view_all') or exists (select 1 from public.routes r where r.id = route_id and r.responsable_id = auth.uid()));
grant select on public.route_pdfs to authenticated;

-- Registra el resultado (OK con la ruta en Storage, o PDF_ERROR). Idempotente: reintentos no crean otro PDF lógico.
create or replace function public.register_route_pdf(p_route uuid, p_version int, p_path text, p_error text) returns public.route_pdfs language plpgsql security definer set search_path = public, storage as $$
declare r public.routes; x public.route_pdfs; fname text;
begin
  if not public.auth_has_perm('routes.publish') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into r from public.routes where id = p_route;
  if not found or r.operational_status = 'BORRADOR' then raise exception 'NOT_PUBLISHED: solo hojas publicadas' using errcode = '23514'; end if;
  fname := 'Hoja_' || r.number || '_v' || p_version || '.pdf';
  if p_path is not null then
    if p_path <> p_route || '/v' || p_version || '/' || fname then raise exception 'BAD_PATH' using errcode = '23514'; end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'route-pdfs' and o.name = p_path) then raise exception 'NOT_UPLOADED' using errcode = '23514'; end if;
  end if;
  insert into public.route_pdfs(route_id, route_version, route_number, file_name, storage_path, status, error, attempts, generated_at, generated_by)
  values (p_route, p_version, r.number, fname, p_path, case when p_path is not null then 'OK' else 'PDF_ERROR' end, p_error, 1, case when p_path is not null then now() end, auth.uid())
  on conflict (route_id, route_version) do update set
    storage_path = case when route_pdfs.status = 'OK' then route_pdfs.storage_path else excluded.storage_path end,
    status = case when route_pdfs.status = 'OK' then 'OK' else excluded.status end,
    error = case when route_pdfs.status = 'OK' then null else excluded.error end,
    generated_at = case when route_pdfs.status = 'OK' then route_pdfs.generated_at else excluded.generated_at end,
    generated_by = case when route_pdfs.status = 'OK' then route_pdfs.generated_by else excluded.generated_by end,
    attempts = route_pdfs.attempts + 1
  returning * into x;
  return x;
end; $$;
grant execute on function public.register_route_pdf(uuid, int, text, text) to authenticated;
-- Snapshot publicado (para regenerar SIEMPRE desde lo publicado, nunca desde datos vivos)
create or replace function public.route_pdf_snapshot(p_route uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r public.routes;
begin
  if not public.auth_has_perm('routes.publish') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into r from public.routes where id = p_route;
  return jsonb_build_object('number', r.number, 'version', r.version, 'pdf_model', r.sheet_snapshot->'pdf_model');
end; $$;
grant execute on function public.route_pdf_snapshot(uuid) to authenticated;

-- ---------- Storage privado route-pdfs ----------
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('route-pdfs', 'route-pdfs', false, 10485760, array['application/pdf'])
on conflict (id) do update set public = false, file_size_limit = 10485760, allowed_mime_types = array['application/pdf'];
-- Subir: quien publica, en <route_id>/v<n>/Hoja_<correlativo>_v<n>.pdf (sin sobrescribir: no hay política de update/delete)
drop policy if exists route_pdfs_upload on storage.objects;
create policy route_pdfs_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'route-pdfs' and public.auth_has_perm('routes.publish') and name ~ '^[0-9a-f-]{36}/v[0-9]+/Hoja_[0-9]{2}-[0-9]{6}_v[0-9]+\.pdf$');
-- Descargar (URL firmada temporal): Despacho/lectura con routes.view_all o el responsable de la hoja
drop policy if exists route_pdfs_read on storage.objects;
create policy route_pdfs_read on storage.objects for select to authenticated
  using (bucket_id = 'route-pdfs' and (public.auth_has_perm('routes.view_all')
    or exists (select 1 from public.routes r where r.id::text = split_part(name, '/', 1) and r.responsable_id = auth.uid())));
