@echo off
REM Restart the Cloudflare tunnel origin (detection engine on :8000).
REM Keep cloudflared running — watchdog will reattach once /health is 200.
title Restart Egg Farm App
cd /d "%~dp0"

set "PY=python"
if exist "%LocalAppData%\Programs\Python\Python311\python.exe" (
  set "PY=%LocalAppData%\Programs\Python\Python311\python.exe"
)

echo Restarting Cloudflare tunnel origin on :8000 ...
for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":8001" ^| findstr "LISTENING"') do (
  taskkill /F /PID %%p >nul 2>&1
)
for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":8000" ^| findstr "LISTENING"') do (
  taskkill /F /PID %%p >nul 2>&1
)
timeout /t 2 /nobreak >nul

set FARM_APP_PORT=8000
set FARM_APP_HOST=0.0.0.0
set FARM_INNER_PORT=8001
set CAM_PUSH_ONLY=1
set TF_ENABLE_ONEDNN_OPTS=0
set CLASSIFY_ENABLED=1
set CLASSIFY_TF=1
set CLASSIFY_SLEEP_SEC=0.05
set CLASSIFY_HEAVY_SLEEP_SEC=0.35
set AWAIT_WEIGHT_TIMEOUT_SEC=8
set SCAN_SEC=5.0
set SCAN_EARLY_SEC=5.0
set PYTHONUNBUFFERED=1
start "Egg Farm Backend" /MIN "%PY%" -u live_inspection_backend.py

echo Waiting for local origin health ...
set /a n=0
:wait_local
timeout /t 2 /nobreak >nul
curl.exe -s -o NUL -w "%%{http_code}" --max-time 2 http://127.0.0.1:8000/health | findstr /C:"200" >nul
if not errorlevel 1 goto ready
set /a n+=1
if %n% LSS 40 goto wait_local
echo WARNING: origin not healthy yet — keep tunnel/watchdog open.
goto end

:ready
echo Origin ready on :8000
if not exist "%USERPROFILE%\cloudflared\cloudflared.exe" goto end
tasklist /FI "IMAGENAME eq cloudflared.exe" 2>NUL | find /I "cloudflared.exe" >nul
if errorlevel 1 (
  echo Starting cloudflared ...
  start "Egg Farm Tunnel" "%USERPROFILE%\cloudflared\start-egg-tunnel-smart.bat"
)

:end
echo Public live API: https://egg-farm.eggsorting.site
timeout /t 3 /nobreak >nul
