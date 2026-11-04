-- SOLO LECTURA (no modifica nada). Vehículos cuyo INTERVALO de service es imposible (p. ej. se cargó el kilometraje como intervalo,
-- como la Kangoo II · AD629SA: intervalo 231.390). Corregirlos desde Configuración → C → EDITAR → "Intervalo de service (km)".
-- El intervalo correcto lo decide Administración (no se corrige automáticamente).
select v.name, v.plate, v.current_km, v.last_service_km, v.service_interval_km as intervalo_guardado,
       v.last_service_km + v.service_interval_km as proximo_mostrado_hoy,
       case when v.service_interval_km >= v.current_km then 'el intervalo es >= al km actual (¿se cargó el kilometraje?)'
            when v.service_interval_km > 100000 then 'intervalo mayor a 100.000 km'
            when v.service_interval_km < 500 then 'intervalo menor a 500 km' end as motivo
  from public.vehicles v
 where v.service_interval_km is null or v.service_interval_km < 500 or v.service_interval_km > 100000 or v.service_interval_km >= v.current_km
 order by v.name;
