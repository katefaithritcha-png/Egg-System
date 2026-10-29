@echo off
setlocal EnableDelayedExpansion
title Egg Farm - LIVE (Cloudflare only)
cd /d "%~dp0"

echo.
echo ============================================================
echo  LIVE FARM  -  Cloudflare only (no localhost for users)
echo  UI:       https://egg-system.paghasianjustine.workers.dev
echo  Farm API: https://egg-farm.eggsorting.site
echo ============================================================
echo.

set "BACKEND_BAT=%~dp0backend\start-egg-backend.bat"
set "WATCH_PS=%~dp0backend\watch-egg-farm.ps1"
set "TUNNEL_BAT=%USERPROFILE%\cloudflared\start-egg-tunnel-smart.bat"
set "CHECK_PS=%~dp0backend\check-backend.ps1"
set "PUBLIC_HEALTH=https://egg-farm.eggsorting.site/health"

if not exist "%BACKEND_BAT%" (
  echo ERROR: missing %BACKEND_BAT%
  pause
  exit /b 1
)
if not exist "%TUNNEL_BAT%" (
  echo ERROR: missing tunnel launcher %TUNNEL_BAT%
  pause
  exit /b 1
)

echo [1/4] Starting farm detection engine (Cloudflare tunnel origin) ...
start "Egg Farm Backend" "%BACKEND_BAT%"

echo [2/4] Waiting for local origin http://127.0.0.1:8000/health ...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ok=$false; for($i=0;$i -lt 90;$i++){ try { $c=(curl.exe -s -o NUL -w '%%{http_code}' --max-time 2 http://127.0.0.1:8000/health); if($c -eq '200'){ $ok=$true; Write-Host ('local ready @'+($i*2)+'s'); break } } catch {}; Start-Sleep 2 }; if(-not $ok){ exit 1 }"
if errorlevel 1 (
  echo ERROR: local origin :8000 did not become ready.
  echo Open the Backend window and check for Python errors.
  pause
  exit /b 1
)

echo [3/4] Starting Cloudflare tunnel (only after origin is up) ...
start "Egg Farm Tunnel" "%TUNNEL_BAT%"

echo [4/4] Waiting for Cloudflare live API %PUBLIC_HEALTH% ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%CHECK_PS%" -Url "%PUBLIC_HEALTH%" -TimeoutSec 180
if errorlevel 1 (
  echo ERROR: Cloudflare farm API did not become ready.
  echo Keep Backend + Tunnel windows open, then retry.
  pause
  exit /b 1
)
echo Cloudflare live API ready.

if exist "%WATCH_PS%" (
  start "Egg Farm Watchdog" /MIN powershell -NoProfile -ExecutionPolicy Bypass -File "%WATCH_PS%"
)

echo.
echo Keep Backend + Tunnel + Watchdog open while the farm is LIVE.
echo Users open ONLY:
echo   https://egg-system.paghasianjustine.workers.dev
echo Camera / API:
echo   https://egg-farm.eggsorting.site
echo.
pause
