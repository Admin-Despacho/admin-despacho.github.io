-- RECUPERACIÓN V4.24 · quita SOLO las funciones nuevas (la pantalla vieja no la usa). NO borra las columnas start_location* ni location_departed_* ni sus datos.
-- ORDEN: si la pantalla nueva ya está publicada, volver PRIMERO la pantalla a la versión anterior.
BEGIN;
drop function if exists public.record_route_departure(uuid, jsonb, text);
drop function if exists public.depart_internal_location(uuid, jsonb, text);
COMMIT;
