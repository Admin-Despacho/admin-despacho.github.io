"""B-W01 · genera propuestas/comercial/20261201000700_comercial_sesion_vigente_total.sql: en CADA RPC expuesta del módulo (com_*, ejecutable por
authenticated) inserta como PRIMERA instrucción `perform public._com_require_session();` (perfil activo + token posterior a la revocación),
ANTES de cualquier otro permiso. Toma el texto FINAL de 000100 a 000600. Falla si alguna función no tiene el formato esperado."""
import re, sys
SRC = ['20261201000100_comercial_autorizaciones', '20261201000200_comercial_cuotas_respaldo', '20261201000300_comercial_consultar_aprobacion',
       '20261201000400_comercial_alarma_urgente', '20261201000500_comercial_admin_sesion_vigente', '20261201000600_comercial_modulo_historial']
last = {}
for f in SRC:
    s = open('propuestas/comercial/' + f + '.sql', encoding='utf-8').read()
    for m in re.finditer(r"create or replace function public\.(com_[a-z_]+)\(", s):
        i = m.start(); j = s.find('$$;', s.find('$$', i) + 2) + 3; last[m.group(1)] = s[i:j]
INTERNAS = {'com_alarm_escalate_due'}   # la ejecuta la tarea programada (no un usuario): sin EXECUTE para authenticated
fns = sorted(k for k in last if k not in INTERNAS)
GUARD = "  perform public._com_require_session();   -- B-W01: sesión vigente ANTES de cualquier permiso\n"
out = ["""-- =====================================================================================================================
-- PROPUESTA · AUTORIZACIONES COMERCIALES · V4 · SESIÓN VIGENTE EN TODAS LAS RPC (auditoría B-W01) · NO APLICADA. Después de 000100 a 000600.
-- Cada RPC expuesta del módulo verifica PRIMERO perfil activo y token posterior a la revocación (= _com_active / auth_has_perm de la base), antes de
-- evaluar cualquier permiso alternativo. Ningún otro cambio en las funciones. Generado por tools/gen_com_sesion_guard.py desde el texto final.
-- RPC (""" + str(len(fns)) + "): " + ', '.join(fns) + """
-- =====================================================================================================================
BEGIN;
SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '60s';
DO $guard$ BEGIN
  IF to_regprocedure('public.com_history(text,jsonb,jsonb,integer)') IS NULL THEN RAISE EXCEPTION 'DEPENDENCIA_FALTANTE: aplicar antes 000600. No se modificó nada.'; END IF;
END $guard$;
create or replace function public._com_require_session() returns void language plpgsql stable security definer set search_path = public as $$
begin
  if (public._com_active()).id is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
end; $$;
revoke all on function public._com_require_session() from public, anon, authenticated;
"""]
n = 0
for k in fns:
    b = last[k]
    if re.search(r"\blanguage sql\b", b[:b.find('$$')]):
        # única función en SQL simple: se convierte a plpgsql conservando la consulta
        head, body = b[:b.find('$$')], b[b.find('$$') + 2:b.rfind('$$')]
        b = head.replace('language sql', 'language plpgsql') + '$$\nbegin\n' + GUARD + '  return (' + body.strip().rstrip(';') + ');\nend; $$;'
    else:
        m = re.search(r"\$\$\s*(declare\b.*?)?\bbegin\b[ \t]*\n", b, re.S)
        if not m: sys.exit('FORMATO INESPERADO en ' + k)
        b = b[:m.end()] + GUARD + b[m.end():]
    if b.count('_com_require_session') != 1: sys.exit('guarda no insertada en ' + k)
    out.append('-- ' + k + '\n' + b + '\n'); n += 1
out.append('COMMIT;\n')
open('propuestas/comercial/20261201000700_comercial_sesion_vigente_total.sql', 'w', encoding='utf-8').write('\n'.join(out))
print('generado:', n, 'RPC con guarda')
