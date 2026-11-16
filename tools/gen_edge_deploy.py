"""V5 · Edge Functions a desplegar construidas desde lo REALMENTE DESPLEGADO (evidencia de Work, 15/11), no desde Git.
admin-users: rules.js DESPLEGADO + SOLO lo de COMERCIAL (cada cambio se verifica: si el texto desplegado no coincide, falla)."""
import os, shutil, sys, hashlib
EV = sys.argv[1]   # carpeta edge-originals de la evidencia
SRC = os.path.join(EV, 'admin-users/source')
assert hashlib.sha256(open(os.path.join(SRC, '_shared/rules.js'), 'rb').read()).hexdigest() == '104b07759c90d46d85514c6c42d5f87251cf67226bea0b5e6d45616dc2fdfca2', 'rules.js desplegado inesperado'
OUT = 'edge-deploy/admin-users'; shutil.rmtree(OUT, ignore_errors=True); shutil.copytree(SRC, OUT)
p = os.path.join(OUT, '_shared/rules.js'); s = open(p, encoding='utf-8').read()
def rep(a, b):
    global s
    if s.count(a) != 1: sys.exit('NO COINCIDE en rules.js desplegado: ' + a[:70])
    s = s.replace(a, b)
rep("export const ROLES = ['ADMIN', 'SUPERVISOR_DESPACHO', 'OPERARIO_DEPOSITO', 'TRANSPORTISTA', 'TRANSPORTISTA_INTERNO', 'SOLO_LECTURA'];",
    "export const ROLES = ['ADMIN', 'SUPERVISOR_DESPACHO', 'OPERARIO_DEPOSITO', 'TRANSPORTISTA', 'TRANSPORTISTA_INTERNO', 'SOLO_LECTURA', 'COMERCIAL'];")
i = s.index('export const ROLE_LABEL'); j = s.index('};', i)
pre_ = s[:j].rstrip(); pre_ = pre_ if pre_.endswith(',') else pre_ + ','   # la última entrada desplegada no lleva coma
s = pre_ + "\n  COMERCIAL: 'Comercial'   // Autorizaciones comerciales\n" + s[j:]
rep("'users.assign_supervisor', 'users.manage_permissions', 'vehicles.view', 'vehicles.service_manage', 'backup.manage'\n",
    "'users.assign_supervisor', 'users.manage_permissions', 'vehicles.view', 'vehicles.service_manage', 'backup.manage',\n  'com.request', 'com.approve', 'com.track', 'com.sources.upload'   // Autorizaciones comerciales\n")
rep("  SOLO_LECTURA: ['routes.view_all']\n", "  SOLO_LECTURA: ['routes.view_all'],\n  COMERCIAL: ['com.request']   // Autorizaciones comerciales: crea y consulta SUS solicitudes\n")
i = s.index('export const ROLE_PERMISSIONS'); j = s.index('};', i) + 2
s = s[:j] + "\n// Autorizaciones comerciales: trazabilidad para Despacho e ingesta de las cargas diarias (Operario)\nROLE_PERMISSIONS.SUPERVISOR_DESPACHO.push('com.track'); ROLE_PERMISSIONS.OPERARIO_DEPOSITO.push('com.track', 'com.sources.upload');" + s[j:]
rep("export const MODULES = ['DESPACHO', 'MIS_HOJAS', 'USUARIOS', 'INFORMES', 'APROBACIONES', 'CONFIGURACION', 'AUDITORIA'];",
    "export const MODULES = ['DESPACHO', 'MIS_HOJAS', 'USUARIOS', 'INFORMES', 'APROBACIONES', 'CONFIGURACION', 'AUDITORIA', 'COMERCIAL'];")
i = s.index('export const MODULE_LABEL'); j = s.index('};', i)
s = s[:j].rstrip() + ", COMERCIAL: 'Comercial' " + s[j:]
rep("  AUDITORIA: ['audit.view', 'identity_docs.view']\n", "  AUDITORIA: ['audit.view', 'identity_docs.view'],\n  COMERCIAL: ['com.request', 'com.approve', 'com.track', 'com.sources.upload']\n")
open(p, 'w', encoding='utf-8').write(s)
open(os.path.join(OUT, 'ORIGEN.txt'), 'w', encoding='utf-8').write('admin-users a desplegar = fuente DESPLEGADA v25 (evidencia de Work, rules.js SHA-256 104b0775…) + SOLO lo de COMERCIAL (tools/gen_edge_deploy.py).\nindex.ts, handler.js, _shared/http.js y deno.json: idénticos a lo desplegado.\n')
print('admin-users para desplegar generado')
