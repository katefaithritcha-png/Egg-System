@echo off
setlocal EnableDelayedExpansion
title Egg Farm - Backend + Tunnel
cd /d "%~dp0"

echo.
echo ============================================================
echo  FULL STACK  (backend + tunnel)
echo  App:      https://egg-system.paghasianjustine.workers.dev
echo  Farm API: https://egg-farm.eggsorting.site
echo ============================================================
echo.
echo Prefer separate windows?
echo   start-egg-backend.bat   = backend only
echo   start-egg-tunnel.bat    = tunnel only (after backend)
echo.

set "BACKEND_BAT=%~dp0backend\start-egg-backend.bat"
set "TUNNEL_BAT=%USERPROFILE%\cloudflared\start-egg-tunnel-smart.bat"
set "CHECK_PS=%~dp0backend\check-backend.ps1"

if not exist "%BACKEND_BAT%" (
  echo ERROR: missing %BACKEND_BAT%
  pause
  exit /b 1
)
if not exist "%TUNNEL_BAT%" (
  echo ERROR: missing %TUNNEL_BAT%
  pause
  exit /b 1
)

echo [1/3] Starting BACKEND in its own window ...
start "Egg Farm Backend" "%BACKEND_BAT%"

echo [2/3] Waiting for http://192.168.11.212:8000/health ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%CHECK_PS%" -Url "http://192.168.11.212:8000/health" -TimeoutSec 180
if errorlevel 1 (
  echo.
  echo ERROR: backend did not become ready.
  echo Look at the "Egg Farm Backend" window for Python errors.
  pause
  exit /b 1
)
echo Backend ready.

echo [3/3] Starting TUNNEL in its own window ...
start "Egg Farm Tunnel" "%TUNNEL_BAT%"

echo.
echo Done. Keep BOTH windows open while using the farm.
echo Open: https://egg-system.paghasianjustine.workers.dev
echo.
pause
