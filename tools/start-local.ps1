# Start one loopback-only API so local demo credentials never reach the network.
param([int]$Port = 8000, [switch]$Calls, [switch]$Push)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'use-node.ps1')
Push-Location $projectRoot
try {
    $env:DEMO_MODE = '1'
    $env:HOST = '127.0.0.1'
    $env:PORT = "$Port"
    # Public credentials are restricted to the isolated loopback development database.
    # Ignore inherited deployment URLs: a local-demo launcher must never seed a hosted database.
    $runtimePassword = if ($env:BC_RUNTIME_PASSWORD) { $env:BC_RUNTIME_PASSWORD } else { 'local-development-runtime-only' }
    $migrationPassword = if ($env:BC_MIGRATION_PASSWORD) { $env:BC_MIGRATION_PASSWORD } else { 'local-development-migration-only' }
    $env:DATABASE_URL = 'postgresql://blood_connection_app:' + [Uri]::EscapeDataString($runtimePassword) + '@127.0.0.1:5436/blood_connection'
    $env:MIGRATION_DATABASE_URL = 'postgresql://blood_connection_migrator:' + [Uri]::EscapeDataString($migrationPassword) + '@127.0.0.1:5436/blood_connection'
    & docker compose -f infra/compose.local-database.yml up -d --wait
    if ($LASTEXITCODE -ne 0) { throw 'Local PostgreSQL startup failed.' }
    Set-Location backend
    if (-not (Test-Path -LiteralPath 'node_modules/fastify')) {
        & npm ci --ignore-scripts
        if ($LASTEXITCODE -ne 0) { throw 'Backend dependency installation failed.' }
    }
    & npm run db:migrate
    if ($LASTEXITCODE -ne 0) { throw 'Database migration failed.' }
    # The long-running API receives only its restricted runtime connection, never migration credentials.
    Remove-Item Env:MIGRATION_DATABASE_URL -ErrorAction SilentlyContinue
    if ($Calls) {
        # This deliberately public fixture only works with the loopback-only local LiveKit container.
        $env:LIVEKIT_URL = 'ws://127.0.0.1:7880'
        $env:LIVEKIT_API_KEY = 'bloodconnection-local'
        $env:LIVEKIT_API_SECRET = 'local-development-only-blood-connection-not-for-production-2015'
    }
    if ($Push) { $env:PUSH_ALLOWED_ORIGINS = 'http://127.0.0.1:8090' }
    & npm start
    if ($LASTEXITCODE -ne 0) { throw 'Backend stopped with an error.' }
} finally { Pop-Location }
