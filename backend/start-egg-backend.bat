@echo off
setlocal EnableDelayedExpansion
title Egg Farm Backend (Cloudflare tunnel origin)
cd /d "%~dp0"

set "PY=python"
if exist "%LocalAppData%\Programs\Python\Python311\python.exe" (
  set "PY=%LocalAppData%\Programs\Python\Python311\python.exe"
)

echo.
echo ============================================================
echo  Egg Farm detection engine  (Cloudflare live backend)
echo    Public UI:   https://egg-system.paghasianjustine.workers.dev
echo    Public API:  https://egg-farm.eggsorting.site
echo    Origin bind: 0.0.0.0:8000  (cloudflared only — not for browsers)
echo ============================================================
echo.

"%PY%" --version >nul 2>&1
if errorlevel 1 (
  echo ERROR: Python not found.
  pause
  exit /b 1
)

REM Stop old gateway (:8001) and anything on :8000 — tunnel talks to this app only.
for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":8001" ^| findstr "LISTENING"') do (
  echo Stopping old process on :8001  PID %%p
  taskkill /F /PID %%p >nul 2>&1
)
for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":8000" ^| findstr "LISTENING"') do (
  echo Stopping old process on :8000  PID %%p
  taskkill /F /PID %%p >nul 2>&1
)
timeout /t 2 /nobreak >nul

echo Starting detection engine for Cloudflare tunnel ...
set FARM_APP_PORT=8000
set FARM_APP_HOST=0.0.0.0
set FARM_INNER_PORT=8001
set CAM_PUSH_ONLY=1
set TF_ENABLE_ONEDNN_OPTS=0
REM Threaded :8000 front serves /live.jpg + /api/frame so cloudflared
REM backpressure cannot freeze uvicorn. Inner API stays on :8001.
REM Crack/dirty YOLO TFLite from models\crackegg.tflite + models\dirty.tflite.
set CLASSIFY_ENABLED=1
set CLASSIFY_TF=1
set CLASSIFY_SLEEP_SEC=0.05
set CLASSIFY_HEAVY_SLEEP_SEC=0.35
set AWAIT_WEIGHT_TIMEOUT_SEC=8
set SCAN_SEC=5.0
set SCAN_EARLY_SEC=5.0
"%PY%" live_inspection_backend.py
echo.
echo App stopped.
pause
