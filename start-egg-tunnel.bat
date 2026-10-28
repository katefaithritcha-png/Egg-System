@echo off
setlocal
title Egg Farm Tunnel ONLY
cd /d "%~dp0"

echo.
echo ============================================================
echo  TUNNEL ONLY  (backend must already be running)
echo  Farm API: https://egg-farm.eggsorting.site
echo ============================================================
echo.
echo Make sure backend is up first:
echo   1) Run start-egg-backend.bat
echo   2) Wait until /health is OK
echo   3) Then run this file
echo.

set "CHECK=%~dp0backend\check-backend.ps1"
if exist "%CHECK%" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%CHECK%" -TimeoutSec 20
  if errorlevel 1 (
    echo.
    echo ERROR: backend not ready on :8000
    echo Start start-egg-backend.bat first, then try again.
    pause
    exit /b 1
  )
)

set "TUNNEL_BAT=%USERPROFILE%\cloudflared\start-egg-tunnel-smart.bat"
if not exist "%TUNNEL_BAT%" (
  echo ERROR: missing %TUNNEL_BAT%
  pause
  exit /b 1
)

call "%TUNNEL_BAT%"
