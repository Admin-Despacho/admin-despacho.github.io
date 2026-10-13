-- OK DESPACHO ONLINE — RC2.1d (incremental): routing_rules_version obligatoria y EXACTA al publicar (análogo a rules_version).
create or replace function public.trg_routes_zz_routing_version() returns trigger language plpgsql as $$
declare cur int; v int;
begin
  if coalesce(auth.role(), '') <> 'authenticated' then return new; end if;  -- restauración/cargas técnicas: el histórico conserva su versión
  select max(version) into cur from public.routing_rules;
  if new.sheet_snapshot is null or not (new.sheet_snapshot ? 'routing_rules_version') or new.sheet_snapshot->>'routing_rules_version' is null then
    raise exception 'ROUTING_RULES_REQUIRED: la hoja debe calcularse con la versión vigente de las reglas de asignación (v%)', cur using errcode = '23514'; end if;
  begin v := (new.sheet_snapshot->>'routing_rules_version')::int; exception when others then raise exception 'ROUTING_RULES_UNKNOWN: versión de reglas de asignación inválida' using errcode = '23514'; end;
  if v < cur then raise exception 'ROUTING_RULES_OUTDATED: las reglas de asignación cambiaron (v%); recalculá la hoja antes de publicar', cur using errcode = '23514'; end if;
  if v > cur then raise exception 'ROUTING_RULES_UNKNOWN: la versión de reglas de asignación v% no existe (vigente v%)', v, cur using errcode = '23514'; end if;
  return new;
end; $$;
-- después de la validación de rules_version (los triggers BEFORE INSERT corren en orden alfabético: routes_rules_version antes que routes_zz_routing_version)
drop trigger if exists routes_zz_routing_version on public.routes;
create trigger routes_zz_routing_version before insert on public.routes for each row execute function public.trg_routes_zz_routing_version();
