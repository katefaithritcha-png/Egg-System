@echo off
setlocal EnableDelayedExpansion
title Egg Farm Backend
cd /d "%~dp0"

REM Prefer a known Python install; fall back to PATH.
set "PY=python"
if exist "%LocalAppData%\Programs\Python\Python311\python.exe" (
  set "PY=%LocalAppData%\Programs\Python\Python311\python.exe"
)

echo.
echo ============================================================
echo  Egg Farm Backend
echo    Gateway (LAN):  http://192.168.11.212:8000
echo    App (LAN):      http://192.168.11.212:8001
echo    Hosted app:     https://egg-system.paghasianjustine.workers.dev
echo    Farm tunnel:    https://egg-farm.eggsorting.site
echo    Storage:        Firebase Firestore only
echo ============================================================
echo.

"%PY%" --version >nul 2>&1
if errorlevel 1 (
  echo ERROR: Python not found.
  echo Install Python 3.11 or add python.exe to PATH.
  pause
  exit /b 1
)

REM Stop old app on :8001 (keep gateway if healthy).
for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":8001" ^| findstr "LISTENING"') do (
  echo Stopping old app on :8001  PID %%p
  taskkill /F /PID %%p >nul 2>&1
)

REM Start gateway on :8000 if missing.
netstat -ano | findstr ":8000" | findstr "LISTENING" >nul
if errorlevel 1 (
  echo Starting farm gateway on :8000 ...
  start "Egg Farm Gateway" /MIN "%PY%" farm_gateway.py
  timeout /t 2 /nobreak >nul
) else (
  echo Gateway already listening on :8000
)

echo Starting farm app on :8001 ...
set FARM_APP_PORT=8001
"%PY%" live_inspection_backend.py
echo.
echo App stopped. Gateway on :8000 may still be running.
pause
