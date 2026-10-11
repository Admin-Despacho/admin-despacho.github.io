# TEST_RESULTS 0.6.3-rc1 (hotfix)

| Prueba | Resultado |
|---|---|
| HOTUSR-01 OPTIONS con apikey / x-client-info | PASS |
| HOTUSR-02 ADMIN ACTIVO lista usuarios (permiso desde `user_has_perm`) | PASS |
| HOTUSR-03 sin users.view → 403 con CORS | PASS |
| HOTUSR-04 ADMIN con USUARIOS deshabilitado → 403 | PASS |
| HOTUSR-05 invitación → accept_invite → ACTIVO | PASS |
| HOTUSR-06 segundo accept_invite → 200 idempotente | PASS |
| HOTUSR-07 excepción interna / falta de secrets → 500 JSON con CORS | PASS |
| HOTUSR-08 crear usuario (F05) · HOTUSR-09 restablecer contraseña (F1.1-01) · HOTUSR-10 eliminar/archivar (F08–F12) | PASS |
| Edge Functions total (deno test) + typecheck admin-users | 76 PASS / 0 FAIL + PASS |
| Smoke: login + pantalla Usuarios (E2E RC1.1, 20) · unitarias (94) · build | PASS |

NOT RUN (real): la función desplegada en el proyecto de staging (CORS desde el dominio real, `user_has_perm` y `accept_invite` contra la base real).
Nota: `commercial-reports`, `internal-approvals` y `passkeys` tienen el mismo encabezado CORS reducido; no se tocaron por el alcance del hotfix.
