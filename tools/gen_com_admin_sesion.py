"""B-AL-04 · genera propuestas/comercial/20261201000500_comercial_admin_sesion_vigente.sql desde el TEXTO EXACTO vigente (000100 a 000300):
en cada función del módulo que usa _is_general_admin() lo reemplaza por _com_admin() (Administrador General CON sesión no revocada) y
no cambia nada más. Recrea la política de lectura de originales con la misma regla. Falla si algún texto no coincide."""
import re, sys
SRC = ['propuestas/comercial/20261201000100_comercial_autorizaciones.sql', 'propuestas/comercial/20261201000200_comercial_cuotas_respaldo.sql',
       'propuestas/comercial/20261201000300_comercial_consultar_aprobacion.sql']
last = {}
for p in SRC:
    s = open(p, encoding='utf-8').read()
    for m in re.finditer(r"create or replace function public\.([a-z_]+)\(", s):
        i = m.start(); j = s.find('$$;', s.find('$$', i) + 2) + 3; last[m.group(1)] = s[i:j]
fns = sorted(k for k, v in last.items() if '_is_general_admin()' in v)
if len(fns) != 19: sys.exit('SE ESPERABAN 19 funciones y hay %d' % len(fns))
out = ["""-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · ADMINISTRADOR CON SESIÓN VIGENTE (auditoría B-AL-04) · NO APLICADA. Después de 000100 a 000400.
-- _is_general_admin() de la base verifica rol ADMIN y perfil ACTIVO, pero NO sessions_revoked_at. En las 19 funciones del módulo que lo usan
-- se reemplaza por _com_admin() (= _com_active(): token posterior a la revocación + Administrador General). Ningún otro cambio.
-- Generado por tools/gen_com_admin_sesion.py desde el texto exacto vigente. Funciones: """ + ', '.join(fns) + """
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regprocedure('public._com_admin()') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: aplicar antes 20261201000400. No se modificó nada.'; END IF;
END $guard$;
"""]
for f in fns:
    b = last[f]; n = b.count('public._is_general_admin()')
    if n == 0: sys.exit('sin calificar en ' + f)
    out.append('-- ' + f + ' (' + str(n) + ' reemplazo/s)\n' + b.replace('public._is_general_admin()', 'public._com_admin()') + '\n')
out.append("""-- política de LECTURA de originales (bucket privado com-sources): misma regla, solo si el almacenamiento existe (como en 000200)
DO $pol$ BEGIN
  IF to_regclass('storage.objects') IS NOT NULL THEN
    EXECUTE 'drop policy if exists com_sources_select on storage.objects';
    EXECUTE $p$create policy com_sources_select on storage.objects for select to authenticated using (bucket_id = 'com-sources' and public._com_admin())$p$;
  END IF;
END $pol$;
COMMIT;
""")
open('propuestas/comercial/20261201000500_comercial_admin_sesion_vigente.sql', 'w', encoding='utf-8').write('\n'.join(out))
print('generado:', len(fns), 'funciones')
