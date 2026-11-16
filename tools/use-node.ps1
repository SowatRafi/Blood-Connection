# Prefer an installed Node 24 LTS; the project-local portable installation leaves other projects alone.
$ErrorActionPreference = 'Stop'
$nodeCommand = Get-Command node -ErrorAction SilentlyContinue
$nodeMajor = if ($nodeCommand) { & $nodeCommand.Source -p 'process.versions.node.split(".")[0]' 2>$null } else { '' }
if ($nodeMajor -ne '24') {
    $portableRoot = Join-Path $env:LOCALAPPDATA 'Programs/BloodConnectionNode'
    $portable = Get-ChildItem -LiteralPath $portableRoot -Filter 'node-v24*-win-x64' -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $portable -or -not (Test-Path -LiteralPath (Join-Path $portable.FullName 'node.exe'))) {
        throw 'Install Node.js 24 LTS before running the backend tools.'
    }
    $env:Path = "$($portable.FullName);$env:Path"
}
