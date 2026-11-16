-- SOLO PRUEBAS LOCALES: esquema mínimo de Storage (mismas columnas que usan las políticas) para probar el acceso a los originales privados.
create schema if not exists storage;
create table if not exists storage.buckets (id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table if not exists storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid default auth.uid(), created_at timestamptz default now());
alter table storage.objects enable row level security;
grant usage on schema storage to authenticated, anon; grant select, insert, update, delete on storage.objects to authenticated, anon;
