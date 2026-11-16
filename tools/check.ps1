# Stop at the first failure so a partial run is never presented as a clean check.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'use-node.ps1')
Push-Location $projectRoot
try {
    # Use real PostgreSQL/PostGIS semantics; the backend suite guards its dedicated test database before resets.
    & docker compose -f infra/compose.local-database.yml up -d --wait
    if ($LASTEXITCODE -ne 0) { throw 'Local PostgreSQL startup failed.' }
    & npm --prefix backend test
    if ($LASTEXITCODE -ne 0) { throw 'Backend checks failed.' }
    & node --test admin/helpers.test.mjs admin/private-evidence.test.mjs
    if ($LASTEXITCODE -ne 0) { throw 'Admin checks failed.' }
    Set-Location mobile
    & flutter analyze
    if ($LASTEXITCODE -ne 0) { throw 'Flutter analysis failed.' }
    & flutter test
    if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed.' }
    # Restore the caller's directory even when a subprocess fails, so later commands cannot target the wrong component.
} finally { Pop-Location }
