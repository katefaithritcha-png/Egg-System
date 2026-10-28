# Install Windows logon auto-start for Egg Farm backend + named tunnel.
$ErrorActionPreference = 'Stop'
$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { throw 'python not found on PATH' }

$backendCmd = "`"$python`" `"c:\Egg System\backend\live_inspection_backend.py`""
$tunnelBat = Join-Path $env:USERPROFILE 'cloudflared\start-egg-named-tunnel.bat'

# Backend: start minimized at logon
schtasks /Create /F /TN 'EggSystemBackend' /SC ONLOGON /RL LIMITED `
  /TR $backendCmd /DELAY 0000:20 | Out-Host

# Named tunnel: start 60s after logon (backend TF needs time)
$tunnelTr = "cmd /c `"timeout /t 60 /nobreak >nul & `"$tunnelBat`"`""
schtasks /Create /F /TN 'EggSystemNamedTunnel' /SC ONLOGON /RL LIMITED `
  /TR $tunnelTr | Out-Host

Write-Host ''
Write-Host 'Installed scheduled tasks:'
Write-Host '  EggSystemBackend'
Write-Host '  EggSystemNamedTunnel'
Write-Host ''
Write-Host 'They start when you sign in to Windows.'
Write-Host 'App: https://egg-system.paghasianjustine.workers.dev'
Write-Host 'Farm: https://egg-farm.eggsorting.site'
