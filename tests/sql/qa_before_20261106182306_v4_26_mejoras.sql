-- Solo PostgreSQL temporal de pruebas. Del esquema QA/base_setup.sql.
create schema okd_delivery_security;grant usage on schema okd_delivery_security to authenticated;
;
CREATE OR REPLACE FUNCTION okd_delivery_security.may_read(p_route uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id=auth.uid() AND p.status='ACTIVO'
      AND (p.role='ADMIN' OR (
        p.role='SUPERVISOR_DESPACHO'
        AND public.auth_has_perm('signatures.view')
        AND EXISTS (
          SELECT 1 FROM public.routes r WHERE r.id=p_route
          AND (public._route_belongs_to(r.id,r.published_by,p.id)
            OR EXISTS (SELECT 1 FROM public.team_of(p.id) AS t(member_id)
              WHERE public._route_belongs_to(r.id,r.published_by,t.member_id)))
        )
      ))
  );
$function$
;
