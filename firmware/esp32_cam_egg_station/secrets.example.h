#ifndef EGG_STATION_SECRETS_H
#define EGG_STATION_SECRETS_H

// Used only when ARDUINO_LOCAL is 0 (ESP32-CAM picture build).
// The DevKit station runs Arduino-only and ignores these.
const char* WIFI_SSID = "YOUR_WIFI_NAME";
const char* WIFI_PASSWORD = "YOUR_WIFI_PASSWORD";

const char* WIFI_SSID_2 = "";
const char* WIFI_PASSWORD_2 = "";
const char* WIFI_SSID_3 = "";
const char* WIFI_PASSWORD_3 = "";

// Prefer the public tunnel when the extender blocks CAM↔laptop LAN.
// LAN example: "http://192.168.11.212:8000"
// Tunnel:     "https://egg-farm.eggsorting.site"  (cloudflared on laptop → :8000)
const char* FARM_BACKEND_URL = "https://egg-farm.eggsorting.site";

// Must match backend/.env FARM_DEVICE_TOKEN (header X-Farm-Device-Token).
const char* FARM_DEVICE_TOKEN = "eggcam-tunnel-2026";

#endif
