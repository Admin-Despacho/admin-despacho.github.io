"""Sección 4 · genera propuestas/comercial/INSTALAR_MODULO_COMERCIAL.sql: las 9 migraciones del módulo en UNA SOLA transacción (si algo falla,
no queda nada) y, al final, el módulo CERRADO (sin ejecución para usuarios) con la lista EXACTA de permisos a otorgar en ACTIVAR."""
import glob, re, sys
files = sorted(glob.glob('propuestas/comercial/20261201000[1-9]00_*.sql')) + sorted(glob.glob('propuestas/comercial/2026120100[1-9][0-9]00_*.sql'))
if len(files) != 11: sys.exit('se esperaban 11 migraciones y hay %d' % len(files))
parts = []
for f in files:
    s = open(f, encoding='utf-8').read()
    if len(re.findall(r'(?m)^BEGIN;\s*$', s)) != 1 or len(re.findall(r'(?m)^COMMIT;\s*$', s)) != 1: sys.exit('transacción propia inesperada en ' + f)
    s = re.sub(r'(?m)^BEGIN;\s*$', '-- (BEGIN propio retirado: corre dentro de la transacción única)', s)
    s = re.sub(r'(?m)^COMMIT;\s*$', '-- (COMMIT propio retirado)', s)
    parts.append('-- ' + '=' * 110 + '\n-- ' + f.split('/')[-1] + '\n-- ' + '=' * 110 + '\n' + s)
head = """-- =====================================================================================================================
-- INSTALACIÓN ÚNICA · MÓDULO AUTORIZACIONES COMERCIALES + ALARMA (000100 a 001100) · NO APLICAR sin autorización (ver PLAN_PUBLICACION).
-- Generado por tools/gen_instalador.py. UNA transacción: si cualquier paso falla, NO queda ningún objeto del módulo.
-- Al terminar, el módulo queda CERRADO: ninguna función comercial es ejecutable por usuarios hasta correr ACTIVAR_MODULO_COMERCIAL.sql
-- (que verifica el estado y otorga EXACTAMENTE los permisos que dejaron las migraciones). KPI: DESHABILITADO (lo exige 000900).
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '600s';
"""
tail = """
-- ===================== CIERRE: módulo SIN ejecución para usuarios hasta ACTIVAR, SIN romper Storage =====================
-- N-V5-04: las funciones auxiliares que usan las POLÍTICAS de Storage conservan su ejecución (solo devuelven verdadero/falso); los originales
-- comerciales igual quedan cerrados porque esas políticas exigen _com_module_open(), que es falso con la instalación CERRADA.
create table public.com_install_grants(fn regprocedure not null, grantee text not null, primary key (fn, grantee));
revoke all on public.com_install_grants from public, anon, authenticated;
create temp table _com_storage_helpers on commit drop as
  select p.oid::regprocedure fn from pg_proc p
   where p.pronamespace = 'public'::regnamespace and (left(p.proname, 4) = 'com_' or left(p.proname, 5) = '_com_')
     and exists (select 1 from pg_policies pl where pl.schemaname = 'storage'
                  and (coalesce(pl.qual, '') ~ ('[[:<:]]' || p.proname || '[(]') or coalesce(pl.with_check, '') ~ ('[[:<:]]' || p.proname || '[(]')));
insert into public.com_install_grants(fn, grantee)
  select p.oid::regprocedure, r from pg_proc p cross join unnest(array['authenticated', 'anon']) r
   where p.pronamespace = 'public'::regnamespace and (left(p.proname, 4) = 'com_' or left(p.proname, 5) = '_com_') and has_function_privilege(r, p.oid, 'EXECUTE')
     and p.oid::regprocedure not in (select fn from _com_storage_helpers);
DO $close$ DECLARE f regprocedure; BEGIN
  FOR f IN SELECT p.oid::regprocedure FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND (left(p.proname, 4) = 'com_' OR left(p.proname, 5) = '_com_')
             AND p.oid::regprocedure NOT IN (SELECT fn FROM _com_storage_helpers) LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', f); END LOOP;
  IF (SELECT kpi_mode FROM public.com_settings WHERE id = 'DEFAULT') <> 'DESHABILITADO' THEN RAISE EXCEPTION 'EL_KPI_DEBE_QUEDAR_DESHABILITADO'; END IF;
END $close$;
-- N-V5-05: estado de instalación con historial
insert into public.com_install_state(id, status) values ('DEFAULT', 'INSTALADO_CERRADO');
insert into public.com_install_log(status, detail) values ('INSTALADO_CERRADO', jsonb_build_object('paso', 'INSTALAR',
  'permisos_pendientes', (select count(*) from public.com_install_grants where grantee = 'authenticated'),
  'auxiliares_de_storage', (select coalesce(jsonb_agg(fn::text), '[]'::jsonb) from _com_storage_helpers)));
COMMIT;
"""
open('propuestas/comercial/INSTALAR_MODULO_COMERCIAL.sql', 'w', encoding='utf-8').write(head + '\n'.join(parts) + tail)
print('instalador generado con', len(files), 'migraciones')
