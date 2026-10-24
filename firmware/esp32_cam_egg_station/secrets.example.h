#ifndef EGG_STATION_SECRETS_H
#define EGG_STATION_SECRETS_H

const char* WIFI_SSID = "YOUR_WIFI_NAME";
const char* WIFI_PASSWORD = "YOUR_WIFI_PASSWORD";

// Optional. The camera joins whichever saved name is in range.
const char* WIFI_SSID_2 = "";
const char* WIFI_PASSWORD_2 = "";
const char* WIFI_SSID_3 = "";
const char* WIFI_PASSWORD_3 = "";

const char* FIREBASE_PROJECT_ID = "egg-system-c36f5";
const char* FIREBASE_WEB_API_KEY = "AIzaSyBBl_A2RIuNbRrCD94EX7bRbcBB--989QQ";

// Same PC that runs: python backend/live_inspection_backend.py
// Used for POST /weight and POST /api/status (heartbeat every 5s).
const char* FARM_BACKEND_URL = "http://192.168.11.212:8000";

// Must match backend/.env FARM_DEVICE_TOKEN (header X-Farm-Device-Token).
// Leave empty only for LAN lab testing when the server also has no token set.
const char* FARM_DEVICE_TOKEN = "YOUR_FARM_DEVICE_TOKEN";

#endif
