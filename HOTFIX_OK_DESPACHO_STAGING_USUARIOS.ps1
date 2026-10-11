$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "OK DESPACHO - Hotfix staging de usuarios" -ForegroundColor Cyan
Write-Host "Corrige: permisos de Usuarios + activacion de invitacion idempotente." -ForegroundColor Gray
Write-Host ""

$root = Get-Location
$handler = Join-Path $root "supabase\functions\admin-users\handler.js"
$index   = Join-Path $root "supabase\functions\admin-users\index.ts"
$rules   = Join-Path $root "supabase\functions\_shared\rules.js"
$test    = Join-Path $root "supabase\functions\admin-users\handler.test.js"

foreach ($f in @($handler,$index,$rules)) {
  if (-not (Test-Path $f)) {
    throw "No encuentro $f. Ejecuta este script desde la carpeta ok-despacho-online."
  }
}

function ReadText([string]$path) {
  return [System.IO.File]::ReadAllText($path)
}
function WriteText([string]$path, [string]$text) {
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path, $text, $utf8)
}
function BackupOnce([string]$path) {
  $bak = "$path.bak_staging"
  if (-not (Test-Path $bak)) { Copy-Item $path $bak }
}
function ReplaceExact([string]$text, [string]$old, [string]$new, [string]$label) {
  if ($text.Contains($new)) {
    Write-Host "Ya aplicado: $label" -ForegroundColor DarkGray
    return $text
  }
  if (-not $text.Contains($old)) {
    throw "No pude aplicar '$label' porque el codigo esperado no coincide. No se modifico esa parte."
  }
  Write-Host "Aplicando: $label" -ForegroundColor Yellow
  return $text.Replace($old,$new)
}

BackupOnce $handler
BackupOnce $index
BackupOnce $rules
if (Test-Path $test) { BackupOnce $test }

# 1) handler.js
$h = ReadText $handler

$oldCors = "'access-control-allow-headers': 'authorization, content-type'"
$newCors = "'access-control-allow-headers': 'authorization, content-type, apikey, x-client-info'"
if (-not $h.Contains($newCors)) {
  $h = ReplaceExact $h $oldCors $newCors "CORS para Supabase JS"
}

$oldBlock = @'
  if (action === 'list') {
    if (!hasPerm(actor, 'users.view')) return json(403, { error: 'No tenés permiso para ver usuarios.', code: 'FORBIDDEN' });
    return json(200, { users: await deps.listProfiles() });
  }

  // El usuario invitado confirma su cuenta la primera vez que entra (crea su contraseña).
  if (action === 'accept_invite') {
    if (!actor || actor.status !== 'INVITACION_PENDIENTE') return json(409, { error: 'La invitación ya fue aceptada o no corresponde.', code: 'NO_INVITE' });
    try { await deps.updateStatus(actor.id, { status: 'ACTIVO' }); }
    catch (e) { return json(500, { error: 'No se pudo activar tu usuario: ' + errMsg(e), code: 'ACCEPT_FAILED' }); }
    await audit('INVITE_ACCEPTED', actor.id, { status: actor.status }, { status: 'ACTIVO' });
    return json(200, { user: await deps.getProfile(actor.id) });
  }

  const allUsers = await deps.listProfiles();
'@

$newBlock = @'
  if (action === 'list') {
    const allowed = actor && await deps.hasPermission(actor.id, 'users.view');
    if (!allowed) return json(403, { error: 'No tenés permiso para ver usuarios.', code: 'FORBIDDEN' });
    return json(200, { users: await deps.listProfiles() });
  }

  // El usuario invitado confirma su cuenta la primera vez que entra (crea su contraseña).
  // Idempotente: si Auth ya consumió el enlace y el perfil quedó ACTIVO, reintentar devuelve éxito.
  if (action === 'accept_invite') {
    if (!actor) return json(404, { error: 'No se encontró el perfil del usuario.', code: 'PROFILE_NOT_FOUND' });
    if (actor.status === 'ACTIVO') return json(200, { user: actor });
    if (actor.status !== 'INVITACION_PENDIENTE') return json(409, { error: 'La invitación no corresponde a un usuario pendiente.', code: 'NO_INVITE' });
    try { await deps.updateStatus(who.id, { status: 'ACTIVO' }); }
    catch (e) { return json(500, { error: 'No se pudo activar tu usuario: ' + errMsg(e), code: 'ACCEPT_FAILED' }); }
    await audit('INVITE_ACCEPTED', who.id, { status: actor.status }, { status: 'ACTIVO' });
    return json(200, { user: await deps.getProfile(who.id) });
  }

  const canManageUsers = actor && await deps.hasPermission(actor.id, 'users.manage');
  if (!canManageUsers) return json(403, { error: 'No tenés permiso para administrar usuarios.', code: 'FORBIDDEN' });

  const allUsers = await deps.listProfiles();
'@

$h = ReplaceExact $h $oldBlock $newBlock "Permisos de usuarios desde la base + activacion idempotente"

$oldValidate = "  const err = validateUserAction(action, { actor, target, allUsers, hasHistory, activeRoutes: routes.length, payload });"
$newValidate = "  const err = validateUserAction(action, { actor, target, allUsers, hasHistory, activeRoutes: routes.length, payload, permissionGranted: true });"
$h = ReplaceExact $h $oldValidate $newValidate "Validacion administrativa usando permiso efectivo"

WriteText $handler $h

# 2) index.ts
$i = ReadText $index
$oldIndex = @'
  async getProfile(id: string) { const { data } = await admin.from('profiles').select('*').eq('id', id).maybeSingle(); return data ? (await withCarriers([data]))[0] : null; },
  async listProfiles()
'@
$newIndex = @'
  async getProfile(id: string) { const { data } = await admin.from('profiles').select('*').eq('id', id).maybeSingle(); return data ? (await withCarriers([data]))[0] : null; },
  async hasPermission(id: string, perm: string) { return !!must(await admin.rpc('user_has_perm', { p_user: id, p_perm: perm })); },
  async listProfiles()
'@
$i = ReplaceExact $i $oldIndex $newIndex "RPC user_has_perm en Edge Function"
WriteText $index $i

# 3) rules.js
$r = ReadText $rules
$oldRules = @'
  const { actor, target, allUsers = [], hasHistory = false, activeRoutes = 0, payload = {} } = ctx;
  const deny = (code, status, message) => ({ code, status, message });
  if (!actor) return deny('NO_AUTH', 401, 'Sesión inválida.');
  if (!hasPerm(actor, 'users.manage')) return deny('FORBIDDEN', 403, 'No tenés permiso para administrar usuarios.');
'@
$newRules = @'
  const { actor, target, allUsers = [], hasHistory = false, activeRoutes = 0, payload = {}, permissionGranted = false } = ctx;
  const deny = (code, status, message) => ({ code, status, message });
  if (!actor) return deny('NO_AUTH', 401, 'Sesión inválida.');
  if (!permissionGranted && !hasPerm(actor, 'users.manage')) return deny('FORBIDDEN', 403, 'No tenés permiso para administrar usuarios.');
'@
$r = ReplaceExact $r $oldRules $newRules "Reglas compartidas compatibles con permiso validado en DB"
WriteText $rules $r

# 4) Ajustes mínimos del test local para que el proyecto quede coherente.
if (Test-Path $test) {
  $t = ReadText $test

  $oldTestDeps = @'
    getProfile: async id => { const p = P(id); return p ? { ...p, carriers: [...p.carriers] } : null; },
    listProfiles:
'@
  $newTestDeps = @'
    getProfile: async id => { const p = P(id); return p ? { ...p, carriers: [...p.carriers] } : null; },
    hasPermission: async (id, perm) => {
      const p = P(id); if (!p || p.status !== 'ACTIVO') return false;
      if (p.role !== 'ADMIN') return false;
      return !((p.disabled_modules || []).includes(perm === 'users.view' || perm === 'users.manage' ? 'USUARIOS' : ''));
    },
    listProfiles:
'@
  if ($t.Contains($oldTestDeps)) {
    $t = $t.Replace($oldTestDeps,$newTestDeps)
  }

  $oldF18 = "  eq((await read(await call(deps, 'tok-inv', { action: 'accept_invite' }))).status, 409);"
  $newF18 = "  eq((await read(await call(deps, 'tok-inv', { action: 'accept_invite' }))).status, 200);"
  if ($t.Contains($oldF18)) { $t = $t.Replace($oldF18,$newF18) }
  WriteText $test $t
}

Write-Host ""
Write-Host "Archivos corregidos correctamente." -ForegroundColor Green
Write-Host "Desplegando admin-users..." -ForegroundColor Cyan

& npx supabase@latest functions deploy admin-users
if ($LASTEXITCODE -ne 0) { throw "Fallo el deploy de admin-users." }

Write-Host ""
Write-Host "HOTFIX TERMINADO." -ForegroundColor Green
Write-Host "Volvé a OK Despacho y recargá la pantalla Usuarios." -ForegroundColor White
