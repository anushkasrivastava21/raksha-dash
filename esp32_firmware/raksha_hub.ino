#include <WiFi.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ---------------------------------------------------------
// 1. CONSTANTS & CREDENTIALS
// ---------------------------------------------------------
const char* WIFI_SSID     = "YOUR_SSID";
const char* WIFI_PASSWORD = "YOUR_PASSWORD";
const char* PI_BASE_URL   = "http://192.168.1.100:8000/run_triage"; // Change to actual Pi LAN IP

// BLE Nordic UART Service (NUS) UUIDs
#define SERVICE_UUID           "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_RX "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

// ---------------------------------------------------------
// 2. GLOBALS
// ---------------------------------------------------------
BLEServer *pServer = NULL;
BLECharacteristic *pTxCharacteristic;
bool deviceConnected = false;

// Sensor states
bool g_tempReady = false;
float g_tempC = 0.0;

bool g_urineReady = false;
int g_urineR = 0, g_urineG = 0, g_urineB = 0;

bool g_ecgReady = false;
int g_ecgHR = 0;
int g_ecgSamples[20];

bool g_spo2Ready = false;
int g_spo2Hr = 0;
float g_spo2Pct = 0.0;

bool g_stethReady = false;
int g_stethRms = 0, g_stethMin = 0, g_stethMax = 0;

char g_voiceKeywords[256] = "";

// ---------------------------------------------------------
// 3. BLE CALLBACKS
// ---------------------------------------------------------
class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
      deviceConnected = true;
      Serial.println("[BLE] Device connected");
    };

    void onDisconnect(BLEServer* pServer) {
      deviceConnected = false;
      Serial.println("[BLE] Device disconnected");
      BLEDevice::startAdvertising(); // restart advertising
    }
};

void handleIncomingCommand(String cmd); // Forward decl

class MyCallbacks: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) {
      std::string rxValue = pCharacteristic->getValue();
      if (rxValue.length() > 0) {
        String cmd = "";
        for (int i = 0; i < rxValue.length(); i++) {
          cmd += rxValue[i];
        }
        cmd.trim();
        Serial.println("[BLE RX] " + cmd);
        handleIncomingCommand(cmd);
      }
    }
};

// ---------------------------------------------------------
// 4. NETWORKING
// ---------------------------------------------------------
void connectWiFi() {
  Serial.print("[WiFi] Connecting to ");
  Serial.println(WIFI_SSID);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  int retries = 0;
  while (WiFi.status() != WL_CONNECTED && retries < 20) {
    delay(500);
    Serial.print(".");
    retries++;
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.println("\n[WiFi] Connected! IP: " + WiFi.localIP().toString());
  } else {
    Serial.println("\n[WiFi] Failed to connect.");
  }
}

void sendPacket(String fullPacket) {
  Serial.println(fullPacket); // USB Debug
  if (deviceConnected && pTxCharacteristic != NULL) {
    pTxCharacteristic->setValue(fullPacket.c_str());
    pTxCharacteristic->notify();
  }
}

void sendTriageToPi() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[TRIAGE] Error: WiFi not connected");
    return;
  }

  Serial.println("[TRIAGE] POSTing to Pi: " + String(PI_BASE_URL));

  // Build JSON Payload
  JsonDocument doc;
  
  if (g_ecgReady) {
    JsonObject ecg = doc["ecg"].to<JsonObject>();
    ecg["heart_rate_bpm"] = g_ecgHR;
    JsonArray samples = ecg["samples"].to<JsonArray>();
    for (int i=0; i<20; i++) samples.add(g_ecgSamples[i]);
  }
  
  if (g_urineReady) {
    JsonObject urine = doc["urine_sensor"].to<JsonObject>();
    urine["red"] = g_urineR;
    urine["green"] = g_urineG;
    urine["blue"] = g_urineB;
  }
  
  if (g_stethReady) {
    JsonObject steth = doc["stethoscope"].to<JsonObject>();
    steth["rms"] = g_stethRms;
    steth["min"] = g_stethMin;
    steth["max"] = g_stethMax;
    steth["samples"] = 50;
  }
  
  if (g_tempReady) {
    doc["temperature"]["body_temp_c"] = g_tempC;
  }
  
  if (g_spo2Ready) {
    JsonObject spo2 = doc["pulse_oximeter"].to<JsonObject>();
    spo2["heart_rate_bpm"] = g_spo2Hr;
    spo2["spo2_percent"] = g_spo2Pct;
  }

  // Voice Keywords (CSV string to JSON Array)
  if (strlen(g_voiceKeywords) > 0) {
    JsonArray kw = doc["voice_keywords"].to<JsonArray>();
    String kwStr = String(g_voiceKeywords);
    int start = 0;
    int end = kwStr.indexOf(',');
    while (end != -1) {
      kw.add(kwStr.substring(start, end));
      start = end + 1;
      end = kwStr.indexOf(',', start);
    }
    kw.add(kwStr.substring(start)); // Add last one
  }

  // Step 3 BP (mock static since it's just passed through)
  JsonObject bp = doc["step_3_bp"].to<JsonObject>();
  bp["systolic"] = 120;
  bp["diastolic"] = 80;

  String jsonPayload;
  serializeJson(doc, jsonPayload);
  Serial.println("[TRIAGE] Payload: " + jsonPayload);

  // Send POST Request
  HTTPClient http;
  http.begin(PI_BASE_URL);
  http.addHeader("Content-Type", "application/json");
  
  int httpResponseCode = http.POST(jsonPayload);
  if (httpResponseCode > 0) {
    String response = http.getString();
    Serial.println("[TRIAGE] Response: " + response);
    // Forward the Pi's AI triage result back to the phone
    sendPacket("TRIAGE|" + response + "|CRC");
  } else {
    Serial.println("[TRIAGE] Error on POST: " + String(httpResponseCode));
    sendPacket("TRIAGE|{\"triage\":\"Error\",\"confidence\":0.0,\"ecg_result\":\"Timeout\",\"symptoms\":[]}|CRC");
  }
  http.end();
}

// ---------------------------------------------------------
// 5. MOCK SENSOR LOGIC
// ---------------------------------------------------------
void stepTempSequence() {
  g_tempC = 36.7; 
  g_tempReady = true;
  sendPacket("TEMP|{\"body_temp_c\":36.7}|CRC");
}

void stepEcgSequence() {
  g_ecgHR = 78;
  for(int i=0; i<20; i++) g_ecgSamples[i] = 1850 + (i*10); // Mock wave
  g_ecgReady = true;
  sendPacket("ECG|{\"heart_rate_bpm\":78,\"samples\":[1850,1860,1870,1880]}|CRC");
}

void stepSpo2Sequence() {
  g_spo2Hr = 72;
  g_spo2Pct = 98.0;
  g_spo2Ready = true;
  sendPacket("SPO2|{\"spo2_percent\":98.0,\"heart_rate_bpm\":72}|CRC");
}

void stepUrineSequence() {
  g_urineR = 3300; g_urineG = 3250; g_urineB = 3400;
  g_urineReady = true;
  sendPacket("URINE|{\"red\":3300,\"green\":3250,\"blue\":3400}|CRC");
}

void stepStethSequence() {
  g_stethRms = 220; g_stethMin = 1500; g_stethMax = 2600;
  g_stethReady = true;
  sendPacket("STETH|{\"rms\":220,\"min\":1500,\"max\":2600,\"samples\":50}|CRC");
}

// ---------------------------------------------------------
// 6. COMMAND PARSER
// ---------------------------------------------------------
void handleIncomingCommand(String cmd) {
  if (cmd == "REQ_TEMP") {
    stepTempSequence();
  } else if (cmd == "REQ_ECG") {
    stepEcgSequence();
  } else if (cmd == "REQ_SPO2") {
    stepSpo2Sequence();
  } else if (cmd == "REQ_URINE") {
    stepUrineSequence();
  } else if (cmd == "REQ_STETH") {
    stepStethSequence();
  } else if (cmd.startsWith("VOICE_KW:")) {
    String kw = cmd.substring(9);
    kw.toCharArray(g_voiceKeywords, sizeof(g_voiceKeywords));
    Serial.println("[VOICE] Stored: " + String(g_voiceKeywords));
  } else if (cmd == "SEND_TRIAGE") {
    sendTriageToPi();
  } else if (cmd == "PING") {
    sendPacket("PONG");
  } else {
    Serial.println("[WARN] Unknown command: " + cmd);
  }
}

void serviceSerialInput() {
  if (Serial.available()) {
    String cmd = Serial.readStringUntil('\n');
    cmd.trim();
    if (cmd.length() > 0) {
      handleIncomingCommand(cmd);
    }
  }
}

// ---------------------------------------------------------
// 7. ARDUINO SETUP & LOOP
// ---------------------------------------------------------
void setup() {
  Serial.begin(115200);
  Serial.println("Raksha ESP32 Hub Booting...");

  // BLE Setup
  BLEDevice::init("Raksha-ESP32");
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);
  
  // TX Characteristic
  pTxCharacteristic = pService->createCharacteristic(
                        CHARACTERISTIC_UUID_TX,
                        BLECharacteristic::PROPERTY_NOTIFY
                      );
  pTxCharacteristic->addDescriptor(new BLE2902());

  // RX Characteristic
  BLECharacteristic *pRxCharacteristic = pService->createCharacteristic(
                                           CHARACTERISTIC_UUID_RX,
                                           BLECharacteristic::PROPERTY_WRITE
                                         );
  pRxCharacteristic->setCallbacks(new MyCallbacks());

  pService->start();
  pServer->getAdvertising()->start();
  Serial.println("[BLE] Started advertising as Raksha-ESP32");

  // Connect WiFi
  connectWiFi();
}

void loop() {
  serviceSerialInput();
  delay(10);
}
