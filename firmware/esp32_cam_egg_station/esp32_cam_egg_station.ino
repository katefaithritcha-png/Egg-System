/*
 * Egg station â€” ESP32 DevKit on the Goouuu expansion board.
 * The ESP32-CAM only takes the picture. Upload this sketch to the DevKit.
 *
 * POWER â€” two 12V adapters. No MB102. No L298N.
 *   Adapter 1 â†’ LM2596 IN. Set OUT to 5.0V. OUT+ = the four servo reds only.
 *   OUTâˆ’ = the four servo browns, and one wire from OUTâˆ’ to expansion black G.
 *   Adapter 2 â†’ expansion round jack. Jumper beside the jack on 5V.
 *   Expansion pin marked 5V â†’ ESP32-CAM 5V. Expansion black G â†’ ESP32-CAM GND.
 *   Expansion pin marked 3V3 â†’ IR VCC and HX711 VCC. Both GNDs â†’ expansion black G.
 *   Red V row stays empty. Do not use those red holes for servos, the IR, the HX711, or the camera.
 *
 * Yellow S holes on the expansion (one signal each) â€” your station flow:
 *   P13 ENTRANCE + P19 IR
 *      Every 10s ENTRANCE goes UP; when IR sees the egg â†’ ENTRANCE DOWN instantly.
 *   P14 GATE (camera decision from laptop)
 *      Clean â†’ full LEFT; Crack/Dirty â†’ full RIGHT; no egg in camera â†’ MIDDLE.
 *   P32/P33 HX711 load cell â€” weigh only (never moves GATE).
 *   P26 SORT â€” after weigh: 1=SMALL, 2=MEDIUM, 3=LARGE, else JUMBO.
 *   P25 PUSH â€” moves ONLY after SORT has assigned the size lane.
 *   P23 and P34 stay empty. P17/P18 stay empty (old L298N).
 *
 * Serial (optional cal only): t | c50 | egg | gate | push | sort
 * IoT flow: ENTRANCEâ†’IRâ†’cameraâ†’GATEâ†’(Clean) scaleâ†’SORTâ†’PUSH.
 * Crack/Dirty: GATE right; recorded by camera; no scale required.
 */

// 1 = station (ENTRANCE/IR/servos/HX711). Upload ONLY to DevKit COM5.
// 0 = picture only. Upload ONLY to ESP32-CAM USB.
// NEVER flash EGG_DEVKIT=1 onto the CAM â€” GPIO19=IR on DevKit but Y4 camera data on CAM.
// Workflow: set 1 â†’ Upload COM5 â†’ set 0 â†’ Upload CAM. Default stays 0 (CAM-safe).
#define EGG_DEVKIT 0
// 1 = after boot, Serial only prints Weight/Class when an egg locks (no scale spam).
// 0 = verbose live scale lines every second (debug).
#define SERIAL_WEIGHT_ONLY 1
// DevKit: local weigh + SORT/PUSH. GATE is driven only by farm camera result.
#if EGG_DEVKIT
#define ARDUINO_LOCAL 1
#define GATE_FROM_FARM 1
#else
#define ARDUINO_LOCAL 0
#define GATE_FROM_FARM 0
#endif

#include "esp_camera.h"
#include "img_converters.h"
#include "soc/soc.h"
#include "soc/rtc_cntl_reg.h"
#include "driver/gpio.h"
#include "soc/gpio_struct.h"
#include "driver/rtc_io.h"
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <new>
#include "HX711.h"
#include "esp_http_server.h"
#include <sys/socket.h>
#include <sys/select.h>
#include <lwip/sockets.h>
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include <Preferences.h>
#include "nvs_flash.h"
#include "mbedtls/platform.h"
#include "secrets.h"

// Cloudflare TLS needs ~2Ã—16KB SSL buffers. Internal DRAM is too fragmented after
// camera/Wiâ€‘Fi, so route mbedTLS calloc into PSRAM (ESP build has PLATFORM_MEMORY).
static void* eggMbedCaloc(size_t n, size_t sz) {
  if (!n || !sz) return nullptr;
  if (n > (SIZE_MAX / sz)) return nullptr;
  void* p = heap_caps_calloc(n, sz, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (!p) p = heap_caps_calloc(n, sz, MALLOC_CAP_8BIT);
  return p;
}
static void eggMbedFree(void* p) {
  if (p) heap_caps_free(p);
}
static void eggEnableTlsPsram() {
  // Prefer PSRAM for malloc > 1KB (SSL I/O buffers are 16KB).
  heap_caps_malloc_extmem_enable(1024);
  mbedtls_platform_set_calloc_free(eggMbedCaloc, eggMbedFree);
}

// When the extender blocks CAMâ†”laptop LAN (AP isolation), POST via Cloudflare
// tunnel instead. Stay on the extender Wiâ€‘Fi â€” no hotspot / main-router needed.
#ifndef FARM_PUBLIC_URL
#define FARM_PUBLIC_URL "https://egg-farm.eggsorting.site"
#endif

// ---- SMARTSORT live camera profile (AI Thinker ESP32-CAM / OV2640) ----
// Sharp + smooth: HQVGA (240x176). QQVGA looked mushy when upscaled on Watch.
// Fire-and-forget tunnel push keeps FPS up without crushing JPEG quality.
#define CAM_FRAME_SIZE FRAMESIZE_HQVGA
// Hardware JPEG quality (0=best/sharp, 63=worst). ~14 keeps shell edges clear.
#define CAM_JPEG_QUALITY 14
// Soft JPEG (GC2145 / frame2jpg): 1–100, HIGHER = sharper (bigger upload).
// ~14 + LAN keep-alive targets ~100–150 ms frame age while HQVGA stays clear.
#define CAM_SOFT_JPEG_Q 14
#define CAM_XCLK_HZ 20000000
// 100 = full sensor FOV (zoomed out). Lower = center crop / zoom in.
#define CAM_ZOOM_PCT 100
// Yield after each encode so Wiâ€‘Fi/core0 stays alive (do not set to 0).
#define CAM_PUBLISH_GAP_MS 1
#define CAM_PUBLISH_GAP_JPEG_MS 1
// Live POST cadence to laptop /api/frame (detection stays on laptop, non-blocking).
#define CAM_LIVE_PUSH_MS 10
#define CAM_LIVE_PUSH_MAX_MS 40
#define CAM_PUSH_ENABLE 1
#define CAM_DIAG_MS 2000
// Tunnel TLS needs its own task â€” never block the encode loop (that freezes :81/:82).
#define CAM_PUSH_STACK_TRIES 4
static framesize_t camLiveSize = CAM_FRAME_SIZE;
static uint32_t camJpgOkAt = 0;  // last successful JPEG encode (stall watchdog)
static volatile uint32_t camEncFpsX10 = 0;   // last measured encode rate Ã—10
static volatile uint32_t camPushFpsX10 = 0;  // last measured push rate Ã—10
static volatile uint32_t camLastEncMs = 0;   // last capture+encode duration
static volatile uint32_t camStreamErrs = 0;
// 0 = join the Wi-Fi in secrets.h (extender, router, or phone hotspot).
// 1 = the camera makes its own Wi-Fi named EggStation. Leave this at 0.
#define CAMERA_AP 0
#define CAMERA_AP_SSID "EggStation"
#define CAMERA_AP_PASS "egg12345"

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

const int ENTRANCE_PIN = 13;      // 1 entrance â€” down holds the line, up lets one egg through
const int SERVO_CAM_PIN = 14;     // GATE â€” middle scan; left=clean; right=crack/dirty
const int SERVO_SIZE_PIN = 25;    // PUSH â€” after SORT assigns lane
const int SERVO_REJECT_PIN = 26;  // SORT â€” 1 small, 2 medium, 3 large, 4 jumbo
const int MOTOR_PIN = 18;     // L298N IN1
const int MOTOR_IN2_PIN = 17; // L298N IN2
const int HX711_DT = 32;
const int HX711_SCK = 33;
const int IR_PIN = 19;

// SmartSort HX711 (Bogde): grams = (raw - tare) / calibrationFactor.
// Calibrate: empty â†’ t | put known weight â†’ c50
// Size lanes (grams) â€” edit these for your farm / capstone rubric:
//   SMALL [SMALL_MIN_G .. MEDIUM_MIN_G) | MEDIUM | LARGE | JUMBO
const float DISPLAY_SCALE = 1.0f;     // lockG is already grams
const float EMPTY_THRESHOLD_G = 5.0f;
// Soft / inaccurate load cell â€” still never treat empty residual as an egg.
const float SMALL_MIN_G = 40.0f;  // real chicken egg floor (empty noise is far below)
const float MEDIUM_MIN_G = 55.0f;  // small < 55 â‰¤ medium
#if EGG_DEVKIT
// Soft cell under-reads large (~60g) as 57â€“59 â†’ was stuck MEDIUM. 58 opens LARGE lane.
const float LARGE_MIN_G = 58.0f;
#else
const float LARGE_MIN_G = 60.0f;
#endif
const float JUMBO_MIN_G = 70.0f;
const float JUMBO_MAX_G = 150.0f;  // allow inaccurate over-reads until c50 is solid
const float SMALL_MAX_G = MEDIUM_MIN_G;   // alias for older comments
const float MEDIUM_MAX_G = LARGE_MIN_G;
const float LARGE_MAX_G = JUMBO_MIN_G;
const float XL_MAX_G = JUMBO_MAX_G;
const float MIN_EGG_G = SMALL_MIN_G;
const float MAX_EGG_G = JUMBO_MAX_G;
const float EGG_G = 2.0f;
const float TRIGGER_RISE_G = 1.0f;
const float LIVE_MAX_G = 150.0f;
// Bogde scale factor: counts per gram. Start at 1 until C calibration.
const float FACTOR_DEFAULT = 1.0f;
const float FACTOR_MIN = 0.05f;
const float FACTOR_MAX = 50000.0f;
const float GPC_DEFAULT = 1.0f;  // unused when DISPLAY_SCALE=1 (grams = d/factor)
const unsigned long WEIGHT_SETTLE_MS = 80;
const unsigned long PEAK_HOLD_MS = 2000;
const unsigned long WEIGHT_FORCE_LOCK_MS = 400;
const unsigned long WEIGHT_GIVE_UP_MS = 1600;
const long REST_D_MIN = 35;   // never lock on empty residual (was 10 â€” empty weighed)
const long REST_D_MAX = 400;  // do NOT clamp real eggs down to 40 (that faked ~40g)
const unsigned long WEIGH_COOLDOWN_MS = 100;
const unsigned long CLEAR_BEFORE_NEXT_MS = 250;
const unsigned long IDLE_ARM_MS = 500;
const int EGG_SEEN_HITS_NEED = 3;
const int LIFT_CLEAR_HITS_NEED = 2;
const int REST_SAMPLES_NEED = 2;
// Pad must bend like a REAL egg â€” empty residual is often d=1â€“25 (never weigh that).
const long PLACE_RISE_COUNTS = 40;
const long AUTO_WEIGH_MIN_D = 40;   // below this = empty / residual, NEVER auto-weigh
const long EGG_ADC_MIN = 35;
const long EMPTY_BAND_COUNTS = 12;  // empty / soft residual below this = clear pad
const long EGG_D_LO = 35;
const long EGG_D_HI = 400;
// Soft cell: empty flicker <~25; real egg must sit clearly above that floor.
const long EGG_SAMPLE_MIN_D = 35;
const long EGG_SAMPLE_MAX_D = 400;
const long EGG_LOCK_MIN_D = 35;
const long EGG_CAL_MIN_D = 20;   // 50g cal can rest lower than a live egg
const long EGG_RISE_ABOVE_IDLE = 20;
const long BAD_TARE_D = 80;
// Soft cell empty flicker: |d| can be 1â€“25 with no egg. Never treat abs-noise as grams.
// Measured after each tare into emptyNoiseD; egg samples must sit above that floor.
long emptyNoiseD = 12;
long lastTareSpan = 0;   // ADC flicker at last tare â€” high = bad zero = wrong grams
bool tareSuspect = false;
const unsigned long EGG_ARM_TIMEOUT_MS = 35000UL;
const int MOTOR_DUTY = 170;
// Each horn only moves to the stops its job uses. The gate is the one that
// needs the full 500â€“2500 swing. The others stall if they are driven into the ends.
const int GATE_LEFT_US = 500;      // Clean â€” full left (then back to middle)
const int GATE_CENTER_US = 1500;   // idle / scanning â€” always return here
const int GATE_RIGHT_US = 2500;    // Crack or Dirty â€” full right (then back to middle)
const unsigned long GATE_PULSE_MS = 500;     // legacy timed pulse (unused for live gate)
const unsigned long GATE_MAX_HOLD_MS = 12000; // safety: middle if eggSeen never clears
const int SORT_SMALL_US = 600;     // lane 1 SMALL
const int SORT_MEDIUM_US = 1200;   // lane 2 MEDIUM
const int SORT_LARGE_US = 1800;    // lane 3 LARGE
const int SORT_JUMBO_US = 2400;    // lane 4 JUMBO
const unsigned long SORT_SETTLE_MS = 700;  // wait for SORT, then PUSH
const int PUSH_HOME_US = 700;      // retracted, scale stays clear
const int PUSH_STROKE_US = 2100;   // one push off the scale into SORT lane
const int ENTRANCE_HOLD_US = 700;  // down / closed (wide travel vs OPEN)
const int ENTRANCE_OPEN_US = 2300; // up / open â€” big swing so movement is obvious
const int SERVO_MID_US = GATE_CENTER_US;
const int SERVO_UP_MS = 800;
const int SERVO_DOWN_MS = 800;
const unsigned long ENTRANCE_EVERY_MS = 10000;   // go UP every 10 s (IR closes instantly)
// Stay UP until IR â€” no timeout DOWN (was timed and closed before eggs arrived).
const unsigned long ENTRANCE_OPEN_MAX_MS = 0;

// GPIO 50 Hz pulses (esp_timer). Pulse only ~700 ms after a move, then stop â€”
// continuous 50 Hz on all four horns shakes them and starves the entrance.
volatile int servoTargetUs[4] = {SORT_MEDIUM_US, PUSH_HOME_US, GATE_CENTER_US, ENTRANCE_HOLD_US};
bool servoDriverOk = false;
const int servoPins[4] = {SERVO_REJECT_PIN, SERVO_SIZE_PIN, SERVO_CAM_PIN, ENTRANCE_PIN};
esp_timer_handle_t servoTimer = nullptr;
volatile bool servoFrameBusy = false;
bool servoTimerRunning = false;
volatile unsigned long servoDriveUntil = 0;
const unsigned long SERVO_DRIVE_MS = 1200;
// ENTRANCE = continuous soft 50 Hz forever (LEDC was unreliable on this board).
// GATE = soft 50 Hz (paused only during laptop HB). ENTRANCE never pauses.
#if EGG_DEVKIT
static int entrancePwmUs = ENTRANCE_HOLD_US;
static int gatePwmUs = GATE_CENTER_US;
static bool gatePwmPaused = false;  // HB only â€” never blocks ENTRANCE
static unsigned long hornPwmPhaseAt = 0;
#endif
unsigned long entranceAt = 0;
unsigned long entranceOpenedAt = 0;
bool entranceOpen = false;

HX711 scale;
Preferences prefs;
float factor = FACTOR_DEFAULT;
float gPerCount = GPC_DEFAULT;  // 1/factor helper (Bogde: grams = d / factor)
uint8_t hxGain = 128;
int hxDtPin = HX711_DT;
int hxSckPin = HX711_SCK;
long idleAdc = 0;
long emptyAdc = 0;  // locked empty-bar reading; a press must not move this
long clearEmptyAdc = 0;
bool haveClearEmpty = false;
long hxLastRaw = 0;
long peakDelta = 0;  // largest |raw-empty| since tare â€” proves a press was seen
long eggPeakD = 0;   // peak bend while IR sees egg (wood force is jumpy)
bool haveIdle = false;
float liveG = 0;
float smoothG = 0;
float scaleG = 0;
bool wasEmpty = true;
bool postedEgg = false;
bool inspectedEgg = false;
bool rejectedEgg = false;
bool sizeDone = false;
bool camRejectDone = false;
bool scanNoted = false;
bool camGateDown = false;
int gateAngle = 0;
int gateLatchedSide = 0;
bool laneOpen = false;
bool camPwmLive = false;
bool rejectArmDown = false;
String pendingSize = "";
float lastStableG = 0;
float lastGoodG = 0;
unsigned long stableAt = 0;
unsigned long lastGoodAt = 0;
int lowStreak = 0;
int eggHits = 0;
unsigned long weightSince = 0;
bool weightShown = false;
bool eggResultPrinted = false;  // one Weight/Class banner per egg
int eggCount = 0;               // 1st egg â†’ result 1, 2nd â†’ result 2, â€¦
bool needIdlePrint = true;      // show empty scale weight once after boot / after remove
bool idleShownOk = false;       // SCALE IDLE shown this cycle
bool announceEggRemoved = false; // after a result, say "egg removed" when back to empty
bool eggSession = false;        // sticky: egg seen until sustained empty
unsigned long eggSessionAt = 0; // first contact time
int eggGoneHits = 0;
int eggSeenHits = 0;            // samples before starting a session
float lastEmptyG = 0;
long emptyAdcAtEgg = 0;         // tare snapshot at session start â€” restore on lift
bool awaitNextEgg = true;       // armed for one new egg
bool mustSeeEmpty = false;      // after abandon â€” wait empty before Ready
bool sessionDone = false;       // this place finished (result or abandon)
unsigned long clearSinceAt = 0;
unsigned long weighCooldownUntil = 0;
unsigned long lastAutoZeroAt = 0;
float sessionBestRestG = 0;

bool stationOn = false;
// Last camera decision from laptop heartbeat â€” used when posting /weight.
static char farmCamResult[16] = "Pending";
static char farmSortResult[12] = "Good";
#if EGG_DEVKIT
// Camera Clean clears as soon as egg leaves FOV â€” latch so pad can still auto-weigh.
bool weighArmedClean = false;
unsigned long weighArmedUntil = 0;
unsigned long weighArmedAt = 0;  // when Clean arm first latched (belt travel clock)
bool padEmptyLatched = false;    // saw empty wood after Clean arm
bool padArrivalSeen = false;     // rising-edge = egg landed on load cell
unsigned long padArrivalAt = 0;  // when arrival sensed (screw-impact settle clock)
long padEmptyBaseD = 0;          // empty bend baseline for arrival sense
int padArrivalHits = 0;
int padEmptyHits = 0;
// Belt travel + settle; keep pad armed while farm awaits weight.
const unsigned long WEIGH_ARMED_MS = 120000UL;
// Camera Clean â†’ egg reaches pad (belt travel ~4â€“5s; use 5s so early locks never fire).
const unsigned long PAD_TRAVEL_MS = 5000UL;
// Rising bend above empty baseline = egg arrived (soft cell).
const long PAD_ARRIVAL_RISE_D = 22L;
// After land: egg hits screw/guide â€” settle before weigh + record (ignore impact).
const unsigned long PAD_IMPACT_SETTLE_MS = 3000UL;
unsigned long gateHoldUntil = 0;
unsigned long gateReturnAt = 0;   // when >0, return GATE to middle at this time
int gateDecisionPulsed = 0;       // -1 clean pulsed, +1 crack pulsed, 0 none
unsigned long hxRecoverUntil = 0;
long calRestD = 0;           // resting d from last good c50 (50g anchor)
float calKnownG = 50.0f;     // reference mass used in last c50
// Soft cell: Bogde grams = d/factor. Do NOT hard-cap at c50+16 â€” that threw away
// real egg samples (d=40â€“45) and locked on empty flicker (d=12â€“18) â†’ S/M swapped.
const float SOFT_GPC = 2.50f;
const float SOFT_SPAN_GAIN = 1.0f;
const long SOFT_OUTLIER_ABOVE_MED = 18;  // drop only wild spikes above median+18
const long SOFT_CLUSTER_RADIUS = 8;      // mean near median for lock grams
const long SCALE_STABLE_SPAN = 90;
#endif
// Shared by DevKit + CAM c50 sampling (must exist when EGG_DEVKIT is 0).
const int SCALE_READS = 64;
bool cameraAp = false;
char activeBackend[64] = "";
int findOctet = 0;                 // 2..254 while searching the Wi-Fi for the laptop
unsigned long findPauseUntil = 0;
bool triedMainWifi = false;
bool wifiSwitching = false;
bool laptopSweepDone = false;
bool hbEverOk = false;  // once true, never abandon a working extender for main Wiâ€‘Fi
char prefSsid[33] = "";
char prefPass[65] = "";
bool havePrefWifi = false;
int wifiTry = 0;
bool cameraOn = false;
unsigned long wifiLostAt = 0;       // when STA dropped (0 = connected)
unsigned long camReinitAt = 0;      // next camera re-init attempt
unsigned long lastWifiKickAt = 0;   // rate-limit reconnect storms
static uint32_t wifiDisconnectCount = 0;
static uint32_t wifiReconnectCount = 0;
static volatile bool camPushRunning = false;
// Pause YUV encode while mbedTLS runs â€” GC2145 + soft JPEG leaves <50KB DRAM.
static volatile bool camTlsBusy = false;
static WiFiClientSecure* gTunnelCli = nullptr;
static bool camInitStarted = false; // set inside initCamera
static volatile bool camReiniting = false;  // publish task must not fb_get during deinit
static volatile bool camInitBusy = false;   // block keep-alive from nested force re-init
static uint8_t camProbeFailStreak = 0;      // consecutive sensor-probe failures
static bool camSensorUnsupported = false;   // last fail was ESP_ERR_NOT_SUPPORTED
static bool camSkipHwJpeg = false;          // this module rejected JPEG (GC2145 / clone)
static bool camHaveRecipe = false;
static pixformat_t camRecipeFmt = PIXFORMAT_YUV422;
static framesize_t camRecipeSize = FRAMESIZE_HQVGA;
static camera_fb_location_t camRecipeLoc = CAMERA_FB_IN_PSRAM;
static uint32_t camRecipeXclk = CAM_XCLK_HZ;
static volatile uint32_t camPausedForTlsAt = 0;  // push task owns pause/reinit window

static bool initCameraQuick();  // fast re-open after tunnel TLS pause
static uint32_t camXclkHz = CAM_XCLK_HZ;
bool beltOn = false;
bool motorRun = false;
bool motorForward = true;
bool irEggWhenLow = true;
unsigned long irSampleAt = 0;
bool irEgg = false;
bool eggLatched = false;          // IR saw a passed egg at entrance (not used for weighing)
unsigned long eggLatchAt = 0;
bool pushArmed = false;
bool pushReturn = false;
unsigned long pushDueAt = 0;
int irLevel = 1;
int irCount = 0;
String streamUrl = "";
float camZoom = 1.0f;  // set by applyCameraZoom(), reported in the heartbeat
// Built once in goOnline(). Rebuilding String URLs every call fragments the heap.
String urlStatus, urlFrame, urlFrameAlt, urlInspect, urlWeight;
volatile uint32_t jpgServed = 0;
volatile uint32_t lastJpgBytes = 0;
unsigned long lastMem = 0;
unsigned long lastAskAt = 0;
httpd_handle_t httpd = NULL;

enum Inspect : uint8_t { I_IDLE = 0, I_ASK = 1, I_WAIT = 2, I_DONE = 3 };
Inspect inspect = I_IDLE;
unsigned long inspectAt = 0;
bool inspectPosted = false;

unsigned long lastHb = 0;
unsigned long lastWt = 0;
unsigned long lastLive = 0;
unsigned long wifiAt = 0;
unsigned long wifiDot = 0;
unsigned long emptyIdleAt = 0;
unsigned long emptySince = 0;
unsigned long ignoreEmptyUntil = 0;
unsigned long lastFrame = 0;
unsigned long lastDecide = 0;
String serialBuf = "";
unsigned long serialAt = 0;

void servoSweep(int pin, int pushUs, int homeUs);
bool servoDriverInit();
void beginInspect();
bool gramsStable();
bool readAdc(long* out);
bool hxRawOk(long adc);
bool hxStuck(long v);
void sizeSweep(const String& cls, bool force);
void applyEmptyZero(long adc, const char* why);
void servoStop();
void servoPass();
void servoReject();
void camServoWrite(int us);
void servoHold(int pin, int us, int holdMs);
void claimServoGpio(int pin);
void servoReattach();
#if ARDUINO_LOCAL
void localGateAfterWeight();
void testAllServos();
#endif
bool commitEggResult(float lockG);
float displayGrams(float rawG);
float serialGramsFromD(long d);
float actualGrams(long d);
#if EGG_DEVKIT
bool tareMedianNow(const char* why);
long medianLong(long* a, int n);
void servoPausePulses();
void servoResumePulses();
void serviceHornPwm();
#endif
void postWeight(float g);
void postWeightEx(float g, const char* sizeCls, const char* measStatus, bool commitEgg);

// SmartSort size bands (grams). g is already grams (DISPLAY_SCALE=1).
String sizeClassOf(float g) {
  float w = displayGrams(g);
  if (w < EMPTY_THRESHOLD_G) return "";
  // Inaccurate cell: always pick a lane so SORT/PUSH still run.
  if (w < SMALL_MIN_G) return "small";
  if (w < MEDIUM_MIN_G - 0.05f) return "small";
  if (w < LARGE_MIN_G) return "medium";
  if (w < JUMBO_MIN_G) return "large";
  return "jumbo";
}

String gradeOf(const String& s) {
  if (s == "small") return "SMALL";
  if (s == "medium") return "MEDIUM";
  if (s == "large") return "LARGE";
  if (s == "extraLarge" || s == "extralarge" || s == "xl") return "LARGE";
  if (s == "jumbo") return "JUMBO";
  return "JUMBO";
}

// Bogde HX711: grams = deltaCounts / calibrationFactor (c50 sets factor).
float serialGramsFromD(long d) {
  if (d < 0) d = -d;
  float f = factor;
  if (f < FACTOR_MIN || f > FACTOR_MAX) f = FACTOR_DEFAULT;
  if (f < 0.0001f) f = FACTOR_DEFAULT;
  float g = (float)d / f;
#if EGG_DEVKIT
  // LARGE only: soft cell parks true ~60g eggs in high-MEDIUM (56â€“59.9).
  // Do not touch below 56 â€” keeps SMALL/MEDIUM as they are now.
  if (calRestD >= 12 && g >= 56.0f && g < 60.0f) {
    long dd = d - calRestD;
    if (dd >= 2) g = 60.0f;  // clearly above 50g cal â†’ LARGE lane
  }
#endif
  if (g < 0) g = 0;
  if (g > LIVE_MAX_G) g = LIVE_MAX_G;
  return g;
}

float actualGrams(long d) {
  return serialGramsFromD(d) / DISPLAY_SCALE;
}

float displayGrams(float rawG) {
  float g = rawG * DISPLAY_SCALE;
  if (g < 0) g = 0;
  if (g > LIVE_MAX_G) g = LIVE_MAX_G;
  return g;
}

#if EGG_DEVKIT
long medianLong(long* a, int n) {
  if (n <= 0) return 0;
  for (int i = 0; i < n; i++) {
    for (int j = i + 1; j < n; j++) {
      if (a[j] < a[i]) {
        long t = a[i];
        a[i] = a[j];
        a[j] = t;
      }
    }
  }
  return a[n / 2];
}
#endif

// Print EMPTY / Ready. Only snap tare when wood looks empty (never tare with egg residual).
void printIdleScale(long delta) {
  (void)delta;
  long z = emptyAdc != 0 ? emptyAdc : idleAdc;
  long dSnap = 0;
  if (hxRawOk(hxLastRaw) && hxRawOk(z)) {
    dSnap = hxLastRaw - z;
    if (dSnap < 0) dSnap = -dSnap;
  }
  // Snap zero only when truly empty â€” never while 50g/egg still on pad after c50.
  if (hxRawOk(hxLastRaw) && (z == 0 || dSnap < 8)) {
    emptyAdc = hxLastRaw;
    idleAdc = hxLastRaw;
    clearEmptyAdc = hxLastRaw;
    haveClearEmpty = true;
    haveIdle = true;
  }
  lastEmptyG = 0;
  Serial.println();
  Serial.println("========== SCALE IDLE ==========");
  Serial.println("Weight: 0.0 g");
  Serial.println("================================");
  Serial.printf("Ready egg %d\n", eggCount + 1);
#if EGG_DEVKIT
  eggSession = false;
#if GATE_FROM_FARM
  Serial.println("Ready â€” camera Clean â†’ egg on pad auto-weighs (optional: type egg)");
#else
  Serial.println("Put egg on pad, then type: egg");
#endif
  Serial.flush();
#endif
  needIdlePrint = false;
  idleShownOk = true;
#if EGG_DEVKIT && GATE_FROM_FARM
  awaitNextEgg = true;  // arm auto-weigh for next Clean egg
#else
  awaitNextEgg = false;
#endif
  mustSeeEmpty = false;
  sessionDone = false;
  eggSeenHits = 0;
  eggResultPrinted = false;
  weightShown = false;
  announceEggRemoved = false;
  eggSession = false;
  clearSinceAt = 0;
  sessionBestRestG = 0;
  weighCooldownUntil = millis() + 500UL;
}

// Read the cell now and print empty/static grams (Serial: static).
void printCurrentStaticWeight() {
  long adc = 0;
  if (readAdc(&adc) && hxRawOk(adc) && !hxStuck(adc)) {
    hxLastRaw = adc;
  }
  // Force tare + EMPTY banner even if residual looked like grams.
  printIdleScale(0);
}

void printEggRemoved(long delta) {
  (void)delta;
  emptyAdcAtEgg = 0;
  lastEmptyG = 0;
  Serial.println();
  Serial.println("========== EGG REMOVED ==========");
  Serial.println("================================");
  announceEggRemoved = false;
  eggResultPrinted = false;
  eggSeenHits = 0;
  eggGoneHits = 0;
  eggSession = false;
  eggSessionAt = 0;
  weightShown = false;
  postedEgg = false;
  sizeDone = false;
  sessionBestRestG = 0;
  liveG = 0;
  scaleG = 0;
  lastStableG = 0;
  sessionDone = false;
  // Do not force tare here â€” printIdleScale snaps only if empty.
  printIdleScale(0);
}

void clearEggToEmpty(long dNow);  // defined after smoothD / holdPeakD

// SmartSort print â€” only 50â€“75 g eggs.
void printEggResult(float g) {
  if (eggResultPrinted) return;
  float w = displayGrams(g);
  String cls = sizeClassOf(g);
  if (!cls.length()) {
    Serial.printf("Weight %.1f g â€” OUT OF RANGE (need 50â€“75 g)\n", w);
    return;
  }
  eggResultPrinted = true;
  sessionDone = true;
  announceEggRemoved = true;
  awaitNextEgg = false;
  needIdlePrint = false;
  pendingSize = cls;
  eggCount++;
  Serial.println();
  int lane = 4;
  if (pendingSize.equalsIgnoreCase("small")) lane = 1;
  else if (pendingSize.equalsIgnoreCase("medium")) lane = 2;
  else if (pendingSize.equalsIgnoreCase("large")) lane = 3;
  Serial.println("========== EGG RESULT ==========");
  Serial.printf("EGG WEIGHT: %.1f g\n", w);
  Serial.printf("EGG SIZE:   %s  â†’ SORT lane %d\n", gradeOf(pendingSize).c_str(), lane);
  Serial.println("================================");
  Serial.println("â†’ SORT assigns lane, then PUSH");
}

#if EGG_DEVKIT
// Soft cal / egg: trimmed MEDIAN.
long softCalD(long* buf, int n) {
  if (n <= 0) return 0;
  if (n == 1) return buf[0];
  long tmp[64];
  int m = n;
  if (m > 64) m = 64;
  for (int i = 0; i < m; i++) tmp[i] = buf[i];
  for (int i = 0; i < m; i++) {
    for (int j = i + 1; j < m; j++) {
      if (tmp[j] < tmp[i]) {
        long t = tmp[i];
        tmp[i] = tmp[j];
        tmp[j] = t;
      }
    }
  }
  int lo = (m >= 8) ? (m / 5) : 0;
  int hi = (m >= 8) ? (m - m / 5) : m;
  if (hi <= lo) {
    lo = 0;
    hi = m;
  }
  int use = hi - lo;
  return tmp[lo + use / 2];
}

// Best accuracy on soft cell: mean of samples within Â±radius of median (kills dips+slams).
long softClusterD(long* buf, int n) {
  if (n <= 0) return 0;
  if (n == 1) return buf[0];
  long med = softCalD(buf, n);
  long sum = 0;
  int cnt = 0;
  for (int i = 0; i < n; i++) {
    long d = buf[i] - med;
    if (d < 0) d = -d;
    if (d <= SOFT_CLUSTER_RADIUS) {
      sum += buf[i];
      cnt++;
    }
  }
  if (cnt < 3) return med;
  return (sum + cnt / 2) / cnt;
}

// Alias kept for c50/v50 call sites â€” cluster is more accurate than upper-half.
long softRestD(long* buf, int n) {
  return softClusterD(buf, n);
}

long softSpanD(long* buf, int n) {
  if (n <= 0) return 0;
  long lo = buf[0], hi = buf[0];
  for (int i = 1; i < n; i++) {
    if (buf[i] < lo) lo = buf[i];
    if (buf[i] > hi) hi = buf[i];
  }
  return hi - lo;
}

// Span after dropping outer 25% â€” soft flicker min/max must not fail c50.
long softTrimSpanD(long* buf, int n) {
  if (n <= 0) return 0;
  if (n < 8) return softSpanD(buf, n);
  long tmp[64];
  int m = n;
  if (m > 64) m = 64;
  for (int i = 0; i < m; i++) tmp[i] = buf[i];
  for (int i = 0; i < m; i++) {
    for (int j = i + 1; j < m; j++) {
      if (tmp[j] < tmp[i]) {
        long t = tmp[i];
        tmp[i] = tmp[j];
        tmp[j] = t;
      }
    }
  }
  int a = m / 4;
  int b = m - 1 - (m / 4);
  if (b <= a) return softSpanD(buf, n);
  return tmp[b] - tmp[a];
}

// True while SORT/PUSH/entrance motion would shake the load cell.
bool scaleMotionBusy() {
  if (pushArmed || pushReturn) return true;
  if (millis() < gateHoldUntil) return true;
  return false;
}

float pctErrorG(float measured, float reference) {
  if (reference < 0.5f) return 0;
  float e = measured - reference;
  if (e < 0) e = -e;
  return (e / reference) * 100.0f;
}
#endif

// Print only if already in real egg gram range â€” never invent JUMBO from noise.
bool commitEggResult(float lockG) {
  // One egg â†’ one result. Never print twice for the same session.
  if (eggResultPrinted || weightShown) return true;
  float w = displayGrams(lockG);
  // Farm-armed Clean: soft cell often reads 15â€“35 g for a real egg â€” allow that band.
  float minCommitG = MIN_EGG_G;
#if EGG_DEVKIT
  if (weighArmedClean || (weighArmedUntil && millis() < weighArmedUntil)) {
    minCommitG = 15.0f;
  }
#endif
  // Hard reject empty / residual â€” never SORT/PUSH/IoT without a real egg on the cell.
  if (w < minCommitG || w > MAX_EGG_G) {
    Serial.printf("Weight %.1f g â€” no egg on load cell (need %.0fâ€“%.0fg)\n",
                  w, minCommitG, MAX_EGG_G);
    return false;
  }
  String cls = sizeClassOf(lockG);
  if (!cls.length()) {
    // Still commit inaccurate / out-of-band grams so SORT + IoT keep working.
    cls = (w < MIN_EGG_G) ? String("") : String("medium");
    if (!cls.length()) {
      Serial.printf("Weight %.1f g â€” empty pad, not committed\n", w);
      return false;
    }
    Serial.printf("Weight %.1f g â€” inaccurate, using %s lane anyway\n", w, cls.c_str());
  }
  weightShown = true;
  sessionDone = true;
  eggSession = false;  // stop lock loop immediately after one result
#if EGG_DEVKIT
  eggSeenHits = 0;
  weighArmedClean = false;  // Clean latch consumed by a committed weigh
  weighArmedUntil = 0;
  weighArmedAt = 0;
  padEmptyLatched = false;
  padArrivalSeen = false;
  padArrivalAt = 0;
  padArrivalHits = 0;
#endif
  liveG = lockG;
  scaleG = lockG;
  lastStableG = lockG;
  pendingSize = cls;
  printEggResult(lockG);
#if ARDUINO_LOCAL
  postedEgg = true;
  inspectedEgg = true;
  camRejectDone = true;
  // Camera already moved GATE. Every weigh must SORT then PUSH (do not skip if sizeDone stuck).
  rejectedEgg = (farmSortResult[0] == 'R');
  sizeDone = false;
  pushArmed = false;
  pushReturn = false;
  sizeSweep(pendingSize, true);  // 1) SORT lane by grams  2) PUSH after settle
#endif
  // IoT: same egg â€” attach grams to the camera Clean/Crack/Dirty record.
  postWeightEx(displayGrams(lockG), pendingSize.c_str(), "uncalibrated", true);
  return eggResultPrinted;
}

#if EGG_DEVKIT
void servoPausePulses() {
  // HX711 quiet: stop PUSH/SORT bit-bang ONLY.
  // Never pause ENTRANCE LEDC â€” that made P13 look "dead" during every tare/weigh.
  if (servoTimer && servoTimerRunning) {
    esp_timer_stop(servoTimer);
    servoTimerRunning = false;
  }
  for (int i = 0; i < 4; i++) {
    if (servoPins[i] == ENTRANCE_PIN || servoPins[i] == SERVO_CAM_PIN) continue;
    digitalWrite(servoPins[i], LOW);
  }
}
void servoKickDrive();  // defined with servo driver below
void servoResumePulses() {
  servoKickDrive();
}
bool tareMedianNow(const char* why) {
  // Short quiet only â€” long 1.2s pauses made the station feel broken.
  servoPausePulses();
  delay(350);
  long buf[16];
  int n = 0;
  long bestSpan = 99999;
  long bestMid = 0;
  bool gotStable = false;
  // Prefer quiet zero. Span 277 was accepted before â†’ inaccurate egg weights.
  const long TARE_SPAN_OK = 120;
  const long TARE_SPAN_SOFT = 220;
  const long TARE_SPAN_FORCE = 400;
  for (int attempt = 0; attempt < 8; attempt++) {
    n = 0;
    for (int i = 0; i < 36 && n < 16; i++) {
      long v = 0;
      if (!readAdc(&v) || !hxRawOk(v) || hxStuck(v)) {
        delay(25);
        continue;
      }
      buf[n++] = v;
      delay(40);
    }
    if (n < 8) {
      Serial.printf("Tare retry (%s) â€” few samples\n", why);
      delay(300);
      continue;
    }
    long lo = buf[0], hi = buf[0];
    for (int i = 1; i < n; i++) {
      if (buf[i] < lo) lo = buf[i];
      if (buf[i] > hi) hi = buf[i];
    }
    long span = hi - lo;
    if (n >= 10) {
      long lo2 = 999999, hi2 = -999999;
      for (int i = 0; i < n; i++) {
        if (buf[i] == lo || buf[i] == hi) continue;
        if (buf[i] < lo2) lo2 = buf[i];
        if (buf[i] > hi2) hi2 = buf[i];
      }
      if (hi2 > lo2) span = hi2 - lo2;
    }
    long mid = medianLong(buf, n);
    if (span < bestSpan) {
      bestSpan = span;
      bestMid = mid;
    }
    if (span <= TARE_SPAN_OK) {
      gotStable = true;
      bestMid = mid;
      bestSpan = span;
      break;
    }
    Serial.printf("Tare retry (%s) span=%ld â€” keep wood empty, wait\n", why, span);
    delay(450);
  }
  tareSuspect = false;
  if (!gotStable && bestSpan <= TARE_SPAN_SOFT && bestMid != 0) {
    gotStable = true;
    tareSuspect = true;
    Serial.printf("Tare soft-OK (%s) span=%ld â€” type t again when quiet for best accuracy\n",
                  why, bestSpan);
  } else if (!gotStable && bestSpan <= TARE_SPAN_FORCE && bestMid != 0) {
    gotStable = true;
    tareSuspect = true;
    Serial.printf("Tare WEAK (%s) span=%ld â€” accuracy poor until you type t on empty quiet pad\n",
                  why, bestSpan);
  }
  if (!gotStable) {
    servoResumePulses();
    lastTareSpan = bestSpan;
    tareSuspect = true;
    Serial.printf("TARE fail (%s) â€” unstable span=%ld. Empty wood, wait 3s, type t\n",
                  why, bestSpan);
    return false;
  }
  applyEmptyZero(bestMid, why);
  lastTareSpan = bestSpan;
  lastAutoZeroAt = millis();
  needIdlePrint = false;
  Serial.printf("Tare ok raw=%ld (span %ld)%s â€” put egg, watch live d=\n",
                bestMid, bestSpan, tareSuspect ? " [WEAK]" : "");
  servoResumePulses();
  return true;
}
#endif

void farmHeaders(HTTPClient& http) {
  http.addHeader("Content-Type", "application/json");
  if (strlen(FARM_DEVICE_TOKEN) > 0) {
    http.addHeader("X-Farm-Device-Token", FARM_DEVICE_TOKEN);
  }
}

// IoT integration: post weight even on DevKit when GATE_FROM_FARM WiFi is up.
// measurementStatus: "uncalibrated" (HX711) | "simulated" (integration test) | "calibrated"
void postWeight(float g) {
  postWeightEx(g, "", "uncalibrated", true);
}

void postWeightEx(float g, const char* sizeCls, const char* measStatus, bool commitEgg) {
#if !(GATE_FROM_FARM || !ARDUINO_LOCAL)
  (void)g;
  (void)sizeCls;
  (void)measStatus;
  (void)commitEgg;
  return;
#else
  if (WiFi.status() != WL_CONNECTED || strlen(FARM_BACKEND_URL) == 0) {
    Serial.println("IoT weight skip â€” WiFi/backend offline");
    return;
  }
  if (!urlWeight.length()) {
    urlWeight = String(FARM_BACKEND_URL) + "/weight";
  }
  // Must share the one HTTP lock with heartbeat â€” races assert in lwIP pbuf_free.
  if (!takeHttpOut(800)) {
    Serial.println("IoT weight skip â€” HTTP busy");
    return;
  }
  HTTPClient http;
  http.setReuse(false);
  http.setConnectTimeout(800);
  http.setTimeout(1200);
  if (!http.begin(urlWeight)) {
    giveHttpOut();
    Serial.println("IoT weight skip â€” begin failed");
    return;
  }
  farmHeaders(http);
  char eventId[40];
  snprintf(eventId, sizeof(eventId), "esp%08lx%04x", (unsigned long)millis(), (unsigned)(esp_random() & 0xFFFF));
  const char* status = (measStatus && measStatus[0]) ? measStatus : "uncalibrated";
  const char* size = (sizeCls && sizeCls[0]) ? sizeCls : "medium";
  const char* cam = farmCamResult[0] ? farmCamResult : "Pending";
  const char* sort = farmSortResult[0] ? farmSortResult : "Good";
  char body[384];
  if (commitEgg) {
    snprintf(body, sizeof(body),
             "{\"weightGrams\":%.1f,\"measurementStatus\":\"%s\",\"sizeClass\":\"%s\","
             "\"deviceId\":\"egg-devkit\",\"eventId\":\"%s\",\"commitEgg\":true,"
             "\"cameraResult\":\"%s\",\"sortingResult\":\"%s\"}",
             g, status, size, eventId, cam, sort);
  } else {
    snprintf(body, sizeof(body),
             "{\"weightGrams\":%.1f,\"measurementStatus\":\"%s\",\"sizeClass\":\"%s\","
             "\"deviceId\":\"egg-devkit\"}",
             g, status, size);
  }
  int code = http.POST((uint8_t*)body, strlen(body));
  Serial.printf("IoT POST /weight %.1fg [%s] â†’ HTTP %d\n", g, status, code);
  http.end();
  giveHttpOut();
#endif
}

int readInspectBody(const String& b) {
  if (b.length() < 8) return -1;
  bool ready = b.indexOf("\"ready\":true") >= 0 || b.indexOf("\"ready\": true") >= 0;
  if (!ready) return -1;
  bool eggSeen = b.indexOf("\"eggSeen\":true") >= 0 || b.indexOf("\"eggSeen\": true") >= 0;
  if (!eggSeen) return -1;
  bool noCrack = b.indexOf("No Crack") >= 0 || b.indexOf("no crack") >= 0;
  bool crack = !noCrack && (b.indexOf("Crack") >= 0 || b.indexOf("crack") >= 0);
  bool empty = b.indexOf("Empty") >= 0 || b.indexOf("empty") >= 0;
  bool rej = b.indexOf("\"reject\":true") >= 0 || b.indexOf("\"reject\": true") >= 0;
  // Dirty/dust is not a system grade â€” only Clean + Crack.
  if (empty && !noCrack && !crack && !rej) return -1;
  if (crack || rej) {
#if !SERIAL_WEIGHT_ONLY
    Serial.println("QUALITY CRACK");
#endif
    return 1;
  }
  if (noCrack) {
#if !SERIAL_WEIGHT_ONLY
    Serial.println("QUALITY CLEAN");
#endif
    return 0;
  }
  return -1;
}

// Shared JPEG ring for :82 /jpg and CAMâ†’laptop POST (must be above postFrame).
static uint8_t* camJpg = NULL;
static size_t camJpgLen = 0;
static volatile uint32_t camJpgSeq = 0;
static volatile uint32_t camJpgTaken = 0;
static volatile uint32_t camJpgPushed = 0;  // last seq POSTed to laptop (skip stale)
static SemaphoreHandle_t camJpgLock = NULL;
static SemaphoreHandle_t httpOutLock = NULL;  // one outbound TCP/HTTP at a time
static uint32_t lastLivePushAt = 0;

static bool takeHttpOut(uint32_t waitMs) {
  if (!httpOutLock) httpOutLock = xSemaphoreCreateMutex();
  if (!httpOutLock) return true;
  return xSemaphoreTake(httpOutLock, pdMS_TO_TICKS(waitMs)) == pdTRUE;
}

static void giveHttpOut() {
  if (httpOutLock) xSemaphoreGive(httpOutLock);
}

int hbFails = 0;  // laptop HB fails â€” also used by postFrame() timeouts
static int lanPushFailStreak = 0;
void applyBackend(const char* base);  // defined later

static bool farmBackendIsHttps() {
  return strncmp(activeBackend, "https://", 8) == 0;
}

static void farmUseTunnel(const char* why) {
  if (farmBackendIsHttps()) return;
  if (!FARM_PUBLIC_URL[0]) return;
  Serial.printf("LAN blocked (%s) — CAM stays on extender, using tunnel\n", why ? why : "");
  Serial.printf("Tunnel %s (keep cloudflared open on laptop)\n", FARM_PUBLIC_URL);
  applyBackend(FARM_PUBLIC_URL);
  lanPushFailStreak = 0;
  // Do not clear hbFails here — avoids "fail x0" and keeps tunnel sticky.
}

// While stuck on tunnel, keep probing secrets LAN URL — 100–150 ms live needs LAN.
bool probeLaptop(const IPAddress& ip);  // defined later
static void farmTryLanRecover() {
  if (!farmBackendIsHttps()) return;
  if (strncmp(FARM_BACKEND_URL, "http://", 7) != 0) return;
  static unsigned long lastTry = 0;
  if (millis() - lastTry < 8000UL) return;
  lastTry = millis();
  int a = 0, b = 0, c = 0, d = 0;
  const char* p = strstr(FARM_BACKEND_URL, "://");
  p = p ? p + 3 : FARM_BACKEND_URL;
  if (sscanf(p, "%d.%d.%d.%d", &a, &b, &c, &d) != 4) return;
  if (!probeLaptop(IPAddress(a, b, c, d))) return;
  Serial.println("LAN recovered — smooth live path (leave tunnel)");
  applyBackend(FARM_BACKEND_URL);
  if (gTunnelCli) gTunnelCli->stop();
  lanPushFailStreak = 0;
  hbFails = 0;
}

static void tunnelTlsApplyClientOpts(WiFiClientSecure* c) {
  if (!c) return;
  c->setInsecure();  // no CA bundle — saves RAM; host is our tunnel
  c->setTimeout(10);
  c->setHandshakeTimeout(15);
}

static void tunnelTlsResetClient() {
  if (gTunnelCli) {
    gTunnelCli->stop();
    delete gTunnelCli;
    gTunnelCli = nullptr;
  }
  eggEnableTlsPsram();
  gTunnelCli = new (std::nothrow) WiFiClientSecure();
  tunnelTlsApplyClientOpts(gTunnelCli);
}

static void tunnelTlsPrepareEarly() {
  eggEnableTlsPsram();  // SSL buffers in PSRAM — required for internet tunnel
  if (!gTunnelCli) {
    gTunnelCli = new (std::nothrow) WiFiClientSecure();
  }
  tunnelTlsApplyClientOpts(gTunnelCli);
  if (gTunnelCli) {
    Serial.printf(
        "TUNNEL internet TLS ready heap=%u psram=%u largest_int=%u\n",
        (unsigned)ESP.getFreeHeap(), (unsigned)ESP.getFreePsram(),
        (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));
  }
}

// Cloudflare HTTPS POST. keepAlive=true only for back-to-back /api/frame.
// Status/HB always closes â€” a half-open socket after HB made frame TLS fail.
static int httpsPostRawOnce(const char* path, const uint8_t* body, size_t bodyLen,
                            const char* contentType, bool keepAlive, bool forceFresh) {
  const char* hostStart = strstr(activeBackend, "://");
  hostStart = hostStart ? hostStart + 3 : activeBackend;
  char host[96];
  size_t hi = 0;
  while (hostStart[hi] && hostStart[hi] != '/' && hostStart[hi] != ':' &&
         hi + 1 < sizeof(host)) {
    host[hi] = hostStart[hi];
    hi++;
  }
  host[hi] = 0;
  if (!host[0]) return -1;

  if (!gTunnelCli) tunnelTlsPrepareEarly();
  if (!gTunnelCli) return -1;

  static IPAddress cachedIp;
  static char cachedHost[96] = {0};
  static unsigned long cachedIpAt = 0;
  bool needConnect = forceFresh || !gTunnelCli->connected();
  bool dnsStale = (cachedHost[0] == 0 || strcmp(cachedHost, host) != 0 ||
                   cachedIpAt == 0 || (millis() - cachedIpAt) > 60000UL);
  IPAddress ip = cachedIp;

  // Only pause encode for a real handshake. Keep-alive writes must NOT freeze
  // the sensor — that dropped enc_fps to ~0 and hid hand motion on Live.
  if (needConnect) {
    camTlsBusy = true;
    vTaskDelay(pdMS_TO_TICKS(60));
    for (int wi = 0; wi < 8; wi++) {
      size_t largest = heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL);
      if (largest >= 20000) break;
      vTaskDelay(pdMS_TO_TICKS(40));
    }
  }

  uint8_t* dramBody = nullptr;
  const uint8_t* sendBody = body;

  // Copy JPEG into internal RAM BEFORE mbedtls connect — handshake eats the
  // large free block; PSRAM-sourced writes then return 0 and Live freezes.
  if (body && bodyLen >= 200 && bodyLen <= 24000) {
    dramBody = (uint8_t*)heap_caps_malloc(bodyLen, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (dramBody) {
      memcpy(dramBody, body, bodyLen);
      sendBody = dramBody;
    } else {
      static unsigned long lastDramLog = 0;
      if (millis() - lastDramLog > 3000UL) {
        lastDramLog = millis();
        Serial.printf("TUNNEL DRAM body alloc fail len=%u largest=%u\n",
                      (unsigned)bodyLen,
                      (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));
      }
    }
  }

  if (needConnect || dnsStale) {
    if (!WiFi.hostByName(host, ip)) {
      static unsigned long lastDnsLog = 0;
      if (millis() - lastDnsLog > 4000UL) {
        lastDnsLog = millis();
        Serial.printf("TUNNEL DNS fail host=%s heap=%u\n", host, (unsigned)ESP.getFreeHeap());
      }
      if (dramBody) heap_caps_free(dramBody);
      camTlsBusy = false;
      return -1;
    }
    cachedIp = ip;
    strncpy(cachedHost, host, sizeof(cachedHost) - 1);
    cachedHost[sizeof(cachedHost) - 1] = 0;
    cachedIpAt = millis();
  }

  if (!needConnect) {
    static unsigned long lastKaLog = 0;
    if (millis() - lastKaLog > 2000UL) {
      lastKaLog = millis();
      Serial.println("TUNNEL TLS keep-alive reuse");
    }
  }
  if (needConnect) {
    // Need contiguous DRAM for both JPEG bounce and mbedtls — bail early.
    if (!dramBody) {
      gTunnelCli->stop();
      camTlsBusy = false;
      return -3;
    }
    gTunnelCli->stop();
    tunnelTlsApplyClientOpts(gTunnelCli);
    static unsigned long lastFreshLog = 0;
    if (millis() - lastFreshLog > 2000UL) {
      lastFreshLog = millis();
      Serial.printf("TUNNEL TLS fresh handshake largest=%u\n",
                    (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));
    }
    bool okConn = gTunnelCli->connect(host, 443, 8000);
    if (!okConn) {
      vTaskDelay(pdMS_TO_TICKS(100));
      okConn = gTunnelCli->connect(ip, 443, host, (const char*)nullptr,
                                   (const char*)nullptr, (const char*)nullptr);
    }
    if (!okConn) {
      static unsigned long lastTlsLog = 0;
      if (millis() - lastTlsLog > 4000UL) {
        lastTlsLog = millis();
        char err[96] = {0};
        gTunnelCli->lastError(err, sizeof(err));
        Serial.printf(
            "TUNNEL TLS fail %s (%s) heap=%u psram=%u largest=%u err=%s\n",
            host, ip.toString().c_str(), (unsigned)ESP.getFreeHeap(),
            (unsigned)ESP.getFreePsram(),
            (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL),
            err[0] ? err : "?");
      }
      if (dramBody) heap_caps_free(dramBody);
      camTlsBusy = false;
      return -1;
    }
  }

  // Keep-alive write still needs DRAM body — PSRAM→mbedtls returns 0 mid-body.
  if (!dramBody) {
    gTunnelCli->stop();
    camTlsBusy = false;
    return -3;
  }

  char hdr[384];
  int hn = snprintf(hdr, sizeof(hdr),
                    "POST %s HTTP/1.1\r\n"
                    "Host: %s\r\n"
                    "Content-Type: %s\r\n"
                    "Content-Length: %u\r\n"
                    "Connection: %s\r\n",
                    path, host, contentType, (unsigned)bodyLen,
                    keepAlive ? "keep-alive" : "close");
  if (strlen(FARM_DEVICE_TOKEN) > 0) {
    hn += snprintf(hdr + hn, sizeof(hdr) - hn,
                   "X-Farm-Device-Token: %s\r\n", FARM_DEVICE_TOKEN);
  }
  hn += snprintf(hdr + hn, sizeof(hdr) - hn, "\r\n");
  int code = -1;
  int contentLen = -1;
  bool peerClose = !keepAlive;
  bool wroteOk = false;
  if (hn > 0 && (size_t)hn < sizeof(hdr) &&
      gTunnelCli->write((const uint8_t*)hdr, (size_t)hn) == (size_t)hn) {
    size_t sent = 0;
    wroteOk = true;
    // DRAM body already contiguous — bigger chunks = fewer TLS writes = smoother.
    while (sent < bodyLen) {
      size_t chunk = bodyLen - sent;
      if (chunk > 2048) chunk = 2048;
      const uint8_t* src = sendBody + sent;
      int w = 0;
      for (int attempt = 0; attempt < 12 && w <= 0; attempt++) {
        if (!gTunnelCli->connected()) break;
        w = gTunnelCli->write(src, chunk);
        if (w <= 0) {
          delay(1 + attempt);
          yield();
        }
      }
      if (w <= 0) {
        wroteOk = false;
        break;
      }
      sent += (size_t)w;
      if ((sent & 0xFFF) == 0) yield();
    }
    if (wroteOk) {
      if (keepAlive) {
        // Fire-and-forget: no ack wait — next JPEG immediately.
        code = 200;
        while (gTunnelCli->available()) (void)gTunnelCli->read();
      } else {
        char line[160];
        size_t li = 0;
        bool gotStatus = false;
        bool hdrDone = false;
        unsigned long t0 = millis();
        while (!hdrDone && millis() - t0 < 700UL) {
          while (gTunnelCli->available()) {
            char ch = (char)gTunnelCli->read();
            if (ch == '\n') {
              line[li] = 0;
              if (li > 0 && line[li - 1] == '\r') line[li - 1] = 0;
              if (!gotStatus && strncmp(line, "HTTP/", 5) == 0) {
                const char* sp = strchr(line, ' ');
                if (sp) code = atoi(sp + 1);
                gotStatus = true;
              } else if (li <= 0) {
                hdrDone = true;
                break;
              } else if (strncasecmp(line, "Content-Length:", 15) == 0) {
                contentLen = atoi(line + 15);
              } else if (strncasecmp(line, "Connection:", 11) == 0 &&
                         strcasestr(line, "close")) {
                peerClose = true;
              }
              li = 0;
              continue;
            }
            if (li + 1 < sizeof(line)) line[li++] = ch;
          }
          if (hdrDone) break;
          if (!gTunnelCli->connected() && !gTunnelCli->available()) break;
          delay(1);
          yield();
        }
        if (contentLen > 0) {
          int left = contentLen;
          unsigned long t1 = millis();
          while (left > 0 && millis() - t1 < 400UL) {
            while (left > 0 && gTunnelCli->available()) {
              gTunnelCli->read();
              left--;
            }
            if (left > 0) {
              delay(1);
              yield();
            }
          }
        }
      }
    }
  }
  // Keep socket when still connected (CF may send Connection: close but leave
  // TCP up). Dead reuse returns -3; push task pauses cam before reconnect —
  // never forceFresh while the sensor still owns DRAM (~32k → Generic error).
  if (!wroteOk || code < 200 || code >= 400 || !gTunnelCli->connected()) {
    gTunnelCli->stop();
  } else if (peerClose && !keepAlive) {
    gTunnelCli->stop();
  }
  if (dramBody) heap_caps_free(dramBody);
  camTlsBusy = false;
  if (wroteOk && code < 0) return -3;
  return wroteOk ? code : -3;
}

static int httpsPostRaw(const char* path, const uint8_t* body, size_t bodyLen,
                        const char* contentType, bool keepAlive = true) {
  static uint8_t tlsFailStreak = 0;
  int code = httpsPostRawOnce(path, body, bodyLen, contentType, keepAlive, false);
  // Only forceFresh when DRAM can absorb mbedtls. Otherwise push task must
  // pause the camera first (handshake with cam on → Generic error @ ~32k).
  if (code == -3) {
    if (gTunnelCli) gTunnelCli->stop();
    size_t largest =
        heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL);
    if (largest >= 42000UL) {
      vTaskDelay(pdMS_TO_TICKS(80));
      code = httpsPostRawOnce(path, body, bodyLen, contentType, keepAlive, true);
    }
  }
  if (code == -1 || code == -3) {
    if (tlsFailStreak < 250) tlsFailStreak++;
    if (tlsFailStreak >= 4) {
      Serial.println("TUNNEL TLS client reset after fail streak");
      tunnelTlsResetClient();
      tlsFailStreak = 0;
      vTaskDelay(pdMS_TO_TICKS(600));
    }
  } else if (code >= 200 && code < 400) {
    tlsFailStreak = 0;
  }
  return code;
}


int postFrame() {
#if ARDUINO_LOCAL
  return -1;
#else
  // cameraOn may be false during TUNNEL recover (sensor paused); JPEG ring is enough.
  if (WiFi.status() != WL_CONNECTED || strlen(activeBackend) == 0) return -1;
  // ONLY the JPEG ring — never esp_camera_fb_get here (publish task owns the sensor).
  uint8_t* jpg = NULL;
  size_t jlen = 0;
  uint32_t seq = 0;
  if (camJpgLock && xSemaphoreTake(camJpgLock, pdMS_TO_TICKS(15)) == pdTRUE) {
    seq = camJpgSeq;
    // Skip re-POSTing the same frame â€” that is what made moving eggs look lagged.
    if (seq != 0 && seq == camJpgPushed) {
      xSemaphoreGive(camJpgLock);
      return 0;
    }
    if (camJpg && camJpgLen >= 200) {
      // PSRAM copy â€” leave internal RAM for mbedTLS handshake.
      jpg = (uint8_t*)heap_caps_malloc(camJpgLen, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
      if (!jpg) jpg = (uint8_t*)malloc(camJpgLen);
      if (jpg) {
        memcpy(jpg, camJpg, camJpgLen);
        jlen = camJpgLen;
      }
    }
    xSemaphoreGive(camJpgLock);
  }
  if (!jpg || jlen < 200) {
    if (jpg) free(jpg);
    return -1;
  }
  if (!takeHttpOut(200)) {
    free(jpg);
    return -2;  // busy, not a link failure
  }

  int c = -1;
  if (farmBackendIsHttps()) {
    static unsigned long lastTryLog = 0;
    if (millis() - lastTryLog > 3000UL) {
      lastTryLog = millis();
      Serial.printf("TUNNEL push try jpg=%u heap=%u\n",
                    (unsigned)jlen, (unsigned)ESP.getFreeHeap());
    }
    // Always prefer TLS keep-alive for live fps — reconnect only when socket dies.
    c = httpsPostRaw("/api/frame", jpg, jlen, "image/jpeg", true);
    if (c == 404) c = httpsPostRaw("/frame", jpg, jlen, "image/jpeg", true);
  } else {
    // Raw LAN keep-alive — HTTPClient close-per-frame cannot hit 100–150 ms.
    static WiFiClient lanCli;
    int ip0 = 0, ip1 = 0, ip2 = 0, ip3 = 0;
    const char* pUrl = strstr(activeBackend, "://");
    pUrl = pUrl ? pUrl + 3 : activeBackend;
    if (sscanf(pUrl, "%d.%d.%d.%d", &ip0, &ip1, &ip2, &ip3) != 4) {
      giveHttpOut();
      free(jpg);
      return -1;
    }
    IPAddress lip(ip0, ip1, ip2, ip3);
    if (!lanCli.connected()) {
      lanCli.stop();
      if (!lanCli.connect(lip, 8000, 350)) {
        giveHttpOut();
        free(jpg);
        lanPushFailStreak++;
        if (lanPushFailStreak >= 6) farmUseTunnel("lan connect fail");
        return -1;
      }
    }
    char hdr[280];
    int hn = snprintf(
        hdr, sizeof(hdr),
        "POST /api/frame HTTP/1.1\r\nHost: %d.%d.%d.%d\r\n"
        "Content-Type: image/jpeg\r\nContent-Length: %u\r\n"
        "Connection: keep-alive\r\n",
        ip0, ip1, ip2, ip3, (unsigned)jlen);
    if (strlen(FARM_DEVICE_TOKEN) > 0) {
      hn += snprintf(hdr + hn, sizeof(hdr) - hn,
                     "X-Farm-Device-Token: %s\r\n", FARM_DEVICE_TOKEN);
    }
    hn += snprintf(hdr + hn, sizeof(hdr) - hn, "\r\n");
    bool wrote = hn > 0 && (size_t)hn < sizeof(hdr) &&
                 lanCli.write((const uint8_t*)hdr, (size_t)hn) == (size_t)hn &&
                 lanCli.write(jpg, jlen) == jlen;
    if (!wrote) {
      lanCli.stop();
      giveHttpOut();
      free(jpg);
      lanPushFailStreak++;
      if (lanPushFailStreak >= 6) farmUseTunnel("lan write fail");
      return -1;
    }
    // Fire-and-forget — drain a few bytes so the socket stays healthy.
    c = 200;
    unsigned long t0 = millis();
    while (millis() - t0 < 8UL) {
      while (lanCli.available()) (void)lanCli.read();
      delay(1);
    }
  }
  giveHttpOut();
  free(jpg);

  int d = -1;
  if (c == 200 || c == 201 || c == 204) {
    d = 0;
    camJpgPushed = seq;
    lastLivePushAt = millis();
    lanPushFailStreak = 0;
    if (hbFails > 0) hbFails = 0;
  } else {
    if (!farmBackendIsHttps()) {
      lanPushFailStreak++;
      if (lanPushFailStreak >= 6) {
        farmUseTunnel("LAN POST fail");
      } else {
        static unsigned long lastConnLog = 0;
        if (millis() - lastConnLog > 4000UL) {
          lastConnLog = millis();
          Serial.printf("LIVE LAN fail http=%d — retry before tunnel\n", c);
        }
      }
    } else {
      static unsigned long lastHttpLog = 0;
      if (millis() - lastHttpLog > 4000UL) {
        lastHttpLog = millis();
        Serial.printf("LIVE tunnel push http=%d jpg=%u\n", c, (unsigned)jlen);
      }
    }
  }
  return d;
#endif
}

static volatile int camState = 0;
static volatile uint32_t camHeap = 0;
static volatile uint32_t camPsram = 0;

#if EGG_DEVKIT
// Read HTTP reply even after server closes â€” weak Wiâ€‘Fi often drops late bytes.
static int readFarmHttpReply(WiFiClient& cli, char* body, size_t bodyCap, unsigned long maxMs) {
  if (!body || bodyCap < 2) return -1;
  char line[128];
  size_t li = 0;
  unsigned long t0 = millis();
  bool inBody = false;
  int status = 0;
  size_t bi = 0;
  body[0] = 0;
  while ((millis() - t0) < 800UL && !cli.available() && cli.connected()) {
    delay(5);
    yield();
  }
  while ((millis() - t0) < maxMs) {
    int ch = cli.read();
    if (ch < 0) {
      if (!cli.connected() && !cli.available()) break;
      delay(2);
      yield();
      continue;
    }
    if (!inBody) {
      if (ch == '\n') {
        line[li < sizeof(line) - 1 ? li : sizeof(line) - 1] = 0;
        if (li == 0 || (li == 1 && line[0] == '\r')) {
          inBody = true;
          li = 0;
          continue;
        }
        if (status == 0 && strncmp(line, "HTTP/", 5) == 0) {
          const char* sp = strchr(line, ' ');
          if (sp) status = atoi(sp + 1);
        }
        li = 0;
      } else if (li < sizeof(line) - 1) {
        line[li++] = (char)ch;
      }
    } else {
      if (bi < bodyCap - 1) body[bi++] = (char)ch;
      else break;
    }
  }
  body[bi] = 0;
  if (status > 0) return status;
  if (body[0]) return 200;
  return -1;
}

// Apply farm Clean/Crack/Dirty to GATE â€” called AFTER Wiâ€‘Fi is fully released.
static void applyFarmGateFromBody(const char* hbBody) {
  if (!hbBody || !hbBody[0]) return;
  if (strstr(hbBody, "\"servoTest\":true") || strstr(hbBody, "\"servoTest\": true")) {
#if !SERIAL_WEIGHT_ONLY
    Serial.println("Heartbeat servoTest â€” GATE P14 now");
#endif
    rejectSweep(true);
  }
  bool scanning = strstr(hbBody, "\"scanning\":true") || strstr(hbBody, "\"scanning\": true");
  if (scanning && !scanNoted) {
    scanNoted = true;
    Serial.println("CAMERA scanning â€” GATE middle");
  }
  if (!scanning) scanNoted = false;
  bool eggSeen = strstr(hbBody, "\"eggSeen\":true") || strstr(hbBody, "\"eggSeen\": true");
  bool cleanEgg = strstr(hbBody, "\"cleanEgg\":true") || strstr(hbBody, "\"cleanEgg\": true");
  bool rejectEggHb = strstr(hbBody, "\"rejectEgg\":true") || strstr(hbBody, "\"rejectEgg\": true");
  // Farm keeps weighArm/awaitingWeight after the egg leaves the camera FOV.
  bool weighArmHb =
      strstr(hbBody, "\"weighArm\":true") || strstr(hbBody, "\"weighArm\": true") ||
      strstr(hbBody, "\"awaitingWeight\":true") ||
      strstr(hbBody, "\"awaitingWeight\": true");
  bool camCrack =
      strstr(hbBody, "\"cameraResult\":\"Crack\"") ||
      strstr(hbBody, "\"cameraResult\": \"Crack\"");
  bool camClean =
      strstr(hbBody, "\"cameraResult\":\"Clean\"") ||
      strstr(hbBody, "\"cameraResult\": \"Clean\"") ||
      strstr(hbBody, "\"cameraResult\":\"Dirty\"") ||
      strstr(hbBody, "\"cameraResult\": \"Dirty\"") ||
      strstr(hbBody, "\"lastLabel\":\"Clean Egg\"") ||
      strstr(hbBody, "\"lastLabel\": \"Clean Egg\"") ||
      strstr(hbBody, "\"lastLabel\":\"No Crack Egg\"") ||
      strstr(hbBody, "\"lastLabel\": \"No Crack Egg\"");
  // Dirty/dust maps to Clean â€” only Crack is reject.
  bool crack = rejectEggHb || camCrack;
  bool noCrack = cleanEgg || camClean || weighArmHb;
  // Pad auto-weigh: arm from farm even when GATE already returned middle.
  if (weighArmHb && !crack && !weightShown && !eggResultPrinted) {
    if (!weighArmedClean || millis() >= weighArmedUntil) {
      Serial.println("Farm weighArm â€” 5s travel, sense pad, 3s settle, then weigh");
      // Camera just fired; egg is still on the belt (~4â€“5s). Clear residual,
      // latch empty, sense landing, settle impact, THEN weigh + record.
      mustSeeEmpty = true;
      awaitNextEgg = false;
      idleShownOk = false;
      eggSeenHits = 0;
      clearSinceAt = 0;
      weighArmedAt = millis();
      padEmptyLatched = false;
      padArrivalSeen = false;
      padArrivalAt = 0;
      padArrivalHits = 0;
      padEmptyHits = 0;
      padEmptyBaseD = 0;
    }
    weighArmedClean = true;
    weighArmedUntil = millis() + WEIGH_ARMED_MS;
  }
  if (scanning) {
    strncpy(farmCamResult, "Scanning", sizeof(farmCamResult) - 1);
    strncpy(farmSortResult, "Good", sizeof(farmSortResult) - 1);
  } else if (crack) {
    strncpy(farmCamResult, "Crack", sizeof(farmCamResult) - 1);
    strncpy(farmSortResult, "Reject", sizeof(farmSortResult) - 1);
    weighArmedClean = false;
    weighArmedUntil = 0;
    weighArmedAt = 0;
    padEmptyLatched = false;
    padArrivalSeen = false;
    padArrivalAt = 0;
    padArrivalHits = 0;
  } else if (noCrack || weighArmHb) {
    strncpy(farmCamResult, "Clean", sizeof(farmCamResult) - 1);
    strncpy(farmSortResult, "Good", sizeof(farmSortResult) - 1);
  } else {
    if (!(weighArmedClean && awaitNextEgg && millis() < weighArmedUntil)) {
      strncpy(farmCamResult, "Pending", sizeof(farmCamResult) - 1);
    }
    strncpy(farmSortResult, "Good", sizeof(farmSortResult) - 1);
  }
  farmCamResult[sizeof(farmCamResult) - 1] = 0;
  farmSortResult[sizeof(farmSortResult) - 1] = 0;
  int wantSide = 0;
  if (!scanning) {
    if (crack) wantSide = 1;
    else if (noCrack) wantSide = -1;
  }
  if (scanning && wantSide == 0) {
    if (gateAngle != 0 || gateLatchedSide != 0) {
      camServoWrite(GATE_CENTER_US);
      gateAngle = 0;
      gateLatchedSide = 0;
      gateDecisionPulsed = 0;
      gateReturnAt = 0;
      gateHoldUntil = 0;
      camGateDown = true;
      Serial.println("GATE P14 middle â€” scanning");
    }
  } else if (wantSide != 0) {
    // Clean/Crack: swing once, HOLD while egg still in camera, MIDDLE when it vanishes.
    // Sticky cleanEgg after FOV clear must NOT re-swing (gateDecisionPulsed stays).
    if (!eggSeen && (gateAngle != 0 || gateLatchedSide != 0 || gateDecisionPulsed != 0)) {
      camServoWrite(GATE_CENTER_US);
      gateAngle = 0;
      gateLatchedSide = 0;
      gateDecisionPulsed = 0;  // next egg may swing again (farm clears cleanEgg when FOV empty)
      gateReturnAt = 0;
      gateHoldUntil = 0;
      camGateDown = true;
      Serial.println("GATE P14 middle â€” egg left camera");
    } else if (eggSeen && gateDecisionPulsed != wantSide) {
      if (!servoDriverOk) servoDriverInit();
      inspectedEgg = true;
      camRejectDone = true;
      rejectedEgg = (wantSide > 0);
      if (wantSide > 0 && motorRun) stopBelt();
      if (wantSide < 0) {
        Serial.println("CAMERA clean â€” GATE P14 FULL LEFT (hold until egg leaves cam)");
        camServoWrite(GATE_LEFT_US);  // blocking ~0.8s burst + soft-PWM hold
        gateAngle = -1;
        awaitNextEgg = true;
        idleShownOk = true;
        mustSeeEmpty = false;
        weighArmedClean = true;
        weighArmedUntil = millis() + WEIGH_ARMED_MS;
        weighCooldownUntil = millis() + 400UL;
        Serial.println("GATE LEFT hold â†’ pad auto-weigh armed 30s");
      } else {
        Serial.println("CAMERA crack/dirty â€” GATE P14 FULL RIGHT (hold until egg leaves cam)");
        camServoWrite(GATE_RIGHT_US);
        gateAngle = 1;
        awaitNextEgg = false;
        weighArmedClean = false;
        weighArmedUntil = 0;
        weighArmedAt = 0;
        padEmptyLatched = false;
        padArrivalSeen = false;
        padArrivalAt = 0;
        padArrivalHits = 0;
        Serial.println("GATE RIGHT hold");
      }
      gateLatchedSide = wantSide;
      gateDecisionPulsed = wantSide;
      camGateDown = false;
      gateReturnAt = millis() + GATE_MAX_HOLD_MS;
      gateHoldUntil = gateReturnAt;
    } else if (eggSeen) {
      // Still in FOV â€” keep soft-PWM hard left/right; refresh safety timeout.
      gatePwmUs = (wantSide < 0) ? GATE_LEFT_US : GATE_RIGHT_US;
      gateReturnAt = millis() + GATE_MAX_HOLD_MS;
      gateHoldUntil = gateReturnAt;
    }
  } else {
    // Farm idle (Pending) â€” middle when egg not in view.
    // Do NOT hold LEFT for weigh-arm; pad arm is separate from GATE pose.
    if (!eggSeen && (gateAngle != 0 || gateLatchedSide != 0)) {
      camServoWrite(GATE_CENTER_US);
      gateAngle = 0;
      gateLatchedSide = 0;
      gateDecisionPulsed = 0;
      gateReturnAt = 0;
      gateHoldUntil = 0;
      camGateDown = true;
      Serial.println("GATE P14 middle â€” idle / ready for next egg");
    } else if (eggSeen && gateAngle != 0) {
      if (gateAngle < 0) gatePwmUs = GATE_LEFT_US;
      else gatePwmUs = GATE_RIGHT_US;
    }
  }
}
#endif  // EGG_DEVKIT

void heartbeat(float g) {
#if ARDUINO_LOCAL && !GATE_FROM_FARM
  (void)g;
  return;
#else
  // Live frames already prove ONLINE — do not steal/close the TLS socket.
  // Live frames own the tunnel — HB steals TLS and freezes the picture.
  if (farmBackendIsHttps() && lastLivePushAt != 0 &&
      (millis() - lastLivePushAt) < 180000UL) {
    return;
  }
  if (wifiSwitching) return;
  if (WiFi.status() != WL_CONNECTED || strlen(FARM_BACKEND_URL) == 0) return;
  if (!urlStatus.length()) {
    if (farmBackendIsHttps() && FARM_PUBLIC_URL[0]) applyBackend(FARM_PUBLIC_URL);
    else if (activeBackend[0]) applyBackend(activeBackend);
    else applyBackend(FARM_BACKEND_URL);
  }
#if EGG_DEVKIT
  // Pause GATE soft-PWM only â€” ENTRANCE LEDC stays live on P13.
  gatePwmPaused = true;
  if (!takeHttpOut(500)) {
    gatePwmPaused = false;
    return;
  }
#else
  // Prefer live push: if campush holds the lock, skip this HB tick.
  if (!takeHttpOut(10)) return;
#endif

#if EGG_DEVKIT
  // Raw HTTP/1.0 + Connection:close â€” HTTPClient was crashing pbuf_free after Clean GATE.
  int ip0 = 0, ip1 = 0, ip2 = 0, ip3 = 0;
  const char* pUrl = strstr(activeBackend, "://");
  pUrl = pUrl ? pUrl + 3 : activeBackend;
  char host[16] = {0};
  int c = -1;
  static char hbBody[512];
  hbBody[0] = 0;
  if (sscanf(pUrl, "%d.%d.%d.%d", &ip0, &ip1, &ip2, &ip3) == 4) {
    snprintf(host, sizeof(host), "%d.%d.%d.%d", ip0, ip1, ip2, ip3);
    char payload[160];
    int plen = snprintf(payload, sizeof(payload),
                        "{\"status\":\"ONLINE\",\"device\":\"ESP32-DevKit\",\"weightGrams\":%.1f}",
                        (g >= 0) ? g : 0.0f);
    // Extender Wiâ€‘Fi: laptop often LOGS DevKit ONLINE while this board still
    // gets http=-1 (POST accepted, reply dropped). Wait for bytes + GET fallback.
    const uint32_t connectMs = hbFails >= 1 ? 2200u : 1600u;

    for (int attempt = 0; attempt < 2 && c != 200; attempt++) {
      if (attempt) delay(50);
      WiFiClient cli;
      cli.setTimeout(1500);
      if (!cli.connect(host, 8000, connectMs)) continue;
      char req[384];
      int rn = snprintf(req, sizeof(req),
                        "POST /api/status HTTP/1.0\r\n"
                        "Host: %s\r\n"
                        "Content-Type: application/json\r\n"
                        "Connection: close\r\n"
                        "Content-Length: %d\r\n",
                        host, plen);
      if (strlen(FARM_DEVICE_TOKEN) > 0) {
        rn += snprintf(req + rn, sizeof(req) - rn,
                       "X-Farm-Device-Token: %s\r\n", FARM_DEVICE_TOKEN);
      }
      rn += snprintf(req + rn, sizeof(req) - rn, "\r\n");
      cli.write((const uint8_t*)req, rn);
      cli.write((const uint8_t*)payload, plen);
      cli.flush();
      c = readFarmHttpReply(cli, hbBody, sizeof(hbBody), 2500UL);
      cli.stop();
    }
    // POST landed on laptop (ONLINE in backend) but reply lost â€” pull gate cue.
    if (c != 200 || !hbBody[0]) {
      WiFiClient cli2;
      cli2.setTimeout(1500);
      if (cli2.connect(host, 8000, connectMs)) {
        char greq[160];
        snprintf(greq, sizeof(greq),
                 "GET /api/gate-cue HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n",
                 host);
        cli2.print(greq);
        cli2.flush();
        int gc = readFarmHttpReply(cli2, hbBody, sizeof(hbBody), 2000UL);
        cli2.stop();
        if (gc == 200 && hbBody[0]) c = 200;
      }
    }
  }
  giveHttpOut();
  gatePwmPaused = false;
  delay(10);  // let lwIP free the closed socket before servo pulses
  if (c != 200) {
    hbFails++;
    // Ignore single blips (OK/fail/OK spam). Only warn on real outages.
    if (hbFails == 3 || hbFails % 10 == 0) {
      Serial.printf(
          "Laptop HB fail x%d http=%d rssi=%d â€” keep trying â†’ %s\n",
          hbFails, c, WiFi.RSSI(), activeBackend);
    }
  } else {
    bool wasDown = (hbFails >= 3) || !hbEverOk;
    hbFails = 0;
    hbEverOk = true;
    if (wasDown) {
      Serial.printf("Laptop HB OK rssi=%d â€” link restored\n", WiFi.RSSI());
    }
    // Show what camera sent so we know if Clean reached DevKit.
    if (strstr(hbBody, "\"cleanEgg\":true") || strstr(hbBody, "\"cameraResult\":\"Clean\"")) {
      static unsigned long lastCleanLog = 0;
      if (millis() - lastCleanLog > 2000UL) {
        lastCleanLog = millis();
        Serial.println("HB body has Clean â€” moving GATE if not already LEFT");
      }
    }
    applyFarmGateFromBody(hbBody);
  }
#else
  // Lock already taken above â€” skip fast so live push can own Wiâ€‘Fi.
  if (!streamUrl.length()) refreshStreamUrl();
  const char* devName = "ESP32-CAM";
  char pbuf[480];
  int n = snprintf(pbuf, sizeof(pbuf), "{\"status\":\"ONLINE\",\"device\":\"%s\",\"zoom\":%.2f", devName, camZoom);
  if (streamUrl.length()) n += snprintf(pbuf + n, sizeof(pbuf) - n, ",\"streamUrl\":\"%s\"", streamUrl.c_str());
  if (streamUrl.length()) {
    String jpgUrl = streamUrl;
    jpgUrl.replace(":81/mjpeg", ":82/jpg");
    n += snprintf(pbuf + n, sizeof(pbuf) - n, ",\"jpgUrl\":\"%s\"", jpgUrl.c_str());
  }
  n += snprintf(pbuf + n, sizeof(pbuf) - n, ",\"cam\":%d,\"h\":%u,\"p\":%u,\"jpg\":%u",
                camState, (unsigned)camHeap, (unsigned)camPsram, (unsigned)camJpgLen);
  if (g >= 0) n += snprintf(pbuf + n, sizeof(pbuf) - n, ",\"weightGrams\":%.1f", g);
  snprintf(pbuf + n, sizeof(pbuf) - n, "}");
  int c = -1;
  if (farmBackendIsHttps()) {
    // Never keep-alive after HB â€” that left a dead TLS socket for the next frame.
    c = httpsPostRaw("/api/status", (const uint8_t*)pbuf, strlen(pbuf),
                     "application/json", false);
  } else {
    HTTPClient http;
    WiFiClient cli;
    http.setReuse(false);
    bool began = false;
    int ip0 = 0, ip1 = 0, ip2 = 0, ip3 = 0;
    const char* pUrl = strstr(activeBackend, "://");
    pUrl = pUrl ? pUrl + 3 : activeBackend;
    http.setConnectTimeout(hbFails >= 2 ? 900 : 600);
    http.setTimeout(hbFails >= 2 ? 1200 : 800);
    if (sscanf(pUrl, "%d.%d.%d.%d", &ip0, &ip1, &ip2, &ip3) == 4) {
      char host[16];
      snprintf(host, sizeof(host), "%d.%d.%d.%d", ip0, ip1, ip2, ip3);
      began = http.begin(cli, host, 8000, "/api/status");
    } else {
      began = http.begin(cli, urlStatus);
    }
    if (!began) {
      giveHttpOut();
      hbFails++;
      if (hbFails >= 2) farmUseTunnel("HB begin fail");
      if (hbFails == 1 || hbFails % 5 == 0) {
        Serial.printf("Laptop HB begin-fail x%d url=%s\n", hbFails, urlStatus.c_str());
      }
      return;
    }
    farmHeaders(http);
    http.addHeader("Connection", "close");
    c = http.POST((uint8_t*)pbuf, strlen(pbuf));
    http.end();
  }
  giveHttpOut();
  if (c != 200) {
    hbFails++;
    if (!farmBackendIsHttps() && hbFails >= 2) farmUseTunnel("HB POST fail");
    if (hbFails == 1 || hbFails % 5 == 0) {
      Serial.printf("Laptop HB fail x%d http=%d rssi=%d (stay on %s) â†’ %s\n",
                    hbFails, c, WiFi.RSSI(), WiFi.SSID().c_str(), activeBackend);
    }
  } else {
    hbFails = 0;
    hbEverOk = true;
  }
#endif
#endif  // ARDUINO_LOCAL && !GATE_FROM_FARM
}

void stopBelt() {
  pinMode(MOTOR_PIN, OUTPUT);
  pinMode(MOTOR_IN2_PIN, OUTPUT);
  digitalWrite(MOTOR_PIN, LOW);
  digitalWrite(MOTOR_IN2_PIN, LOW);
  motorRun = false;
}

void startBelt() {
  // GPIO only. LEDC on these pins steals the servo timer and all four horns stop.
  pinMode(MOTOR_PIN, OUTPUT);
  pinMode(MOTOR_IN2_PIN, OUTPUT);
  if (motorForward) {
    digitalWrite(MOTOR_IN2_PIN, LOW);
    digitalWrite(MOTOR_PIN, HIGH);
  } else {
    digitalWrite(MOTOR_PIN, LOW);
    digitalWrite(MOTOR_IN2_PIN, HIGH);
  }
  motorRun = true;
}

void learnIrIdle() {
  // This sensor sits HIGH when the beam is clear. Learning the idle level
  // flipped it on a low glitch and treated the clear beam as an egg.
  irEggWhenLow = true;
  irCount = 0;
  irEgg = false;
  eggLatched = false;
#if !SERIAL_WEIGHT_ONLY
  Serial.println("IR idle HIGH on P19 â€” egg only when the pin goes LOW");
#endif
}

void sampleIr() {
  if (millis() - irSampleAt < 15) return;
  irSampleAt = millis();
  int v = digitalRead(IR_PIN);
  irLevel = v;
  bool rawEgg = irEggWhenLow ? (v == LOW) : (v == HIGH);
  if (rawEgg) {
    if (irCount < 12) irCount++;
  } else if (irCount > 0) {
    irCount--;
  }
  bool was = irEgg;
  irEgg = irCount >= 8;
  if (irEgg && !was) {
    // Passed egg at entrance only â€” never starts weigh / SORT / PUSH.
    eggLatched = true;
    eggLatchAt = millis();
    static unsigned long lastIrMsgAt = 0;
    if (millis() - lastIrMsgAt > 3000UL) {
      lastIrMsgAt = millis();
      Serial.println("IR passed egg â€” ENTRANCE DOWN (weigh is separate)");
    }
  }
}

void holdSckLow() {
  gpio_hold_dis(GPIO_NUM_12);
  pinMode(hxSckPin, OUTPUT);
  digitalWrite(hxSckPin, LOW);
}

void latchSckLow() {
  holdSckLow();
}

void claimServoGpio(int pin) {
  gpio_num_t p = (gpio_num_t)pin;
  rtc_gpio_deinit(p);
  gpio_hold_dis(p);
  gpio_pulldown_dis(p);
  gpio_pullup_dis(p);
  ledcDetach(pin);
  gpio_reset_pin(p);
  pinMode(pin, OUTPUT);
  digitalWrite(pin, LOW);
}

int servoSlot(int pin) {
  if (pin == SERVO_REJECT_PIN) return 0;
  if (pin == SERVO_SIZE_PIN) return 1;
  if (pin == SERVO_CAM_PIN) return 2;
  if (pin == ENTRANCE_PIN) return 3;
  return -1;
}

void servoApply(int slot) {
  if (slot < 0 || slot > 3) return;
  int us = servoTargetUs[slot];
  if (us < 500) us = 500;
  if (us > 2500) us = 2500;
  servoTargetUs[slot] = us;
  // Pulse is generated by servoFrameCb â€” only the target is stored here.
}

void servoKickDrive() {
  servoDriveUntil = millis() + SERVO_DRIVE_MS;
  if (!servoTimer || !servoDriverOk) return;
  if (!servoTimerRunning) {
    if (esp_timer_start_periodic(servoTimer, 20000) == ESP_OK) servoTimerRunning = true;
  }
}

// One 50 Hz frame: HIGH for target Âµs on each horn, then LOW (bit-bang).
// Stops after SERVO_DRIVE_MS so horns do not chatter when idle.
static void servoFrameCb(void* /*arg*/) {
  if (servoFrameBusy || !servoDriverOk) return;
  servoFrameBusy = true;
  if ((long)(millis() - servoDriveUntil) >= 0) {
    for (int i = 0; i < 4; i++) {
#if EGG_DEVKIT
      // PUSH/SORT only â€” GATE/ENTRANCE are soft-PWM in the main loop.
      if (servoPins[i] == ENTRANCE_PIN || servoPins[i] == SERVO_CAM_PIN) continue;
#endif
      digitalWrite(servoPins[i], LOW);
    }
    if (servoTimer && servoTimerRunning) {
      esp_timer_stop(servoTimer);
      servoTimerRunning = false;
    }
    servoFrameBusy = false;
    return;
  }
  for (int i = 0; i < 4; i++) {
    int pin = servoPins[i];
#if EGG_DEVKIT
    if (pin == ENTRANCE_PIN || pin == SERVO_CAM_PIN) continue;
#endif
    int us = servoTargetUs[i];
    if (us < 500) us = 500;
    if (us > 2500) us = 2500;
    digitalWrite(pin, HIGH);
    delayMicroseconds(us);
    digitalWrite(pin, LOW);
    delayMicroseconds(40);
  }
  servoFrameBusy = false;
}

#if EGG_DEVKIT
// Short 50 Hz burst. Long blocking bursts caused TG1WDT_SYS_RESET â†’ flash boot loop.
static void hornForceBurst(int pin, int us, int frames) {
  if (us < 500) us = 500;
  if (us > 2500) us = 2500;
  if (frames > 30) frames = 30;  // max ~0.6s â€” never starve the watchdog
  ledcDetach(pin);
  pinMode(pin, OUTPUT);
  for (int i = 0; i < frames; i++) {
    digitalWrite(pin, HIGH);
    delayMicroseconds(us);
    digitalWrite(pin, LOW);
    if (us < 20000) delayMicroseconds(20000 - us);
    else delayMicroseconds(100);
    if ((i & 3) == 3) yield();  // feed WDT / Wiâ€‘Fi
  }
}

static void entranceServoWrite(int us) {
  if (us < 500) us = 500;
  if (us > 2500) us = 2500;
  int slot = servoSlot(ENTRANCE_PIN);
  if (slot >= 0) servoTargetUs[slot] = us;
  entrancePwmUs = us;
  Serial.printf("ENTRANCE P13 â†’ %dus (burst)\n", us);
  hornForceBurst(ENTRANCE_PIN, us, 25);  // ~0.5s then soft-PWM holds
}

static void gateServoWrite(int us) {
  if (us < 500) us = 500;
  if (us > 2500) us = 2500;
  int slot = servoSlot(SERVO_CAM_PIN);
  if (slot >= 0) servoTargetUs[slot] = us;
  gatePwmUs = us;
  hornForceBurst(SERVO_CAM_PIN, us, 25);
}

// ENTRANCE pulsed every 20ms always. GATE only when not in HB.
void serviceHornPwm() {
  if (!servoDriverOk) return;
  unsigned long now = millis();
  if (now - hornPwmPhaseAt < 20UL) return;
  hornPwmPhaseAt = now;
  int eus = entrancePwmUs;
  if (eus < 500) eus = 500;
  if (eus > 2500) eus = 2500;
  digitalWrite(ENTRANCE_PIN, HIGH);
  delayMicroseconds(eus);
  digitalWrite(ENTRANCE_PIN, LOW);
  if (!gatePwmPaused) {
    int gus = gatePwmUs;
    if (gus < 500) gus = 500;
    if (gus > 2500) gus = 2500;
    digitalWrite(SERVO_CAM_PIN, HIGH);
    delayMicroseconds(gus);
    digitalWrite(SERVO_CAM_PIN, LOW);
  }
  yield();
}
#endif

bool servoDriverInit() {
  if (servoDriverOk) return true;
  const int restUs[4] = {SORT_MEDIUM_US, PUSH_HOME_US, GATE_CENTER_US, ENTRANCE_HOLD_US};
  for (int i = 0; i < 4; i++) {
    claimServoGpio(servoPins[i]);
    servoTargetUs[i] = restUs[i];
  }
  esp_timer_create_args_t args = {};
  args.callback = &servoFrameCb;
  args.arg = nullptr;
  args.dispatch_method = ESP_TIMER_TASK;
  args.name = "servo50";
  if (esp_timer_create(&args, &servoTimer) != ESP_OK) {
    Serial.println("SERVO timer create failed");
    return false;
  }
  servoTimerRunning = false;
  servoDriverOk = true;
#if EGG_DEVKIT
  gatePwmPaused = false;
  entrancePwmUs = ENTRANCE_HOLD_US;
  gatePwmUs = GATE_CENTER_US;
  pinMode(ENTRANCE_PIN, OUTPUT);
  pinMode(SERVO_CAM_PIN, OUTPUT);
  entranceServoWrite(ENTRANCE_HOLD_US);
  gateServoWrite(GATE_CENTER_US);
#endif
  servoKickDrive();
  Serial.println("SERVO ready â€” ENTRANCE=softPWM always, GATE=softPWM, PUSH/SORT=pulse");
  return true;
}

void servoRestart() {
  if (servoTimer) {
    if (servoTimerRunning) esp_timer_stop(servoTimer);
    esp_timer_delete(servoTimer);
    servoTimer = nullptr;
  }
  servoTimerRunning = false;
  servoDriverOk = false;
#if EGG_DEVKIT
  gatePwmPaused = false;
#endif
  servoDriverInit();
}

void servoReattach() {
  if (!servoDriverOk) {
    servoDriverInit();
    return;
  }
  for (int i = 0; i < 4; i++) {
    pinMode(servoPins[i], OUTPUT);
    servoApply(i);
  }
}

void entranceForceDown(const char* why) {
#if EGG_DEVKIT
  entranceServoWrite(ENTRANCE_HOLD_US);
#else
  int slot = servoSlot(ENTRANCE_PIN);
  servoTargetUs[slot] = ENTRANCE_HOLD_US;
  servoKickDrive();
#endif
  entranceOpen = false;
  entranceAt = millis();
  Serial.println(why);
}

void serviceEntrance() {
  if (!servoDriverOk) return;
  // Debounce IR here (same hysteresis as sampleIr). Raw digitalRead caused
  // held-DOWN / IR-clear flip-flop spam when the beam edge was noisy.
  int irPin = digitalRead(IR_PIN);
  bool rawEgg = irEggWhenLow ? (irPin == LOW) : (irPin == HIGH);
  static uint8_t eggStreak = 0;
  static uint8_t clearStreak = 0;
  static bool beamBlocked = false;
  static bool forcedDownForBeam = false;
  static unsigned long blockWarnAt = 0;
  static unsigned long clearMsgAt = 0;
  if (rawEgg) {
    if (eggStreak < 255) eggStreak++;
    clearStreak = 0;
  } else {
    if (clearStreak < 255) clearStreak++;
    eggStreak = 0;
  }
  if (!beamBlocked && eggStreak >= 8) beamBlocked = true;
  if (beamBlocked && clearStreak >= 8) beamBlocked = false;

  if (beamBlocked || irEgg) {
    // Close once when we first decide the beam is blocked (no ForceDown spam).
    if (!forcedDownForBeam &&
        (entranceOpen || servoTargetUs[servoSlot(ENTRANCE_PIN)] != ENTRANCE_HOLD_US)) {
      entranceForceDown("ENTRANCE P13 DOWN â€” IR egg detected");
      forcedDownForBeam = true;
    } else {
      entranceOpen = false;
    }
    if (millis() - blockWarnAt > 5000UL) {
      blockWarnAt = millis();
      Serial.printf(
          "ENTRANCE held DOWN â€” IR P19=%d (egg when %s). Clear beam or type ir / entrance\n",
          irPin, irEggWhenLow ? "LOW" : "HIGH");
    }
    return;
  }
  forcedDownForBeam = false;
  // Beam stably clear â€” rate-limit the clear message (was every flicker).
  if (clearStreak == 8 && millis() - clearMsgAt > 2000UL) {
    clearMsgAt = millis();
    entranceAt = millis();  // full 10s after stable clear
    Serial.println("IR clear â€” next ENTRANCE UP in 10s (or type entrance now)");
  }
  // During weigh / push / result â€” hold entrance so egg 2 does not enter mid-cycle.
  if (eggSession || weightShown || announceEggRemoved || eggResultPrinted ||
      pushArmed || pushReturn) {
    return;
  }
  // Stay UP until IR detects egg â€” never timeout DOWN.
  if (entranceOpen) {
#if EGG_DEVKIT
    entrancePwmUs = ENTRANCE_OPEN_US;  // soft-PWM in loop keeps holding UP
#endif
    if (ENTRANCE_OPEN_MAX_MS > 0 &&
        millis() - entranceOpenedAt >= ENTRANCE_OPEN_MAX_MS) {
      entranceForceDown("ENTRANCE P13 DOWN â€” no IR egg, wait 10s");
    }
    return;
  }
  if (entranceAt == 0) entranceAt = millis();
  if (millis() - entranceAt >= ENTRANCE_EVERY_MS) {
#if EGG_DEVKIT
    entranceServoWrite(ENTRANCE_OPEN_US);
#else
    int slot = servoSlot(ENTRANCE_PIN);
    servoTargetUs[slot] = ENTRANCE_OPEN_US;
    servoKickDrive();
#endif
    entranceOpen = true;
    entranceOpenedAt = millis();
    entranceAt = millis();
    Serial.println("ENTRANCE P13 UP â€” waiting for IR egg (then DOWN)");
  }
}

void servicePush() {
  if (pushReturn && millis() >= pushDueAt) {
    pushReturn = false;
    servoWriteUs(SERVO_SIZE_PIN, PUSH_HOME_US);
    Serial.println("PUSH P25 home");
#if EGG_DEVKIT
    // Do NOT tare/Ready here â€” egg residual on soft cell poisoned zero â†’ fake ~70 g.
    // Clear result flags, wait until wood near empty, then Ready (mustSeeEmpty path).
    if (announceEggRemoved || weightShown || eggResultPrinted) {
      gateHoldUntil = 0;
      gateDecisionPulsed = 0;  // next Clean/Crack may move GATE again
      eggLatched = false;
      weightShown = false;
      announceEggRemoved = false;
      eggResultPrinted = false;
      eggSession = false;
      eggSessionAt = 0;
      postedEgg = false;
      sizeDone = false;
      liveG = 0;
      scaleG = 0;
      lastStableG = 0;
#if GATE_FROM_FARM
      awaitNextEgg = true;  // next Clean egg can auto-weigh after pad clears
#else
      awaitNextEgg = false;
#endif
      mustSeeEmpty = true;
      idleShownOk = false;
      clearSinceAt = 0;
      Serial.println();
      Serial.println("========== EGG REMOVED ==========");
      Serial.println("================================");
    }
#endif
    return;
  }
  if (!pushArmed || millis() < pushDueAt) return;
  pushArmed = false;
  servoWriteUs(SERVO_SIZE_PIN, PUSH_STROKE_US);
  Serial.printf("PUSH P25 â€” egg off scale into %s lane\n",
                pendingSize.length() ? gradeOf(pendingSize).c_str() : "SORT");
  pushReturn = true;
  pushDueAt = millis() + 500;
}

void servoWriteUs(int pin, int us) {
  if (us < 500) us = 500;
  if (us > 2500) us = 2500;
  int slot = servoSlot(pin);
  if (slot < 0) return;
  if (!servoDriverOk) servoDriverInit();
  if (us < 500) us = 500;
  if (us > 2500) us = 2500;
#if EGG_DEVKIT
  if (pin == ENTRANCE_PIN) {
    entranceServoWrite(us);
    return;
  }
  if (pin == SERVO_CAM_PIN) {
    gateServoWrite(us);
    return;
  }
#endif
  // Skip re-kick if already at this angle â€” avoids chatter from repeated writes.
  if (servoTargetUs[slot] == us && servoTimerRunning &&
      (long)(millis() - servoDriveUntil) < 0) {
    return;
  }
  servoTargetUs[slot] = us;
  servoApply(slot);
  servoKickDrive();
}

void camServoWrite(int us) {
  servoWriteUs(SERVO_CAM_PIN, us);
  camPwmLive = servoDriverOk;
}

void servoHold(int pin, int us, int holdMs) {
  servoWriteUs(pin, us);
  if (pin == SERVO_CAM_PIN) camPwmLive = servoDriverOk;
  // Keep bit-bang pulses alive for the whole hold (was stopping at SERVO_DRIVE_MS).
  if (holdMs > 0 && pin != ENTRANCE_PIN) {
    servoDriveUntil = millis() + (unsigned long)holdMs + 50UL;
    servoKickDrive();
  }
  if (holdMs > 0) delay(holdMs);
}

void servoSet(int pin, int us) { servoHold(pin, us, 800); }

void servoSweep(int pin, int pushUs, int homeUs) {
  Serial.printf("SERVO pin=%d UP %d â†’ DOWN %d\n", pin, pushUs, homeUs);
  servoHold(pin, pushUs, SERVO_UP_MS);
  servoHold(pin, homeUs, SERVO_DOWN_MS);
  holdSckLow();
}

void servoStop() {
  if (gateAngle == 0) return;
  Serial.println("GATE back to middle (P14)");
  camServoWrite(GATE_CENTER_US);
  gateAngle = 0;
  gateLatchedSide = 0;
  camGateDown = true;
  laneOpen = false;
  holdSckLow();
}

void servoPass() {
  // Clean = full LEFT; live path holds until egg leaves camera (heartbeat).
  if (!servoDriverOk) servoDriverInit();
  camServoWrite(GATE_LEFT_US);
  Serial.println("CLEAN â€” GATE P14 full LEFT");
  gateAngle = -1;
  gateLatchedSide = -1;
  camGateDown = false;
  laneOpen = false;
#if EGG_DEVKIT
  gateReturnAt = millis() + GATE_MAX_HOLD_MS;
  gateHoldUntil = gateReturnAt;
  gateDecisionPulsed = -1;
#endif
  holdSckLow();
}

void servoReject() {
  // Crack/Dirty = full RIGHT; live path holds until egg leaves camera (heartbeat).
  if (!servoDriverOk) servoDriverInit();
  camServoWrite(GATE_RIGHT_US);
  Serial.println("CRACK/DIRTY â€” GATE P14 full RIGHT");
  gateAngle = 1;
  gateLatchedSide = 1;
  camGateDown = false;
  rejectArmDown = false;
#if EGG_DEVKIT
  gateReturnAt = millis() + GATE_MAX_HOLD_MS;
  gateHoldUntil = gateReturnAt;
  gateDecisionPulsed = 1;
#endif
  holdSckLow();
}

#if EGG_DEVKIT
void serviceGate() {
  // Safety only â€” return GATE middle after hold. Do NOT clear gateDecisionPulsed:
  // farm keeps cleanEgg/awaitingWeight sticky, which would re-fire LEFT every 12s.
  if (gateReturnAt == 0) return;
  if ((long)(millis() - gateReturnAt) < 0) return;
  gateReturnAt = 0;
  if (gateAngle == 0 && gateLatchedSide == 0) return;
  camServoWrite(GATE_CENTER_US);
  gateAngle = 0;
  gateLatchedSide = 0;
  camGateDown = true;
  laneOpen = false;
  Serial.println("GATE P14 middle â€” hold timeout (decision latched)");
  holdSckLow();
}
#endif

#if ARDUINO_LOCAL
// After weight: keep GATE in middle. Camera/farm moves it clean (right) or crack (left).
void localGateAfterWeight() {
  if (!servoDriverOk) servoDriverInit();
  Serial.println("GATE P14 middle â€” camera decides clean/crack");
  servoWriteUs(SERVO_CAM_PIN, GATE_CENTER_US);
  gateAngle = 0;
  gateLatchedSide = 0;
  camGateDown = true;
  laneOpen = false;
  gateHoldUntil = 0;
  holdSckLow();
}

// Move every horn once so you can see all four working.
void testAllServos() {
  if (!servoDriverOk) servoDriverInit();
  Serial.println("ALL SERVO TEST â€” P13 entrance, P14 gate, P25 push, P26 sort");
  Serial.println("  ENTRANCE P13 UP â†’ DOWN");
  servoHold(ENTRANCE_PIN, ENTRANCE_OPEN_US, 700);
  servoHold(ENTRANCE_PIN, ENTRANCE_HOLD_US, 500);
  Serial.println("  GATE P14 left â†’ right â†’ middle");
  servoHold(SERVO_CAM_PIN, GATE_LEFT_US, 700);
  servoHold(SERVO_CAM_PIN, GATE_RIGHT_US, 700);
  servoHold(SERVO_CAM_PIN, GATE_CENTER_US, 500);
  gateAngle = 0;
  gateLatchedSide = 0;
  Serial.println("  PUSH P25 stroke â†’ home");
  servoHold(SERVO_SIZE_PIN, PUSH_STROKE_US, 700);
  servoHold(SERVO_SIZE_PIN, PUSH_HOME_US, 500);
  Serial.println("  SORT P26 small â†’ medium â†’ large â†’ jumbo â†’ medium");
  servoHold(SERVO_REJECT_PIN, SORT_SMALL_US, 500);
  servoHold(SERVO_REJECT_PIN, SORT_MEDIUM_US, 500);
  servoHold(SERVO_REJECT_PIN, SORT_LARGE_US, 500);
  servoHold(SERVO_REJECT_PIN, SORT_JUMBO_US, 500);
  servoHold(SERVO_REJECT_PIN, SORT_MEDIUM_US, 500);
  entranceOpen = false;
  entranceAt = millis();
  Serial.println("ALL SERVO TEST done");
}

// Boot: park horns only. Do NOT dance every servo (that confused "all move").
// Full motion test: type "all" on Serial.
bool bootComponentCheck(bool hxOk) {
  Serial.println();
  Serial.println("========== STATION PARK ==========");
  bool ok = true;

  if (!servoDriverOk) {
    Serial.println("[FAIL] SERVO driver (GPIO 50Hz)");
    ok = false;
  } else {
    Serial.println("[OK]   SERVO driver");
  }

  // Rest positions â€” prove each horn. 5V+G alone is NOT enough â€” signal wire required.
  servoWriteUs(SERVO_SIZE_PIN, PUSH_HOME_US);
  servoWriteUs(SERVO_REJECT_PIN, SORT_MEDIUM_US);

  Serial.println();
  Serial.println("*** ENTRANCE WIRING CHECK (most common miss) ***");
  Serial.println("  red  = LM2596 OUT+ 5V     (you said OK)");
  Serial.println("  brown= LM2596 OUT- / GND  (you said OK)");
  Serial.println("  orange/yellow SIGNAL = expansion S13 = ESP32 GPIO13");
  Serial.println("  If SIGNAL is on S14/S25/S26, ENTRANCE will never move.");
  Serial.println();

  // Raw blink â€” proves DevKit GPIO13 is alive (meter/LED on S13).
  Serial.println("[TEST] GPIO13 HIGH/LOW 1Hz x4 â€” meter/LED on S13 should toggle");
  ledcDetach(ENTRANCE_PIN);
  pinMode(ENTRANCE_PIN, OUTPUT);
  for (int i = 0; i < 4; i++) {
    digitalWrite(ENTRANCE_PIN, HIGH);
    delay(500);
    digitalWrite(ENTRANCE_PIN, LOW);
    delay(500);
  }

  Serial.println("[TEST] ENTRANCE servo FULL LEFT (500us) â€” watch ENTRANCE horn only");
  hornForceBurst(ENTRANCE_PIN, 500, 30);
  Serial.println("[TEST] ENTRANCE servo FULL RIGHT (2500us)");
  hornForceBurst(ENTRANCE_PIN, 2500, 30);
  Serial.println("[TEST] ENTRANCE park (closed)");
  entranceServoWrite(ENTRANCE_HOLD_US);

  Serial.println("[TEST] GATE P14 LEFTâ€¦");
  servoWriteUs(SERVO_CAM_PIN, GATE_LEFT_US);
  delay(800);
  Serial.println("[TEST] GATE P14 RIGHTâ€¦");
  servoWriteUs(SERVO_CAM_PIN, GATE_RIGHT_US);
  delay(800);
  Serial.println("[TEST] GATE P14 MIDDLEâ€¦");
  servoWriteUs(SERVO_CAM_PIN, GATE_CENTER_US);
  delay(500);

  gateAngle = 0;
  gateLatchedSide = 0;
  camGateDown = true;
  entranceOpen = false;
  entranceAt = millis();
  pushArmed = false;
  pushReturn = false;
  sizeDone = false;
  Serial.println("[OK]   park done");
  Serial.println("      ENTRANCE dead + GPIO13 blink OK â†’ bad servo or signal not in S13");
  Serial.println("      GPIO13 blink dead â†’ wire is NOT on DevKit GPIO13 / S13");

  int irPin = digitalRead(IR_PIN);
  bool irClear = irEggWhenLow ? (irPin == HIGH) : (irPin == LOW);
  Serial.printf("[%s] IR P19 level=%d (egg when %s) â€” %s\n",
                irClear ? "OK" : "WARN",
                irPin,
                irEggWhenLow ? "LOW" : "HIGH",
                irClear ? "beam clear" : "blocked / cover sensor");

  if (hxOk) {
    Serial.printf("[OK]   HX711 idle=%ld factor=%.2f\n", idleAdc, factor);
  } else {
    Serial.println("[..]   HX711 â€” tare after this check");
  }

  Serial.println("When eggs run:");
  Serial.println("  P13 ENTRANCE UP every 10s; IR egg -> instant DOWN");
  Serial.println("  P14 GATE: Clean=LEFT Crack/Dirty=RIGHT no-egg=MIDDLE");
  Serial.println("  HX711 weigh -> P26 SORT 1S/2M/3L/4J -> P25 PUSH");
  Serial.println("Type 'all' to test every horn once.");
  Serial.println("=================================");
  return ok;
}
#endif

void rejectSweep(bool force) {
  if (!force && liveG < EGG_G) {
#if !SERIAL_WEIGHT_ONLY
    Serial.println("REJECT skipped â€” no egg");
#endif
    return;
  }
  servoReject();
}

int sizeUsOf(const String& cls) {
  String c = cls;
  c.toLowerCase();
  c.replace(" ", "");
  if (c == "small") return SORT_SMALL_US;
  if (c == "medium") return SORT_MEDIUM_US;
  if (c == "large" || c == "extralarge" || c == "xl") return SORT_LARGE_US;
  return SORT_JUMBO_US;
}

void sizeSweep(const String& cls, bool force) {
  if (!force && rejectedEgg) return;
  if (!force && sizeDone) return;
  // After a printed result, always sort â€” do not require liveG >= EGG_G (soft cell).
  if (!force && !eggResultPrinted && liveG < EGG_G && lastStableG < EGG_G) {
    return;
  }
  String use = cls.length() ? cls : pendingSize;
  if (!use.length()) use = "medium";
  int us = sizeUsOf(use);
  // Output lanes after weigh: 1 SMALL | 2 MEDIUM | 3 LARGE | 4 JUMBO
  int lane = 4;
  const char* name = "JUMBO";
  if (use.equalsIgnoreCase("small")) {
    lane = 1;
    name = "SMALL";
  } else if (use.equalsIgnoreCase("medium")) {
    lane = 2;
    name = "MEDIUM";
  } else if (use.equalsIgnoreCase("large") || use.equalsIgnoreCase("extralarge") ||
             use.equalsIgnoreCase("xl")) {
    lane = 3;
    name = "LARGE";
  }
  pendingSize = use;
  // 1) SORT moves to the weight lane first
  servoWriteUs(SERVO_REJECT_PIN, us);
  Serial.printf("SORT P26 â†’ lane %d %s (S<%.0f M<%.0f L<%.0f Jâ‰¥%.0f)\n",
                lane, name, MEDIUM_MIN_G, LARGE_MIN_G, JUMBO_MIN_G, JUMBO_MIN_G);
  // 2) After SORT settles, PUSH sends the egg into that output
  pushReturn = false;
  pushArmed = true;
  pushDueAt = millis() + SORT_SETTLE_MS;
  sizeDone = true;
  ignoreEmptyUntil = millis() + SORT_SETTLE_MS + 200;
  holdSckLow();
}

bool gramsStable() {
  if (eggHits < 2) return false;
  if (liveG < EGG_G) return false;
  if (lastStableG < EGG_G) return false;
  if (!eggStill()) return false;  // moving egg = not a result yet
  float dd = liveG - lastStableG;
  if (dd < 0) dd = -dd;
  if (dd > 8.0f) return false;
  return (millis() - stableAt) >= 150;
}

int farmAsk() {
#if ARDUINO_LOCAL
  return -2;
#else
  if (WiFi.status() != WL_CONNECTED || strlen(FARM_BACKEND_URL) == 0) return -2;
  if (!takeHttpOut(40)) return -2;
  HTTPClient http;
  http.setReuse(false);
  http.setConnectTimeout(250);
  http.setTimeout(350);
  http.begin(urlInspect);
  farmHeaders(http);
  int c = http.POST("{}");
  int d = -2;
  if (c == 200) {
    String b = http.getString();
#if !SERIAL_WEIGHT_ONLY
    Serial.printf("Inspect POST 200 %s\n", b.c_str());
#endif
    d = readInspectBody(b);
  } else {
#if !SERIAL_WEIGHT_ONLY
    Serial.printf("Inspect POST %d\n", c);
#endif
    if (c >= 400) d = -3;
    else if (c > 0 && c < 400) d = -1;
  }
  http.end();
  giveHttpOut();
  return d;
#endif
}

int farmDecide() {
#if ARDUINO_LOCAL
  return -1;
#else
  if (WiFi.status() != WL_CONNECTED || strlen(FARM_BACKEND_URL) == 0) return -1;
  if (!takeHttpOut(40)) return -1;
  HTTPClient http;
  http.setReuse(false);
  http.setConnectTimeout(250);
  http.setTimeout(350);
  http.begin(urlInspect);
  farmHeaders(http);
  int c = http.GET();
  int d = -1;
  if (c == 200) {
    String b = http.getString();
    d = readInspectBody(b);
#if !SERIAL_WEIGHT_ONLY
    if (d >= 0) Serial.printf("Inspect GET reject=%d\n", d);
#endif
  }
  http.end();
  giveHttpOut();
  return d;
#endif
}

void finishInspect(int d) {
  inspectedEgg = true;
  rejectedEgg = (d == 1);
  float g = lastStableG >= EGG_G ? lastStableG : liveG;
  if (!pendingSize.length()) pendingSize = sizeClassOf(g);
  if (d == 2) {
#if !SERIAL_WEIGHT_ONLY
    Serial.println("DIRTY â€” gate stays");
#endif
    inspect = I_DONE;
    return;
  }
  if (rejectedEgg) {
    stopBelt();
    rejectSweep(true);
  } else {
    servoPass();
  }
  inspect = I_DONE;
}

void beginInspect() {
  if (inspect != I_IDLE || inspectedEgg) return;
  if (!eggLatched && !irEgg) return;
  inspect = I_ASK;
  inspectPosted = false;
  inspectAt = millis();
  lastFrame = 0;
  lastDecide = 0;
  stopBelt();
  camGateDown = false;
  servoStop();
  float g = lastStableG >= EGG_G ? lastStableG : liveG;
  pendingSize = sizeClassOf(g);
#if !SERIAL_WEIGHT_ONLY
  Serial.println("EGG STOPPED center â€” camera check");
#endif
  if (g >= EGG_G) postWeight(g);
}

void runInspect() {
  if (inspect == I_IDLE) return;
  if (motorRun) stopBelt();
  if (inspect == I_ASK) {
    if (!inspectPosted) {
      // loop() no longer sleeps inside the scale read, so space the retries.
      if (millis() - lastAskAt < 300) return;
      lastAskAt = millis(); 
      int asked = farmAsk();
      if (asked >= 0) {
        inspectPosted = true;
        finishInspect(asked);
        return;
      }
      if (asked == -3) {
        static int postFails = 0;
        postFails++;
        if (postFails >= 6) {
          postFails = 0;
#if !SERIAL_WEIGHT_ONLY
          Serial.println("Inspect stopped â€” laptop error");
#endif
          inspect = I_IDLE;
          inspectPosted = false;
          eggLatched = false;
          liveG = 0;
          scaleG = 0;
          smoothG = 0;
          lastStableG = 0;
          eggHits = 0;
          return;
        }
      }
      inspectPosted = (asked != -2);
      if (!inspectPosted) return;
    }
    if (lastFrame == 0 || millis() - lastFrame >= 280) {
      lastFrame = millis();
      int pic = postFrame();
      if (pic >= 0) {
        finishInspect(pic);
        return;
      }
    }
    inspect = I_WAIT;
    return;
  }
  if (inspect == I_WAIT) {
    if (millis() - lastFrame >= 280) {
      lastFrame = millis();
      int pic = postFrame();
      if (pic >= 0) {
        finishInspect(pic);
        return;
      }
    }
    if (millis() - lastDecide < 150) return;
    lastDecide = millis();
    int d = farmDecide();
    if (d < 0) {
      if (millis() - inspectAt > 6500) {
        // Scale/IR may have the egg while the camera never saw it â€” keep gate, do not wipe weight.
#if !SERIAL_WEIGHT_ONLY
        Serial.println("Inspect timeout â€” no camera egg, gate stays");
#endif
        if (irEgg || liveG >= EGG_G) {
          inspectedEgg = true;
          inspect = I_DONE;
#if !SERIAL_WEIGHT_ONLY
          Serial.println("Egg still on station (IR/scale) â€” lift for next, or fix camera view");
#endif
        } else {
          inspectedEgg = false;
          inspect = I_IDLE;
          eggLatched = false;
        }
        return;
      }
      return;
    }
    finishInspect(d);
    return;
  }
  if (inspect == I_DONE) {
#if !SERIAL_WEIGHT_ONLY
    Serial.println("Inspect done â€” lift egg for next");
#endif
    inspect = I_IDLE;
  }
}

// Classic ESP32 GPIO32â€“39. SCK high longer than 60 us powers the HX711 down.
// DOUT then sits high and the word is mostly ones (-1, 4194303, 8388607,
// -4194305). A delay function can stall on flash while SCK is already high.
// This pulse only reads the CPU cycle counter, and the other core is stalled
// so Wi-Fi cannot stretch that wait.
extern "C" void spi_flash_disable_interrupts_caches_and_other_cpu(void);
extern "C" void spi_flash_enable_interrupts_caches_and_other_cpu(void);

static const uint32_t HX_OUT1_W1TS = 0x3FF44014;
static const uint32_t HX_OUT1_W1TC = 0x3FF44018;
static const uint32_t HX_EN1_W1TS = 0x3FF44030;
static const uint32_t HX_EN1_W1TC = 0x3FF44034;
static const uint32_t HX_IN1 = 0x3FF44040;

static void IRAM_ATTR __attribute__((noinline)) hxSpin(uint32_t cycles) {
  uint32_t start, now;
  __asm__ __volatile__("rsr %0, ccount" : "=a"(start));
  do {
    __asm__ __volatile__("rsr %0, ccount" : "=a"(now));
  } while ((now - start) < cycles);
}

static void IRAM_ATTR __attribute__((noinline)) hxWake() {
  const uint32_t sckBit = 1UL << (HX711_SCK - 32);
  *((volatile uint32_t*)HX_EN1_W1TS) = sckBit;
  *((volatile uint32_t*)HX_OUT1_W1TS) = sckBit;
  hxSpin(20000);
  *((volatile uint32_t*)HX_OUT1_W1TC) = sckBit;
}

// 24 data bits, then the gain clocks. DOUT stays valid through the low time,
// so the bit is sampled after SCK falls. Cache and the other core are stopped
// for the burst so the high time cannot run past 60 us.
bool hxRadioOn = false;

static long IRAM_ATTR __attribute__((noinline)) hxShift24() {
  const uint32_t sckBit = 1UL << (HX711_SCK - 32);
  const uint32_t dtBit = 1UL << (HX711_DT - 32);
  volatile uint32_t* setSck = (volatile uint32_t*)HX_OUT1_W1TS;
  volatile uint32_t* clrSck = (volatile uint32_t*)HX_OUT1_W1TC;
  volatile uint32_t* in1 = (volatile uint32_t*)HX_IN1;
  int pulses = 25;
  if (hxGain == 32) pulses = 26;
  else if (hxGain == 64) pulses = 27;
  uint32_t value = 0;
  bool radio = hxRadioOn;
  if (radio) spi_flash_disable_interrupts_caches_and_other_cpu();
  else noInterrupts();
  *((volatile uint32_t*)HX_EN1_W1TS) = sckBit;
  *clrSck = sckBit;
  for (int i = 0; i < pulses; i++) {
    uint32_t start, now;
    *setSck = sckBit;
    __asm__ __volatile__("rsr %0, ccount" : "=a"(start));
    do {
      __asm__ __volatile__("rsr %0, ccount" : "=a"(now));
    } while ((now - start) < 1000);
    if (i < 24) {
      value <<= 1;
      if (*in1 & dtBit) value |= 1UL;
    }
    *clrSck = sckBit;
    __asm__ __volatile__("rsr %0, ccount" : "=a"(start));
    do {
      __asm__ __volatile__("rsr %0, ccount" : "=a"(now));
    } while ((now - start) < 1000);
  }
  if (radio) spi_flash_enable_interrupts_caches_and_other_cpu();
  else interrupts();
  if (value & 0x800000UL) value |= 0xFF000000UL;
  return (long)(int32_t)value;
}

bool hxStuck(long v);

bool hxReadOnce(long* out) {
  if (!scale.wait_ready_timeout(600, 1)) return false;
  // IRAM shifter â€” this is what produced live counts when the cell was pressed.
  *out = hxShift24();
  return true;
}

bool hxBatchLive(long* s, int n) {
  long good[8];
  int g = 0;
  for (int i = 0; i < n && g < 8; i++) {
    if (hxStuck(s[i])) continue;
    good[g++] = s[i];
  }
  if (g < 4) return false;
  long lo = good[0], hi = good[0];
  for (int i = 1; i < g; i++) {
    if (good[i] < lo) lo = good[i];
    if (good[i] > hi) hi = good[i];
  }
  return (hi - lo) < 150000L;
}

// Non-blocking HX711. Takes at most one sample per call, only when the chip is ready,
// then returns at once so heartbeat, camera and servos keep running.
// Same filter as readAdc(): median of a batch, outliers beyond 8000 counts dropped.
// Returns 0 = no new reading yet, 1 = new reading in *out, -1 = batch failed.
const int ADC_BATCH = 3;  // faster still detect (HX711 ~10 Hz)
long adcBuf[ADC_BATCH];
int adcN = 0;
unsigned long adcBatchAt = 0;
bool hxSaw = false;
bool hxLocked = false;
// 0, -1, the rails, and a run of low bits all ones (4194303 and friends)
// are a floating DT pin. A live cell jitters and does not land on those codes.
bool hxStuck(long v) {
  if (v == 0 || v == -1) return true;
  if (v <= -8388607L || v >= 8388607L) return true;
  unsigned long u = (unsigned long)v & 0xFFFFFFUL;
  // A solid run of low ones is DOUT rising and staying high:
  // 262143, 2097151, 4194303, 8388607, -4194305.
  if (u >= 0x0FFFFUL && (u & (u + 1UL)) == 0) return true;
  return (u & 0x0FFFFFUL) == 0x0FFFFFUL;
}
// Empty ~2000â€“2300; with egg the raw can drop toward ~600â€“1200 (channel polarity).
// Only reject rails / stuck codes â€” not a loaded cell.
const long HX_RAW_LO = 200L;
const long HX_RAW_HI = 8000L;
bool hxRawOk(long adc) {
  return adc >= HX_RAW_LO && adc <= HX_RAW_HI;
}
int pollAdc(long* out) {
  unsigned long now = millis();
  // Keep SCK low. Holding it high for more than 60 us powers the HX711 down,
  // and the first reading after that is often the full-scale code 8388607.
  if (adcN > 0 && now - adcBatchAt > 1500) {
    // The loop was slow (for example Wi-Fi retries). Use the newest good sample, do not fail.
    *out = adcBuf[adcN - 1];
    adcN = 0;
    return 1;
  }
  if (scale.is_ready()) {
    long v = 0;
    if (!hxReadOnce(&v)) return 0;
    hxSaw = true;
    // Never batch 10kâ€“45k garbage (your log). Keep last good for display.
    if (hxStuck(v) || !hxRawOk(v)) {
      adcN = 0;  // discard partial batch; noteMotion gap clears "still"
      // Rare rail/stuck codes only â€” do not spam when egg pulls raw down.
      static unsigned long lastNoiseAt = 0;
      static unsigned long lastWakeAt = 0;
      if (hxStuck(v)) {
        // Power-cycle SCK wake â€” need ~400 ms settle (delay(2) never recovered).
        if (now - lastWakeAt > 5000UL) {
          lastWakeAt = now;
          hxWake();
          latchSckLow();
#if EGG_DEVKIT
          hxRecoverUntil = now + 400UL;
#endif
        }
        if (now - lastNoiseAt > 30000) {
          lastNoiseAt = now;
          Serial.printf("HX711 stuck raw=%ld â€” check DT=P32 SCK=P33 3V3/GND, then t\n", v);
        }
      }
      return 0;
    }
#if EGG_DEVKIT
    if (hxRecoverUntil != 0) {
      if (now < hxRecoverUntil) return 0;  // discard samples during settle
      hxRecoverUntil = 0;
      Serial.println("HX711 wake settle OK â€” resume scale");
    }
#endif
    hxLastRaw = v;
    if (adcN == 0) adcBatchAt = now;
    adcBuf[adcN++] = v;
  }
  if (adcN < ADC_BATCH && !(adcN >= 2 && now - adcBatchAt > 500)) return 0;

  int n = adcN;
  adcN = 0;
  long s[ADC_BATCH];
  for (int i = 0; i < n; i++) s[i] = adcBuf[i];
  for (int i = 0; i < n; i++) {
    for (int j = i + 1; j < n; j++) {
      if (s[j] < s[i]) {
        long t = s[i];
        s[i] = s[j];
        s[j] = t;
      }
    }
  }
  long med = s[n / 2];
  // In-band samples only (~2kâ€“4k). Drop batch if it still scatters (wiring).
  long tight[ADC_BATCH];
  int k = 0;
  for (int i = 0; i < n; i++) {
    if (!hxRawOk(s[i]) || hxStuck(s[i])) continue;
    long d = s[i] - med;
    if (d < 0) d = -d;
    if (d <= 400L) tight[k++] = s[i];
  }
  if (k < 2) return 0;
  *out = tight[k / 2];
  hxLastRaw = *out;
  return 1;
}

bool adcInRange(long v) {
  return v > -8388607L && v < 8388607L;
}

// Full-scale 8388607 means this channel's inputs are open. Try the other
// gain, the B channel, and DT/SCK swapped before giving up.
void releaseHxPin(int pin) {
  gpio_num_t p = (gpio_num_t)pin;
  if (rtc_gpio_is_valid_gpio(p)) {
    rtc_gpio_hold_dis(p);
    rtc_gpio_deinit(p);
  }
  gpio_hold_dis(p);
  gpio_reset_pin(p);
}

void hxArm(int dt, int sck) {
  hxDtPin = dt;
  hxSckPin = sck;
  releaseHxPin(dt);
  releaseHxPin(sck);
  scale.begin((uint8_t)dt, (uint8_t)sck, true, false);
  // No pull-up on DT â€” the HX711 drives this pin. A pull-up can freeze the word.
  pinMode(dt, INPUT);
  pinMode(sck, OUTPUT);
  digitalWrite(sck, LOW);
  scale.set_gain(hxGain, true);
}

bool tryLoadCell(int dt, int sck, uint8_t gain) {
  hxGain = gain;
  hxArm(dt, sck);
  long got[6];
  int n = 0;
  for (int i = 0; i < 10 && n < 6; i++) {
    long v = 0;
    if (!hxReadOnce(&v)) continue;
    hxSaw = true;
    hxLastRaw = v;
#if !SERIAL_WEIGHT_ONLY
    Serial.printf("HX711 DT=%d SCK=%d gain %u raw %ld\n", dt, sck, gain, v);
#endif
    got[n++] = v;
    delay(1);
  }
  return hxBatchLive(got, n);
}

static uint32_t IRAM_ATTR __attribute__((noinline)) hxProbePins() {
  const uint32_t sckBit = 1UL << (HX711_SCK - 32);
  const uint32_t dtBit = 1UL << (HX711_DT - 32);
  *((volatile uint32_t*)HX_EN1_W1TS) = sckBit;
  *((volatile uint32_t*)HX_OUT1_W1TC) = sckBit;
  hxSpin(2000);
  uint32_t low = *((volatile uint32_t*)HX_IN1);
  *((volatile uint32_t*)HX_OUT1_W1TS) = sckBit;
  hxSpin(800);
  uint32_t high = *((volatile uint32_t*)HX_IN1);
  *((volatile uint32_t*)HX_OUT1_W1TC) = sckBit;
  uint32_t pack = 0;
  if (low & sckBit) pack |= 1;
  if (low & dtBit) pack |= 2;
  if (high & sckBit) pack |= 4;
  if (high & dtBit) pack |= 8;
  return pack;
}

void hxPinCheck() {
  pinMode(HX711_SCK, OUTPUT);
  digitalWrite(HX711_SCK, LOW);
  pinMode(HX711_DT, INPUT_PULLUP);
  delay(2);
  int idle = digitalRead(HX711_DT);
  int sckLevel = digitalRead(HX711_SCK);
  uint32_t pack = hxProbePins();
#if !SERIAL_WEIGHT_ONLY
  Serial.printf("PINCHECK idle DT=%d SCK=%d  3us SCK low=%lu high=%lu  DT while SCK low=%lu high=%lu\n",
                idle, sckLevel, pack & 1, (pack >> 2) & 1, (pack >> 1) & 1, (pack >> 3) & 1);
#else
  (void)idle;
  (void)sckLevel;
  (void)pack;
#endif
}

bool openLoadCell() {
  hxLocked = false;
  hxPinCheck();
#if !SERIAL_WEIGHT_ONLY
  Serial.printf("HX711 clock code %p\n", (const void*)hxShift24);
#endif
  const uint8_t gains[3] = {128, 64, 32};
  for (int i = 0; i < 3; i++) {
    if (!tryLoadCell(HX711_DT, HX711_SCK, gains[i])) continue;
#if !SERIAL_WEIGHT_ONLY
    Serial.printf("HX711 locked DT=%d SCK=%d gain %u\n", HX711_DT, HX711_SCK, gains[i]);
#endif
    hxLocked = true;
    return true;
  }
  hxGain = 128;
  hxArm(HX711_DT, HX711_SCK);
  return false;
}

bool readAdc(long* out) {
  long samples[7];
  int n = 0;
  for (int i = 0; i < 12 && n < 5; i++) {
    long v = 0;
    if (!hxReadOnce(&v)) continue;
    hxSaw = true;
    if (hxStuck(v) || !hxRawOk(v)) continue;
    hxLastRaw = v;
    samples[n++] = v;
  }
  if (n < 3) return false;
  for (int i = 0; i < n; i++) {
    for (int j = i + 1; j < n; j++) {
      if (samples[j] < samples[i]) {
        long t = samples[i];
        samples[i] = samples[j];
        samples[j] = t;
      }
    }
  }
  long med = samples[n / 2];
  long tight[7];
  int k = 0;
  for (int i = 0; i < n; i++) {
    long d = samples[i] - med;
    if (d < 0) d = -d;
    if (d <= 400L) tight[k++] = samples[i];
  }
  if (k < 2) return false;
  *out = tight[k / 2];
  hxLastRaw = *out;
  return true;
}

// Good cell ~2280â€“3200. Empty wood drifts ~10â€“20 counts â€” that used to print fake eggs.
const float EMPTY_NOISE_G = 5.0f;
// Soft cell: empty chatter is only a few counts. Do NOT set this near egg bend (~15â€“25).
const long EMPTY_NOISE_COUNTS = 8;  // empty-band noise; egg start needs EGG_ADC_MIN / PLACE_RISE
const float FORCE_G = 2.0f;
const long FORCE_COUNTS = 12;

// Soft cell floor â€” keep this LOW or weighing never starts. IR never changes this.
long forceCountsNow() {
  return EGG_ADC_MIN;
}
// Allow large bend when A+/Aâˆ’ polarity makes raw fall hard under an egg.
const long HX_MAX_DELTA = 2800L;
// Placement can jump >700 counts; only treat rail/stuck spikes as glitches.
const long HX_GLITCH_JUMP = 2200L;
unsigned long hxGlitchUntil = 0;
int hxGoodStreak = 0;
long motionBuf[8];
int motionN = 0;
// Empty spanâ‰ˆ40. Wood mount wobbles more â€” was 140 and never stayed "still" 3s.
const long MOTION_SPAN_MAX = 220;
int emptyHits = 0;
unsigned long stillSince = 0;
unsigned long lastGoodMotionAt = 0;
unsigned long weakBendMsgAt = 0;
float smoothD = 0;
long holdPeakD = 0;                 // best bend in the last PEAK_HOLD_MS
unsigned long holdPeakAt = 0;

// Call when live bend is back near empty after a weighed egg.
void clearEggToEmpty(long dNow) {
  eggPeakD = 0;
  smoothD = 0;
  holdPeakD = 0;
  holdPeakAt = 0;
  smoothG = 0;
  scaleG = 0;
  liveG = 0;
  lastGoodG = 0;
  lastGoodAt = 0;
  lastStableG = 0;
  eggHits = 0;
  weightSince = 0;
  weightShown = false;
  eggSession = false;
  eggSessionAt = 0;
  eggGoneHits = 0;
  eggSeenHits = 0;
  sessionBestRestG = 0;
  lowStreak = 0;
  emptyHits = 0;
  emptySince = 0;
  wasEmpty = true;
  postedEgg = false;
  inspectedEgg = false;
  rejectedEgg = false;
  camRejectDone = false;
  sizeDone = false;
  pendingSize = "";
  eggLatched = false;
  lastAutoZeroAt = millis();  // block tare chase so egg #2 is not absorbed
  inspect = I_IDLE;
  inspectPosted = false;
  // printEggRemoved sets the only cooldown for the next egg
  if (announceEggRemoved) printEggRemoved(dNow);
  else {
    eggResultPrinted = false;
    needIdlePrint = false;
    weighCooldownUntil = millis() + WEIGH_COOLDOWN_MS;
  }
}

void noteMotion(long adc) {
  lastGoodMotionAt = millis();
  if (motionN < 8) motionBuf[motionN++] = adc;
  else {
    for (int i = 1; i < 8; i++) motionBuf[i - 1] = motionBuf[i];
    motionBuf[7] = adc;
  }
}

long motionSpan() {
  if (motionN < 2) return 9999;
  long lo = motionBuf[0], hi = motionBuf[0];
  for (int i = 1; i < motionN; i++) {
    if (motionBuf[i] < lo) lo = motionBuf[i];
    if (motionBuf[i] > hi) hi = motionBuf[i];
  }
  long span = hi - lo;
  return span < 0 ? -span : span;
}

bool eggStill() {
  // Empty log spanâ‰ˆ40 counts â€” that is still. Need 3 good samples in the buffer.
  if (motionN < 3) return false;
  if (lastGoodMotionAt == 0 || millis() - lastGoodMotionAt > 2500) return false;
  long span = motionSpan();
  if (span > MOTION_SPAN_MAX) {
    stillSince = 0;
    return false;
  }
  if (stillSince == 0) stillSince = millis();
  return (millis() - stillSince) >= 80;
}

// Boot tare often locked while raw was still climbing (quiet~2400 â†’ idle~3100).
// Then empty bar looks like d=500 â†’ fake 200g. Track settled raw and snap zero.
long settleBuf[12];
int settleN = 0;
void applyEmptyZero(long adc, const char* why) {
  emptyAdc = adc;
  idleAdc = adc;
  clearEmptyAdc = adc;
  haveClearEmpty = true;
  haveIdle = true;
  peakDelta = 0;
  eggPeakD = 0;
  smoothD = 0;
  holdPeakD = 0;
  holdPeakAt = 0;
  emptyHits = 0;
  liveG = 0;
  smoothG = 0;
  scaleG = 0;
  lastGoodG = 0;
  lastStableG = 0;
  lastGoodAt = 0;
  lowStreak = 0;
  eggHits = 0;
  weightShown = false;
  weightSince = 0;
  eggResultPrinted = false;
  announceEggRemoved = false;
  needIdlePrint = true;
  wasEmpty = true;
#if !SERIAL_WEIGHT_ONLY
  Serial.printf("SCALE %s â†’ idle=%ld (empty bar = 0.0g)\n", why, emptyAdc);
#else
  (void)why;
#endif
}

bool readSettledEmpty(long* out) {
  // Wait out HX711 warm drift after WiFi, then take a tight median.
  delay(500);
  long buf[10];
  int n = 0;
  for (int pass = 0; pass < 4 && n < 8; pass++) {
    n = 0;
    for (int i = 0; i < 14 && n < 10; i++) {
      long v = 0;
      if (!readAdc(&v) || !hxRawOk(v) || hxStuck(v)) {
        delay(40);
        continue;
      }
      buf[n++] = v;
      delay(35);
    }
    if (n < 6) continue;
    for (int i = 0; i < n; i++) {
      for (int j = i + 1; j < n; j++) {
        if (buf[j] < buf[i]) {
          long t = buf[i];
          buf[i] = buf[j];
          buf[j] = t;
        }
      }
    }
    long span = buf[n - 1] - buf[0];
    if (span < 0) span = -span;
    if (span <= 180) {
      *out = buf[n / 2];
      return true;
    }
    delay(200);
  }
  if (n >= 5) {
    *out = buf[n / 2];
    return true;
  }
  return false;
}

void healEmptyZero(long adc) {
  // Corrupt tare (emptyAdc stuck at a glitch) made dâ‰ˆ45000 while rawâ‰ˆ2300.
  if (!hxRawOk(emptyAdc) && hxRawOk(adc)) {
    applyEmptyZero(adc, "zero healed");
    return;
  }
  if (haveClearEmpty && hxRawOk(clearEmptyAdc) && hxRawOk(emptyAdc)) {
    long drift = emptyAdc - clearEmptyAdc;
    if (drift < 0) drift = -drift;
    // Was 2000 â€” too high; your bad tare was only ~500â€“700 counts.
    if (drift > 220) {
      applyEmptyZero(clearEmptyAdc, "zero repaired");
    }
  }
}

// Only fix extreme bad tare (dâ‰¥800). Never chase while weighing / egg on cell.
void maybeAutoZero(long adc) {
  if (!haveIdle || !hxRawOk(adc) || hxStuck(adc)) return;
  if (eggSession || weightShown || announceEggRemoved || eggResultPrinted) return;
  if (eggSeenHits > 0) return;  // IR must not block scale auto-zero
  if (millis() - lastAutoZeroAt < 5000) return;

  long zero0 = emptyAdc != 0 ? emptyAdc : idleAdc;
  long preD = adc - zero0;
  if (preD < 0) preD = -preD;
  if (preD < 800) return;  // normal soft-cell noise / residual â€” leave alone

  if (settleN < 12) settleBuf[settleN++] = adc;
  else {
    for (int i = 1; i < 12; i++) settleBuf[i - 1] = settleBuf[i];
    settleBuf[11] = adc;
  }
  if (settleN < 10) return;

  long lo = settleBuf[0], hi = settleBuf[0], sum = 0;
  for (int i = 0; i < settleN; i++) {
    long v = settleBuf[i];
    if (v < lo) lo = v;
    if (v > hi) hi = v;
    sum += v;
  }
  if ((hi - lo) > 150) return;

  long med = sum / settleN;
  applyEmptyZero(med, "bad tare rezero");
  lastAutoZeroAt = millis();
  settleN = 0;
  Serial.printf("Scale re-zero (was d~%ld)\n", preD);
}

float gramsFromDelta(long d) {
  // Load cell only â€” IR (entrance) never changes weigh thresholds.
  if (!haveIdle || factor < FACTOR_MIN) return -1;
  long need = forceCountsNow();
  if (d < need || d > HX_MAX_DELTA) return 0;
  float useF = factor;
  if (useF < FACTOR_MIN || useF > FACTOR_MAX) useF = FACTOR_DEFAULT;
  float g = (float)d / useF;
  if (g < FORCE_G) return 0;
  if (g > LIVE_MAX_G) g = LIVE_MAX_G;
  return g;
}

float gramsFrom(long adc) {
  if (!hxRawOk(adc)) return 0;
  long zero = emptyAdc != 0 ? emptyAdc : idleAdc;
  if (!hxRawOk(zero)) return 0;
  long d = adc - zero;
  if (d < 0) d = -d;
  return gramsFromDelta(d);
}

void loadFactor() {
  factor = FACTOR_DEFAULT;
  gPerCount = GPC_DEFAULT;
  if (!prefs.begin("eggscale", true)) return;
  float s = prefs.getFloat("cal_v2", 0);  // SmartSort Bogde factor
  if (s < FACTOR_MIN) s = prefs.getFloat("factor", 0);  // migrate old key once
  uint8_t g = prefs.getUChar("gain", 128);
#if EGG_DEVKIT
  long cr = (long)prefs.getInt("cal_rest", 0);
  if (cr >= 12 && cr <= 40) calRestD = cr;
#endif
  prefs.end();
  // Old station used factorâ‰ˆ4.64 with DISPLAY_SCALE 12.5 â€” convert to Bogde.
  if (s > 2.0f && s < 40.0f) {
    s = s / 12.5f;
    Serial.printf("Migrated old scale factor â†’ Bogde %.4f\n", s);
  }
  if (s >= FACTOR_MIN && s <= FACTOR_MAX) factor = s;
  bool badCal = false;
  // factor 0.10 from false c50 (d=5) made every egg read 100g â€” reset.
  if (factor > 0.0f && factor < 0.15f) {
    Serial.printf("Bad saved factor %.4f (weak c50) â€” reset 0.35; redo c50\n", factor);
    factor = 0.35f;
    badCal = true;
  }
  // factor 1.38 from spike-biased c50 â€” reset.
  if (factor > 1.0f) {
    Serial.printf("Bad saved factor %.4f (spike c50) â€” reset 0.35; redo c50\n", factor);
    factor = 0.35f;
    badCal = true;
  }
  // Only wipe clearly broken cal (c55/empty flicker). Soft c50 d=15 â†’ factor 0.30 is OK.
  if (factor > 0.0f && factor < 0.25f) {
    Serial.printf("Bad saved factor %.4f (noisy cal) â€” reset 0.35; redo c50\n", factor);
    factor = 0.35f;
    badCal = true;
  }
  gPerCount = (factor > 0.0001f) ? (1.0f / factor) : GPC_DEFAULT;
  if (g == 64 || g == 128) hxGain = g;
  if (badCal) {
#if EGG_DEVKIT
    calRestD = 0;
#endif
    saveFactor();
  }
}

void saveFactor() {
  if (!prefs.begin("eggscale", false)) return;
  prefs.putFloat("cal_v2", factor);
  prefs.putFloat("factor", factor);
  prefs.putFloat("gpc", (factor > 0.0001f) ? (1.0f / factor) : GPC_DEFAULT);
  prefs.putUChar("gain", hxGain);
#if EGG_DEVKIT
  prefs.putInt("cal_rest", (int)calRestD);
#endif
  prefs.end();
}

void runSerialLine(String line) {
  line.trim();
  if (!line.length()) return;
  if (line.length() >= 5 && line.substring(0, 5).equalsIgnoreCase("wifi ")) {
#if ARDUINO_LOCAL
    Serial.println("Arduino-only station â€” WiFi/Firebase disabled");
    return;
#else
    String rest = line.substring(5);
    rest.trim();
    int comma = rest.indexOf(',');
    if (comma <= 0 || comma >= (int)rest.length() - 1) {
      Serial.println("Use: wifi Name,password");
      return;
    }
    String ssid = rest.substring(0, comma);
    String pass = rest.substring(comma + 1);
    ssid.trim();
    pass.trim();
    if (!ssid.length() || ssid.length() > 32 || pass.length() > 64) {
      Serial.println("WiFi name must be 1 to 32 characters");
      return;
    }
    if (!prefs.begin("eggwifi", false)) {
      Serial.println("Could not save WiFi");
      return;
    }
    prefs.putString("ssid", ssid);
    prefs.putString("pass", pass);
    prefs.end();
    ssid.toCharArray(prefSsid, sizeof(prefSsid));
    pass.toCharArray(prefPass, sizeof(prefPass));
    havePrefWifi = true;
    wifiTry = 0;
    Serial.printf("Saved WiFi %s â€” connecting\n", prefSsid);
    connectSavedWifi();
    wifiSwitching = stationOn;
    hbFails = 0;
    laptopSweepDone = false;
    findOctet = 0;
    return;
#endif
  }
  line.toLowerCase();
  Serial.printf("> %s\n", line.c_str());
  if (line == "servo" || line == "cam" || line == "gate") {
    Serial.println("TEST GATE P14 â€” middle â†’ clean(right) â†’ crack(left) â†’ middle");
    servoDriverInit();
    servoWriteUs(SERVO_CAM_PIN, GATE_CENTER_US);
    gateAngle = 0;
    delay(900);
    servoPass();
    delay(1200);
    servoReject();
    delay(1200);
    servoStop();
    delay(900);
    Serial.println("TEST GATE done â€” did P14 move?");
    return;
  }
  if (line == "push") {
    Serial.println("TEST PUSH P25 â€” stroke, then home clear of the scale");
    servoDriverInit();
    servoHold(SERVO_SIZE_PIN, PUSH_STROKE_US, SERVO_UP_MS);
    servoHold(SERVO_SIZE_PIN, PUSH_HOME_US, SERVO_DOWN_MS);
    return;
  }
  if (line == "size") {
    Serial.println("TEST PUSH P25 then SORT P26 large");
    rejectedEgg = false;
    sizeDone = false;
    servoDriverInit();
    sizeSweep("large", true);
    return;
  }
  if (line == "sort") {
    Serial.println("TEST SORTING P26 â€” small, medium, large, jumbo, then medium");
    servoDriverInit();
    servoHold(SERVO_REJECT_PIN, SORT_SMALL_US, 700);
    servoHold(SERVO_REJECT_PIN, SORT_MEDIUM_US, 700);
    servoHold(SERVO_REJECT_PIN, SORT_LARGE_US, 700);
    servoHold(SERVO_REJECT_PIN, SORT_JUMBO_US, 700);
    servoHold(SERVO_REJECT_PIN, SORT_MEDIUM_US, 700);
    return;
  }
  if (line == "swap") {
    Serial.println("P13 entrance | P14 gate | P25 push | P26 sorting");
    return;
  }
  if (line == "static" || line == "empty" || line == "idle") {
    printCurrentStaticWeight();
    return;
  }
  if (line == "horn" || line == "all") {
#if ARDUINO_LOCAL
    testAllServos();
#else
    Serial.println("HORN TEST entrance, gate, push, sort");
    servoDriverInit();
    rejectedEgg = false;
    sizeDone = false;
    camGateDown = false;
    servoHold(ENTRANCE_PIN, ENTRANCE_OPEN_US, 700);
    servoHold(ENTRANCE_PIN, ENTRANCE_HOLD_US, 700);
    entranceOpen = false;
    entranceAt = millis();
    servoStop();
    delay(700);
    servoPass();
    delay(700);
    servoReject();
    delay(700);
    sizeDone = false;
    sizeSweep("large", true);
    Serial.println("HORN TEST done");
#endif
    return;
  }
  if (line == "m" || line == "motor") {
    beltOn = true;
    startBelt();
    Serial.println("BELT ON â€” type s to stop, rev if it runs backward");
    return;
  }
  if (line == "rev") {
    motorForward = !motorForward;
    if (motorRun) startBelt();
    Serial.println(motorForward ? "BELT direction forward (IN1 high)" : "BELT direction reversed (IN2 high)");
    return;
  }
  if (line == "ir") {
    irEggWhenLow = !irEggWhenLow;
    irEgg = false;
    irCount = 0;
    eggLatched = false;
    Serial.printf("IR pin P19 level=%d  egg when %s\n", digitalRead(IR_PIN), irEggWhenLow ? "LOW" : "HIGH");
    return;
  }
  if (line == "entrance" || line == "ent" || line == "p13") {
#if EGG_DEVKIT
    if (!servoDriverOk) servoDriverInit();
    Serial.printf("ENTRANCE TEST GPIO%d â€” IR P19=%d eggWhen%s\n",
                  ENTRANCE_PIN, digitalRead(IR_PIN), irEggWhenLow ? "LOW" : "HIGH");
    Serial.printf("  FULL sweep 500 â†’ 2500 â†’ %d (closed)\n", ENTRANCE_HOLD_US);
    hornForceBurst(ENTRANCE_PIN, 500, 50);
    delay(200);
    hornForceBurst(ENTRANCE_PIN, 2500, 50);
    delay(200);
    entranceServoWrite(ENTRANCE_HOLD_US);
    entranceOpen = false;
    entranceAt = millis();
    irEgg = false;
    irCount = 0;
    Serial.println("ENTRANCE TEST done â€” horn must swing. No move = signal not on ESP32 GPIO13");
#else
    Serial.println("entrance test is DevKit only â€” this build is CAM (EGG_DEVKIT 0)");
#endif
    return;
  }
  if (line == "s" || line == "stop") {
    beltOn = false;
    stopBelt();
    Serial.println("BELT OFF");
    return;
  }
  if (line == "start") {
#if ARDUINO_LOCAL
    if (stationOn) {
      Serial.println("Station already running");
      return;
    }
    Serial.println("Starting station...");
    goOnline();
    return;
#else
    Serial.println("start is only for the DevKit Arduino-only station");
    return;
#endif
  }
  if (line == "egg" || line == "go") {
#if EGG_DEVKIT
    if (!stationOn) {
      Serial.println("Station was idle â€” starting (empty tare)â€¦");
      goOnline();
      Serial.println("Next: put egg on wood, then type egg to weigh");
      return;
    }
    // If empty zero drifted (idle d huge), re-tare BEFORE arming â€” otherwise
    // every sample looks like 100g+ and never sits in the egg band.
    {
      long probe = 0;
      long z = emptyAdc != 0 ? emptyAdc : idleAdc;
      if (readAdc(&probe) && hxRawOk(probe) && hxRawOk(z)) {
        long d0 = probe - z;
        if (d0 < 0) d0 = -d0;
        if (d0 >= BAD_TARE_D) {
          Serial.printf("Zero drifted (d=%ld) â€” lift egg, re-taring emptyâ€¦\n", d0);
          servoPausePulses();
          delay(300);
          if (tareMedianNow("egg-prep")) {
            Serial.println("Zero OK â€” put egg on wood, type egg again");
            return;
          }
          Serial.println("Re-tare failed â€” check HX711 wires, type t");
          return;
        }
      }
    }
    // Manual weigh â€” pause servos; reject if SORT/PUSH still moving.
    if (scaleMotionBusy()) {
      Serial.println("Scale busy (servo moving) â€” wait for PUSH home, then type egg");
      return;
    }
    needIdlePrint = false;
    idleShownOk = true;
    awaitNextEgg = false;
    mustSeeEmpty = false;
    eggSession = false;
    eggSeenHits = 0;
    eggResultPrinted = false;
    weightShown = false;
    announceEggRemoved = false;
    sessionDone = false;
    motionN = 0;
    stillSince = 0;
    // Bad boot tare (span 200+) makes every egg wrong â€” re-zero first.
    if (tareSuspect || lastTareSpan > 180) {
      Serial.println("Weak tare â€” re-zeroing empty pad for accuracyâ€¦");
      Serial.println("(lift egg if on pad, wait)");
      delay(400);
      if (!tareMedianNow("pre-egg")) {
        Serial.println("Tare failed â€” empty pad, type t, then egg");
        return;
      }
      Serial.println("Zero OK â€” put egg on wood, type egg");
      return;
    }
    Serial.println("Weighing â€” keep egg STILL (servos paused)â€¦");
    Serial.println("WIRE: HX711 DTâ†’P32 SCKâ†’P33 VCCâ†’3V3 GNDâ†’GND | no press on egg");
    servoPausePulses();
    delay(1500);
    long minD = EGG_SAMPLE_MIN_D;
    if (emptyNoiseD > minD) minD = emptyNoiseD;
    if (minD > 12) minD = 12;
    long lockMin = EGG_LOCK_MIN_D;
    if (lockMin < minD) lockMin = minD;
    // Collect wide band first â€” grams analyzed after median (no c50+16 hard cap).
    long maxD = 90;
    long rawBuf[64];
    int nRaw = 0;
    int nAll = 0;
    long sumAll = 0;
    long peak = 0;
    for (int i = 0; i < SCALE_READS; i++) {
      if (scaleMotionBusy()) {
        servoResumePulses();
        Serial.println("Weigh aborted â€” servo moved mid-sample");
        return;
      }
      long a = 0;
      if (readAdc(&a) && hxRawOk(a)) {
        long z = emptyAdc != 0 ? emptyAdc : idleAdc;
        long d = a - z;
        if (d < 0) d = -d;
        nAll++;
        sumAll += d;
        if (d > peak) peak = d;
        if (d >= minD && d <= maxD && nRaw < 64) {
          rawBuf[nRaw++] = d;
          if ((nRaw % 4) == 1) Serial.printf("d=%ld (n=%d peak=%ld) â†’ %.1fg\n",
                                             d, nRaw, peak, (factor > 0.05f) ? (d / factor) : 0);
        } else if ((i % 8) == 0) {
          Serial.printf("skip d=%ld (peak %ld floor=%ld)\n", d, peak, minD);
        }
      }
      delay(55);
    }
    servoResumePulses();
    if (nRaw < 5) {
      Serial.printf("No egg on pad (n=%d peak=%ld) â€” put egg, type egg\n", nRaw, peak);
      return;
    }
    // Pass 2: drop spikes far above median (keep mid-band egg bend, not empty flicker-only).
    long med0 = softCalD(rawBuf, nRaw);
    long buf[64];
    int n = 0;
    int nSkipHi = 0;
    for (int i = 0; i < nRaw; i++) {
      if (rawBuf[i] > med0 + SOFT_OUTLIER_ABOVE_MED) {
        nSkipHi++;
        continue;
      }
      buf[n++] = rawBuf[i];
    }
    if (n < 5) {
      // Fall back to raw if median was too low and everything looked like a spike.
      for (int i = 0; i < nRaw; i++) buf[i] = rawBuf[i];
      n = nRaw;
    }
    long useLock = softClusterD(buf, n);
    long spanRaw = softSpanD(buf, n);
    long span = softTrimSpanD(buf, n);
    float meanAll = (nAll > 0) ? ((float)sumAll / (float)nAll) : 0;
    bool noEgg = (useLock < lockMin) || (peak < lockMin) ||
                 (peak >= 100 && useLock < 14);
    if (noEgg) {
      Serial.printf("No egg on pad (n=%d lock=%ld peak=%ld mean=%.1f) â€” put egg, type egg\n",
                    n, useLock, peak, meanAll);
      return;
    }
    if (span > SCALE_STABLE_SPAN) {
      Serial.printf("Unstable (trimSpan=%ld raw=%ld > %ld) â€” hold egg still, type egg again\n",
                    span, spanRaw, SCALE_STABLE_SPAN);
      return;
    }
    float lockG = actualGrams(useLock);
    float shown = displayGrams(lockG);
    float useF = (factor > 0.05f) ? factor : 0.36f;
    // Explicit gram analysis (Bogde: grams = d / factor).
    Serial.println("========== GRAM ANALYSIS ==========");
    Serial.printf("formula:  grams = d / factor\n");
    Serial.printf("factor:   %.4f  (from c50)\n", useF);
    if (calRestD >= 12) {
      Serial.printf("c50:      %.0fg @ d=%ld  (readback %.1fg)\n",
                    calKnownG, calRestD, (float)calRestD / useF);
    }
    Serial.printf("samples:  n=%d  median_d=%ld  lock_d=%ld  peak=%ld  trimSpan=%ld\n",
                  n, med0, useLock, peak, span);
    Serial.printf("lock:     d=%ld / %.4f = %.2f g\n", useLock, useF, shown);
    Serial.printf("bands:    S%.0f-%.0f M%.0f-%.0f L%.0f-%.0f J%.0f-%.0f\n",
                  SMALL_MIN_G, MEDIUM_MIN_G, MEDIUM_MIN_G, LARGE_MIN_G,
                  LARGE_MIN_G, JUMBO_MIN_G, JUMBO_MIN_G, JUMBO_MAX_G);
    Serial.printf("class:    %s\n", gradeOf(sizeClassOf(lockG)).c_str());
    if (nSkipHi > 0) {
      Serial.printf("outliers: dropped %d spikes > median+%ld\n", nSkipHi, SOFT_OUTLIER_ABOVE_MED);
    }
    if (calRestD >= 12) {
      Serial.printf("Î”d vs c50: %+ld counts (egg d âˆ’ cal d)\n", useLock - calRestD);
    }
    Serial.println("===================================");
    if (!commitEggResult(lockG)) {
      Serial.println("Reject â€” hold egg still, type egg again");
    }
    return;
#else
    Serial.println("egg arm is only for the DevKit station");
    return;
#endif
  }
  if (line.startsWith("sim") || line.startsWith("SIM")) {
    // Integration test weight â€” does NOT use load cell. Labeled simulated on backend.
    float g = 55.0f;
    if (line.length() > 3) {
      float parsed = line.substring(3).toFloat();
      if (parsed >= 40.0f && parsed <= 100.0f) g = parsed;
    }
    String cls = sizeClassOf(g);
    if (!cls.length()) cls = "medium";
    Serial.println();
    Serial.println("========== SIMULATED WEIGHT (IoT TEST) ==========");
    Serial.printf("TEST WEIGHT: %.1f g  [%s] â€” NOT from load cell\n", g, cls.c_str());
    Serial.println("measurementStatus=simulated â€” do not treat as production mass");
    Serial.println("=================================================");
    pendingSize = cls;
    postWeightEx(g, cls.c_str(), "simulated", true);
#if ARDUINO_LOCAL
    if (!sizeDone) {
      sizeSweep(cls, true);
    }
#endif
    return;
  }
  if (line == "help" || line == "?" || line == "calhelp") {
#if ARDUINO_LOCAL
    Serial.println("SCALE: t | now | c50 | v50 | egg | sim55 | test | mount");
    Serial.println("IOT:   sim55 / sim60 / sim70 â€” fake weight â†’ backend (integration)");
    Serial.println("MOTORS: start | all | entrance | gate | push | sort | m | s | ir");
    Serial.println("CAL: emptyâ†’t â†’ put 50gâ†’c50 â†’ removeâ†’t â†’ egg (Priority 6 later)");
    Serial.println("now = exact weight right now (empty should be ~0 g)");
    Serial.println("v50 = put 50g, print %%error (no SORT)");
    Serial.println("factor = d/knownGrams ; grams = d/factor");
    Serial.printf("Sizes: S%.0f-%.0f M%.0f-%.0f L%.0f-%.0f J%.0f-%.0f\n",
                  SMALL_MIN_G, MEDIUM_MIN_G, MEDIUM_MIN_G, LARGE_MIN_G,
                  LARGE_MIN_G, JUMBO_MIN_G, JUMBO_MIN_G, JUMBO_MAX_G);
#else
    Serial.println("servo | size | cam | horn | t | c50 | w | mount | m | s | rev | ir | wifi Name,password");
#endif
    return;
  }
  if (line == "v50" || line == "verify") {
#if EGG_DEVKIT
    if (scaleMotionBusy()) {
      Serial.println("Scale busy â€” wait, then v50");
      return;
    }
    if (!haveIdle) {
      Serial.println("Type t first (empty), then put 50g, then v50");
      return;
    }
    Serial.println("VERIFY 50g â€” keep reference STILLâ€¦");
    servoPausePulses();
    delay(900);
    long buf[64];
    int n = 0;
    long peak = 0;
    long z = emptyAdc != 0 ? emptyAdc : idleAdc;
    for (int i = 0; i < SCALE_READS; i++) {
      long a = 0;
      if (readAdc(&a) && hxRawOk(a)) {
        long d = a - z;
        if (d < 0) d = -d;
        if (d > peak) peak = d;
        if (d >= 10 && d <= 80 && n < 64) buf[n++] = d;
      }
      delay(55);
    }
    servoResumePulses();
    if (n < 6) {
      Serial.printf("VERIFY fail n=%d peak=%ld â€” put 50g still\n", n, peak);
      return;
    }
    long d = softRestD(buf, n);
    float g = actualGrams(d);  // same stretch path as egg weigh
    float ref = (calKnownG > 1.0f) ? calKnownG : 50.0f;
    float err = pctErrorG(g, ref);
    Serial.println("========== VERIFY ==========");
    Serial.printf("d=%ld  measured=%.1fg  reference=%.1fg\n", d, g, ref);
    Serial.printf("%% error = |meas-ref|/ref*100 = %.2f %%\n", err);
    Serial.printf("factor=%.4f  softGPC=%.2f g/count  (target: error < 2%%)\n", factor, SOFT_GPC);
    if (err > 5.0f) Serial.println("HIGH ERROR â€” redo t + c50 or check mount/wiring");
    else if (err > 2.0f) Serial.println("Fair â€” redo c50 with still 50g");
    else Serial.println("GOOD â€” calibration looks consistent");
    Serial.println("============================");
#else
    Serial.println("v50 is DevKit only");
#endif
    return;
  }
  if (line == "mount" || line == "wood") {
    Serial.println();
    Serial.println("=== WHY NUTS WORK BUT EGG ON WOOD DOES NOT ===");
    Serial.println("Your dâ‰ˆ0-30 with egg = almost ZERO force on the cell.");
    Serial.println("Finger on a nut bends the bar. Wood on BOTH ends cancels the bend.");
    Serial.println();
    Serial.println("CORRECT (side view):");
    Serial.println("  [BASE]====[fixed-end nuts]====CELL====[weigh nuts]==[WOOD/EGG]");
    Serial.println("                              ^ air gap under wood â€” not on table");
    Serial.println();
    Serial.println("WRONG (what your log looks like):");
    Serial.println("  [WOOD sitting on BOTH ends / on the table]  -> d stays ~0");
    Serial.println();
    Serial.println("Fix: unscrew wood from the fixed end. Bolt wood ONLY to weighing-end nuts.");
    Serial.println("Then: empty -> t -> set egg on wood (no press). d should jump to hundreds.");
    Serial.println("Send w while egg sits on wood to measure span.");
    return;
  }
  if (line == "w" || line == "weight" || line == "ok" || line == "OK") {
    // Try A128, A64, B32. Egg on wood OR press weighing-end nuts.
    Serial.println();
    Serial.println("*** WEIGHT TEST â€” put EGG on WOOD (or press weighing-end nuts) NOW ***");
    const uint8_t gains[3] = {128, 64, 32};
    long bestSpan = 0;
    uint8_t bestGain = hxGain;
    for (int gi = 0; gi < 3; gi++) {
      hxGain = gains[gi];
      scale.set_gain(hxGain, true);
      delay(80);
      long zero = 0;
      int zn = 0;
      for (int i = 0; i < 8; i++) {
        long v = 0;
        if (!hxReadOnce(&v) || hxStuck(v)) continue;
        zero += v;
        zn++;
        delay(20);
      }
      if (zn < 3) {
        Serial.printf("  gain %u â€” no samples\n", gains[gi]);
        continue;
      }
      zero /= zn;
      long lo = zero, hi = zero;
      unsigned long endAt = millis() + 2500;
      while (millis() < endAt) {
        long v = 0;
        if (!hxReadOnce(&v) || hxStuck(v)) {
          delay(5);
          continue;
        }
        hxLastRaw = v;
        if (v < lo) lo = v;
        if (v > hi) hi = v;
        long d = v - zero;
        if (d < 0) d = -d;
        Serial.printf("  gain %u raw %ld d=%ld\n", gains[gi], v, d);
        delay(100);
      }
      long span = hi - lo;
      if (span < 0) span = -span;
      Serial.printf("  gain %u span=%ld (zero=%ld)\n", gains[gi], span, zero);
      if (span > bestSpan) {
        bestSpan = span;
        bestGain = gains[gi];
      }
    }
    hxGain = bestGain;
    scale.set_gain(hxGain, true);
    saveFactor();
    // Fresh empty zero after the test.
    long adc = 0;
    if (readAdc(&adc)) {
      idleAdc = adc;
      emptyAdc = adc;
      haveIdle = true;
      peakDelta = 0;
    }
    Serial.printf("*** WEIGHT TEST END best gain %u span=%ld ***\n", bestGain, bestSpan);
    if (bestSpan < 150) {
      Serial.println("NO FORCE â€” HX711 OK, but egg/wood is not bending the cell.");
      Serial.println("Send mount â€” bolt wood ONLY to weighing-end nuts (not both ends / table).");
      Serial.println("If pressing a nut still gives span>150 but egg on wood does not: wood mount is wrong.");
    } else if (bestSpan < 600) {
      Serial.printf("WEAK span=%ld â€” light force only. Check wood is on weighing end only.\n", bestSpan);
    } else {
      float fakeG = (float)bestSpan / factor;
      Serial.printf("WEIGHT OK span=%ld â‰ˆ %.0fg â€” resting egg/wood path is good\n", bestSpan, fakeG);
    }
    return;
  }
  if (line == "t" || line == "tare" || line == "t!") {
    // Tare = load cell only. IR is entrance; never blocks weighing zero.
    bool forceTare = (line == "t!");
    if (!forceTare) {
      long z = emptyAdc != 0 ? emptyAdc : idleAdc;
      long probe = 0;
      long dd = 0;
      if (readAdc(&probe) && hxRawOk(probe) && hxRawOk(z)) {
        dd = probe - z;
        if (dd < 0) dd = -dd;
      }
      if (dd >= 15) {
        Serial.println("TARE BLOCKED â€” remove weight from wood, then t");
        Serial.println("Or t! to force (only if really empty)");
        return;
      }
    }
    digitalWrite(HX711_SCK, LOW);
    delay(250);
    // Stable empty: median of several good samples (reject glitches).
    long buf[9];
    int n = 0;
    for (int i = 0; i < 12 && n < 9; i++) {
      long v = 0;
      if (!readAdc(&v) || !hxRawOk(v)) {
        delay(30);
        continue;
      }
      buf[n++] = v;
      delay(25);
    }
    if (n < 5) {
      Serial.println("TARE BLOCKED â€” HX711 unstable. Check DT=P32 SCK=P33, 3V3, re-seat wires");
      return;
    }
    for (int i = 0; i < n; i++) {
      for (int j = i + 1; j < n; j++) {
        if (buf[j] < buf[i]) {
          long t = buf[i];
          buf[i] = buf[j];
          buf[j] = t;
        }
      }
    }
    long adc = buf[n / 2];
    // Trim min/max so one glitch sample does not block tare (your span=574).
    long lo = buf[1], hi = buf[n - 2];
    if (n < 7) {
      lo = buf[0];
      hi = buf[n - 1];
    }
    long span = hi - lo;
    if (span < 0) span = -span;
    if (span > 550 && !forceTare) {
      Serial.printf("TARE BLOCKED â€” bar not still (span=%ld). Empty wood, wait, t  â€” or t! to force\n", span);
      return;
    }
    idleAdc = adc;
    emptyAdc = adc;
    clearEmptyAdc = adc;
    haveClearEmpty = true;
    haveIdle = true;
    peakDelta = 0;
    eggPeakD = 0;
    smoothD = 0;
    holdPeakD = 0;
    holdPeakAt = 0;
    liveG = 0;
    smoothG = 0;
    scaleG = 0;
    lastGoodG = 0;
    lastGoodAt = 0;
    lowStreak = 0;
    eggHits = 0;
    lastStableG = 0;
    wasEmpty = true;
    weightShown = false;
    weightSince = 0;
    // Keep saved/default factor â€” tare only zeros empty (do not wipe c50).
    scale.set_scale(factor);
    scale.tare(10);
    Serial.printf("TARE OK idle=%ld factor=%.4f\n", idleAdc, factor);
    // Prove empty pad = 0 g after tare.
    // IMPORTANT: use SIGNED mean (a-idle). Soft cell |d| flicker is NOT mass.
    // Noise floor = ~75th |d| (NOT max) â€” max spikes were 22+ and blocked all eggs.
    {
      long sumSigned = 0;
      long sumAbs = 0;
      int n = 0;
      long lo = 0, hi = 0;
      long absBuf[24];
      for (int i = 0; i < 24; i++) {
        long a = 0;
        if (!readAdc(&a) || !hxRawOk(a)) {
          delay(30);
          continue;
        }
        long sd = a - idleAdc;
        long ad = (sd < 0) ? -sd : sd;
        if (n == 0) {
          lo = hi = ad;
        } else {
          if (ad < lo) lo = ad;
          if (ad > hi) hi = ad;
        }
        sumSigned += sd;
        sumAbs += ad;
        if (n < 24) absBuf[n] = ad;
        n++;
        delay(40);
      }
      if (n >= 5) {
        float meanSigned = (float)sumSigned / (float)n;
        long avgAbs = sumAbs / n;
        // Sort abs â†’ 75th percentile as egg deadband (ignore rare max spikes).
        for (int i = 0; i < n; i++) {
          for (int j = i + 1; j < n; j++) {
            if (absBuf[j] < absBuf[i]) {
              long t = absBuf[i];
              absBuf[i] = absBuf[j];
              absBuf[j] = t;
            }
          }
        }
        long p75 = absBuf[(n * 3) / 4];
        emptyNoiseD = p75;
        if (emptyNoiseD < 6) emptyNoiseD = 6;
        // Hard cap: 50g soft cal sits ~18â€“23. Floor must stay below that.
        if (emptyNoiseD > 12) emptyNoiseD = 12;
        float g = (factor > 0.05f) ? (meanSigned / factor) : 0;
        if (g < 0) g = -g;
        if (g <= 3.0f || (meanSigned < (float)emptyNoiseD && meanSigned > -(float)emptyNoiseD)) {
          g = 0;
        }
        Serial.println("========== EMPTY PAD (no egg) ==========");
        Serial.printf("Exact weight now:  %.2f g\n", g);
        Serial.printf("signed mean d=%.1f  |d| avg=%ld (min=%ld max=%ld p75=%ld)  n=%d\n",
                      meanSigned, avgAbs, lo, hi, p75, n);
        Serial.printf("egg sample floor dâ‰¥%ld  factor=%.4f  idle raw=%ld\n",
                      emptyNoiseD, factor, idleAdc);
        lastTareSpan = hi;
        tareSuspect = (hi > 25 || g > 0.05f);
        if (g <= 0.05f) {
          Serial.println("OK â€” empty is 0 g (tare locked)");
          if (hi >= 18) {
            Serial.println("NOTE: soft flicker spikes high â€” using p75 floor (eggs still weigh)");
          }
          if (!tareSuspect) Serial.println("Zero quality: GOOD â€” ready for c50 / egg");
        } else {
          Serial.println("NOT ZERO â€” clear pad, wait 2s, type t again");
        }
        Serial.println("========================================");
      }
    }
    Serial.println("Next: put known 50g â†’ c50 | or put egg â†’ egg | or type now");
    return;
  }
  if (line == "now" || line == "0" || line == "empty" || line == "wt") {
#if EGG_DEVKIT
    // Live exact weight â€” signed mean vs tare (empty â†’ ~0). Abs softRest is egg-only.
    if (scaleMotionBusy()) {
      Serial.println("Scale busy â€” wait, then type now");
      return;
    }
    servoPausePulses();
    delay(300);
    long z = emptyAdc != 0 ? emptyAdc : idleAdc;
    long buf[24];
    int n = 0;
    long peak = 0;
    long sumSigned = 0;
    for (int i = 0; i < 30 && n < 24; i++) {
      long a = 0;
      if (!readAdc(&a) || !hxRawOk(a)) {
        delay(40);
        continue;
      }
      long sd = a - z;
      long ad = (sd < 0) ? -sd : sd;
      if (ad > peak) peak = ad;
      sumSigned += sd;
      buf[n++] = ad;
      delay(45);
    }
    servoResumePulses();
    if (n < 5) {
      Serial.println("HX711 fail â€” check DT=P32 SCK=P33 3V3 GND");
      return;
    }
    float meanSigned = (float)sumSigned / (float)n;
    long dMed = softRestD(buf, n);
    long span = softSpanD(buf, n);
    long floorD = emptyNoiseD;
    if (floorD < 8) floorD = 8;
    float useF = (factor > 0.05f) ? factor : 0.35f;
    // Exact empty weight = signed mean (tare zero). Inside noise floor â†’ 0.00 g.
    float gExact = meanSigned / useF;
    bool looksEmpty = (meanSigned < (float)floorD && meanSigned > -(float)floorD) ||
                      (dMed <= floorD);
    if (looksEmpty) gExact = 0;
    else if (gExact < 0) gExact = -gExact;
    // Egg-style reading (abs rest) for when mass is on the pad.
    float gEgg = (float)dMed / useF;
    Serial.println();
    Serial.println("========== SCALE NOW ==========");
    Serial.printf("EXACT WEIGHT:  %.2f g\n", gExact);
    Serial.printf("signed mean d=%.1f  |d| rest=%ld  peak=%ld  span=%ld  n=%d\n",
                  meanSigned, dMed, peak, span, n);
    Serial.printf("tare raw=%ld  factor=%.4f  noise floor dâ‰¤%ld\n", z, factor, floorD);
    if (looksEmpty) {
      Serial.println("Pad EMPTY â€” exact weight is 0.00 g");
    } else if (gEgg < SMALL_MIN_G) {
      Serial.printf("Light load ~%.1fg (egg rest) â€” not a full egg yet\n", gEgg);
    } else {
      Serial.printf("Egg-style rest: %.1fg â†’ %s\n", gEgg, gradeOf(sizeClassOf(gEgg)).c_str());
    }
    Serial.println("================================");
#else
    Serial.println("now is DevKit only");
#endif
    return;
  }
  if (line == "r" || line == "R" || line == "test") {
    // Diagnostic: empty vs egg â€” if d barely moves, mount/cell not software.
    long sum = 0;
    int n = 0;
    long z = emptyAdc != 0 ? emptyAdc : idleAdc;
    for (int i = 0; i < 8; i++) {
      long adc = 0;
      if (readAdc(&adc) && hxRawOk(adc) && !hxStuck(adc)) {
        long d = adc - z;
        if (d < 0) d = -d;
        sum += d;
        n++;
      }
      delay(40);
    }
    if (n < 3) {
      Serial.println("HX711 fail â€” check DT=P32 SCK=P33 3V3 GND");
      return;
    }
    long d = sum / n;
    float grams = serialGramsFromD(d);
    Serial.println();
    Serial.println("========== SCALE TEST ==========");
    Serial.printf("avg d=%ld   grams=%.1f   factor=%.4f\n", d, grams, factor);
    if (d < 10) {
      Serial.println("â†’ EMPTY / weak bend (no egg or mount issue)");
    } else if (d < 12) {
      Serial.println("â†’ WEAK â€” little force on cell; check mount air-gap");
    } else {
      Serial.printf("â†’ OK signal for weigh (need dâ‰¥%ld)\n", EGG_SAMPLE_MIN_D);
    }
    Serial.println("Empty: type t then test | Egg on wood: type test again");
    Serial.println("================================");
    return;
  }
  if (line.startsWith("c") && line != "cam") {
    float known = 50;
    if (line.length() > 1) known = line.substring(1).toFloat();
    if (known < 5 || known > 500) known = 50;
#if EGG_DEVKIT
    // Soft cell: 50g and 55g make almost the same d â€” c55 poisons factor (emptyâ†’fake egg).
    if (known < 49.0f || known > 51.0f) {
      Serial.println("Use c50 only on this soft cell (c55/c60 confuses grams)");
      Serial.println("Put known 50g â†’ type c50");
      return;
    }
    known = 50;
#endif
    if (!haveIdle) {
      Serial.println("Empty pad â†’ type t first, then put known weight, then c50");
      return;
    }
#if EGG_DEVKIT
    if (scaleMotionBusy()) {
      Serial.println("Scale busy (servo moving) â€” wait, then c50");
      return;
    }
    servoPausePulses();
#endif
    Serial.printf("Calibrating %.0fg â€” keep reference STILL (no hands)â€¦\n", known);
    Serial.println("Formula: factor = deltaCounts / knownGrams");
    Serial.println("         grams  = deltaCounts / factor");
    delay(1200);  // soft cell settle before sampling
    long dbuf[64];
    int dn = 0;
    long peak = 0;
    long zero = emptyAdc != 0 ? emptyAdc : idleAdc;
    for (int i = 0; i < SCALE_READS; i++) {
      long adc = 0;
      if (!readAdc(&adc) || !hxRawOk(adc) || hxStuck(adc)) {
        delay(55);
        continue;
      }
      long d = adc - zero;
      if (d < 0) d = -d;
      if (d > peak) peak = d;
      if (d >= 10 && d <= 200 && dn < 64) {
        dbuf[dn++] = d;
        if ((dn % 4) == 1) Serial.printf("cal d=%ld (n=%d)\n", d, dn);
      }
      delay(55);
    }
#if EGG_DEVKIT
    servoResumePulses();
#endif
    if (dn < 8) {
      Serial.printf("CAL fail â€” only %d samples (peak=%ld). Hold %.0fg STILL, c50\n",
                    dn, peak, known);
      return;
    }
#if EGG_DEVKIT
    long restBuf[64];
    int rn = 0;
    for (int i = 0; i < dn; i++) {
      if (dbuf[i] >= 16 && dbuf[i] <= 90) restBuf[rn++] = dbuf[i];
    }
    // c50 + egg both use cluster/median â€” same physics as Bogde factor.
    long d = (rn >= 6) ? softClusterD(restBuf, rn) : softClusterD(dbuf, dn);
    long spanRaw = (rn >= 6) ? softSpanD(restBuf, rn) : softSpanD(dbuf, dn);
    long span = (rn >= 6) ? softTrimSpanD(restBuf, rn) : softTrimSpanD(dbuf, dn);
    if (peak > d * 3 + 20) {
      Serial.printf("CAL note: spike peak=%ld ignored (rest d=%ld trimSpan=%ld rawSpan=%ld)\n",
                    peak, d, span, spanRaw);
    }
    // Trimmed span: ignore outer 25% flicker so soft cell can pass without 4 retries.
    long spanLimit = SCALE_STABLE_SPAN + 14;  // was +6 â€” too tight for soft flicker
    if (span > spanLimit) {
      Serial.printf("CAL fail â€” unstable trimSpan=%ld (raw=%ld). Hands off, c50 again\n",
                    span, spanRaw);
      return;
    }
#else
    long d = dbuf[dn / 2];
    long span = 0;
#endif
    if (d < 5 || d > 150) {
      Serial.printf("CAL fail â€” d=%ld unstable (peak=%ld). Rest %.0fg gently, c50\n",
                    d, peak, known);
      return;
    }
    if (d < EGG_CAL_MIN_D) {
      Serial.printf("CAL REJECTED d=%ld â€” too soft (need rest dâ‰¥%ld)\n", d, EGG_CAL_MIN_D);
      Serial.println("Check mount/wiring before more software tweaks");
      return;
    }
    if (d < 18) {
      Serial.printf("WARNING: soft cal d=%ld â€” fix mount air-gap for better accuracy\n", d);
    }
    // Bogde: factor = Î”counts / knownGrams ; grams = Î”counts / factor
    factor = (float)d / known;
    if (factor < FACTOR_MIN) factor = FACTOR_MIN;
    if (factor > FACTOR_MAX) factor = FACTOR_MAX;
    gPerCount = 1.0f / factor;
#if EGG_DEVKIT
    calRestD = d;
    calKnownG = known;
#endif
    scale.set_scale(factor);
    saveFactor();
    float shown = (float)d / factor;
    Serial.println("========== CALIBRATION OK ==========");
    Serial.printf("Known weight:        %.1f g\n", known);
    Serial.printf("Raw delta (d):       %ld\n", d);
    Serial.printf("factor = d/known:    %.6f\n", factor);
    Serial.printf("Readback:            %.1f g\n", shown);
#if EGG_DEVKIT
    {
      float errPct = pctErrorG(shown, known);
      Serial.printf("%% error:             %.2f %%\n", errPct);
      Serial.printf("Stability trimSpan:  %ld (want â‰¤ %ld)\n", span, SCALE_STABLE_SPAN + 14);
      if (errPct > 2.0f) {
        Serial.println("WARNING: %%error > 2% â€” repeat c50 with still reference");
      }
    }
#endif
    Serial.println("Sizes: S45-55 M55-60 L60-70 J70-100");
    Serial.println("NEXT: remove weight â†’ t â†’ put egg â†’ egg");
    Serial.println("====================================");
    needIdlePrint = false;
    idleShownOk = true;
    eggSession = false;
    eggSessionAt = 0;
    eggSeenHits = 0;
    weightShown = false;
    eggResultPrinted = false;
    announceEggRemoved = false;
  }
}

void handleSerial() {
  while (Serial.available()) {
    char c = (char)Serial.read();
    serialAt = millis();
    if (c == '\r') continue;
    if (c == '\n') {
      runSerialLine(serialBuf);
      serialBuf = "";
      return;
    }
    if (serialBuf.length() < 96) serialBuf += c;
  }
  if (serialBuf.length() > 0 && millis() - serialAt > 90) {
    runSerialLine(serialBuf);
    serialBuf = "";
  }
}

static const char* STREAM_TYPE = "multipart/x-mixed-replace;boundary=123456789000000000000987654321";
static const char* STREAM_B = "\r\n--123456789000000000000987654321\r\n";
static const char* STREAM_P = "Content-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n";
static const char INDEX_HTML[] =
    "<html><head><title>Egg camera</title></head>"
    "<body style='margin:0;background:#111'>"
    "<img src='/mjpeg' style='width:100vw;height:100vh;object-fit:contain;background:#000;display:block'>"
    "</body></html>";

struct JpgSink {
  uint8_t* buf;
  size_t cap;
  size_t len;
};

static size_t jpgWrite(void* arg, size_t index, const void* data, size_t len) {
  JpgSink* s = (JpgSink*)arg;
  if (!data || !len) return 1;
  if (index + len > s->cap) return 0;
  memcpy(s->buf + index, data, len);
  if (index + len > s->len) s->len = index + len;
  return len;
}

static uint8_t* scaleBuf = NULL;
static size_t scaleCap = 0;
static uint8_t* encBuf = NULL;
static uint8_t* holdBuf = NULL;
static const size_t kJpgCap = 180 * 1024;

static bool ensureJpgBufs() {
  if (!encBuf) {
    encBuf = (uint8_t*)heap_caps_malloc(kJpgCap, MALLOC_CAP_8BIT | MALLOC_CAP_SPIRAM);
    if (!encBuf) encBuf = (uint8_t*)malloc(kJpgCap);
  }
  if (!holdBuf) {
    holdBuf = (uint8_t*)heap_caps_malloc(kJpgCap, MALLOC_CAP_8BIT | MALLOC_CAP_SPIRAM);
    if (!holdBuf) holdBuf = (uint8_t*)malloc(kJpgCap);
  }
  return encBuf && holdBuf;
}

// About 320x240 from the wide frame, so the JPEG finishes before the egg moves on.
static bool shrinkYuv(const camera_fb_t* fb, camera_fb_t* out) {
  *out = *fb;
  // QVGA is already small â€” shrinking it wastes time. Only downscale bigger frames.
  if (!fb || fb->format != PIXFORMAT_YUV422 || fb->width <= 320 || fb->height <= 240) return false;
  int ow = (fb->width * 2) / 5;
  ow &= ~1;
  int oh = (fb->height * 2) / 5;
  int opairs = ow / 2;
  if (opairs < 1 || oh < 1) return false;
  size_t need = (size_t)opairs * 4 * (size_t)oh;
  if (!scaleBuf || scaleCap < need) {
    if (scaleBuf) free(scaleBuf);
    scaleBuf = (uint8_t*)heap_caps_malloc(need, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!scaleBuf) scaleBuf = (uint8_t*)malloc(need);
    scaleCap = scaleBuf ? need : 0;
  }
  if (!scaleBuf) return false;
  size_t stride = (size_t)fb->width * 2;
  int maxPair = fb->width / 2 - 1;
  for (int y = 0; y < oh; y++) {
    int sy = (y * 5) / 2;
    if (sy >= fb->height) sy = fb->height - 1;
    const uint8_t* src = fb->buf + (size_t)sy * stride;
    uint8_t* dst = scaleBuf + (size_t)y * (size_t)opairs * 4;
    for (int p = 0; p < opairs; p++) {
      int sp = (p * 5) / 2;
      if (sp > maxPair) sp = maxPair;
      const uint8_t* s = src + (size_t)sp * 4;
      dst[0] = s[0];
      dst[1] = s[1];
      dst[2] = s[2];
      dst[3] = s[3];
      dst += 4;
    }
  }
  out->buf = scaleBuf;
  out->len = need;
  out->width = opairs * 2;
  out->height = oh;
  return true;
}

static bool jpegHasEoi(const uint8_t* p, size_t n) {
  if (!p || n < 4) return false;
  size_t start = (n > 24) ? (n - 24) : 0;
  for (size_t i = start; i + 1 < n; i++) {
    if (p[i] == 0xFF && p[i + 1] == 0xD9) return true;
  }
  return false;
}

static void camPublishTask(void*) {
  camState = 7;
  static int camFailStreak = 0;
  static uint32_t encCount = 0;
  static uint32_t encMsSum = 0;
  static uint32_t diagAt = 0;
  // Let the sensor produce a few frames before the first encode.
  vTaskDelay(pdMS_TO_TICKS(250));
  diagAt = millis();
  for (;;) {
    if (camTlsBusy) {
      vTaskDelay(pdMS_TO_TICKS(20));
      continue;
    }
    if (!cameraOn || camReiniting) {
      vTaskDelay(pdMS_TO_TICKS(40));
      continue;
    }
    int64_t t0 = esp_timer_get_time();
    camera_fb_t* fb = esp_camera_fb_get();
    if (!fb || !fb->buf || fb->len < 200 || fb->width < 16 || fb->height < 16) {
      if (fb) esp_camera_fb_return(fb);
      camState = 1;
      camFailStreak++;
      camStreamErrs++;
      if (camFailStreak >= 40) {
        Serial.println("cam fb fail streak â€” request re-init");
        cameraOn = false;  // serviceCamKeepAlive will re-init
        camFailStreak = 0;
      }
      vTaskDelay(pdMS_TO_TICKS(15));
      continue;
    }
    // Reject truncated YUV (frame2jpg crashes on bad len).
    const bool isHwJpeg = (fb->format == PIXFORMAT_JPEG);
    if (fb->format == PIXFORMAT_YUV422) {
      size_t need = (size_t)fb->width * (size_t)fb->height * 2u;
      if (fb->len < need) {
        esp_camera_fb_return(fb);
        camState = 3;
        camFailStreak++;
        camStreamErrs++;
        vTaskDelay(pdMS_TO_TICKS(15));
        continue;
      }
    }

    uint8_t* outJpg = NULL;
    size_t outLen = 0;
    bool ok = false;

    if (isHwJpeg && fb->buf[0] == 0xFF && fb->buf[1] == 0xD8) {
      if (!jpegHasEoi(fb->buf, fb->len)) {
        // Truncated / magenta glitch JPEG â€” do not push to laptop.
        esp_camera_fb_return(fb);
        camState = 4;
        camFailStreak++;
        camStreamErrs++;
        vTaskDelay(pdMS_TO_TICKS(10));
        continue;
      }
      // Copy JPEG ring in PSRAM when possible â€” free the sensor buffer ASAP.
      outJpg = (uint8_t*)heap_caps_malloc(fb->len, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
      if (!outJpg) outJpg = (uint8_t*)malloc(fb->len);
      if (outJpg) {
        memcpy(outJpg, fb->buf, fb->len);
        outLen = fb->len;
        ok = true;
        camState = 0;
      } else {
        camState = 2;
        camStreamErrs++;
      }
    } else {
      // YUV/RGB fallback â€” slower; keep quality modest so Wiâ€‘Fi stays live.
      if (frame2jpg(fb, CAM_SOFT_JPEG_Q, &outJpg, &outLen) && outJpg && outLen >= 200 &&
          jpegHasEoi(outJpg, outLen)) {
        ok = true;
        camState = 0;
      } else {
        if (outJpg) {
          free(outJpg);
          outJpg = NULL;
        }
        camState = 3;
        camHeap = ESP.getFreeHeap();
        camPsram = ESP.getFreePsram();
        camFailStreak++;
        camStreamErrs++;
      }
    }
    // Always return the DMA buffer before touching Wiâ€‘Fi / ring swap.
    esp_camera_fb_return(fb);

    if (ok && outJpg && camJpgLock &&
        xSemaphoreTake(camJpgLock, pdMS_TO_TICKS(30)) == pdTRUE) {
      uint8_t* old = camJpg;
      camJpg = outJpg;
      camJpgLen = outLen;
      camJpgSeq++;
      camJpgOkAt = millis();
      camFailStreak = 0;
      xSemaphoreGive(camJpgLock);
      if (old) free(old);
      outJpg = NULL;
    }
    if (outJpg) free(outJpg);

#if !EGG_DEVKIT && CAM_PUSH_ENABLE
    // Fallback only if dedicated push task could not start â€” rare, slow, so
    // encode/:81 stay usable. Prefer camPushTask (started before camera init).
    if (!camPushRunning) {
      static uint32_t lastInlinePush = 0;
      if (!wifiSwitching && WiFi.status() == WL_CONNECTED &&
          camJpgLen >= 200 && strlen(activeBackend) > 0 &&
          camJpgSeq != camJpgPushed &&
          millis() - lastInlinePush >= 2000UL) {
        lastInlinePush = millis();
        int pr = postFrame();
        if (pr == 0) { /* ok */ }
        else if (pr != -2) camStreamErrs++;
        Serial.printf("CAM push fallback http=%d pushed=%u (no push task)\n",
                      pr, (unsigned)camJpgPushed);
      }
    }
#endif

    uint32_t encMs = (uint32_t)((esp_timer_get_time() - t0) / 1000LL);
    camLastEncMs = encMs;
    encCount++;
    encMsSum += encMs;
    if (millis() - diagAt >= CAM_DIAG_MS) {
      uint32_t span = millis() - diagAt;
      if (span < 1) span = 1;
      camEncFpsX10 = (encCount * 10000UL) / span;
      uint32_t avgMs = encCount ? (encMsSum / encCount) : 0;
      Serial.printf(
          "CAM diag enc_fps=%.1f enc_ms=%u jpg=%u seq=%u pushed=%u err=%u "
          "state=%d heap=%u psram=%u rssi=%d wifi_dc=%u\n",
          camEncFpsX10 / 10.0f, (unsigned)avgMs, (unsigned)camJpgLen,
          (unsigned)camJpgSeq, (unsigned)camJpgPushed, (unsigned)camStreamErrs,
          camState, (unsigned)ESP.getFreeHeap(), (unsigned)ESP.getFreePsram(),
          (int)WiFi.RSSI(), (unsigned)wifiDisconnectCount);
      encCount = 0;
      encMsSum = 0;
      diagAt = millis();
    }

    if (camFailStreak >= 50) {
      Serial.println("cam encode fail streak â€” request re-init");
      cameraOn = false;
      camFailStreak = 0;
    }
    // Hardware JPEG is fast â€” shorter yield. Soft JPEG needs more Wiâ€‘Fi time.
    vTaskDelay(pdMS_TO_TICKS(isHwJpeg ? CAM_PUBLISH_GAP_JPEG_MS : CAM_PUBLISH_GAP_MS));
  }
}

#if !EGG_DEVKIT && CAM_PUSH_ENABLE
static void camPushTask(void*) {
  camPushRunning = true;
  static uint32_t pushOk = 0;
  static uint32_t pushBusy = 0;
  static uint32_t pushDiagAt = 0;
  static int lastPr = 0;
  Serial.printf("CAM push task up core=%d stack_hwm=%u via=%s\n",
                xPortGetCoreID(), (unsigned)uxTaskGetStackHighWaterMark(NULL),
                farmBackendIsHttps() ? "tunnel" : "lan");
  pushDiagAt = millis();
  for (;;) {
    farmTryLanRecover();
    // New JPEG ready (camera may already be paused from prior tunnel push).
    if (!wifiSwitching && WiFi.status() == WL_CONNECTED &&
        camJpgLen >= 200 && strlen(activeBackend) > 0 &&
        camJpgSeq != camJpgPushed) {
      // Continuous egg detect: keep-alive while socket lives; pause cam only
      // for a real reconnect. Back off on fail — handshake storms freeze Live.
      static int consecFail = 0;
      const bool needHandshake =
          farmBackendIsHttps() &&
          (!gTunnelCli || !gTunnelCli->connected());
      // Soft pause for keep-alive reuse. Full deinit only after repeated
      // handshake fails (DRAM fight) — deinit-every-push made Live ~0.5 fps.
      if (needHandshake && farmBackendIsHttps() && cameraOn) {
        camTlsBusy = true;
        camPausedForTlsAt = millis();
        vTaskDelay(pdMS_TO_TICKS(30));
        if (consecFail >= 2) {
          camReiniting = true;
          vTaskDelay(pdMS_TO_TICKS(20));
          esp_camera_deinit();
          cameraOn = false;
          camReiniting = false;
          vTaskDelay(pdMS_TO_TICKS(30));
        }
      }
      int pr = postFrame();
      lastPr = pr;
      if (pr == 0) {
        pushOk++;
        consecFail = 0;
      } else if (pr == -2) {
        pushBusy++;
      } else {
        camStreamErrs++;
        if (consecFail < 20) consecFail++;
        if (gTunnelCli) gTunnelCli->stop();
      }
      camTlsBusy = false;
      if (farmBackendIsHttps() && !cameraOn) {
        if (initCameraQuick()) {
          uint32_t want = camJpgSeq;
          uint32_t t0 = millis();
          while (millis() - t0 < 200UL && camJpgSeq == want) {
            vTaskDelay(pdMS_TO_TICKS(10));
          }
        } else {
          camReinitAt = millis() + 500UL;
        }
      }
      // Realtime detect: push the next JPEG ASAP while keep-alive is healthy.
      uint32_t gap = farmBackendIsHttps() ? (pr == 0 ? 0 : 80) : CAM_LIVE_PUSH_MS;
      if (pr == -2) gap = 2;
      else if (pr != 0) {
        gap = farmBackendIsHttps() ? (uint32_t)(80 + consecFail * 40) : CAM_LIVE_PUSH_MAX_MS;
        if (gap > 500) gap = 500;
      }
      if (millis() - pushDiagAt >= CAM_DIAG_MS) {
        uint32_t span = millis() - pushDiagAt;
        if (span < 1) span = 1;
        camPushFpsX10 = (pushOk * 10000UL) / span;
        Serial.printf(
            "CAM push_fps=%.1f http_last=%d jpg=%u pushed=%u busy=%u via=%s\n",
            camPushFpsX10 / 10.0f, lastPr, (unsigned)camJpgLen,
            (unsigned)camJpgPushed, (unsigned)pushBusy,
            farmBackendIsHttps() ? "tunnel" : "lan");
        pushOk = 0;
        pushBusy = 0;
        pushDiagAt = millis();
      }
      vTaskDelay(pdMS_TO_TICKS(gap));
      continue;
    }
    vTaskDelay(pdMS_TO_TICKS(farmBackendIsHttps() ? 5 : CAM_LIVE_PUSH_MS));
  }
}

// Start BEFORE camera init while DRAM is still contiguous (49k after DMA fails).
static void camPushStartEarly() {
  static bool started = false;
  if (started || camPushRunning) return;
  if (!camJpgLock) camJpgLock = xSemaphoreCreateMutex();
  // TLS client is heap-allocated; still need ~24â€“32k task stack for mbedtls.
  const uint32_t stacks[CAM_PUSH_STACK_TRIES] = {32768, 28672, 24576, 20480};
  for (int i = 0; i < CAM_PUSH_STACK_TRIES; i++) {
    BaseType_t ok =
        xTaskCreatePinnedToCore(camPushTask, "campush", stacks[i], NULL, 3, NULL, 0);
    if (ok == pdPASS) {
      started = true;
      Serial.printf("CAM push task created stack=%u (early, before camera)\n",
                    (unsigned)stacks[i]);
      return;
    }
  }
  Serial.println("CAM push task FAILED â€” encode will use slow inline fallback");
}
#endif

static void camPublishStart() {
  if (!camJpgLock) camJpgLock = xSemaphoreCreateMutex();
  static bool encStarted = false;
  if (encStarted) return;
  encStarted = true;
  // Encode only â€” TLS push is a separate early task so :81/:82 never freeze.
  // Smaller encode stack â€” leave internal RAM for TLS handshake.
  BaseType_t ok = xTaskCreatePinnedToCore(camPublishTask, "camjpg", 28672, NULL, 1, NULL, 1);
  if (ok != pdPASS) {
    encStarted = false;
    Serial.println("CAM encode task FAILED");
  } else {
    Serial.println("CAM encode task ok (push is separate)");
  }
}

static esp_err_t index_handler(httpd_req_t* req) {
  httpd_resp_set_type(req, "text/html");
  return httpd_resp_send(req, INDEX_HTML, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t jpg_handler(httpd_req_t* req) {
  uint8_t* copy = NULL;
  size_t len = 0;
  if (camJpgLock && xSemaphoreTake(camJpgLock, pdMS_TO_TICKS(80)) == pdTRUE) {
    if (camJpg && camJpgLen >= 200) {
      copy = (uint8_t*)malloc(camJpgLen);
      if (copy) {
        memcpy(copy, camJpg, camJpgLen);
        len = camJpgLen;
        camJpgTaken = camJpgSeq;
      }
    }
    xSemaphoreGive(camJpgLock);
  }
  if (!copy) {
    char msg[48];
    snprintf(msg, sizeof(msg), "nojpeg %d h=%u p=%u", camState, (unsigned)camHeap, (unsigned)camPsram);
    httpd_resp_set_type(req, "text/plain");
    httpd_resp_send(req, msg, HTTPD_RESP_USE_STRLEN);
    return ESP_OK;
  }
  httpd_resp_set_type(req, "image/jpeg");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  httpd_resp_set_hdr(req, "Cache-Control", "no-store");
  esp_err_t r = httpd_resp_send(req, (const char*)copy, len);
  free(copy);
  jpgServed++;
  lastJpgBytes = (uint32_t)len;
  return r;
}

static uint8_t* streamCopy = NULL;
static size_t streamCopyCap = 0;

static esp_err_t stream_handler(httpd_req_t* req) {
  httpd_resp_set_type(req, STREAM_TYPE);
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  httpd_resp_set_hdr(req, "Cache-Control", "no-store");
  int sock = httpd_req_to_sockfd(req);
  if (sock >= 0) {
    int one = 1;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  }
  uint32_t seen = 0;
  char hdr[80];
  while (true) {
    int fd = httpd_req_to_sockfd(req);
    if (fd >= 0) {
      fd_set fds;
      FD_ZERO(&fds);
      FD_SET(fd, &fds);
      struct timeval tv = {0, 0};
      if (select(fd + 1, &fds, NULL, NULL, &tv) > 0) {
        char peek;
        if (recv(fd, &peek, 1, MSG_DONTWAIT) == 0) break;
      }
    } else break;
    uint8_t* copy = NULL;
    size_t len = 0;
    if (camJpgLock && xSemaphoreTake(camJpgLock, pdMS_TO_TICKS(15)) == pdTRUE) {
      if (camJpg && camJpgLen >= 200 && camJpgSeq != seen) {
        if (!streamCopy || streamCopyCap < camJpgLen) {
          if (streamCopy) free(streamCopy);
          streamCopy = (uint8_t*)heap_caps_malloc(camJpgLen, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
          if (!streamCopy) streamCopy = (uint8_t*)malloc(camJpgLen);
          streamCopyCap = streamCopy ? camJpgLen : 0;
        }
        if (streamCopy) {
          memcpy(streamCopy, camJpg, camJpgLen);
          copy = streamCopy;
          len = camJpgLen;
          seen = camJpgSeq;
          camJpgTaken = seen;
        }
      }
      xSemaphoreGive(camJpgLock);
    }
    if (!copy) {
      vTaskDelay(pdMS_TO_TICKS(1));
      continue;
    }
    int n = snprintf(hdr, sizeof(hdr), STREAM_P, (unsigned)len);
    esp_err_t err = httpd_resp_send_chunk(req, STREAM_B, strlen(STREAM_B));
    if (err == ESP_OK) err = httpd_resp_send_chunk(req, hdr, n);
    if (err == ESP_OK) err = httpd_resp_send_chunk(req, (const char*)copy, len);
    if (err != ESP_OK) break;
  }
  httpd_resp_send_chunk(req, NULL, 0);
  return ESP_OK;
}

static esp_err_t servo_handler(httpd_req_t* req) {
#if EGG_DEVKIT
  rejectSweep(true);
#endif
  httpd_resp_set_type(req, "text/plain");
  return httpd_resp_send(req, "SERVO", HTTPD_RESP_USE_STRLEN);
}

void startHttp() {
  httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
  cfg.server_port = 81;
  cfg.ctrl_port = 32769;
  cfg.stack_size = 10240;
  // The live video keeps this server. Snapshots use port 82 so a grab
  // cannot freeze the picture while an egg is moving.
  cfg.max_open_sockets = 3;
  cfg.lru_purge_enable = true;
  cfg.recv_wait_timeout = 3;
  cfg.send_wait_timeout = 3;
  if (httpd_start(&httpd, &cfg) != ESP_OK) return;
  httpd_uri_t a = {.uri = "/", .method = HTTP_GET, .handler = index_handler, .user_ctx = NULL};
  httpd_uri_t c = {.uri = "/mjpeg", .method = HTTP_GET, .handler = stream_handler, .user_ctx = NULL};
  httpd_uri_t e = {.uri = "/stream", .method = HTTP_GET, .handler = index_handler, .user_ctx = NULL};
  httpd_uri_t d = {.uri = "/servo", .method = HTTP_GET, .handler = servo_handler, .user_ctx = NULL};
  httpd_register_uri_handler(httpd, &a);
  httpd_register_uri_handler(httpd, &c);
  httpd_register_uri_handler(httpd, &d);
  httpd_register_uri_handler(httpd, &e);

  httpd_handle_t snaps = NULL;
  httpd_config_t snap = HTTPD_DEFAULT_CONFIG();
  snap.server_port = 82;
  snap.ctrl_port = 32770;
  snap.stack_size = 8192;
  snap.max_open_sockets = 2;
  snap.lru_purge_enable = true;
  snap.recv_wait_timeout = 2;
  snap.send_wait_timeout = 2;
  httpd_uri_t b = {.uri = "/jpg", .method = HTTP_GET, .handler = jpg_handler, .user_ctx = NULL};
  if (httpd_start(&snaps, &snap) == ESP_OK) {
    httpd_register_uri_handler(snaps, &b);
  } else {
    httpd_register_uri_handler(httpd, &b);
  }
  Serial.println("HTTP :81 stream  :82 /jpg");
}

void applyCameraZoom(sensor_t* s) {
  camZoom = 1.0f;
  if (!s) return;
  if (s->set_quality) s->set_quality(s, CAM_JPEG_QUALITY);
  // OV2640 PCLK divider only â€” GC2145 (PID 0x2145) has no set_res_raw; writing
  // 0xD3 then bouncing SVGAâ†”QVGA killed SCCB and crashed (LoadProhibited).
  if (s->set_res_raw && s->set_reg) s->set_reg(s, 0xD3, 0xFF, 10);
  if (s->set_framesize) s->set_framesize(s, camLiveSize);
  Serial.printf("Camera FOV %dx%d (before widen)\n",
                resolution[camLiveSize].width, resolution[camLiveSize].height);
}

// After first frame: force widest FOV (user: camera too close / zoomed in).
// Default OV2640 QVGA is a CENTER CROP â€” looks macro. Scale full sensor down instead.
// set_res_raw: startX = sensor MODE (0=UXGA, 1=SVGA, 2=CIF).
static bool widenCameraFov(sensor_t* s) {
  if (!s) {
    Serial.println("Zoom-out: no sensor");
    return false;
  }
  const int ow = resolution[camLiveSize].width;
  const int oh = resolution[camLiveSize].height;
  if (!s->set_res_raw) {
    // Do NOT bounce SVGAâ†”QVGA â€” that reboot-looped GC2145 clones.
    Serial.println("Zoom-out skipped (no set_res_raw) â€” keep stable QVGA");
    camZoom = 1.0f;
    return false;
  }
  // Try several full-sensor windows (widest first). scale_h/v = bin/scale to output size.
  struct {
    int mode;
    int rw, rh;
    const char* name;
    float zoom;
  } opts[] = {
    {0, 1600, 1200, "UXGA", 0.50f},
    {0, 1280, 960, "SXGA-ish", 0.58f},
    {1, 800, 600, "SVGA", 0.70f},
    {1, 800, 600, "SVGA-nobin", 0.70f},
  };
  for (size_t i = 0; i < sizeof(opts) / sizeof(opts[0]); i++) {
    bool scale = (i != 3);
    int r = s->set_res_raw(s, opts[i].mode, 0, 0, 0, 0, 0,
                           opts[i].rw, opts[i].rh, ow, oh, scale, scale);
    if (r == 0) {
      delay(160);
      Serial.printf("Camera ZOOM-OUT OK (%s %dx%d â†’ %dx%d)\n",
                    opts[i].name, opts[i].rw, opts[i].rh, ow, oh);
      camZoom = opts[i].zoom;
      return true;
    }
    Serial.printf("Zoom-out %s failed (%d)\n", opts[i].name, r);
  }
  Serial.println("Zoom-out ALL failed â€” view may stay close (center crop)");
  return false;
}

static void camPowerCycle() {
  pinMode(PWDN_GPIO_NUM, OUTPUT);
  digitalWrite(PWDN_GPIO_NUM, HIGH);
  delay(20);
  digitalWrite(PWDN_GPIO_NUM, LOW);
  delay(80);
}

static void camFillPins(camera_config_t* cfg) {
  *cfg = {};
  cfg->ledc_channel = LEDC_CHANNEL_0;
  cfg->ledc_timer = LEDC_TIMER_0;
  cfg->pin_d0 = Y2_GPIO_NUM;
  cfg->pin_d1 = Y3_GPIO_NUM;
  cfg->pin_d2 = Y4_GPIO_NUM;
  cfg->pin_d3 = Y5_GPIO_NUM;
  cfg->pin_d4 = Y6_GPIO_NUM;
  cfg->pin_d5 = Y7_GPIO_NUM;
  cfg->pin_d6 = Y8_GPIO_NUM;
  cfg->pin_d7 = Y9_GPIO_NUM;
  cfg->pin_xclk = XCLK_GPIO_NUM;
  cfg->pin_pclk = PCLK_GPIO_NUM;
  cfg->pin_vsync = VSYNC_GPIO_NUM;
  cfg->pin_href = HREF_GPIO_NUM;
  cfg->pin_sccb_sda = SIOD_GPIO_NUM;
  cfg->pin_sccb_scl = SIOC_GPIO_NUM;
  cfg->pin_pwdn = PWDN_GPIO_NUM;
  cfg->pin_reset = RESET_GPIO_NUM;
  cfg->xclk_freq_hz = camXclkHz ? camXclkHz : CAM_XCLK_HZ;
  cfg->jpeg_quality = CAM_JPEG_QUALITY;
  cfg->grab_mode = CAMERA_GRAB_LATEST;
}

static void camSafeDeinit() {
  camReiniting = true;
  delay(40);  // let camPublishTask drop any in-flight fb_get
  esp_camera_deinit();
  delay(120);
}

static void camTuneSensor(sensor_t* s) {
  if (!s) return;
  s->set_framesize(s, camLiveSize);
  if (s->set_quality) s->set_quality(s, CAM_JPEG_QUALITY);
  // Mild processing â€” keep shell/crack edges; avoid heavy smooth that hides defects.
  s->set_brightness(s, 0);
  s->set_contrast(s, 1);
  s->set_saturation(s, 0);
  s->set_sharpness(s, 1);
  s->set_whitebal(s, 1);
  s->set_awb_gain(s, 1);
  s->set_exposure_ctrl(s, 1);
  s->set_aec2(s, 1);
  // Slightly shorter exposure when light allows â†’ less blur if hand/camera shakes.
  // Cannot remove physical shake; add light / mount the camera for best results.
  s->set_ae_level(s, -1);
  s->set_gain_ctrl(s, 1);
  s->set_agc_gain(s, 0);
  s->set_gainceiling(s, (gainceiling_t)GAINCEILING_4X);
  s->set_bpc(s, 1);
  s->set_wpc(s, 1);
  s->set_raw_gma(s, 1);
  s->set_lenc(s, 1);
  s->set_dcw(s, 1);
  s->set_colorbar(s, 0);
  s->set_hmirror(s, 0);
  s->set_vflip(s, 0);
  applyCameraZoom(s);
}

bool initCamera(bool force = false) {
  if (camInitBusy) {
    Serial.println("Camera init already running â€” skip nested call");
    return false;
  }
  if (camInitStarted && !force) {
    Serial.println("Camera already started");
    return cameraOn;
  }
  camInitBusy = true;
  if (force) {
    Serial.println("Camera force re-initâ€¦");
    camSafeDeinit();
    camInitStarted = false;
    cameraOn = false;
    camJpgOkAt = 0;
  }
  camReiniting = true;
  // camInitBusy cleared on every exit path below.
  // Board must be "AI Thinker ESP32-CAM" with PSRAM Enabled â€” "ESP32 Dev Module"
  // leaves PSRAM off. DRAM JPEG still works without PSRAM IF the OV2640 probes.
  psramInit();
  delay(50);
  size_t psramBytes = ESP.getPsramSize();
  bool havePsram = psramFound() && psramBytes >= 1024UL * 1024UL;
  Serial.printf("PSRAM: found=%d size=%u heap=%u free=%u\n",
                (int)psramFound(), (unsigned)psramBytes,
                (unsigned)ESP.getHeapSize(), (unsigned)ESP.getFreeHeap());
  if (!havePsram) {
    Serial.println("*** PSRAM missing/disabled ***");
    Serial.println("Arduino IDE â†’ Tools: Board=AI Thinker ESP32-CAM | PSRAM=Enabled");
    Serial.println("Port: CAM USB (not DevKit). Still trying JPEG-in-DRAMâ€¦");
  }

  // Prefer YUV (software JPEG via frame2jpg). Hardware JPEG only if sensor allows it.
  // Log "JPEG format is not supported on this sensor" â‰  dead ribbon â€” try YUV/RGB next.
  struct CamTry {
    pixformat_t fmt;
    framesize_t size;
    camera_fb_location_t loc;
    const char* tag;
  };
  // XCLK: 20 MHz first, then 10 MHz (helps many clone modules).
  const uint32_t xclkList[] = {CAM_XCLK_HZ, 10000000UL};
  const int nXclk = 2;
  camSensorUnsupported = false;
  bool sawJpegRejected = false;
  bool sawProbeFail = false;

  for (int xi = 0; xi < nXclk; xi++) {
    camXclkHz = xclkList[xi];
    Serial.printf("Camera XCLK=%u Hz\n", (unsigned)camXclkHz);

    CamTry tries[14];
    int nTry = 0;
    // This board rejects HW JPEG (PID often 0x2145 / GC2145). Prefer YUV first so
    // we do not power-cycle the sensor twice before a working mode.
    // HQVGA first (sharp enough). QVGA fallback. QQVGA last (too soft on Watch).
    if (havePsram) {
      if (!camSkipHwJpeg) {
        tries[nTry++] = {PIXFORMAT_JPEG, FRAMESIZE_HQVGA, CAMERA_FB_IN_PSRAM, "JPEG-HQVGA-PSRAM"};
        tries[nTry++] = {PIXFORMAT_JPEG, FRAMESIZE_QVGA, CAMERA_FB_IN_PSRAM, "JPEG-QVGA-PSRAM"};
      }
      tries[nTry++] = {PIXFORMAT_YUV422, FRAMESIZE_HQVGA, CAMERA_FB_IN_PSRAM, "YUV-HQVGA-PSRAM"};
      tries[nTry++] = {PIXFORMAT_YUV422, FRAMESIZE_QVGA, CAMERA_FB_IN_PSRAM, "YUV-QVGA-PSRAM"};
      tries[nTry++] = {PIXFORMAT_YUV422, FRAMESIZE_QQVGA, CAMERA_FB_IN_PSRAM, "YUV-QQVGA-PSRAM"};
    }
    if (!camSkipHwJpeg) {
      tries[nTry++] = {PIXFORMAT_JPEG, FRAMESIZE_HQVGA, CAMERA_FB_IN_DRAM, "JPEG-HQVGA-DRAM"};
      tries[nTry++] = {PIXFORMAT_JPEG, FRAMESIZE_QVGA, CAMERA_FB_IN_DRAM, "JPEG-QVGA-DRAM"};
    }
    tries[nTry++] = {PIXFORMAT_YUV422, FRAMESIZE_HQVGA, CAMERA_FB_IN_DRAM, "YUV-HQVGA-DRAM"};
    tries[nTry++] = {PIXFORMAT_YUV422, FRAMESIZE_QVGA, CAMERA_FB_IN_DRAM, "YUV-QVGA-DRAM"};
    tries[nTry++] = {PIXFORMAT_RGB565, FRAMESIZE_HQVGA, CAMERA_FB_IN_DRAM, "RGB-HQVGA-DRAM"};

    for (int ti = 0; ti < nTry; ti++) {
      camLiveSize = tries[ti].size;
      camSafeDeinit();
      camPowerCycle();

      camera_config_t cfg;
      camFillPins(&cfg);
      cfg.pixel_format = tries[ti].fmt;
      cfg.frame_size = tries[ti].size;
      // Dual buffers + GRAB_LATEST = always the newest frame when the egg moves.
      // One FB in tunnel/DRAM-tight builds â€” dual buffers + TLS starve internal heap.
      cfg.fb_count = 1;
      cfg.fb_location = tries[ti].loc;
      cfg.grab_mode = CAMERA_GRAB_LATEST;
      if (tries[ti].fmt == PIXFORMAT_JPEG) {
        cfg.jpeg_quality = CAM_JPEG_QUALITY;
      }

      esp_err_t err = esp_camera_init(&cfg);
      if (err != ESP_OK) {
        Serial.printf("cam %s fail (%s)\n", tries[ti].tag, esp_err_to_name(err));
        camSafeDeinit();
        if (err == ESP_ERR_NOT_SUPPORTED) {
          if (tries[ti].fmt == PIXFORMAT_JPEG) {
            sawJpegRejected = true;
            camSkipHwJpeg = true;
            Serial.println("JPEG rejected by sensor â€” trying YUV/RGB (not a dead ribbon yet)");
          } else {
            sawProbeFail = true;
            camSensorUnsupported = true;
          }
          // Do NOT break â€” JPEG-not-supported and probe-fail share 0x106; try next format.
        }
        continue;
      }

      digitalWrite(PWDN_GPIO_NUM, LOW);
      sensor_t* s = esp_camera_sensor_get();
      if (s) {
        Serial.printf("Sensor PID=0x%04x VER=0x%02x (%s)\n",
                      (unsigned)s->id.PID, (unsigned)s->id.VER, tries[ti].tag);
        // GC2145 clones report 0x2145 and never support HW JPEG.
        if (s->id.PID == 0x2145 || s->id.PID == 0x2155) camSkipHwJpeg = true;
      }
      camTuneSensor(s);
      Serial.printf("Camera init %s â€” waiting for frameâ€¦\n", tries[ti].tag);

      camera_fb_t* test = NULL;
      for (int attempt = 0; attempt < 8 && !test; attempt++) {
        delay(attempt == 0 ? 250 : 120);
        test = esp_camera_fb_get();
      }
      if (!test) {
        Serial.printf("No first frame (%s) â€” next mode\n", tries[ti].tag);
        camSafeDeinit();
        continue;
      }
      Serial.printf("First frame %dx%d fmt=%u len=%u (%s)\n",
                    test->width, test->height, (unsigned)test->format,
                    (unsigned)test->len, tries[ti].tag);
      esp_camera_fb_return(test);
      // Widen only when OV2640 set_res_raw exists. Never SVGA-bounce GC2145.
      if (s && s->set_res_raw) {
        widenCameraFov(s);
        if (s->set_framesize) s->set_framesize(s, camLiveSize);
        if (s->set_quality) s->set_quality(s, CAM_JPEG_QUALITY);
        delay(120);
        camera_fb_t* check = esp_camera_fb_get();
        if (!check || !check->buf || check->len < 200) {
          if (check) esp_camera_fb_return(check);
          Serial.println("Zoom-out killed frames â€” keep plain QVGA (no SVGA bounce)");
          camZoom = 1.0f;
          check = esp_camera_fb_get();
        }
        if (!check || !check->buf || check->len < 200) {
          if (check) esp_camera_fb_return(check);
          Serial.printf("Post-init frame dead (%s) â€” next mode\n", tries[ti].tag);
          camSafeDeinit();
          continue;
        }
        Serial.printf("Post-zoom frame %dx%d len=%u\n",
                      check->width, check->height, (unsigned)check->len);
        esp_camera_fb_return(check);
      } else {
        Serial.println("Stable QVGA locked â€” skip zoom (clone sensor)");
        camZoom = 1.0f;
      }
      Serial.printf("Camera OK %s zoom=%.2f xclk=%u\n",
                    tries[ti].tag, camZoom, (unsigned)camXclkHz);
      camJpgOkAt = millis();
      camProbeFailStreak = 0;
      camSensorUnsupported = false;
      camPublishStart();
      camInitStarted = true;
      cameraOn = true;
      camReiniting = false;
      camHaveRecipe = true;
      camRecipeFmt = tries[ti].fmt;
      camRecipeSize = tries[ti].size;
      camRecipeLoc = tries[ti].loc;
      camRecipeXclk = camXclkHz;

      camInitBusy = false;
      camPwmLive = false;
#if EGG_DEVKIT
      servoReattach();
#endif
      return true;
    }
  }

  camXclkHz = CAM_XCLK_HZ;
  if (camProbeFailStreak < 250) camProbeFailStreak++;
  Serial.println("Camera FAIL â€” no working mode (will retry slowly)");
  if (sawJpegRejected && !sawProbeFail) {
    Serial.println("Sensor answered but JPEG mode refused â€” YUV/RGB DRAM also failed.");
    Serial.println("Enable PSRAM (Tools) or check 5V / FPC seating.");
  } else if (camSensorUnsupported || sawProbeFail) {
    Serial.println("Sensor probe failed. Check:");
    Serial.println("  1) FPC ribbon fully seated (contacts toward board)");
    Serial.println("  2) CAM 5V+G from expansion (not 3V3 alone)");
    Serial.println("  3) Tools: AI Thinker ESP32-CAM + PSRAM Enabled, flash CAM USB");
  } else if (!havePsram) {
    Serial.println("Also: Board=AI Thinker ESP32-CAM | PSRAM=Enabled | USB=CAM");
  }
  camInitStarted = false;
  cameraOn = false;
  camReiniting = false;
  camInitBusy = false;
  return false;
}

#if !EGG_DEVKIT
// Fast re-open after tunnel TLS pause — skips probe/power-cycle matrix.
static bool initCameraQuick() {
  if (!camHaveRecipe) return initCamera(true);
  if (camInitBusy) return false;
  camInitBusy = true;
  camReiniting = true;
  camSafeDeinit();
  camXclkHz = camRecipeXclk;
  camera_config_t cfg;
  camFillPins(&cfg);
  cfg.pixel_format = camRecipeFmt;
  cfg.frame_size = camRecipeSize;
  cfg.fb_count = 1;
  cfg.fb_location = camRecipeLoc;
  cfg.grab_mode = CAMERA_GRAB_LATEST;
  if (camRecipeFmt == PIXFORMAT_JPEG) cfg.jpeg_quality = CAM_JPEG_QUALITY;
  esp_err_t err = esp_camera_init(&cfg);
  if (err != ESP_OK) {
    Serial.printf("quick cam fail (%s) — full re-init\n", esp_err_to_name(err));
    camInitBusy = false;
    camReiniting = false;
    return initCamera(true);
  }
  digitalWrite(PWDN_GPIO_NUM, LOW);
  sensor_t* s = esp_camera_sensor_get();
  camTuneSensor(s);
  camera_fb_t* test = NULL;
  for (int i = 0; i < 8 && !test; i++) {
    delay(i == 0 ? 200 : 80);
    test = esp_camera_fb_get();
  }
  if (!test) {
    Serial.println("quick cam no frame — full re-init");
    camSafeDeinit();
    camInitBusy = false;
    camReiniting = false;
    return initCamera(true);
  }
  esp_camera_fb_return(test);
  cameraOn = true;
  camInitStarted = true;
  camInitBusy = false;
  camReiniting = false;
  camJpgOkAt = millis();
  camProbeFailStreak = 0;
  return true;
}

// Keep CAM online forever: Wiâ€‘Fi reconnect, laptop URL restore, JPEG/camera revive.
void serviceCamKeepAlive() {
  // 1) Wiâ€‘Fi â€” reconnect fast, rotate SSIDs, never give up.
  if (WiFi.status() == WL_CONNECTED) {
    if (wifiLostAt != 0) {
      wifiReconnectCount++;
      Serial.printf("WiFi RECOVERED rssi=%d reconnects=%u\n",
                    (int)WiFi.RSSI(), (unsigned)wifiReconnectCount);
    }
    wifiLostAt = 0;
    wifiSwitching = false;
  } else {
    if (wifiLostAt == 0) {
      wifiLostAt = millis();
      wifiDisconnectCount++;
      Serial.printf("WiFi LOST rssi=%d disconnects=%u â€” will retry\n",
                    (int)WiFi.RSSI(), (unsigned)wifiDisconnectCount);
    }
    unsigned long lostMs = millis() - wifiLostAt;
    if (millis() - lastWifiKickAt >= 3000UL) {
      lastWifiKickAt = millis();
      Serial.printf("WiFi DOWN %lus â€” reconnect (always-on)\n", lostMs / 1000UL);
      wifiSwitching = true;
      connectSavedWifi();
    }
    // Hard radio bounce if stuck offline > 45s.
    if (lostMs > 45000UL && millis() - lastWifiKickAt >= 2000UL) {
      Serial.println("WiFi stuck â€” radio bounce");
      WiFi.disconnect(true, false);
      delay(150);
      WiFi.mode(WIFI_OFF);
      delay(200);
      WiFi.mode(WIFI_STA);
      WiFi.setSleep(false);
      connectSavedWifi();
      wifiLostAt = millis();
    }
  }

  // 2) Laptop URL â€” never yank tunnel back to LAN (extender isolation).
  // Tunnel sticky until reboot. Optional rare LAN probe only if not on HTTPS.
  if (WiFi.status() == WL_CONNECTED && !farmBackendIsHttps() && hbFails >= 3 &&
      strlen(FARM_BACKEND_URL) > 0) {
    static unsigned long lastUrlFix = 0;
    if (millis() - lastUrlFix >= 20000UL) {
      lastUrlFix = millis();
      farmUseTunnel("keep-alive HB fails");
    }
  }

  // 3) Camera sensor â€” must produce JPEG or /watch stays blank forever.
  // Fast 8s re-init storms (esp. 0x106) fragment the heap â†’ lwIP pbuf_free assert.
  // Never nest force re-init while camboot/initCamera is still running (crash loop).
  static unsigned long jpgZeroSince = 0;
  if (camInitBusy || camReiniting) {
    return;
  }
  if (!cameraOn) {
    // Tunnel: push task pauses sensor for TLS and reinits — do NOT race it here.
    if (farmBackendIsHttps() &&
        (camTlsBusy || (millis() - camPausedForTlsAt) < 6000UL)) {
      return;
    }
    // Tunnel live push pauses sensor often — reinit fast, not 15s+.
    unsigned long gapMs = farmBackendIsHttps() ? 800UL : 15000UL;
    if (!farmBackendIsHttps()) {
      if (camProbeFailStreak >= 6) gapMs = 180000UL;
      else if (camProbeFailStreak >= 4) gapMs = 90000UL;
      else if (camProbeFailStreak >= 2) gapMs = 45000UL;
    } else if (camProbeFailStreak >= 4) {
      gapMs = 3000UL;
    }
    if (camSensorUnsupported && camProbeFailStreak >= 2) {
      if (gapMs < 60000UL) gapMs = 60000UL;
    }
    if (camReinitAt == 0) camReinitAt = millis() + (farmBackendIsHttps() ? 1500UL : 20000UL);
    if ((long)(millis() - camReinitAt) >= 0) {
      camReinitAt = millis() + gapMs;
      Serial.printf("Camera offline â€” re-init (streak=%u next=%lus)\n",
                    (unsigned)camProbeFailStreak, gapMs / 1000UL);
      bool okCam = farmBackendIsHttps() ? initCameraQuick() : initCamera(true);
      if (okCam) {
        Serial.println("Camera back ONLINE");
      }
    }
  } else if (camJpgLen < 200) {
    if (jpgZeroSince == 0) jpgZeroSince = millis();
    if (millis() - jpgZeroSince > 8000UL) {
      jpgZeroSince = millis();
      Serial.println("jpg=0 for 8s â€” force camera re-init (no picture otherwise)");
      if (!initCamera(true)) {
        // Do not ESP.restart() on probe fail â€” that caused reboot loops + pbuf assert.
        Serial.println("Re-init failed â€” keep Wiâ€‘Fi, retry later");
        camReinitAt = millis() + 30000UL;
      }
    }
  } else if (camTlsBusy) {
    // Encode pauses during HTTPS â€” do not treat that as a dead camera.
    jpgZeroSince = 0;
    if (camJpgOkAt > 0) camJpgOkAt = millis();
  } else if (camJpgOkAt > 0 && millis() - camJpgOkAt > 20000UL) {
    jpgZeroSince = 0;
    Serial.println("JPEG stall 20s â€” re-init camera");
    if (!initCamera(true)) {
      Serial.println("Re-init failed â€” keep Wiâ€‘Fi, retry later");
      camReinitAt = millis() + 30000UL;
    }
  } else if (camJpgOkAt > 0 && millis() - camJpgOkAt > 10000UL) {
    jpgZeroSince = 0;
    camPublishStart();
  } else {
    jpgZeroSince = 0;  // healthy encode â€” next jpg=0 stall waits a full 8s
  }
}
#endif

static void camBootTask(void*) {
  cameraOn = initCamera();
  vTaskDelete(NULL);
}

void applyBackend(const char* base) {
  if (!base || !base[0]) return;
  if (strcmp(activeBackend, base) == 0 && urlStatus.length()) return;
  strncpy(activeBackend, base, sizeof(activeBackend) - 1);
  activeBackend[sizeof(activeBackend) - 1] = 0;
  urlStatus = String(activeBackend) + "/api/status";
  urlFrame = String(activeBackend) + "/api/frame";
  urlFrameAlt = String(activeBackend) + "/frame";
  urlInspect = String(activeBackend) + "/api/inspect";
  urlWeight = String(activeBackend) + "/weight";
  Serial.printf("Laptop backend %s\n", activeBackend);
}

void refreshStreamUrl() {
  IPAddress ip = cameraAp ? WiFi.softAPIP() : WiFi.localIP();
  streamUrl = String("http://") + ip.toString() + ":81/mjpeg";
}

bool probeLaptop(const IPAddress& ip) {
  // Extender needs a longer TCP probe than 120â€“900 ms.
  if (!takeHttpOut(50)) return false;
  WiFiClient cli;
  bool ok = false;
  for (int i = 0; i < 3 && !ok; i++) {
    if (i) delay(80);
    ok = cli.connect(ip, 8000, 2000);
  }
  if (ok) cli.stop();
  giveHttpOut();
  return ok;
}

void startLaptopSearch() {
  if (cameraAp || WiFi.status() != WL_CONNECTED) return;
  findOctet = 2;
  Serial.printf("Looking for the laptop on WiFi %s\n", WiFi.SSID().c_str());
}

// Extender names end in -ext and often hide the laptop. The router name is the same without -ext.
bool mainWifiName(char* out, size_t n) {
  const char* s = WIFI_SSID;
  size_t len = strlen(s);
  if (len < 5 || strcmp(s + len - 4, "-ext") != 0 || n <= len - 4) return false;
  memcpy(out, s, len - 4);
  out[len - 4] = 0;
  return true;
}

void beginMainWifi() {
  // Disabled: auto-roam off a working extender caused wifi=6 / rssi=0 dropouts.
  // Keep STA on secrets.h WIFI_SSID. Switch SSID only by reflashing secrets.
  (void)triedMainWifi;
  Serial.println("Stay on current WiFi (auto main-router roam disabled)");
}

void findLaptopStep() {
  // Tunnel mode is intentional on isolated extenders â€” do not sweep back to LAN.
  if (farmBackendIsHttps()) return;
  if (laptopSweepDone || cameraAp || wifiSwitching || WiFi.status() != WL_CONNECTED) return;
  if (findOctet < 2) {
    // With a fixed secrets.h URL, keep using it â€” IP sweep races heartbeat â†’ http=-1.
    if (hbFails >= 2 && millis() >= findPauseUntil) {
      if (strlen(FARM_PUBLIC_URL) > 0) {
        farmUseTunnel("findLaptop HB fails");
        findPauseUntil = millis() + 30000UL;
      } else if (strlen(FARM_BACKEND_URL) > 0) {
        applyBackend(FARM_BACKEND_URL);
        findPauseUntil = millis() + 15000UL;
      } else {
        startLaptopSearch();
      }
    }
    return;
  }
  IPAddress me = WiFi.localIP();
  IPAddress gw = WiFi.gatewayIP();
  int mine = (int)me[3];
  int gate = (int)gw[3];
  while (findOctet == mine || findOctet == gate) findOctet++;
  if (findOctet > 254) {
    // Keep using secrets.h URL even if the TCP probe raced Wiâ€‘Fi startup.
    if (strlen(FARM_BACKEND_URL) > 0) {
      applyBackend(FARM_BACKEND_URL);
      Serial.println("Using saved laptop URL â€” keep backend open on :8000");
    } else if (hbFails == 0 && strlen(activeBackend) > 0) {
      Serial.println("Laptop OK (saved backend) â€” skip WiFi sweep");
    } else {
      Serial.println("Laptop not on this WiFi.");
    }
    laptopSweepDone = true;
    findOctet = 0;
    return;
  }
  IPAddress ip(me[0], me[1], me[2], (uint8_t)findOctet);
  findOctet++;
  if (!probeLaptop(ip)) return;
  char url[40];
  snprintf(url, sizeof(url), "http://%u.%u.%u.%u:8000", ip[0], ip[1], ip[2], ip[3]);
  applyBackend(url);
  findOctet = 0;
  laptopSweepDone = true;
  hbFails = 0;
#if !SERIAL_WEIGHT_ONLY
  Serial.println("Laptop found");
#endif
}

void goOnline() {
  if (stationOn) return;
  stationOn = true;

#if EGG_DEVKIT
  cameraOn = false;
  loadFactor();
  if (factor < FACTOR_MIN || factor > FACTOR_MAX) {
    factor = FACTOR_DEFAULT;
    saveFactor();
  }
  bool cellOk = openLoadCell();
  scale.set_scale(factor);
  servoRestart();
  servoWriteUs(ENTRANCE_PIN, ENTRANCE_HOLD_US);
  servoWriteUs(SERVO_CAM_PIN, GATE_CENTER_US);
  servoWriteUs(SERVO_SIZE_PIN, PUSH_HOME_US);
  servoWriteUs(SERVO_REJECT_PIN, SORT_MEDIUM_US);
  entranceAt = millis();
  entranceOpen = false;
  gateAngle = 0;
  camGateDown = true;
  beltOn = false;
  stopBelt();
  gateAngle = 0;
  gateLatchedSide = 0;
  needIdlePrint = false;
  announceEggRemoved = false;
  eggSession = false;
  eggSeenHits = 0;
#if GATE_FROM_FARM
  awaitNextEgg = true;
#else
  awaitNextEgg = false;
#endif
  mustSeeEmpty = false;
  clearSinceAt = 0;
  eggResultPrinted = false;
  weightShown = false;
  idleShownOk = false;
  sessionDone = false;
  weighCooldownUntil = millis() + 800UL;
  eggCount = 0;
  settleN = 0;
  lastAutoZeroAt = millis();
  // Skip early boot tare (HX711 still ringing after servo power-up â†’ span 2000+).
  // Component check first, then one solid tare on quiet wood.
  delay(300);
  bool hxOk = cellOk;
#if GATE_FROM_FARM
  applyBackend(FARM_BACKEND_URL);
  if (WiFi.status() != WL_CONNECTED) connectSavedWifi();
  WiFi.setSleep(false);  // modem sleep + soft-PWM = DevKit HB http=-1 forever
#endif
  delay(200);
  // Park horns, one short tare (triple tare was slow and killed ENTRANCE).
  bootComponentCheck(false);
  delay(800);  // let cell settle after park demo
  bool tare2 = tareMedianNow("boot");
  hxOk = tare2 && haveIdle;
  if (tare2) {
    saveFactor();
    Serial.printf("[OK]   HX711 idle=%ld factor=%.2f tareSpan=%ld%s\n",
                  idleAdc, factor, lastTareSpan, tareSuspect ? " WEAK" : "");
    if (tareSuspect || lastTareSpan > 120) {
      Serial.println("*** Optional: empty pad, type t, then c50 ***");
    }
  } else {
    Serial.println("*** HX711 weak â€” empty wood, type t (station still runs) ***");
  }
  // Re-assert ENTRANCE DOWN after tare (LEDC must stay armed).
  entranceServoWrite(ENTRANCE_HOLD_US);
  servoKickDrive();
  Serial.println();
  Serial.println("========== STATION READY ==========");
  Serial.println("1) IR egg passed  -> ENTRANCE P13 DOWN");
  Serial.println("2) Camera scan    -> GATE stays MIDDLE");
  Serial.println("   Clean          -> GATE full LEFT  (hold while egg in view)");
  Serial.println("   Crack/Dirty    -> GATE full RIGHT (hold while egg in view)");
  Serial.println("   Egg leaves cam -> GATE MIDDLE");
  Serial.println("3) Clean on pad -> AUTO weigh -> SORT lane -> PUSH (no typing)");
  Serial.println("   SORT P26: 1=SMALL 2=MEDIUM 3=LARGE 4=JUMBO (by grams)");
  Serial.println("   PUSH P25: only after SORT assigns the lane");
  Serial.println("SORT/PUSH never move from camera â€” only after weigh.");
  Serial.printf("Scale factor=%.4f  | cal optional: empty->t | 50g->c50\n", factor);
#if GATE_FROM_FARM
  Serial.printf("Farm gate URL %s\n", FARM_BACKEND_URL);
  Serial.println("IoT continuous â€” leave Serial Monitor closed if you want");
#endif
  Serial.println("===================================");
  printIdleScale(0);
#else
  IPAddress ip = cameraAp ? WiFi.softAPIP() : WiFi.localIP();
  const char* backend = cameraAp ? "http://192.168.4.2:8000" : FARM_BACKEND_URL;
  applyBackend(backend);
  // Tunnel HTTPS needs DRAM for mbedTLS â€” local :81/:82 httpd would steal it,
  // and the laptop cannot reach CAM LAN ports through extender isolation anyway.
  if (farmBackendIsHttps()) {
    Serial.println("Tunnel mode â€” skip local :81/:82 (save DRAM for TLS)");
    streamUrl = "";
  } else {
    startHttp();
    streamUrl = String("http://") + ip.toString() + ":81/mjpeg";
    Serial.println("Camera view " + streamUrl);
  }
  Serial.print("WiFi ");
  Serial.print(cameraAp ? CAMERA_AP_SSID : WiFi.SSID());
  Serial.print(" IP ");
  Serial.println(ip);
  // HTTPS secrets URL = tunnel direct (skip LAN probe â€” extender isolation).
  if (!cameraAp && WiFi.status() == WL_CONNECTED && strlen(FARM_BACKEND_URL) > 0) {
    if (strncmp(FARM_BACKEND_URL, "https://", 8) == 0) {
      Serial.println("Tunnel direct (secrets) â€” skip LAN probe");
      Serial.println("Keep cloudflared open on laptop â†’ :8000");
      laptopSweepDone = true;
      findOctet = 0;
      lastHb = millis();  // defer HB so first LIVE pushes own TLS
    } else {
      delay(500);
      int a = 0, b = 0, c = 0, d = 0;
      const char* p = strstr(FARM_BACKEND_URL, "://");
      p = p ? p + 3 : FARM_BACKEND_URL;
      bool answered = false;
      if (sscanf(p, "%d.%d.%d.%d", &a, &b, &c, &d) == 4) {
        for (int tryN = 0; tryN < 8 && !answered; tryN++) {
          answered = probeLaptop(IPAddress(a, b, c, d));
          if (!answered) delay(200);
        }
      }
      if (answered) {
        applyBackend(FARM_BACKEND_URL);
        Serial.println("Laptop answered on LAN");
        laptopSweepDone = true;
        findOctet = 0;
        hbFails = 0;
        hbEverOk = true;
      } else {
        Serial.println("LAN quiet at boot — tunnel now, will keep retrying LAN");
        farmUseTunnel("boot probe");
        laptopSweepDone = true;
        findOctet = 0;
      }
    }
  }
#if !EGG_DEVKIT && CAM_PUSH_ENABLE
  // Warm TLS handshake BEFORE camera DMA while DRAM is still contiguous.
  tunnelTlsPrepareEarly();
  if (farmBackendIsHttps() && WiFi.status() == WL_CONNECTED && gTunnelCli) {
    const char* hostStart = strstr(activeBackend, "://");
    hostStart = hostStart ? hostStart + 3 : activeBackend;
    char host[96];
    size_t hi = 0;
    while (hostStart[hi] && hostStart[hi] != '/' && hostStart[hi] != ':' &&
           hi + 1 < sizeof(host)) {
      host[hi] = hostStart[hi];
      hi++;
    }
    host[hi] = 0;
    Serial.printf("TUNNEL warm TLS %s largest_int=%u\n", host,
                  (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));
    tunnelTlsApplyClientOpts(gTunnelCli);
    bool ok = host[0] && gTunnelCli->connect(host, 443, 10000);
    if (ok) {
      // Keep socket open — first live frames reuse this handshake (no cam pause).
      char req[160];
      snprintf(req, sizeof(req),
               "GET /health HTTP/1.1\r\nHost: %s\r\nConnection: keep-alive\r\n\r\n",
               host);
      gTunnelCli->print(req);
      unsigned long t0 = millis();
      while (millis() - t0 < 2500UL) {
        while (gTunnelCli->available()) (void)gTunnelCli->read();
        if (!gTunnelCli->connected()) break;
        delay(1);
      }
      Serial.println("TUNNEL warm TLS OK — keep-alive for live push");
    } else {
      Serial.println("TUNNEL warm TLS fail — will retry in push task");
      gTunnelCli->stop();
    }
  }
  camPushStartEarly();
#endif
  Serial.println("Starting camera (encode separate from tunnel push)â€¦");
  delay(200);
  xTaskCreatePinnedToCore(camBootTask, "camboot", 16384, NULL, 1, NULL, 1);
#endif
}

void loadPrefWifi() {
  havePrefWifi = false;
  prefSsid[0] = 0;
  prefPass[0] = 0;
  if (!prefs.begin("eggwifi", true)) return;
  String ssid = prefs.getString("ssid", "");
  String pass = prefs.getString("pass", "");
  prefs.end();
  if (!ssid.length() || ssid.length() > 32 || pass.length() > 64) return;
  ssid.toCharArray(prefSsid, sizeof(prefSsid));
  pass.toCharArray(prefPass, sizeof(prefPass));
  havePrefWifi = true;
}

// Try saved networks one at a time. A full scan crashes this board.
bool pickWifi(const char** ssid, const char** pass) {
  loadPrefWifi();
  const char* names[4] = {
    havePrefWifi ? prefSsid : "",
    WIFI_SSID,
    WIFI_SSID_2,
    WIFI_SSID_3,
  };
  const char* passes[4] = {
    havePrefWifi ? prefPass : "",
    WIFI_PASSWORD,
    WIFI_PASSWORD_2,
    WIFI_PASSWORD_3,
  };
  for (int n = 0; n < 4; n++) {
    int i = (wifiTry + n) % 4;
    if (!names[i] || !names[i][0]) continue;
    *ssid = names[i];
    *pass = passes[i] ? passes[i] : "";
    wifiTry = (i + 1) % 4;
    return true;
  }
  return false;
}

void connectSavedWifi() {
  const char* ssid = WIFI_SSID;
  const char* pass = WIFI_PASSWORD;
  if (!pickWifi(&ssid, &pass)) {
    ssid = WIFI_SSID;
    pass = WIFI_PASSWORD;
  }
  latchSckLow();
  WiFi.persistent(false);
  WiFi.setAutoReconnect(true);
  WiFi.disconnect(false, false);
  delay(120);
  WiFi.mode(WIFI_STA);
  delay(80);
  WiFi.setSleep(false);  // never modem-sleep â€” keeps CAM reachable
  WiFi.setAutoReconnect(true);
  hxRadioOn = true;
#if !SERIAL_WEIGHT_ONLY
  Serial.printf("Trying WiFi %s\n", ssid);
  Serial.flush();
#endif
  WiFi.begin(ssid, pass);
#if !EGG_DEVKIT
  WiFi.setTxPower(WIFI_POWER_19_5dBm);
#endif
  wifiAt = millis();
}

void setup() {
#if EGG_DEVKIT
  // This DevKit has no PSRAM. Keep large buffers in internal RAM.
  heap_caps_malloc_extmem_enable(0xFFFFFFFF);
#endif
  Serial.begin(115200);
  Serial.setDebugOutput(false);
  Serial.setTimeout(10);
  delay(200);
  Serial.println();
  Serial.println("boot ok");
  // If Monitor still shows LAN 192.168.11.212 first, this new binary was NOT flashed.
  Serial.println("FW 2026-10-30p REALTIME-DETECT");
  Serial.printf("secrets backend %s (realtime egg detect)\n", FARM_BACKEND_URL);
  eggEnableTlsPsram();
#if EGG_DEVKIT
  Serial.println("DevKit STATION â€” GATE from camera, SORT/PUSH from weight");
  Serial.println("IoT: camera Clean â†’ auto weigh on pad (no IDE typing)");
  Serial.println("Cal optional: t (empty) â†’ c50 (50g) | manual: egg");
  Serial.println("Also: all=servos | sim55=fake weight | help");
  Serial.println("pins P13 entr P14 gate P25 push P26 sort P19 IR P32/33 HX711");
#elif !SERIAL_WEIGHT_ONLY
  Serial.println("Serial 115200 â€” set Monitor baud to 115200");
  Serial.println("Serial LIVE â€” put egg on wood (optional: t | c50 | help)");
#endif
  Serial.flush();
#if EGG_DEVKIT
  holdSckLow();
  pinMode(MOTOR_PIN, OUTPUT);
  pinMode(MOTOR_IN2_PIN, OUTPUT);
  digitalWrite(MOTOR_PIN, LOW);
  digitalWrite(MOTOR_IN2_PIN, LOW);
  pinMode(HX711_DT, INPUT_PULLUP);
  pinMode(IR_PIN, INPUT_PULLUP);
  learnIrIdle();
#if !SERIAL_WEIGHT_ONLY
  Serial.println("POWER: LM2596 5V servos | expansion 5V = camera | 3V3 = HX711+IR");
#endif
  hxGain = 128;
  hxArm(HX711_DT, HX711_SCK);
  delay(300);
  for (int i = 0; i < 4; i++) {
    long quiet = 0;
    if (hxReadOnce(&quiet)) {
#if !SERIAL_WEIGHT_ONLY
      Serial.printf("HX711 quiet raw %ld\n", quiet);
#endif
    }
#if !SERIAL_WEIGHT_ONLY
    else Serial.println("HX711 quiet not ready");
#endif
  }
#else
  WRITE_PERI_REG(RTC_CNTL_BROWN_OUT_REG, 0);
  Serial.println("ESP32-CAM picture only â€” expansion 5V+G, same Wi-Fi as laptop");
#endif
#if !SERIAL_WEIGHT_ONLY
  Serial.printf("heap %u\n", (unsigned)ESP.getFreeHeap());
#endif
  Serial.flush();
  esp_err_t nvsErr = nvs_flash_init();
  if (nvsErr == ESP_ERR_NVS_NO_FREE_PAGES || nvsErr == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    nvs_flash_erase();
    nvs_flash_init();
  }
#if ARDUINO_LOCAL && !GATE_FROM_FARM
  WiFi.persistent(false);
  WiFi.disconnect(true, true);
  WiFi.mode(WIFI_OFF);
  hxRadioOn = false;
  Serial.println("Arduino-only");
#else
  // DevKit+GATE_FROM_FARM or ESP32-CAM: join WiFi for farm / stream.
  if (CAMERA_AP && !EGG_DEVKIT) {
    cameraAp = true;
    WiFi.mode(WIFI_AP);
    WiFi.softAPConfig(IPAddress(192, 168, 4, 1), IPAddress(192, 168, 4, 1), IPAddress(255, 255, 255, 0));
    WiFi.softAP(CAMERA_AP_SSID, CAMERA_AP_PASS, 6, 0, 2);
#if !SERIAL_WEIGHT_ONLY
    Serial.println("Camera WiFi EggStation is on (extender not used)");
#endif
  } else {
    connectSavedWifi();
#if EGG_DEVKIT
    Serial.println("WiFi on â€” GATE follows farm camera (clean/crack/middle)");
#else
#if !SERIAL_WEIGHT_ONLY
    Serial.println("If this name is missing, the next saved WiFi is tried in 15s");
#endif
#endif
  }
  wifiAt = millis();
  wifiDot = millis();
#endif
#if EGG_DEVKIT
  if (!servoDriverInit()) {
    Serial.println("SERVO driver failed");
  } else {
    servoWriteUs(SERVO_CAM_PIN, GATE_CENTER_US);
    servoWriteUs(SERVO_SIZE_PIN, PUSH_HOME_US);
    servoWriteUs(SERVO_REJECT_PIN, SORT_MEDIUM_US);
    servoWriteUs(ENTRANCE_PIN, ENTRANCE_HOLD_US);
    gateAngle = 0;
    entranceAt = millis();
    entranceOpen = false;
    Serial.println("SERVO ready");
  }
#endif
#if ARDUINO_LOCAL
  // Auto-start â€” no typing "start". Short delay so USB/Serial settle.
  Serial.println();
  Serial.println("Auto-start in 2sâ€¦");
  delay(2000);
  goOnline();
#endif
}

void serviceLatchedEgg() {
#if !ARDUINO_LOCAL
  static unsigned long scaleWaitStart = 0;
  static unsigned long scaleWaitMsg = 0;
  static bool weakInspectOnce = false;
  static bool saidGateFollow = false;
#endif

  // Clear only when egg left and we are idle â€” weight may already be posted.
  if (!irEgg && !eggLatched && postedEgg && inspect == I_IDLE) {
    postedEgg = false;
    inspectedEgg = false;
    sizeDone = false;
#if !ARDUINO_LOCAL
    scaleWaitStart = 0;
    scaleWaitMsg = 0;
    weakInspectOnce = false;
    saidGateFollow = false;
#endif
    return;
  }
  if (!eggLatched) {
#if !ARDUINO_LOCAL
    scaleWaitStart = 0;
    scaleWaitMsg = 0;
    weakInspectOnce = false;
#endif
    return;
  }
  float nowG = gramsFrom(hxLastRaw);
  if (nowG >= EGG_G) {
    liveG = nowG;
    scaleG = nowG;
    if (lastStableG < EGG_G) {
      lastStableG = nowG;
      stableAt = millis();
    }
  }
  if (!irEgg && liveG < EGG_G && millis() - eggLatchAt > 8000) {
    eggLatched = false;
    return;
  }
  // DevKit already prints + SORT in commitEggResult â€” do not print again here (ghost egg 2).
#if !EGG_DEVKIT
  if (!postedEgg && weightShown && liveG >= EGG_G) {
    float g = lastStableG >= EGG_G ? lastStableG : liveG;
    String sc = sizeClassOf(g);
    pendingSize = sc;
    lastStableG = g;
    postedEgg = true;
    printEggResult(g);
    postWeight(displayGrams(g));
  }
#endif

#if !ARDUINO_LOCAL
  if (!inspectedEgg && inspect == I_IDLE) {
    bool haveWeight = liveG >= EGG_G && (weightShown || gramsStable());
    if (scaleWaitStart == 0) scaleWaitStart = millis();
    if (!haveWeight) {
      if (millis() - scaleWaitStart < 4000) {
        if (millis() - scaleWaitMsg > 5000) {
          scaleWaitMsg = millis();
#if !SERIAL_WEIGHT_ONLY
          Serial.println("EGG IN â€” waiting scale (d must rise; wood on weighing end only)");
#endif
        }
        return;
      }
      if (millis() - scaleWaitMsg > 10000) {
        scaleWaitMsg = millis();
#if !SERIAL_WEIGHT_ONLY
        Serial.println("EGG IN â€” weak scale (d low). Fix wood mount â€” camera waits for real grams");
#endif
      }
      return;
    }
    scaleWaitStart = 0;
    scaleWaitMsg = 0;
    weakInspectOnce = false;
    beginInspect();
    return;
  }
  if (inspect != I_DONE && inspect != I_IDLE) return;
  if (!saidGateFollow) {
    saidGateFollow = true;
#if !SERIAL_WEIGHT_ONLY
    Serial.println("Gate follows camera only â€” sort and push stay");
#endif
  }
#endif
}

// Live scale status. In SERIAL_WEIGHT_ONLY mode this prints nothing â€” only Weight/Class locks do.
void reportLive() {
  static unsigned long lastFaultAt = 0;
  unsigned long now = millis();
  long zero = emptyAdc != 0 ? emptyAdc : idleAdc;
  long delta = 0;
  if (hxRawOk(hxLastRaw) && !hxStuck(hxLastRaw)) {
    delta = hxLastRaw - zero;
    if (delta < 0) delta = -delta;
    if (delta <= HX_MAX_DELTA && delta > peakDelta) peakDelta = delta;
    if (delta < EMPTY_NOISE_COUNTS && holdPeakD < FORCE_COUNTS &&
        (holdPeakAt == 0 || millis() - holdPeakAt > PEAK_HOLD_MS)) {
      peakDelta = delta;
    }
  } else {
    delta = 0;
  }

#if SERIAL_WEIGHT_ONLY
  if (hxStuck(hxLastRaw) && now - lastFaultAt > 15000) {
    lastFaultAt = now;
    Serial.println("HX711 fault â€” check DT=P32 SCK=P33");
  }
  // Backup EMPTY print if main path missed it (never clear needIdlePrint without printing).
  if (needIdlePrint && !eggResultPrinted && !announceEggRemoved &&
      !eggSession && !mustSeeEmpty && !weightShown && delta < EGG_ADC_MIN) {
    printIdleScale(delta);
    return;
  }
  (void)now;
  return;
#else
  float shown = 0;
  long showNeed = FORCE_COUNTS;
  bool still = eggStill();
  bool rawOk = hxRawOk(hxLastRaw) && !hxStuck(hxLastRaw);
  int beam = irEgg ? 1 : 0;
  long dShow = holdPeakD;
  if ((long)(smoothD + 0.5f) > dShow) dShow = (long)(smoothD + 0.5f);
  if (rawOk && delta > dShow && delta <= HX_MAX_DELTA) dShow = delta;
  if (rawOk && millis() >= hxGlitchUntil && dShow >= showNeed && dShow <= HX_MAX_DELTA) {
    if (liveG >= EGG_G) shown = liveG;
    else {
      float g = gramsFromDelta(dShow);
      if (g >= EGG_G) shown = g;
    }
  }

  if (hxStuck(hxLastRaw) && now - lastFaultAt > 8000) {
    lastFaultAt = now;
    Serial.println("HX711 raw stuck â€” check DT=P32 SCK=P33 and cell wires");
  }

  bool waitingCell = holdPeakD >= showNeed && !weightShown;
  bool busy = waitingCell || (liveG >= EGG_G) || beam;
  unsigned long liveGap = waitingCell ? 1200UL : (busy ? 800UL : (rawOk ? 2000UL : 3000UL));
  if (now - lastLive < liveGap) return;
  lastLive = now;
  const char* beamWord = beam ? "egg" : "clear";
  const char* moveWord = still ? "still" : "moving";
  if (waitingCell) {
    String preview = (shown >= EGG_G) ? sizeClassOf(shown) : String("â€”");
    Serial.printf("weighingâ€¦ %.1fg â†’ %s  (hold still)  d=%ld span=%ld beam %s\n",
                  shown, preview.c_str(), holdPeakD, motionSpan(), beamWord);
  } else if (shown >= EGG_G) {
    Serial.printf("scale %.1fg (%s) beam %s %s\n",
                  shown, sizeClassOf(shown).c_str(), beamWord, moveWord);
  } else {
    Serial.printf("scale 0.0g empty  d=%ld beam %s %s\n", delta, beamWord, moveWord);
  }
#endif
}

void loop() {
  handleSerial();
  if (!stationOn) {
#if ARDUINO_LOCAL
    // Wait for Serial "start" â€” do not move servos or run IoT yet.
#else
    if (cameraAp || WiFi.status() == WL_CONNECTED) {
      goOnline();
    } else {
#if !SERIAL_WEIGHT_ONLY
      if (millis() - wifiDot >= 500) {
        wifiDot = millis();
        Serial.print(".");
      }
#endif
      if (millis() - wifiAt > 15000) {
#if !SERIAL_WEIGHT_ONLY
        Serial.println("\nNext saved WiFi");
#endif
        connectSavedWifi();
      }
    }
#if EGG_DEVKIT
    serviceHornPwm();
    serviceEntrance();
    servicePush();
    serviceGate();
#endif
#endif
    delay(10);
    return;
  }

#if EGG_DEVKIT
  serviceHornPwm();  // GATE P14 + ENTRANCE P13 â€” must run every loop
  serviceEntrance();
  servicePush();
  serviceGate();
  sampleIr();
  if (!beltOn || inspect != I_IDLE || irEgg) {
    if (motorRun) stopBelt();
  } else if (!motorRun) {
    startBelt();
  }
#endif

#if !ARDUINO_LOCAL || GATE_FROM_FARM
  if (wifiSwitching) {
    if (WiFi.status() == WL_CONNECTED) {
      wifiSwitching = false;
      hbFails = 0;
#if !EGG_DEVKIT
      refreshStreamUrl();
      Serial.print("WiFi ");
      Serial.print(WiFi.SSID());
      Serial.print(" IP ");
      Serial.println(WiFi.localIP());
      Serial.println("Camera view " + streamUrl);
      // Keep tunnel sticky across Wiâ€‘Fi reconnect â€” never force LAN again.
      if (farmBackendIsHttps() && FARM_PUBLIC_URL[0]) {
        applyBackend(FARM_PUBLIC_URL);
        laptopSweepDone = true;
        findOctet = 0;
      } else if (strlen(FARM_BACKEND_URL) > 0) {
        applyBackend(FARM_BACKEND_URL);
        laptopSweepDone = true;
        findOctet = 0;
      } else {
        startLaptopSearch();
      }
#else
      Serial.print("WiFi ");
      Serial.print(WiFi.SSID());
      Serial.print(" IP ");
      Serial.println(WiFi.localIP());
      Serial.println("DevKit online â€” GATE waits for camera result");
#endif
    } else if (millis() - wifiAt > 12000) {
      wifiSwitching = false;
      Serial.println("Main WiFi not in range â€” back to extender / saved WiFi");
      connectSavedWifi();
      findPauseUntil = millis() + 20000;
    }
  } else if (!cameraAp && WiFi.status() != WL_CONNECTED && millis() - wifiAt > 8000) {
    Serial.println("WiFi lost â€” trying the next saved WiFi");
    connectSavedWifi();
  }

#if !EGG_DEVKIT
  serviceCamKeepAlive();  // always online: Wiâ€‘Fi + camera + laptop URL
  if (!wifiSwitching) findLaptopStep();
  // Live push runs in camPushTask (not here) so loop/HB cannot freeze the picture.
#endif

  if (millis() - lastMem >= 10000) {
    lastMem = millis();
  }

#if EGG_DEVKIT
  // Slower steady HB â€” 1s spam caused OK/fail flicker on weak extender Wiâ€‘Fi.
  {
    unsigned long hbGap = 2500UL;
    if (hbFails >= 2) hbGap = 1800UL;
    else if (weighArmedClean) hbGap = 2000UL;
    if (millis() - lastHb >= hbGap) {
      lastHb = millis();
      heartbeat(scaleG);
    }
  }
#else
  // Tunnel: rare HB so LIVE JPEG push owns Wiâ€‘Fi. LAN: normal cadence.
  {
    unsigned long hbGap = farmBackendIsHttps() ? 180000UL : (hbFails > 0 ? 4000UL : 3000UL);
    if (!camReiniting && !camInitBusy && millis() - lastHb >= hbGap) {
      lastHb = millis();
      heartbeat(scaleG);
      if (hbFails == 0) {
        Serial.printf("ONLINE HB OK  rssi=%d  jpg=%u  cam=%d  ip=%s\n",
                      WiFi.RSSI(), (unsigned)camJpgLen, camState,
                      WiFi.localIP().toString().c_str());
      } else if (hbFails == 1 || hbFails % 10 == 0) {
        Serial.printf("ONLINE recoveringâ€¦ hbFails=%d jpg=%u\n",
                      hbFails, (unsigned)camJpgLen);
      }
    }
  }
#endif

#if !ARDUINO_LOCAL
  handleSerial();
#if EGG_DEVKIT
  // Station only â€” CAM must not run inspect HTTP (it stole Wiâ€‘Fi and froze live).
  runInspect();
#endif
#endif
#endif

#if !EGG_DEVKIT
  delay(10);
  return;
#endif

  // Scale: accept in-band medians (loaded cell may sit well below empty raw).
  long adc = 0;
  int pr = pollAdc(&adc);
  if (pr != 1 || hxStuck(adc) || !hxRawOk(adc)) {
    reportLive();
    serviceLatchedEgg();
    delay(2);
    return;
  }
  lastWt = millis();
  if (!haveIdle) {
    applyEmptyZero(adc, "first sample");
  }

  static long prevAdc = 0;
  long jump = 0;
  if (prevAdc != 0) {
    jump = adc - prevAdc;
    if (jump < 0) jump = -jump;
  }
  // Huge jump to a stuck/rail code = wiring glitch. Large jump that stays
  // readable = egg placed/removed â€” keep weighing.
  if (jump > HX_GLITCH_JUMP && hxStuck(adc)) {
    hxGlitchUntil = millis() + 400;
    hxGoodStreak = 0;
    motionN = 0;
    stillSince = 0;
    prevAdc = adc;
    reportLive();
    serviceLatchedEgg();
    return;
  }
  if (millis() < hxGlitchUntil) {
    hxGoodStreak = 0;
    prevAdc = adc;
    reportLive();
    serviceLatchedEgg();
    return;
  }
  hxGoodStreak++;
  prevAdc = adc;
  noteMotion(adc);

  // Re-zero empty wood even while armed â€” bad tare left idle d=300..2500 and blocked eggs.
  // maybeAutoZero refuses egg-sized drift; only snaps absurd bad tare / tiny noise.
  if (!eggSession && !weightShown && !announceEggRemoved && !mustSeeEmpty &&
      !irEgg && !eggLatched) {
    healEmptyZero(adc);
    maybeAutoZero(adc);
  }

  long zeroNow = emptyAdc != 0 ? emptyAdc : idleAdc;
  long dNow = adc - zeroNow;
  if (dNow < 0) dNow = -dNow;
  if (dNow > HX_MAX_DELTA) {
    hxGoodStreak = 0;
    reportLive();
    serviceLatchedEgg();
    return;
  }

  bool stillNow = eggStill();
  float nowGquick = actualGrams(dNow);
  float eggNeedG = TRIGGER_RISE_G;

  // --- Ready / empty cycle. IoT: Clean eggs auto-weigh on the pad (no Serial). ---
  if (!idleShownOk && !eggSession && !weightShown && !announceEggRemoved &&
      !mustSeeEmpty && dNow < EMPTY_BAND_COUNTS) {
    if (hxRawOk(adc)) {
      emptyAdc = adc;
      idleAdc = adc;
      hxLastRaw = adc;
    }
    printIdleScale(0);
  }

  // After PUSH: wait empty, or snap tare if soft residual sticks.
  if (mustSeeEmpty && !eggSession && !weightShown && !announceEggRemoved) {
    if (clearSinceAt == 0) clearSinceAt = millis();
    bool emptyOk = (dNow < EMPTY_BAND_COUNTS) &&
                   (millis() - clearSinceAt >= CLEAR_BEFORE_NEXT_MS);
    bool softResidual = (millis() - clearSinceAt >= 2000UL) && (dNow < 30);
    if (emptyOk || softResidual) {
      if (hxRawOk(adc)) {
        emptyAdc = adc;
        idleAdc = adc;
        hxLastRaw = adc;
      }
      mustSeeEmpty = false;
      clearSinceAt = 0;
      eggSeenHits = 0;
      printIdleScale(0);
    }
  }

  // DevKit+farm: auto-weigh after camera Clean (weighArmedClean / farm weighArm).
  // Latch survives egg leaving FOV until timeout / weigh / reject.
  bool farmCleanWeigh = false;
  bool pastTravel = true;
#if EGG_DEVKIT && GATE_FROM_FARM
  if (weighArmedClean && millis() >= weighArmedUntil) {
    weighArmedClean = false;
    weighArmedAt = 0;
    padEmptyLatched = false;
    padArrivalSeen = false;
    padArrivalAt = 0;
    padArrivalHits = 0;
    // Keep gateDecisionPulsed latched â€” sticky cleanEgg must NOT re-swing GATE LEFT.
    // Pulsed clears only when farm goes idle (no clean/reject) or after weigh/PUSH.
    Serial.println("Clean weigh arm expired â€” GATE stays latched until farm idle");
  }
  pastTravel = (weighArmedAt == 0) || ((millis() - weighArmedAt) >= PAD_TRAVEL_MS);
  bool farmWindow = weighArmedClean && (millis() < weighArmedUntil);
  if (farmWindow && !pastTravel) {
    static unsigned long travelMsgAt = 0;
    if (millis() - travelMsgAt > 1000UL) {
      travelMsgAt = millis();
      unsigned long left = PAD_TRAVEL_MS - (millis() - weighArmedAt);
      Serial.printf("Belt travel (4â€“5s) â€” load cell listens in %lu ms\n", left);
    }
  }
  // Soft thresholds once past travel (empty latch / arrival sense / lock).
  farmCleanWeigh = farmWindow && pastTravel;
#endif
  // Empty floor: must beat measured empty noise by a wide margin (soft cell flickers).
  // Farm-armed: softer bend floor so under-reading cells still lock real eggs.
  long autoMinD = farmCleanWeigh ? 28L : AUTO_WEIGH_MIN_D;
  long placeMinD = farmCleanWeigh ? 28L : PLACE_RISE_COUNTS;
  long needBend = emptyNoiseD + (farmCleanWeigh ? 18L : 28L);
  if (needBend < autoMinD) needBend = autoMinD;
  if (needBend < placeMinD) needBend = placeMinD;
  bool onCell = (dNow >= needBend) && (dNow <= HX_MAX_DELTA);
  float peekG = actualGrams(dNow);
  // Live grams on heartbeat so the dashboard shows pad mass before lock.
  if (onCell && peekG >= 5.0f && peekG <= MAX_EGG_G) {
    scaleG = peekG;
    liveG = peekG;
  } else if (!eggSession && !weightShown && peekG < 5.0f) {
    scaleG = 0;
  }
  // HARD: real egg grams only â€” never soft residual on empty wood.
  // Soft cell often under-reads 15â€“35 g; farm-armed floor matches backend attach.
  float minLockG = farmCleanWeigh ? 15.0f : MIN_EGG_G;
  bool massOnPad = onCell && (dNow >= needBend) &&
                   (peekG >= minLockG) && (peekG <= MAX_EGG_G);
  // Farm-armed: accept mass even if wood still settles (eggStill alone blocked locks).
  bool stableEgg = massOnPad && (farmCleanWeigh || eggStill());
  bool allowWeigh = true;
#if EGG_DEVKIT
  // --- Load-cell arrival sense (after 4â€“5s travel) ---
  // 1) Latch empty  2) Sense egg landed  3) 3s settle  4) Weigh + record.
  static unsigned long waitEmptyMsg = 0;
  static unsigned long senseMsgAt = 0;
  if (farmCleanWeigh && !eggSession && !weightShown && !eggResultPrinted) {
    if (!padEmptyLatched) {
      if (dNow < EMPTY_BAND_COUNTS) {
        if (++padEmptyHits >= 3) {
          padEmptyHits = 0;
          padEmptyLatched = true;
          padEmptyBaseD = dNow;
          padArrivalSeen = false;
          padArrivalAt = 0;
          padArrivalHits = 0;
          mustSeeEmpty = false;
          awaitNextEgg = true;
          idleShownOk = true;
          Serial.printf("Pad empty (d=%ld) â€” sensing egg arrival on load cell\n", dNow);
        }
      } else {
        padEmptyHits = 0;
        if (millis() - waitEmptyMsg > 1500UL) {
          waitEmptyMsg = millis();
          Serial.printf("Waiting pad empty before sense (d=%ld)\n", dNow);
        }
      }
    } else if (!padArrivalSeen) {
      long rise = dNow - padEmptyBaseD;
      if (rise < 0) rise = 0;
      bool arrived = (rise >= PAD_ARRIVAL_RISE_D) && massOnPad &&
                     (peekG >= minLockG) && (peekG <= MAX_EGG_G);
      if (arrived) {
        if (++padArrivalHits >= 2) {
          padArrivalSeen = true;
          padArrivalAt = millis();
          padArrivalHits = 0;
          Serial.printf(
              "Load cell: egg ARRIVED rise=%ld d=%ld ~%.1fg â€” settle %lu ms "
              "before weigh/record\n",
              rise, dNow, peekG, (unsigned long)PAD_IMPACT_SETTLE_MS);
        }
      } else {
        padArrivalHits = 0;
        // Keep empty baseline fresh while waiting so slow drift does not fake arrival.
        if (dNow < EMPTY_BAND_COUNTS) {
          padEmptyBaseD = (padEmptyBaseD * 3 + dNow) / 4;
        }
        if (millis() - senseMsgAt > 1500UL) {
          senseMsgAt = millis();
          Serial.printf("Load cell sensingâ€¦ d=%ld rise=%ld (need +%ld)\n",
                        dNow, rise, PAD_ARRIVAL_RISE_D);
        }
      }
    } else if (padArrivalAt > 0 &&
               (millis() - padArrivalAt) < PAD_IMPACT_SETTLE_MS) {
      // Egg is on pad but still bouncing on the screw â€” do not lock yet.
      static unsigned long impactMsgAt = 0;
      if (millis() - impactMsgAt > 800UL) {
        impactMsgAt = millis();
        unsigned long left =
            PAD_IMPACT_SETTLE_MS - (millis() - padArrivalAt);
        Serial.printf("Egg settling â€” weigh/record in %lu ms (ignore screw impact)\n", left);
      }
    }
  } else if (!farmCleanWeigh) {
    padEmptyHits = 0;
  }
  // Weigh/record only after egg settled on pad (never on travel or screw impact).
  bool impactSettled = padArrivalSeen && padArrivalAt > 0 &&
                       (millis() - padArrivalAt) >= PAD_IMPACT_SETTLE_MS;
  int needHits = (farmCleanWeigh && impactSettled) ? 2 : 99;
  allowWeigh = farmCleanWeigh && impactSettled && massOnPad && awaitNextEgg;
#else
  int needHits = EGG_SEEN_HITS_NEED;
  allowWeigh = massOnPad;
#endif
  bool eggLike = awaitNextEgg && idleShownOk && !mustSeeEmpty && !eggSession &&
                 !weightShown && !announceEggRemoved && !eggResultPrinted &&
                 !sessionDone && stableEgg && allowWeigh &&
                 (millis() >= weighCooldownUntil);
  if (!farmCleanWeigh && !eggSession) {
    eggSeenHits = 0;  // camera not Clean â†’ never accumulate empty-pad hits
  }
  if (eggLike) {
    if (++eggSeenHits >= needHits) {
      eggSession = true;
      eggSessionAt = millis();
      weightSince = eggSessionAt;
      emptyAdcAtEgg = (emptyAdc != 0) ? emptyAdc : idleAdc;
      sessionBestRestG = 0;
      awaitNextEgg = false;
      sessionDone = false;
      eggGoneHits = 0;
      smoothD = (float)dNow;
      holdPeakD = 0;
      holdPeakAt = 0;
      Serial.printf(
          "Egg settled â€” AUTO weighing d=%ld ~%.1fg (need dâ‰¥%ld gâ‰¥%.0f)\n",
          dNow, peekG, needBend, minLockG);
      // Do NOT pause ENTRANCE/GATE here â€” that broke P13 every weigh.
    }
  } else if (!eggSession) {
    if (dNow < EMPTY_BAND_COUNTS) eggSeenHits = 0;
  }

  bool looksEmpty = (dNow < EMPTY_BAND_COUNTS);

  // After a printed result: clear only when truly empty â€” never d<26 (overlaps egg band 19â€“36).
  static int liftClearHits = 0;
  if (announceEggRemoved || weightShown) {
    if (looksEmpty && dNow < 12) {
      if (++liftClearHits >= 4) {
        liftClearHits = 0;
#if EGG_DEVKIT
        gateHoldUntil = 0;
#endif
        clearEggToEmpty(dNow);
        postWeight(0);
        reportLive();
        serviceLatchedEgg();
        return;
      }
    } else {
      liftClearHits = 0;
    }
  } else {
    liftClearHits = 0;
  }

  // Lift cancel only on sustained near-zero.
  if (eggSession && !weightShown && !announceEggRemoved && !eggResultPrinted) {
    if (dNow < 5) {
      if (++eggGoneHits >= 8) {
        eggSession = false;
        eggSessionAt = 0;
        eggGoneHits = 0;
        eggSeenHits = 0;
        holdPeakD = 0;
        smoothD = 0;
        sessionDone = false;
        awaitNextEgg = true;
        idleShownOk = true;
        weighCooldownUntil = millis() + 300UL;
#if EGG_DEVKIT
        // Same Clean egg â€” re-arm; sense emptyâ†’arrival again when egg returns.
        weighArmedClean = true;
        weighArmedUntil = millis() + WEIGH_ARMED_MS;
        padEmptyLatched = false;
        padArrivalSeen = false;
        padArrivalAt = 0;
        padArrivalHits = 0;
        padEmptyHits = 0;
        servoResumePulses();
#endif
        Serial.println("Egg lifted â€” waiting for egg on pad again");
      }
    } else {
      eggGoneHits = 0;
    }
  }

  if (dNow < EMPTY_NOISE_COUNTS && !eggSession) {
    smoothD = 0.15f * smoothD + 0.85f * (float)dNow;
    if (smoothD < (float)EMPTY_NOISE_COUNTS) smoothD = 0;
    holdPeakD = 0;
    holdPeakAt = 0;
  } else if (smoothD < 1.0f) {
    smoothD = (float)dNow;
  } else {
    smoothD = 0.55f * smoothD + 0.45f * (float)dNow;
  }

  // Keep peak during weigh â€” clearing it mid-session made late lock peak=0.
  if (!eggSession && holdPeakD > 0 && millis() - holdPeakAt > PEAK_HOLD_MS) {
    holdPeakD = 0;
    holdPeakAt = 0;
  }

  // While moving, peak is OK for "something is there". When still, use smoothed resting bend
  // â€” NEVER lock on holdPeakD (that is the hand/placement bump and changes every try).
  long dUse = (long)(smoothD + 0.5f);
  if (!stillNow && holdPeakD > dUse) dUse = holdPeakD;
  if (dUse > HX_MAX_DELTA) dUse = 0;

  if (dNow < EMPTY_NOISE_COUNTS && holdPeakD < FORCE_COUNTS) {
    if (!haveClearEmpty) {
      clearEmptyAdc = adc;
      haveClearEmpty = true;
    } else {
      clearEmptyAdc = (clearEmptyAdc * 3 + adc) / 4;
    }
  }

  // Prefer resting smooth bend for grams â€” not placement peak (that caused jumbo swings).
  long restD = (long)(smoothD + 0.5f);
  if (eggSession || eggLike) {
    if (restD < FORCE_COUNTS && dNow > restD) restD = dNow;
    else if (dNow >= FORCE_COUNTS) restD = (restD * 2 + dNow) / 3;
  }
  float raw = gramsFromDelta(restD);
  if (raw < EGG_G) raw = actualGrams(restD > 0 ? restD : dNow);
  if (raw < EGG_G && (eggLike || eggSession)) raw = nowGquick >= EGG_G ? nowGquick : raw;
  // Stay in egg path for whole sticky session (wobble must not abort the 6s wait).
  bool haveBend = eggSession || eggLike;
  if (!weightShown && !announceEggRemoved) {
    haveBend = haveBend ||
               (holdPeakD >= FORCE_COUNTS && (millis() - holdPeakAt) <= PEAK_HOLD_MS);
  }

  if (!haveBend) {
    lowStreak++;
    int needClear = (announceEggRemoved || weightShown) ? 8 : 25;
    if (lowStreak >= needClear) {
      bool hadW = (lastStableG >= EGG_G || weightShown || announceEggRemoved);
      if (hadW) {
        clearEggToEmpty(dNow);
        postWeight(0);
      } else {
        eggPeakD = 0;
        smoothD = 0;
        holdPeakD = 0;
        holdPeakAt = 0;
        smoothG = 0;
        scaleG = 0;
        liveG = 0;
        lastGoodG = 0;
        lastStableG = 0;
        eggHits = 0;
        weightSince = 0;
        weightShown = false;
        eggSession = false;
        eggSessionAt = 0;
        wasEmpty = true;
      }
    }
    reportLive();
    serviceLatchedEgg();
    return;
  }

  // Keep updating grams while wood wobbles â€” do NOT return early or lock never runs.
  eggHits++;
  if (eggHits > 20) eggHits = 20;
  lowStreak = 0;
  emptySince = 0;
  // Always track live grams during a session (even small rises above static).
  if (raw >= eggNeedG || nowGquick >= eggNeedG) {
    float use = (raw >= eggNeedG) ? raw : nowGquick;
    if (smoothG < eggNeedG) smoothG = use;
    else smoothG = 0.55f * smoothG + 0.45f * use;
  }
  lastGoodG = (smoothG >= eggNeedG) ? smoothG : nowGquick;
  lastGoodAt = millis();
  if (lastGoodG >= eggNeedG) {
    scaleG = lastGoodG;
    liveG = lastGoodG;
  }

  unsigned long bendAge = (eggSessionAt > 0) ? (millis() - eggSessionAt) : 0;
  // Farm path already waited PAD_IMPACT_SETTLE_MS before starting the session.
  bool bendReady = eggSessionAt > 0 && bendAge >= WEIGHT_SETTLE_MS;

  // Lock samples â€” DevKit IoT auto-weigh uses the same path as CAM (no Serial "egg").
  static int restSampleN = 0;
  static float restSampleSum = 0;
  if (!eggSession) {
    restSampleN = 0;
    restSampleSum = 0;
  }

  if (!weightShown && !eggResultPrinted && !sessionDone && eggSession && eggSessionAt > 0) {
    long sampleD = (long)(smoothD + 0.5f);
    if (sampleD < EGG_D_LO && dNow >= EGG_D_LO) sampleD = dNow;
    if (sampleD > REST_D_MAX) sampleD = REST_D_MAX;
    // Reject empty residual samples â€” do not average noise into a fake egg.
    // Farm-armed Soft cell: lower bend + gram floors so lock still commits.
    long restMinD = farmCleanWeigh ? 28L : REST_D_MIN;
    long restAutoD = farmCleanWeigh ? 28L : AUTO_WEIGH_MIN_D;
    float minSampleG = farmCleanWeigh ? minLockG : MIN_EGG_G;
    bool sampleOk = bendReady && sampleD >= restMinD && sampleD >= restAutoD;
    int needRest = farmCleanWeigh ? REST_SAMPLES_NEED : (REST_SAMPLES_NEED + 2);
    // After impact settle, allow ~2s of resting samples before give-up retry.
    unsigned long giveUpMs = farmCleanWeigh ? 2500UL : WEIGHT_GIVE_UP_MS;
    if (sampleOk) {
      float g = actualGrams(sampleD);
      float w = displayGrams(g);
      if (w >= minSampleG && w <= MAX_EGG_G) {
        restSampleSum += g;
        restSampleN++;
        sessionBestRestG = (sessionBestRestG < 0.5f) ? g : (0.5f * sessionBestRestG + 0.5f * g);
      }
    }
    bool readyPrint = bendReady && restSampleN >= needRest;
    bool forcePrint = bendAge >= WEIGHT_FORCE_LOCK_MS && restSampleN >= needRest;
    if ((readyPrint || forcePrint) && restSampleN >= needRest) {
      if (commitEggResult(restSampleSum / (float)restSampleN)) {
        restSampleN = 0;
        restSampleSum = 0;
#if EGG_DEVKIT
        servoResumePulses();
#endif
      }
    }
    if (!weightShown && !eggResultPrinted && bendAge >= giveUpMs) {
      // Prefer best resting sample even if count is short (soft under-read).
      float tryG = (restSampleN > 0)
          ? (restSampleSum / (float)restSampleN)
          : sessionBestRestG;
      if (tryG < minSampleG && sessionBestRestG >= minSampleG) {
        tryG = sessionBestRestG;
      }
      if (tryG >= minSampleG) {
        commitEggResult(tryG);
#if EGG_DEVKIT
        servoResumePulses();
#endif
      }
      if (!eggResultPrinted) {
        eggSession = false;
        eggSessionAt = 0;
        restSampleN = 0;
        restSampleSum = 0;
#if EGG_DEVKIT
        // Keep farm Clean arm â€” egg still on pad, keep arrival latch for retry.
        sessionDone = false;
        awaitNextEgg = true;
        mustSeeEmpty = false;
        idleShownOk = true;
        weighArmedClean = true;
        weighArmedUntil = millis() + WEIGH_ARMED_MS;
        padEmptyLatched = true;
        padArrivalSeen = true;
        // Egg already on pad â€” skip another 3s impact wait on retry.
        padArrivalAt = millis() - PAD_IMPACT_SETTLE_MS;
        weighCooldownUntil = millis() + 400UL;
        eggSeenHits = 0;
        servoResumePulses();
        Serial.println("Weigh settle retry â€” pad still armed for Clean egg");
#else
        sessionDone = true;
        awaitNextEgg = false;
        mustSeeEmpty = true;
        idleShownOk = false;
        clearSinceAt = 0;
#endif
      }
    }
  }

  if (liveG >= EGG_G) {
    emptySince = 0;
    if (wasEmpty) {
      wasEmpty = false;
      // Do not clear a result that already printed â€” wait for egg removed.
      if (!eggResultPrinted && !announceEggRemoved) {
        postedEgg = false;
        inspectedEgg = false;
        rejectedEgg = false;
        camRejectDone = false;
        sizeDone = false;
        pendingSize = "";
      }
      lastStableG = liveG;
      stableAt = millis();
      if (!pendingSize.length()) pendingSize = sizeClassOf(liveG);
    } else {
      float dd = liveG - lastStableG;
      if (dd < 0) dd = -dd;
      if (lastStableG < EGG_G || dd > 8.0f) {
        lastStableG = liveG;
        stableAt = millis();
      } else {
        lastStableG = 0.75f * lastStableG + 0.25f * liveG;
      }
    }
    if (inspect == I_IDLE && gramsStable()) {
      pendingSize = sizeClassOf(lastStableG);
    }
  } else if (!wasEmpty && millis() > ignoreEmptyUntil && (lastGoodAt == 0 || millis() - lastGoodAt > 400)) {
    if (emptySince == 0) emptySince = millis();
    else if (millis() - emptySince > 300) {
      wasEmpty = true;
      postedEgg = false;
      inspectedEgg = false;
      rejectedEgg = false;
      camRejectDone = false;
      sizeDone = false;
      pendingSize = "";
      lastStableG = 0;
      lastGoodG = 0;
      lastGoodAt = 0;
      lowStreak = 0;
      eggHits = 0;
      weightSince = 0;
      weightShown = false;
      stableAt = 0;
      inspect = I_IDLE;
      inspectPosted = false;
      emptyIdleAt = millis();
#if EGG_DEVKIT
      if (millis() >= gateHoldUntil) {
        servoStop();
        servoWriteUs(SERVO_SIZE_PIN, PUSH_HOME_US);
        servoWriteUs(SERVO_REJECT_PIN, SORT_MEDIUM_US);
      }
#else
      servoStop();
      servoWriteUs(SERVO_SIZE_PIN, PUSH_HOME_US);
      servoWriteUs(SERVO_REJECT_PIN, SORT_MEDIUM_US);
#endif
      pushArmed = false;
      pushReturn = false;
      eggLatched = false;
      emptySince = 0;
      if (announceEggRemoved) printEggRemoved(dNow);
      else {
        eggResultPrinted = false;
        needIdlePrint = false;
      }
      postWeight(0);
    }
  }

  // emptyAdc is locked after tare. Never follow a slow egg placement into a new zero.
  // That bug made finger-press work (fast jump) but a resting egg look like 0.0 g.
  if (wasEmpty && haveIdle && inspect == I_IDLE && raw < EGG_G) {
    long fromEmpty = adc - emptyAdc;
    if (fromEmpty < 0) fromEmpty = -fromEmpty;
    if (fromEmpty < EMPTY_NOISE_COUNTS) {
      emptyIdleAt = millis();
      smoothG = 0;
      scaleG = 0;
      liveG = 0;
      raw = 0;
    }
  } else if (!wasEmpty) {
    emptyIdleAt = millis();
  }

  // Only clear to empty when the bar is truly light â€” do not wipe a resting egg.
  if (!eggLatched && !irEgg && inspect == I_IDLE && !postedEgg && raw < EGG_G &&
      liveG < EGG_G && smoothG < EGG_G) {
    long fromEmpty = adc - emptyAdc;
    if (fromEmpty < 0) fromEmpty = -fromEmpty;
    if (fromEmpty < EMPTY_NOISE_COUNTS) {
      smoothG = 0;
      scaleG = 0;
      liveG = 0;
      raw = 0;
      eggHits = 0;
      weightSince = 0;
      weightShown = false;
      wasEmpty = true;
    }
  }

  reportLive();

  serviceLatchedEgg();
}
