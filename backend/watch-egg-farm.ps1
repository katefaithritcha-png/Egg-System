# LIVE Cloudflare farm watchdog.
# Keeps origin :8000 + cloudflared up so CF never sees "connection refused".
# ESP32-CAM + users → https://egg-farm.eggsorting.site (never localhost).

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Py = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'
if (-not (Test-Path $Py)) { $Py = 'python' }
$Cf = Join-Path $env:USERPROFILE 'cloudflared\cloudflared.exe'
$TokenFile = Join-Path $env:USERPROFILE 'cloudflared\egg-farm-backend.token'
$PublicUrl = 'https://egg-farm.eggsorting.site/health'
$LocalUrl = 'http://127.0.0.1:8000/health'
$Log = Join-Path $Root '_watchdog.log'

function Write-Log([string]$Msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
  Write-Host $line
  try { Add-Content -Path $Log -Value $line -ErrorAction SilentlyContinue } catch {}
}

function Test-HttpOk([string]$Url, [int]$TimeoutSec = 6) {
  try {
    $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time $TimeoutSec $Url 2>$null
    return ($code -eq '200')
  } catch { return $false }
}

function Test-LocalHealth {
  return (Test-HttpOk $LocalUrl 3)
}

function Ensure-Listen([int]$Port) {
  return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

function Stop-App {
  Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'live_inspection|farm_gateway' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 2
}

function Set-AppEnv {
  $env:FARM_APP_PORT = '8000'
  $env:FARM_APP_HOST = '0.0.0.0'
  $env:FARM_INNER_PORT = '8001'
  $env:CAM_PUSH_ONLY = '1'
  $env:TF_ENABLE_ONEDNN_OPTS = '0'
  $env:CLASSIFY_ENABLED = '1'
  $env:CLASSIFY_TF = '1'
  $env:CLASSIFY_SLEEP_SEC = '0.05'
  $env:CLASSIFY_HEAVY_SLEEP_SEC = '0.35'
  $env:AWAIT_WEIGHT_TIMEOUT_SEC = '8'
  $env:SCAN_SEC = '5.0'
  $env:SCAN_EARLY_SEC = '5.0'
  $env:PYTHONUNBUFFERED = '1'
}

function Start-App {
  Write-Log 'starting detection engine (origin :8000)'
  Set-AppEnv
  Start-Process -FilePath $Py -ArgumentList @('-u', 'live_inspection_backend.py') `
    -WorkingDirectory $Root -WindowStyle Minimized `
    -RedirectStandardOutput (Join-Path $Root '_boot_out.txt') `
    -RedirectStandardError (Join-Path $Root '_boot_err.txt')
}

function Wait-LocalUp([int]$MaxSec = 60) {
  $deadline = (Get-Date).AddSeconds($MaxSec)
  while ((Get-Date) -lt $deadline) {
    if (Test-LocalHealth) { return $true }
    Start-Sleep -Seconds 2
  }
  return $false
}

function Start-Tunnel {
  if (-not (Test-Path $Cf) -or -not (Test-Path $TokenFile)) {
    Write-Log 'cloudflared/token missing — cannot start tunnel'
    return
  }
  Write-Log 'starting cloudflared'
  Get-Process cloudflared -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1
  $token = (Get-Content $TokenFile -Raw).Trim()
  Start-Process -FilePath $Cf `
    -ArgumentList @('tunnel', '--no-autoupdate', 'run', '--token', $token) `
    -WorkingDirectory (Split-Path $Cf) -WindowStyle Minimized
}

Write-Log 'LIVE farm watchdog started (origin + tunnel)'
$failStreak = 0

while ($true) {
  $localOk = Test-LocalHealth
  if (-not $localOk) {
    Write-Log 'origin :8000 down or not healthy — restart detection engine'
    # Do not kill a healthy listen that is still booting TF models.
    if (-not (Ensure-Listen 8000)) {
      Start-App
    } else {
      # Listening but /health fails — hard bounce.
      Stop-App
      Start-App
    }
    if (-not (Wait-LocalUp 70)) {
      Write-Log 'origin failed to become healthy'
    } else {
      Write-Log 'origin healthy again'
    }
  }

  $cfUp = [bool](Get-Process cloudflared -ErrorAction SilentlyContinue)
  if (-not $cfUp) {
    # Only attach tunnel after origin answers — avoids CF "connection refused".
    if (Test-LocalHealth) {
      Start-Tunnel
      Start-Sleep -Seconds 6
    } else {
      Write-Log 'skip tunnel start — origin not ready'
    }
  }

  if (Test-LocalHealth) {
    if (-not (Test-HttpOk $PublicUrl 12)) {
      $failStreak++
      Write-Log ("public Cloudflare health fail streak={0}" -f $failStreak)
      if ($failStreak -ge 2) {
        Write-Log 'bouncing tunnel (origin is up locally)'
        Start-Tunnel
        Start-Sleep -Seconds 8
        if (-not (Test-HttpOk $PublicUrl 12)) {
          Write-Log 'public still down — bounce origin + tunnel'
          Stop-App
          Start-App
          [void](Wait-LocalUp 70)
          Start-Tunnel
          Start-Sleep -Seconds 8
        }
        $failStreak = 0
      }
    } else {
      $failStreak = 0
    }
  }

  Start-Sleep -Seconds 8
}
