#ifndef EGG_STATION_SECRETS_H
#define EGG_STATION_SECRETS_H

const char* WIFI_SSID = "YOUR_WIFI_NAME";
const char* WIFI_PASSWORD = "YOUR_WIFI_PASSWORD";

const char* FIREBASE_PROJECT_ID = "egg-system-c36f5";
const char* FIREBASE_WEB_API_KEY = "YOUR_WEB_API_KEY";

// Same PC that runs: python backend/live_inspection_backend.py
// Used for POST /weight and POST /api/status (heartbeat every 5s).
const char* FARM_BACKEND_URL = "http://192.168.11.212:8000";

#endif
