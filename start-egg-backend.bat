@echo off
setlocal
title Egg Farm Backend ONLY
cd /d "%~dp0"

echo.
echo ============================================================
echo  BACKEND ONLY  (no tunnel)
echo  Gateway: http://192.168.11.212:8000
echo  App:     http://192.168.11.212:8001
echo  Tunnel:  https://egg-farm.eggsorting.site
echo  Storage: Firebase Firestore (accounts + farm data)
echo ============================================================
echo.
echo This starts the farm PC server only.
echo For internet / phone access, run start-egg-tunnel.bat in
echo a SECOND window after this one shows Ready.
echo.
echo For both at once, use: start-egg-farm.bat
echo.

call "%~dp0backend\start-egg-backend.bat"
