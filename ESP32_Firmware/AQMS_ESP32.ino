#include <Adafruit_GFX.h>    
#include <Adafruit_ST7735.h> 
#include <DHT.h>             
#include <SPI.h>
#include <PMS.h> 
#include <Wire.h>
#include <Adafruit_BMP280.h>
#include <TinyGPS++.h>
#include <WiFi.h>
#include <WiFiMulti.h>
#include <WebServer.h>
#include <ArduinoJson.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <time.h>

// --- FIREBASE LIBRARIES ---
#include <Firebase_ESP_Client.h>
#include <addons/TokenHelper.h>  
#include <addons/RTDBHelper.h>   

// ==========================================
// 🔴 USER CONFIGURATION
// ==========================================
// Wi-Fi, Discord, and Firebase values now come from config.h,
// which is excluded by .gitignore and never committed to GitHub.
// Copy config.example.h to config.h (same folder) and fill in your real values.
#include "config.h"

// ==========================================
FirebaseData fbdo;
FirebaseAuth auth;
FirebaseConfig config;
bool firebaseReady = false;

WiFiMulti wifiMulti;
WebServer server(80);

// ----------- PINS -----------
#define TFT_CS   15
#define TFT_RST  12
#define TFT_DC    2
#define TFT_MOSI 23  
#define TFT_SCLK 18  

#define DHTPIN      4
#define DHTTYPE     DHT22
#define MQ7_PIN     34    
#define MQ135_PIN   35    
#define BUTTON_PIN  32    
#define PMS_TX_PIN  26    
#define GPS_RX_PIN  27    
#define GPS_TX_PIN  -1  
#define BMP_SDA     16
#define BMP_SCL     17
#define BUZZER_PIN  13

Adafruit_ST7735 tft = Adafruit_ST7735(TFT_CS, TFT_DC, TFT_MOSI, TFT_SCLK, TFT_RST);
DHT dht(DHTPIN, DHTTYPE);
Adafruit_BMP280 bmp; 
HardwareSerial pmsSerial(2);
HardwareSerial gpsSerial(1); 
PMS pms(pmsSerial);
PMS::DATA data;
TinyGPSPlus gps;

unsigned long lastScreenUpdate = 0;
unsigned long lastFirebaseUpdate = 0;
unsigned long lastDiscordUpdate = 0;
unsigned long lastBuzzerCheck = 0;
unsigned long alarmStartTime = 0;
bool isAlarming = false;
int alarmPattern = 0;
unsigned long patternStartTime = 0;

const long SCREEN_INTERVAL = 2000;
const long FIREBASE_INTERVAL = 60000;
const long DISCORD_INTERVAL = 300000;
const long BUZZER_CHECK_INTERVAL = 1000;
const long ALARM_DURATION = 10000;
const long PATTERN_INTERVAL = 500;

// ========== GAS SENSOR STRUCT & CALIBRATION ==========
struct SensorReading {
  float temperature;
  float humidity;
  float pressure;
  float co_ppm;
  float co2_ppm;
  int pm1;
  int pm25;
  int pm10;
  float lat;
  float lng;
  unsigned long timestamp;
};

float baselineCO_Raw = 415.0;   // clean‑air raw (MQ7)
float baselineCO2_Raw = 124.0;  // clean‑air raw (MQ135)
bool sensorsCalibrated = true;

#define FILTER_SIZE 5
float coRawBuffer[FILTER_SIZE] = {0};
float co2RawBuffer[FILTER_SIZE] = {0};
byte filterIndex = 0;

int readCO_RawFiltered() {
  int raw = analogRead(MQ7_PIN);
  coRawBuffer[filterIndex] = raw;
  float sum = 0;
  for (int i = 0; i < FILTER_SIZE; i++) sum += coRawBuffer[i];
  return round(sum / FILTER_SIZE);
}

int readCO2_RawFiltered() {
  int raw = analogRead(MQ135_PIN);
  co2RawBuffer[filterIndex] = raw;
  float sum = 0;
  for (int i = 0; i < FILTER_SIZE; i++) sum += co2RawBuffer[i];
  return round(sum / FILTER_SIZE);
}

float readCO_ppm() {
  int raw = readCO_RawFiltered();
  if (raw <= 0) return 0.0;
  float ratio = baselineCO_Raw / (float)raw;
  float ppm = 10.0 * (ratio - 1.0);
  if (ppm < 0) ppm = 0;
  return ppm;
}

float readCO2_ppm() {
  int raw = readCO2_RawFiltered();
  if (raw <= 0) return 400.0;
  float ratio = baselineCO2_Raw / (float)raw;
  float ppm = 400.0 + 100.0 * (ratio - 1.0);
  if (ppm < 300) ppm = 300;
  if (ppm > 5000) ppm = 5000;
  return ppm;
}

// ========== OFFLINE QUEUE ==========
const int MAX_QUEUE = 50;
SensorReading offlineQueue[MAX_QUEUE];
int queueStart = 0, queueEnd = 0, queueSize = 0;
bool isOnline = true;

void addToQueue(SensorReading& reading) {
  if (queueSize < MAX_QUEUE) {
    offlineQueue[queueEnd] = reading;
    queueEnd = (queueEnd + 1) % MAX_QUEUE;
    queueSize++;
  } else {
    offlineQueue[queueEnd] = reading;
    queueStart = (queueStart + 1) % MAX_QUEUE;
    queueEnd = (queueEnd + 1) % MAX_QUEUE;
  }
}

void flushQueue() {
  if (!firebaseReady || WiFi.status() != WL_CONNECTED) return;
  while (queueSize > 0) {
    SensorReading r = offlineQueue[queueStart];
    FirebaseJson json;
    json.set("temperature", r.temperature);
    json.set("humidity", r.humidity);
    json.set("pressure", r.pressure);
    json.set("co2", r.co2_ppm);
    json.set("co", r.co_ppm);
    json.set("pm1", r.pm1);
    json.set("pm25", r.pm25);
    json.set("pm10", r.pm10);
    json.set("lat", r.lat);
    json.set("lng", r.lng);

    time_t now;
    time(&now);
    Serial.print("Timestamp: ");
    Serial.println((long)now);
    json.set("lastSeen", (long)now);

    if (!Firebase.RTDB.setJSON(&fbdo, "/sensors/current", &json)) {
      Serial.println("❌ Flush failed, will retry later.");
      return;
    }
    String historyPath = "sensors/history/" + String(r.timestamp);
    Firebase.RTDB.setJSON(&fbdo, historyPath.c_str(), &json);
    
    queueStart = (queueStart + 1) % MAX_QUEUE;
    queueSize--;
    Serial.println("🚀 Flushed one entry. Remaining: " + String(queueSize));
    delay(100);
  }
}

// ========== GPS CACHE ==========
float lastLat = 0.0;
float lastLng = 0.0;

// ========== THRESHOLDS (ppm) ==========
const float KHI_TEMP_THRESHOLD = 40.0;
const float KHI_HUM_THRESHOLD = 85.0;
const int KHI_CO_PPM_THRESHOLD = 9;
const int KHI_CO2_PPM_THRESHOLD = 800;
const int KHI_PM1_THRESHOLD = 50;
const int KHI_PM25_THRESHOLD = 150;
const int KHI_PM10_THRESHOLD = 250;

int screenIdx = 0;
bool pulseState = false;
bool alarmActive = false;
String currentAlarm = "";

// ========== CENTRAL SENSOR READ ==========
SensorReading readAllSensors() {
  filterIndex = (filterIndex + 1) % FILTER_SIZE;
  SensorReading r;
  r.temperature = dht.readTemperature();
  r.humidity = dht.readHumidity();
  r.pressure = bmp.readPressure() / 100.0F;
  r.co_ppm = readCO_ppm();
  r.co2_ppm = readCO2_ppm();
  pms.readUntil(data, 100);
  r.pm1 = data.PM_AE_UG_1_0;
  r.pm25 = data.PM_AE_UG_2_5;
  r.pm10 = data.PM_AE_UG_10_0;
  if (gps.location.isValid()) {
    r.lat = gps.location.lat();
    r.lng = gps.location.lng();
    lastLat = r.lat;
    lastLng = r.lng;
  } else {
    r.lat = lastLat;
    r.lng = lastLng;
  }
  r.timestamp = millis();
  return r;
}

// ========== BUZZER ==========
void startBuzzerAlarm(String alarmType) {
  if (!isAlarming) {
    isAlarming = true;
    alarmStartTime = millis();
    currentAlarm = alarmType;
    alarmActive = true;
    patternStartTime = millis();
    alarmPattern = 0;
    sendToDiscord("🚨 **ALERT!** High " + alarmType + " detected in Karachi!");
  }
}

void stopBuzzerAlarm() {
  if (isAlarming) {
    isAlarming = false;
    alarmActive = false;
    digitalWrite(BUZZER_PIN, LOW);
    currentAlarm = "";
  }
}

void updateBuzzerPattern() {
  if (!isAlarming) return;
  unsigned long now = millis();
  if (now - alarmStartTime >= ALARM_DURATION) {
    stopBuzzerAlarm();
    return;
  }
  if (now - patternStartTime >= PATTERN_INTERVAL) {
    patternStartTime = now;
    alarmPattern = (alarmPattern + 1) % 8;
    digitalWrite(BUZZER_PIN, (alarmPattern < 3) ? HIGH : LOW);
  }
}

void checkSensorThresholds() {
  SensorReading r = readAllSensors();
  if (r.temperature >= KHI_TEMP_THRESHOLD) startBuzzerAlarm("Temperature");
  else if (r.humidity >= KHI_HUM_THRESHOLD) startBuzzerAlarm("Humidity");
  else if (r.co_ppm >= KHI_CO_PPM_THRESHOLD) startBuzzerAlarm("CO Level");
  else if (r.co2_ppm >= KHI_CO2_PPM_THRESHOLD) startBuzzerAlarm("CO2 Level");
  else if (r.pm1 >= KHI_PM1_THRESHOLD) startBuzzerAlarm("PM1.0");
  else if (r.pm25 >= KHI_PM25_THRESHOLD) startBuzzerAlarm("PM2.5");
  else if (r.pm10 >= KHI_PM10_THRESHOLD) startBuzzerAlarm("PM10");
  else if (isAlarming && (millis() - alarmStartTime >= 1000)) stopBuzzerAlarm();
}

// ========== DISCORD ==========
void sendToDiscord(String content) {
  if (WiFi.status() == WL_CONNECTED) {
    WiFiClientSecure client;
    client.setInsecure();
    HTTPClient http;
    http.begin(client, discord_webhook);
    http.addHeader("Content-Type", "application/json");
    String payload = "{\"content\": \"" + content + "\"}";
    http.POST(payload);
    http.end();
  }
}

void sendDiscordReport() {
  SensorReading r = readAllSensors();
  String msg = "### 📊 Live Sensor Report\\n";
  msg += "`Temp:` " + String(r.temperature,1) + "C  |  `Hum:` " + String(r.humidity,1) + "%\\n";
  msg += "`Press:` " + String(r.pressure,1) + "hPa\\n";
  msg += "`PM1:` " + String(r.pm1) + "  `PM2.5:` " + String(r.pm25) + "  `PM10:` " + String(r.pm10) + "\\n";
  msg += "`CO (ppm):` " + String(r.co_ppm,1) + "  `CO2 (ppm):` " + String(r.co2_ppm,0) + "\\n";
  msg += "`Lat:` " + String(r.lat,6) + "  `Lng:` " + String(r.lng,6);
  if (alarmActive) msg += "\\n🚨 **ACTIVE ALARM:** " + currentAlarm;
  sendToDiscord(msg);
}

// ========== FIREBASE (with updated paths) ==========
void sendToFirebase() {
  if (!firebaseReady || WiFi.status() != WL_CONNECTED) {
    SensorReading r = readAllSensors();
    addToQueue(r);
    return;
  }
  flushQueue();

  SensorReading r = readAllSensors();
  FirebaseJson json;
  json.set("temperature", r.temperature);
  json.set("humidity", r.humidity);
  json.set("pressure", r.pressure);
  json.set("co2", r.co2_ppm);
  json.set("co", r.co_ppm);
  json.set("pm1", r.pm1);
  json.set("pm25", r.pm25);
  json.set("pm10", r.pm10);
  json.set("lat", r.lat);
  json.set("lng", r.lng);

  // Get Unix timestamp (seconds since 1970)
  time_t now;
  time(&now);
  // If NTP not yet synced, now may be < 100000 – fallback to millis() relative
  if (now < 100000) {
    now = millis() / 1000;   // fallback, but not ideal – ensure NTP is configured
  }
  json.set("lastSeen", (long)now);

  // ----- Send to /sensors/current -----
  Serial.print("Firebase current... ");
  if (Firebase.RTDB.setJSON(&fbdo, "/sensors/current", &json)) {
    Serial.println("SUCCESS");
  } else {
    Serial.printf("FAIL: %s\n", fbdo.errorReason().c_str());
    addToQueue(r);
  }

  // ----- Send to /sensors/history with a time‑ordered key -----
  // Use a combination of Unix timestamp and millis() to guarantee uniqueness
  // and chronological order (older entries have smaller keys).
  String historyPath = "/sensors/history/" + String(now) + "_" + String(millis());
  Serial.print("Firebase history... ");
  if (!Firebase.RTDB.setJSON(&fbdo, historyPath.c_str(), &json)) {
    Serial.printf("FAIL: %s\n", fbdo.errorReason().c_str());
  } else {
    Serial.println("SUCCESS");
  }
}

// ========== LOCAL SERVER ==========
void handleJsonData() {
  SensorReading r = readAllSensors();
  StaticJsonDocument<1024> doc;
  doc["temp"] = r.temperature;
  doc["hum"] = r.humidity;
  doc["pressure"] = r.pressure;
  doc["altitude"] = bmp.readAltitude(1013.25);
  doc["pm1"] = r.pm1;
  doc["pm25"] = r.pm25;
  doc["pm10"] = r.pm10;
  doc["co"] = r.co_ppm;
  doc["co2"] = r.co2_ppm;
  doc["lat"] = r.lat;
  doc["lng"] = r.lng;
  doc["alarm_active"] = alarmActive;
  doc["alarm_type"] = currentAlarm;
  String response;
  serializeJson(doc, response);
  server.send(200, "application/json", response);
}

// ========== CALIBRATION (optional) ==========
void calibrateSensors() {
  tft.fillScreen(ST7735_BLACK);
  tft.setTextSize(1);
  tft.setTextColor(ST7735_CYAN);
  tft.setCursor(10, 30); tft.print("Calibrating...");
  long sumCO = 0, sumCO2 = 0;
  for (int i = 0; i < 20; i++) {
    sumCO += analogRead(MQ7_PIN);
    sumCO2 += analogRead(MQ135_PIN);
    delay(100);
  }
  baselineCO_Raw = sumCO / 20.0;
  baselineCO2_Raw = sumCO2 / 20.0;
  sensorsCalibrated = true;
  tft.fillScreen(ST7735_BLACK);
  tft.setTextColor(ST7735_GREEN);
  tft.setCursor(10, 30); tft.print("Calibrated!");
  delay(2000);
  tft.fillScreen(ST7735_BLACK);
  drawStaticUI();
}

// ========== DISPLAY HELPERS ==========
void drawStaticUI() {
  tft.setTextColor(ST7735_CYAN);
  tft.setTextSize(1);
  tft.setCursor(10, 5);
  tft.print("Screen " + String(screenIdx + 1));
  if (alarmActive) {
    tft.setCursor(100, 5);
    tft.setTextColor(ST7735_RED, ST7735_BLACK);
    tft.print("ALARM!");
  }
  tft.drawFastHLine(0, 15, 160, ST7735_WHITE);
}

void drawGasScreen(const char* label, float ppmVal, uint16_t labelColor) {
  int rawVal = (strcmp(label, "CO (MQ7)") == 0) ? readCO_RawFiltered() : readCO2_RawFiltered();
  tft.setTextSize(2); tft.setCursor(10, 25); tft.setTextColor(labelColor, ST7735_BLACK);
  tft.print(label);
  int barWidth = map(rawVal, 0, 4095, 0, 140);
  if (barWidth > 140) barWidth = 140;
  uint16_t barColor = (ppmVal >= ((strcmp(label, "CO (MQ7)") == 0) ? KHI_CO_PPM_THRESHOLD : KHI_CO2_PPM_THRESHOLD)) ? ST7735_RED : ST7735_GREEN;
  tft.drawRect(10, 50, 142, 20, ST7735_WHITE);
  tft.fillRect(11, 51, barWidth, 18, barColor);
  tft.fillRect(11 + barWidth, 51, 140 - barWidth, 18, ST7735_BLACK);
  tft.setTextSize(1); tft.setCursor(10, 80); tft.setTextColor(ST7735_WHITE, ST7735_BLACK);
  tft.printf("Val: %.0f ppm", ppmVal);
  if (ppmVal >= ((strcmp(label, "CO (MQ7)") == 0) ? KHI_CO_PPM_THRESHOLD : KHI_CO2_PPM_THRESHOLD)) {
    tft.setCursor(10, 95);
    tft.setTextColor(ST7735_RED, ST7735_BLACK);
    tft.print("THRESHOLD EXCEEDED!");
  }
}

void drawMiniBar(int y, int val, int maxVal, uint16_t color, int threshold) {
  int w = map(val, 0, maxVal, 0, 100);
  if (w > 100) w = 100;
  if (val >= threshold) color = ST7735_RED;
  tft.drawRect(10, y, 102, 10, ST7735_WHITE);
  tft.fillRect(11, y+1, w, 8, color);
  tft.fillRect(11+w, y+1, 100-w, 8, ST7735_BLACK);
  tft.setCursor(120, y); tft.setTextColor(color, ST7735_BLACK); tft.print(val);
  int thresholdPos = map(threshold, 0, maxVal, 10, 110);
  if (thresholdPos <= 110) tft.drawLine(thresholdPos, y, thresholdPos, y+10, ST7735_WHITE);
}

void updateDisplay() {
  SensorReading r = readAllSensors();
  float t = r.temperature;
  float h = r.humidity;
  float p = r.pressure;
  float alt = bmp.readAltitude(1013.25);
  float coPpm = r.co_ppm;
  float co2Ppm = r.co2_ppm;

  if (pulseState) tft.fillCircle(150, 7, 3, ST7735_GREEN);
  else { tft.drawCircle(150, 7, 3, ST7735_GREEN); tft.fillCircle(150, 7, 2, ST7735_BLACK); }

  if (alarmActive) {
    tft.setCursor(100, 5);
    tft.setTextColor(ST7735_RED, ST7735_BLACK);
    tft.print("ALARM!");
  }

  if (screenIdx == 0) {
    tft.setTextSize(2);
    tft.setCursor(10, 30); 
    tft.setTextColor((t >= KHI_TEMP_THRESHOLD) ? ST7735_RED : ST7735_YELLOW, ST7735_BLACK);
    tft.printf("T: %.1f C", t);
    tft.setCursor(10, 60); 
    tft.setTextColor((h >= KHI_HUM_THRESHOLD) ? ST7735_RED : ST7735_BLUE, ST7735_BLACK);
    tft.printf("H: %.1f %%", h);
  }
  else if (screenIdx == 1) drawGasScreen("CO (MQ7)", coPpm, ST7735_ORANGE);
  else if (screenIdx == 2) drawGasScreen("CO2 (MQ135)", co2Ppm, ST7735_MAGENTA);
  else if (screenIdx == 3) {
    tft.setTextSize(1); tft.setTextColor(ST7735_WHITE, ST7735_BLACK);
    tft.setCursor(10, 20); tft.print("PM 1.0:");
    drawMiniBar(30, r.pm1, 100, ST7735_CYAN, KHI_PM1_THRESHOLD);
    tft.setCursor(10, 50); tft.print("PM 2.5:");
    drawMiniBar(60, r.pm25, 150, ST7735_YELLOW, KHI_PM25_THRESHOLD);
    tft.setCursor(10, 80); tft.print("PM 10 :");
    drawMiniBar(90, r.pm10, 200, ST7735_MAGENTA, KHI_PM10_THRESHOLD);
  }
  else if (screenIdx == 4) {
    tft.setTextSize(2); tft.setCursor(10, 30); tft.setTextColor(ST7735_YELLOW, ST7735_BLACK);
    tft.printf("P:%.0f hPa", p);
    tft.setCursor(10, 65); tft.setTextColor(ST7735_GREEN, ST7735_BLACK);
    tft.printf("A:%.0f m", alt);
  }
  else if (screenIdx == 5) {
    tft.setTextSize(1);
    if (gps.location.isValid()) {
      tft.setTextColor(ST7735_GREEN, ST7735_BLACK);
      tft.setCursor(10, 30); tft.printf("LAT: %.5f", gps.location.lat());
      tft.setCursor(10, 50); tft.printf("LNG: %.5f", gps.location.lng());
    } else {
      tft.setTextColor(ST7735_YELLOW, ST7735_BLACK);
      tft.setCursor(10, 30); tft.printf("LAT: %.5f (cached)", lastLat);
      tft.setCursor(10, 50); tft.printf("LNG: %.5f (cached)", lastLng);
    }
    tft.setCursor(10, 70); tft.setTextColor(ST7735_WHITE, ST7735_BLACK);
    tft.printf("SATS: %d", gps.satellites.value());
  }
  else if (screenIdx == 6) {
    tft.setTextSize(1);
    tft.setCursor(10, 30); 
    tft.setTextColor(alarmActive ? ST7735_RED : ST7735_GREEN, ST7735_BLACK);
    tft.println(alarmActive ? "Status: ALARM!" : "Status: NORMAL");
    tft.setTextColor(ST7735_WHITE, ST7735_BLACK);
    tft.setCursor(10, 50); tft.printf("IP: %s", WiFi.localIP().toString().c_str());
    tft.setCursor(10, 70); tft.print("DB: " + String(firebaseReady ? "Active" : "Offline"));
    if (alarmActive) {
      tft.setCursor(10, 90);
      tft.setTextColor(ST7735_RED, ST7735_BLACK);
      tft.print("Alarm: " + currentAlarm);
    }
  }
}

// ==========================================
// 🔵 SETUP (ORIGINAL ORDER, but with WiFi timeout)
// ==========================================
void setup() {
  Serial.begin(115200);

  // 1. Hardware Init
  pmsSerial.begin(9600, SERIAL_8N1, PMS_TX_PIN, -1);
  gpsSerial.begin(115200, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);

  Serial.println("Raw GPS data for 15 seconds:");
unsigned long start = millis();
while (millis() - start < 15000) {
  while (gpsSerial.available()) {
    char c = gpsSerial.read();
    Serial.print(c);   // print every character
  }
}
Serial.println("\nEnd of raw data check.");

  Wire.begin(BMP_SDA, BMP_SCL);
  bmp.begin(0x76);
  dht.begin();
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  pinMode(BUZZER_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, LOW);

  // 2. WiFi Init with timeout (non‑blocking)
  wifiMulti.addAP(WIFI_SSID_1, WIFI_PASS_1);
  wifiMulti.addAP(WIFI_SSID_2, WIFI_PASS_2);
  Serial.print("Connecting WiFi...");
  unsigned long wifiStart = millis();
  while (wifiMulti.run() != WL_CONNECTED) {
    Serial.print(".");
    delay(500);
    if (millis() - wifiStart > 15000) {
      Serial.println("\nWiFi connection timeout - continuing offline");
      break;
    }
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.println("\nWiFi Connected!");

    // ---- NTP Time Sync ----
    configTime(0, 0, "pool.ntp.org", "time.nist.gov", "time.google.com");
    Serial.print("Waiting for NTP time sync...");
    time_t now = time(nullptr);
    while (now < 100000) {   // wait until a reasonable date (post‑2000)
      delay(500);
      Serial.print(".");
      now = time(nullptr);
    }
    Serial.println("\nNTP time acquired");

    // 3. Send Startup Discord Message
    sendToDiscord("# 🟢 AQMS SYSTEM ONLINE\nSystem booted successfully. Monitoring sensors.");
    delay(1000);

    // 4. Force First Read & Report
    pms.readUntil(data, 500);
    sendDiscordReport();
  } else {
    Serial.println("\nNo WiFi, will operate offline.");
    // Still read sensors (no Discord)
    pms.readUntil(data, 500);
  }

  // 5. Firebase Init (will work offline, writes queued)
  config.database_url = DATABASE_URL;
  config.signer.tokens.legacy_token = DATABASE_SECRET;
  Firebase.begin(&config, &auth);
  Firebase.reconnectWiFi(true);
  firebaseReady = true;

  // 6. TFT & Server
  server.on("/data", handleJsonData);
  server.begin();

  tft.initR(INITR_BLACKTAB);
  tft.setRotation(1);
  tft.fillScreen(ST7735_BLACK);
  drawStaticUI();

  // Pre‑fill filter buffers
  for (int i = 0; i < FILTER_SIZE; i++) {
    readCO_RawFiltered();
    readCO2_RawFiltered();
    delay(10);
  }
}

// ==========================================
// 🔄 LOOP (SIMPLE BUTTON SCREEN SWITCH)
// ==========================================
void loop() {
  if (WiFi.status() == WL_CONNECTED) server.handleClient();
  while (gpsSerial.available() > 0) { gps.encode(gpsSerial.read()); }
  if (wifiMulti.run() != WL_CONNECTED) {}

  // Track online/offline for queue flushing
  bool nowOnline = (WiFi.status() == WL_CONNECTED) && firebaseReady;
  if (nowOnline && !isOnline) {
    isOnline = true;
    flushQueue();
  } else if (!nowOnline && isOnline) {
    isOnline = false;
  }

  // --- BUTTON (SIMPLE SCREEN SWITCH) ---
  if (digitalRead(BUTTON_PIN) == LOW) {
    screenIdx = (screenIdx + 1) % 7;
    tft.fillScreen(ST7735_BLACK);
    drawStaticUI();
    updateDisplay();
    delay(300);
  }

  unsigned long currentMillis = millis();

  if (currentMillis - lastScreenUpdate >= SCREEN_INTERVAL) {
    lastScreenUpdate = currentMillis;
    pulseState = !pulseState;
    updateDisplay();
  }

  if (currentMillis - lastFirebaseUpdate >= FIREBASE_INTERVAL) {
    lastFirebaseUpdate = currentMillis;
    sendToFirebase();
  }

  if (currentMillis - lastDiscordUpdate >= DISCORD_INTERVAL) {
    lastDiscordUpdate = currentMillis;
    if (WiFi.status() == WL_CONNECTED) {
      sendDiscordReport();
    }
  }

  if (currentMillis - lastBuzzerCheck >= BUZZER_CHECK_INTERVAL) {
    lastBuzzerCheck = currentMillis;
    checkSensorThresholds();
  }

  updateBuzzerPattern();
}