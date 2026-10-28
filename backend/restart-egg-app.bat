@echo off
REM Restart ONLY the farm app on :8001. Gateway on :8000 stays up so
REM cloudflared does not log "connection refused" during the restart.
title Restart Egg Farm App
cd /d "%~dp0"

echo Restarting farm app on :8001 (gateway :8000 stays up)...
for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":8001" ^| findstr "LISTENING"') do (
  taskkill /F /PID %%p >nul 2>&1
)
timeout /t 1 /nobreak >nul

netstat -ano | findstr ":8000" | findstr "LISTENING" >nul
if errorlevel 1 (
  start "Egg Farm Gateway" /MIN python farm_gateway.py
  timeout /t 2 /nobreak >nul
)

set FARM_APP_PORT=8001
start "Egg Farm App" /MIN python live_inspection_backend.py
echo Done. Tunnel should stay clean ^(HTTP 503 at worst while app boots^).
timeout /t 3 /nobreak >nul
