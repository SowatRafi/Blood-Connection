# Start one loopback-only API so local demo credentials never reach the network.
param([int]$Port = 8000, [switch]$Calls, [switch]$Push)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$pythonPath = Join-Path $projectRoot 'backend/.venv/Scripts/python.exe'
if (-not (Test-Path -LiteralPath $pythonPath)) {
    throw 'Create backend/.venv and install backend/requirements.txt first; see README.md.'
}
Push-Location $projectRoot
try {
    $env:DEMO_MODE = '1'
    $env:HOST = '127.0.0.1'
    $env:PORT = "$Port"
    if ($Calls) {
        # This deliberately public fixture only works with the loopback-only local LiveKit container.
        $env:LIVEKIT_URL = 'ws://127.0.0.1:7880'
        $env:LIVEKIT_API_KEY = 'bloodconnection-local'
        $env:LIVEKIT_API_SECRET = 'local-development-only-blood-connection-not-for-production-2015'
    }
    if ($Push) { $env:PUSH_ALLOWED_ORIGINS = 'http://127.0.0.1:8090' }
    & $pythonPath -m backend
} finally { Pop-Location }
