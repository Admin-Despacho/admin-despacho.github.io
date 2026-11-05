-- SOLO LECTURA (SQL Editor de producción). Calcula lo MISMO que routesListInfo(): fecha programada de la hoja (snapshot publicado),
-- salida y regreso REALES y patente, para las últimas 30 hojas del Transportista Interno. No escribe nada.
select r.number                                                                            as hoja,
       (select x->'r'->>'fecha' from jsonb_array_elements(coalesce(r.sheet_snapshot->'pdf_model'->'data', '[]'::jsonb)) x
         where x->'r' ? 'fecha' limit 1)                                                  as fecha_programada_snapshot,
       to_char(r.published_at at time zone 'America/Argentina/Mendoza', 'DD/MM/YYYY HH24:MI') as publicada,
       to_char(r.started_at at time zone 'America/Argentina/Mendoza', 'DD/MM/YYYY HH24:MI')   as salida_real,
       to_char(r.depot_arrived_at at time zone 'America/Argentina/Mendoza', 'DD/MM/YYYY HH24:MI') as regreso_real,
       v.plate as patente, r.operational_status as estado
  from public.routes r join public.carriers c on c.id = r.carrier_id left join public.vehicles v on v.id = r.vehicle_id
 where c.kind = 'INTERNO' and r.operational_status <> 'BORRADOR'
 order by r.published_at desc limit 30;
-- Si "depot_arrived_at" no existe en producción (V4.23 no aplicada), quitar esa columna de la consulta.
