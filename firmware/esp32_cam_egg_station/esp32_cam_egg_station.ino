/*
 * Egg Sorting station — AI Thinker ESP32-CAM
 * HX711 load cell + L298N conveyor + IR egg detect + OV2640 MJPEG stream
 *
 * Arduino IDE: ESP32 board package, libraries "HX711" (bogde) and ESP32 built-in HTTP.
 * Open Serial Monitor at 115200, copy the printed stream URL into the PC backend.
 *
 * ESP32-CAM-MB upload (required or flash will fail):
 *   Board: AI Thinker ESP32-CAM
 *   Upload Speed: 115200   (not 460800)
 *   Flash Frequency: 40MHz
 *   Flash Mode: DIO
 * Unplug HX711 / L298N / IR first. Hold IO0, tap RST, Upload, keep holding IO0.
 *
 * IR module (+ / G / DO / AO): + → 5V, G → GND, DO → GPIO 4. Leave AO unconnected.
 * Scale Serial (after Station online): t = tare, c50 = calibrate with 50g, h = help.
 */

#include "esp_camera.h"
#include "soc/soc.h"
#include "soc/rtc_cntl_reg.h"
#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include "HX711.h"
#include "esp_http_server.h"
#include <Preferences.h>
#include "secrets.h"

static const char* FIRESTORE_COLLECTION = "egg_readings";

const int LOADCELL_DOUT_PIN = 13;
const int LOADCELL_SCK_PIN = 12;
HX711 scale;
Preferences scalePrefs;
float calibration_factor = 2280.0;
bool scaleReady = false;
const float DEFAULT_CAL_WEIGHT_G = 50.0;

const int MOTOR_ENA = 14;
const int MOTOR_IN1 = 15;
const int CONVEYOR_SPEED = 180;
// L298N IN2 stays jumpered to L298N GND. Do not use GPIO 2 for the motor.

// GPIO 4 is the onboard flash LED; it is the only spare pin with PSRAM in use.
const int IR_DO_PIN = 4;
// HIGH = egg for this module. Serial IR pin=0 means clear → conveyor ON.
const bool IR_ACTIVE_LOW = false;

#define PWDN_GPIO_NUM 32
#define RESET_GPIO_NUM -1
#define XCLK_GPIO_NUM 0
#define SIOD_GPIO_NUM 26
#define SIOC_GPIO_NUM 27
#define Y9_GPIO_NUM 35
#define Y8_GPIO_NUM 34
#define Y7_GPIO_NUM 39
#define Y6_GPIO_NUM 36
#define Y5_GPIO_NUM 21
#define Y4_GPIO_NUM 19
#define Y3_GPIO_NUM 18
#define Y2_GPIO_NUM 5
#define VSYNC_GPIO_NUM 25
#define HREF_GPIO_NUM 23
#define PCLK_GPIO_NUM 22

httpd_handle_t stream_httpd = NULL;
unsigned long lastWeightCheck = 0;
unsigned long lastWeightPost = 0;
unsigned long lastHeartbeat = 0;
unsigned long lastWifiDot = 0;
unsigned long wifiBeginAt = 0;
bool stationOnline = false;
bool irHoldingBelt = false;
bool postedThisEgg = false;
bool irEverClear = false;
bool irStuckWarned = false;
String streamUrl = "";

bool irSeesEgg() {
  pinMode(IR_DO_PIN, INPUT_PULLUP);
  int v = digitalRead(IR_DO_PIN);
  return IR_ACTIVE_LOW ? (v == LOW) : (v == HIGH);
}

static const char* _STREAM_CONTENT_TYPE = "multipart/x-mixed-replace;boundary=123456789000000000000987654321";
static const char* _STREAM_BOUNDARY = "\r\n--123456789000000000000987654321\r\n";
static const char* _STREAM_PART = "Content-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n";

static const char INDEX_HTML[] =
    "<!DOCTYPE html><html><body style='margin:0;background:#111;text-align:center'>"
    "<p style='color:#fff;font-family:sans-serif'>Egg CAM</p>"
    "<img src='/stream' style='max-width:100%'>"
    "</body></html>";

String sizeClassFromGrams(float g) {
  if (g < 40.0) return "peewee";
  if (g <= 47.0) return "small";
  if (g <= 54.0) return "medium";
  if (g <= 61.3) return "large";
  if (g <= 68.5) return "extraLarge";
  return "jumbo";
}

String gradeLabel(const String& sizeClass) {
  if (sizeClass == "peewee") return "PEEWEE";
  if (sizeClass == "small") return "SMALL";
  if (sizeClass == "medium") return "MEDIUM";
  if (sizeClass == "large") return "LARGE";
  if (sizeClass == "extraLarge") return "EXTRA LARGE";
  return "JUMBO";
}

void sendToFirestore(float weight, const String& grade, const String& sizeClass) {
  if (WiFi.status() != WL_CONNECTED) {
    return;
  }

  WiFiClientSecure client;
  client.setInsecure();
  HTTPClient http;

  String url = String("https://firestore.googleapis.com/v1/projects/") +
               FIREBASE_PROJECT_ID +
               "/databases/(default)/documents/" +
               FIRESTORE_COLLECTION +
               "?key=" + FIREBASE_WEB_API_KEY;

  http.begin(client, url);
  http.addHeader("Content-Type", "application/json");

  char iso[32];
  snprintf(iso, sizeof(iso), "1970-01-01T00:00:00Z");
  time_t now = time(nullptr);
  if (now > 1600000000) {
    strftime(iso, sizeof(iso), "%Y-%m-%dT%H:%M:%SZ", gmtime(&now));
  }

  String payload = "{\"fields\":{";
  payload += "\"weight\":{\"doubleValue\":" + String(weight, 2) + "},";
  payload += "\"grade\":{\"stringValue\":\"" + grade + "\"},";
  payload += "\"sizeClass\":{\"stringValue\":\"" + sizeClass + "\"},";
  payload += "\"deviceId\":{\"stringValue\":\"esp32-cam-station\"},";
  payload += "\"streamUrl\":{\"stringValue\":\"" + streamUrl + "\"},";
  payload += "\"createdAt\":{\"timestampValue\":\"" + String(iso) + "\"}";
  payload += "}}";

  int code = http.POST(payload);
  Serial.printf("Firestore POST %d\n", code);
  http.end();
}

void sendToFarmBackend(float weight) {
  if (WiFi.status() != WL_CONNECTED || strlen(FARM_BACKEND_URL) == 0) {
    return;
  }
  HTTPClient http;
  http.setConnectTimeout(800);
  http.setTimeout(800);
  http.begin(String(FARM_BACKEND_URL) + "/weight");
  http.addHeader("Content-Type", "application/json");
  String body = "{\"weightGrams\":" + String(weight, 1) + "}";
  int code = http.POST(body);
  Serial.printf("Farm backend POST %d\n", code);
  http.end();
}

void sendHeartbeat() {
  if (WiFi.status() != WL_CONNECTED || strlen(FARM_BACKEND_URL) == 0) {
    return;
  }
  HTTPClient http;
  http.setConnectTimeout(800);
  http.setTimeout(800);
  http.begin(String(FARM_BACKEND_URL) + "/api/status");
  http.addHeader("Content-Type", "application/json");
  String payload = "{\"status\":\"ONLINE\",\"device\":\"ESP32-CAM\"";
  if (streamUrl.length() > 0) {
    payload += ",\"streamUrl\":\"" + streamUrl + "\"";
  }
  payload += "}";
  int httpCode = http.POST(payload);
  Serial.printf("Heartbeat POST %d\n", httpCode);
  http.end();
}

void startConveyor(int speed) {
  (void)speed;
  // Re-claim pins in case camera/LEDC stole them. Full ON (no PWM).
  pinMode(MOTOR_ENA, OUTPUT);
  pinMode(MOTOR_IN1, OUTPUT);
  digitalWrite(MOTOR_ENA, HIGH);
  digitalWrite(MOTOR_IN1, HIGH);
}

void stopConveyor() {
  pinMode(MOTOR_ENA, OUTPUT);
  pinMode(MOTOR_IN1, OUTPUT);
  digitalWrite(MOTOR_ENA, LOW);
  digitalWrite(MOTOR_IN1, LOW);
}

void loadSavedScaleFactor() {
  if (!scalePrefs.begin("eggscale", true)) {
    return;
  }
  float saved = scalePrefs.getFloat("factor", 0);
  scalePrefs.end();
  if (saved > 10.0 && saved < 100000.0) {
    calibration_factor = saved;
    Serial.printf("Scale factor loaded: %.2f\n", calibration_factor);
  }
}

void saveScaleFactor() {
  if (!scalePrefs.begin("eggscale", false)) {
    Serial.println("Scale save failed");
    return;
  }
  scalePrefs.putFloat("factor", calibration_factor);
  scalePrefs.end();
  Serial.printf("Scale factor saved: %.2f\n", calibration_factor);
}

void printScaleHelp() {
  Serial.println();
  Serial.println("SCALE Serial commands (Newline in Serial Monitor):");
  Serial.println("  t     = TARE  (empty the bar, then send t)");
  Serial.println("  c     = CALIBRATE with 50g on the bar");
  Serial.println("  c100  = CALIBRATE with 100g (or c50, c55.5)");
  Serial.println("  h     = help");
  Serial.println("Mount bar first. Empty → t. Put known weight → c50. Then press to post.");
  Serial.println();
}

void handleScaleSerial() {
  if (!Serial.available()) {
    return;
  }
  String line = Serial.readStringUntil('\n');
  line.trim();
  line.toLowerCase();
  if (line.length() == 0) {
    return;
  }

  if (line == "h" || line == "help") {
    printScaleHelp();
    return;
  }

  if (!scale.wait_ready_timeout(500)) {
    Serial.println("Scale not ready — check HX711 wiring");
    return;
  }

  if (line == "t" || line == "tare") {
    scale.tare(10);
    Serial.println("TARE done — bar empty = 0.0g");
    return;
  }

  if (line.startsWith("c")) {
    float known = DEFAULT_CAL_WEIGHT_G;
    if (line.length() > 1) {
      known = line.substring(1).toFloat();
    }
    if (known < 5.0 || known > 500.0) {
      Serial.println("Use c50 or c100 (known weight in grams on the bar)");
      return;
    }
    Serial.printf("Calibrating with %.1fg on the bar...\n", known);
    long reading = scale.get_value(15);
    if (reading == 0) {
      Serial.println("No change from tare — put the known weight on the bar and try again");
      return;
    }
    calibration_factor = (float)reading / known;
    if (calibration_factor < 0) {
      calibration_factor = -calibration_factor;
    }
    scale.set_scale(calibration_factor);
    saveScaleFactor();
    float check = scale.get_units(10);
    if (check < 0) {
      check = -check;
    }
    Serial.printf("CAL done. Reading now %.1fg (want ~%.1fg). Factor=%.2f\n",
                  check, known, calibration_factor);
    return;
  }

  Serial.printf("Unknown command '%s' — type h for help\n", line.c_str());
}

static esp_err_t stream_handler(httpd_req_t* req) {
  camera_fb_t* fb = NULL;
  esp_err_t res = ESP_OK;
  char part[64];
  httpd_resp_set_type(req, _STREAM_CONTENT_TYPE);
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

  while (true) {
    fb = esp_camera_fb_get();
    if (!fb) {
      res = ESP_FAIL;
      break;
    }
    if (httpd_resp_send_chunk(req, _STREAM_BOUNDARY, strlen(_STREAM_BOUNDARY)) != ESP_OK) {
      esp_camera_fb_return(fb);
      res = ESP_FAIL;
      break;
    }
    size_t hlen = snprintf(part, sizeof(part), _STREAM_PART, fb->len);
    if (httpd_resp_send_chunk(req, part, hlen) != ESP_OK) {
      esp_camera_fb_return(fb);
      res = ESP_FAIL;
      break;
    }
    if (httpd_resp_send_chunk(req, (const char*)fb->buf, fb->len) != ESP_OK) {
      esp_camera_fb_return(fb);
      res = ESP_FAIL;
      break;
    }
    esp_camera_fb_return(fb);
  }
  return res;
}

static esp_err_t jpg_handler(httpd_req_t* req) {
  camera_fb_t* fb = esp_camera_fb_get();
  if (!fb) {
    httpd_resp_send_500(req);
    return ESP_FAIL;
  }
  httpd_resp_set_type(req, "image/jpeg");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  httpd_resp_set_hdr(req, "Content-Disposition", "inline; filename=egg.jpg");
  esp_err_t res = httpd_resp_send(req, (const char*)fb->buf, fb->len);
  esp_camera_fb_return(fb);
  return res;
}

static esp_err_t index_handler(httpd_req_t* req) {
  httpd_resp_set_type(req, "text/html");
  return httpd_resp_send(req, INDEX_HTML, HTTPD_RESP_USE_STRLEN);
}

void startCameraServer() {
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = 81;
  config.ctrl_port = 32769;
  config.stack_size = 8192;
  if (httpd_start(&stream_httpd, &config) != ESP_OK) {
    Serial.println("HTTP server failed");
    return;
  }
  httpd_uri_t index_uri = {
      .uri = "/",
      .method = HTTP_GET,
      .handler = index_handler,
      .user_ctx = NULL};
  httpd_uri_t jpg_uri = {
      .uri = "/jpg",
      .method = HTTP_GET,
      .handler = jpg_handler,
      .user_ctx = NULL};
  httpd_uri_t stream_uri = {
      .uri = "/stream",
      .method = HTTP_GET,
      .handler = stream_handler,
      .user_ctx = NULL};
  httpd_register_uri_handler(stream_httpd, &index_uri);
  httpd_register_uri_handler(stream_httpd, &jpg_uri);
  httpd_register_uri_handler(stream_httpd, &stream_uri);
  Serial.println("HTTP on port 81  /  /jpg  /stream");
}

bool startCameraXclk() {
  // Arduino-ESP32 3.x LEDC cannot do 20 MHz at 1-bit; the camera driver then
  // fails before SCCB. Drive GPIO 0 ourselves and skip the driver's XCLK setup.
  if (!ledcAttach(XCLK_GPIO_NUM, 8000000, 1)) {
    Serial.println("XCLK attach failed");
    return false;
  }
  ledcWrite(XCLK_GPIO_NUM, 1);
  Serial.println("XCLK 8 MHz on GPIO 0");
  return true;
}

bool initCamera() {
  pinMode(PWDN_GPIO_NUM, OUTPUT);
  digitalWrite(PWDN_GPIO_NUM, LOW);
  delay(50);
  startCameraXclk();

  camera_config_t config = {};
  config.ledc_channel = LEDC_CHANNEL_1;
  config.ledc_timer = LEDC_TIMER_1;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = -1;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size = FRAMESIZE_QVGA;
  config.jpeg_quality = 12;
  config.fb_count = 1;
  config.fb_location = CAMERA_FB_IN_PSRAM;
  config.grab_mode = CAMERA_GRAB_WHEN_EMPTY;
  config.xclk_freq_hz = 8000000;

  Serial.println("Camera init (external XCLK)");
  if (esp_camera_init(&config) == ESP_OK) {
    Serial.println("Camera OK");
    return true;
  }
  return false;
}

void startWifi() {
  Serial.print("WiFi connecting to ");
  Serial.println(WIFI_SSID);
  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  Serial.println("WiFi.begin");
  Serial.flush();
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  wifiBeginAt = millis();
  lastWifiDot = millis();
}

void finishStationStart() {
  if (stationOnline) {
    return;
  }
  stationOnline = true;
  Serial.print("WiFi IP ");
  Serial.println(WiFi.localIP());

  if (!initCamera()) {
    Serial.println("Camera init failed");
  }

  startCameraServer();
  streamUrl = String("http://") + WiFi.localIP().toString() + ":81/stream";
  Serial.println("Live stream: " + streamUrl);
  Serial.println("Photo: " + String("http://") + WiFi.localIP().toString() + ":81/jpg");
  Serial.println("Open Photo URL on the PC now");
  Serial.println(String("Farm backend: ") + FARM_BACKEND_URL);
  Serial.println("Scale next. Station: CAM + HX711 + L298N + IR only (no servo).");

  scale.begin(LOADCELL_DOUT_PIN, LOADCELL_SCK_PIN);
  loadSavedScaleFactor();
  if (scale.wait_ready_timeout(800)) {
    scale.set_scale(calibration_factor);
    scale.tare(10);
    scaleReady = true;
    Serial.printf("HX711 ready (factor=%.2f). Type h for tare/calibrate help.\n",
                  calibration_factor);
    printScaleHelp();
  } else {
    scaleReady = false;
    Serial.println("HX711 not found — camera/WiFi still start");
  }

  startConveyor(CONVEYOR_SPEED);
  Serial.printf("Conveyor ON ENA(14)=%d IN1(15)=%d\n", digitalRead(MOTOR_ENA), digitalRead(MOTOR_IN1));
  Serial.println("Station online — CAM, scale, conveyor, IR.");
}

void setup() {
  WRITE_PERI_REG(RTC_CNTL_BROWN_OUT_REG, 0);
  Serial.begin(115200);
  Serial.println();
  Serial.println("boot ok");
  delay(200);

  pinMode(MOTOR_ENA, OUTPUT);
  pinMode(MOTOR_IN1, OUTPUT);
  pinMode(IR_DO_PIN, INPUT_PULLUP);

  Serial.println("MOTOR TEST 5s — watch the TT motor NOW");
  Serial.println("Adapter 6-12V ON L298N +12V. ENA jumper ON. IN2=L298N GND. IN1=GPIO15.");
  Serial.println("Shared GND. If it does not spin in these 5s, it is power/wiring not the sketch.");
  startConveyor(CONVEYOR_SPEED);
  delay(5000);
  Serial.printf("MOTOR pins ENA14=%d IN115=%d (both should be 1)\n",
                digitalRead(MOTOR_ENA), digitalRead(MOTOR_IN1));
  Serial.println("MOTOR stays ON while IR is clear");

  startWifi();
}

void loop() {
  if (!stationOnline) {
    if (WiFi.status() == WL_CONNECTED) {
      Serial.println();
      finishStationStart();
    } else {
      if (millis() - lastWifiDot >= 500) {
        lastWifiDot = millis();
        Serial.print(".");
        Serial.flush();
      }
      if (millis() - wifiBeginAt > 40000) {
        Serial.println();
        Serial.println("WiFi retry");
        startWifi();
      }
    }
    delay(10);
    return;
  }

  if (millis() - lastHeartbeat >= 5000) {
    lastHeartbeat = millis();
    sendHeartbeat();
  }

  handleScaleSerial();

  pinMode(IR_DO_PIN, INPUT_PULLUP);

  if (!irSeesEgg()) {
    irStuckWarned = false;
    if (!irEverClear) {
      irEverClear = true;
      Serial.println("IR clear — egg-stop is armed. Conveyor runs until an egg.");
    }
    startConveyor(CONVEYOR_SPEED);
    if (irHoldingBelt) {
      irHoldingBelt = false;
      postedThisEgg = false;
      Serial.println("IR clear — conveyor ON");
    }
  } else if (!irEverClear) {
    startConveyor(CONVEYOR_SPEED);
    if (!irStuckWarned) {
      irStuckWarned = true;
      Serial.println("IR never clear — conveyor ON. Unplug DO from GPIO4 or turn the pot.");
    }
  } else {
    stopConveyor();
    if (!irHoldingBelt) {
      irHoldingBelt = true;
      postedThisEgg = false;
      Serial.println("IR egg — conveyor STOP (camera/scale)");
    }
  }

  if (millis() - lastWeightCheck < 800) {
    return;
  }
  lastWeightCheck = millis();

  scale.power_up();
  delay(50);
  int dout = digitalRead(LOADCELL_DOUT_PIN);
  if (!scale.wait_ready_timeout(300)) {
    Serial.printf("HX711 not ready DT(pin13)=%d (need 0). VCC=5V GND=CAM SCK=12 DT=13\n", dout);
    return;
  }

  long adc = scale.read();
  if (adc == -1) {
    scale.power_down();
    delay(50);
    scale.power_up();
    Serial.println("SCALE FAIL adc=-1. HX711 has no load-cell signal.");
    Serial.println("VCC=5V  GND=CAM  DT=GPIO13  SCK=GPIO12  red E+  black E-  green A+  white A-");
    return;
  }
  long raw = scale.get_value(1);
  float weight = scale.get_units(1);
  Serial.printf("scale adc=%ld raw=%ld %.1fg  IR pin=%d %s\n",
                adc,
                raw,
                weight,
                digitalRead(IR_DO_PIN),
                irSeesEgg() ? "EGG" : "clear");

  if (weight < 0) {
    weight = -weight;
  }
  // Post when someone presses the load cell (or an egg sits on it).
  // IR stop is optional — do not wait for IR to show SIZE CLASS on the app.
  if (weight < 5.0 || weight > 150.0) {
    return;
  }
  if (millis() - lastWeightPost < 2500) {
    return;
  }

  weight = scale.get_units(3);
  if (weight < 0) {
    weight = -weight;
  }
  if (weight < 5.0 || weight > 150.0) {
    Serial.printf("ignore %.1fg — noise, not a weight reading\n", weight);
    return;
  }

  if (irHoldingBelt) {
    postedThisEgg = true;
  }
  lastWeightPost = millis();
  String sizeClass = sizeClassFromGrams(weight);
  String grade = gradeLabel(sizeClass);
  Serial.printf("Egg %.1fg %s — posted to app SIZE CLASS\n", weight, grade.c_str());

  sendToFirestore(weight, grade, sizeClass);
  sendToFarmBackend(weight);
}
