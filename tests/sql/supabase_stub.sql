-- Simulación mínima del entorno de Supabase para probar la migración y las políticas RLS
-- en un PostgreSQL local. NO reemplaza la prueba en un proyecto Supabase real.
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key, email text);
create or replace function auth.uid() returns uuid language sql stable as
$$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create or replace function auth.role() returns text language sql stable as
$$ select nullif(current_setting('request.jwt.claim.role', true), '') $$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.role() to anon, authenticated, service_role;
grant select, insert, update, delete on auth.users to service_role;

-- ===== Agregados para Fase 1.1 (equivalentes a lo que Supabase ya tiene) =====
alter table auth.users add column if not exists last_sign_in_at timestamptz;
create table if not exists auth.sessions (id uuid primary key default gen_random_uuid(), user_id uuid references auth.users(id) on delete cascade, created_at timestamptz default now());
-- auth.jwt(): claims del token (en Supabase lo arma PostgREST a partir del JWT)
create or replace function auth.jwt() returns jsonb language sql stable as
$$ select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb,
                    jsonb_build_object('sub', current_setting('request.jwt.claim.sub', true), 'role', current_setting('request.jwt.claim.role', true))) $$;
grant execute on function auth.jwt() to anon, authenticated, service_role;
grant select, insert, update, delete on auth.sessions to service_role;

-- ===== RC1: esquema mínimo de Supabase Storage (en Supabase ya existe) =====
create schema if not exists storage;
create table if not exists storage.buckets (id text primary key, name text, public boolean default false, file_size_limit bigint, allowed_mime_types text[]);
create table if not exists storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id), name text, owner uuid default auth.uid(), metadata jsonb, created_at timestamptz default now(), unique (bucket_id, name));
alter table storage.objects enable row level security;
grant usage on schema storage to authenticated, service_role, anon;
grant select, insert, update, delete on storage.objects to authenticated, service_role;
grant select on storage.buckets to authenticated, service_role;

-- Comunicaciones: Vault simulado, exclusivamente en el PostgreSQL temporal de pruebas.
-- SOLO PARA PRUEBAS LOCALES. En Supabase, Vault ya está instalado (extensión supabase_vault) y cifra los secretos.
-- Esta simulación reproduce su API (create_secret / update_secret / decrypted_secrets) y su aislamiento (sin acceso para usuarios).
create schema if not exists vault;
create table if not exists vault.secrets (id uuid primary key default gen_random_uuid(), name text unique, description text, secret text not null);
create or replace function vault.create_secret(new_secret text, new_name text default null, new_description text default '') returns uuid language sql as $$
  insert into vault.secrets(name, description, secret) values (new_name, new_description, new_secret) returning id $$;
create or replace function vault.update_secret(secret_id uuid, new_secret text default null, new_name text default null, new_description text default null) returns void language sql as $$
  update vault.secrets set secret = coalesce(new_secret, secret) where id = secret_id $$;
create or replace view vault.decrypted_secrets as select id, name, description, secret as decrypted_secret from vault.secrets;
revoke all on schema vault from public, anon, authenticated;

