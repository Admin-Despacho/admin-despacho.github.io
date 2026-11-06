-- RECUPERACIÓN V4.26: quita el aviso automático, el buscador, la sugerencia 2 y la importación. CONSERVA las tablas (correos importados).
-- No elimina correos, auditoría ni datos importados. No restaura filas históricas sobre datos nuevos.
BEGIN;
update public.notification_settings set departure_notice_enabled=false, departure_notice_active_since=null where id='DEFAULT';
drop trigger if exists routes_zz_departure_notice on public.routes;
drop function if exists public.trg_route_departure_notice(), public.search_deliveries(text), public.delivery_email_suggestion2(uuid), public.client_padron_import(jsonb,boolean);
COMMIT;
