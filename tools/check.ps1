# Stop at the first failure so a partial run is never presented as a clean check.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    & ./backend/.venv/Scripts/python.exe -m unittest backend.test_app -v
    if ($LASTEXITCODE -ne 0) { throw 'Backend checks failed.' }
    & node --test admin/helpers.test.mjs admin/private-evidence.test.mjs
    if ($LASTEXITCODE -ne 0) { throw 'Admin checks failed.' }
    Set-Location mobile
    & flutter analyze
    if ($LASTEXITCODE -ne 0) { throw 'Flutter analysis failed.' }
    & flutter test
    if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed.' }
} finally { Pop-Location }
