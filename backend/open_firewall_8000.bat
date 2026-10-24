@echo off
:: Run as Administrator once — lets ESP32-CAM reach the laptop on port 8000.
netsh advfirewall firewall delete rule name="Egg System Backend 8000" >nul 2>&1
netsh advfirewall firewall add rule name="Egg System Backend 8000" dir=in action=allow protocol=TCP localport=8000
echo Opened TCP 8000 for Egg System backend.
pause
