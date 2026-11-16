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
