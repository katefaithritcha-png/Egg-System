@echo off
:: Run as Administrator once — lets ESP32-CAM push frames over LAN (smooth live).
:: Extender AP isolation may still block; if so, disable client isolation on the extender.
net session >nul 2>&1
if errorlevel 1 (
  echo Requesting Administrator...
  powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
netsh advfirewall firewall delete rule name="Egg Farm CAM 8000" >nul 2>&1
netsh advfirewall firewall add rule name="Egg Farm CAM 8000" dir=in action=allow protocol=TCP localport=8000 profile=any
echo.
echo OK — inbound TCP 8000 allowed.
echo Reboot the ESP32-CAM (unplug USB or press RESET), then hard-refresh Watch.
pause
