@echo off
setlocal
title Egg Farm Backend ONLY
cd /d "%~dp0"

echo.
echo ============================================================
echo  BACKEND ONLY  (start tunnel separately for live internet)
echo  Public API: https://egg-farm.eggsorting.site
echo  Public UI:  https://egg-system.paghasianjustine.workers.dev
echo ============================================================
echo.
echo Prefer start-egg-farm.bat (backend + Cloudflare tunnel together).
echo.

call "%~dp0backend\start-egg-backend.bat"
