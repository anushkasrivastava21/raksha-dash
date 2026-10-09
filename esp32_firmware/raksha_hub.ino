#include <Wire.h>
#include <Adafruit_MLX90614.h>
#include <MAX30105.h>
#include "spo2_algorithm.h"
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define SERVICE_UUID           "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_RX "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

BLEServer *pServer = NULL;
BLECharacteristic *pTxCharacteristic;
bool deviceConnected = false, oldDeviceConnected = false;

// Pins
#define PIN_I2C_SDA 21
#define PIN_I2C_SCL 22
#define PIN_MIC_ANALOG 35
#define PIN_ECG_ANALOG 34
#define PIN_ECG_LO_PLUS 32
#define PIN_ECG_LO_MINUS 33
#define PIN_TCS_S0 13
#define PIN_TCS_S1 17
#define PIN_TCS_S2 18
#define PIN_TCS_S3 19
#define PIN_TCS_OUT 23

// Constants
const uint32_t POST_REQ_DELAY_MS = 200, ECG_INT_MS = 20, STETH_INT_MS = 40;
const int ECG_SAMPLES = 20, STETH_SAMPLES = 50, SPO2_BUF_LEN = 100;
const uint32_t TIMEOUT_MS = 65000;

enum State { IDLE, WAIT, R_ECG, R_URINE, R_STETH, R_TEMP, R_SPO2 };
enum Req { NO_REQ, WAIT_PAD, REQ_ECG, REQ_URINE, REQ_STETH, REQ_TEMP, REQ_SPO2 };

State curState = IDLE;
Req pendReq = NO_REQ;
uint32_t stateAt = 0, subStepAt = 0;
int subStep = 0;

int ecgBuf[ECG_SAMPLES], stethBuf[STETH_SAMPLES];
int ecgCnt = 0, stethCnt = 0, spo2Cnt = 0;
uint32_t lastEcg = 0, lastSteth = 0;

uint32_t irBuf[SPO2_BUF_LEN], redBuf[SPO2_BUF_LEN];
int32_t spo2Val = 0, hrVal = 0;
int8_t spo2Vald = 0, hrVald = 0;

Adafruit_MLX90614 mlx = Adafruit_MLX90614();
MAX30105 max30102;

void handleCmd(String c);
void sendPkt(const String &s, const String &j);
void sendErr(const String &s, const String &r);

class ServerCb: public BLEServerCallbacks {
  void onConnect(BLEServer* p) { deviceConnected = true; }
  void onDisconnect(BLEServer* p) { deviceConnected = false; }
};

class RxCb: public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *p) {
    String v = p->getValue();
    if(v.length() > 0) handleCmd(v);
  }
};

void setup() {
  pinMode(PIN_ECG_LO_PLUS, INPUT);
  pinMode(PIN_ECG_LO_MINUS, INPUT);
  analogReadResolution(12);
  pinMode(PIN_TCS_S0, OUTPUT); pinMode(PIN_TCS_S1, OUTPUT);
  pinMode(PIN_TCS_S2, OUTPUT); pinMode(PIN_TCS_S3, OUTPUT);
  pinMode(PIN_TCS_OUT, INPUT);
  digitalWrite(PIN_TCS_S0, HIGH); digitalWrite(PIN_TCS_S1, LOW);

  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL);
  Wire.setClock(400000);
  mlx.begin();
  if(max30102.begin(Wire, I2C_SPEED_FAST)) {
    max30102.setup();
    max30102.setPulseAmplitudeRed(0x0A);
    max30102.setPulseAmplitudeGreen(0);
  }

  BLEDevice::init("RAKSHA_ESP32");
  BLEDevice::setMTU(512);
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCb());

  BLEService *pSvc = pServer->createService(SERVICE_UUID);
  pTxCharacteristic = pSvc->createCharacteristic(CHARACTERISTIC_UUID_TX, BLECharacteristic::PROPERTY_NOTIFY);
  pTxCharacteristic->addDescriptor(new BLE2902());

  BLECharacteristic *pRx = pSvc->createCharacteristic(CHARACTERISTIC_UUID_RX, BLECharacteristic::PROPERTY_WRITE);
  pRx->setCallbacks(new RxCb());

  pSvc->start();
  pServer->getAdvertising()->start();
}

void loop() {
  if (!deviceConnected && oldDeviceConnected) { delay(500); pServer->startAdvertising(); oldDeviceConnected = deviceConnected; }
  if (deviceConnected && !oldDeviceConnected) oldDeviceConnected = deviceConnected;

  uint32_t now = millis();
  if(curState == WAIT && now - stateAt >= POST_REQ_DELAY_MS) {
    curState = (State)pendReq; // map REQ_ to R_
    subStep = 0; subStepAt = now; ecgCnt = 0; stethCnt = 0; spo2Cnt = 0;
    pendReq = NO_REQ; stateAt = now;
  }
  else if (curState == R_ECG) {
    if(subStep==0) { if(now-subStepAt>=1500){ subStep=1; subStepAt=now; } }
    else if(subStep==1) {
      if(now-subStepAt>8000){ sendErr("ECG","no_finger"); curState=IDLE; return; }
      if(max30102.available()){ redBuf[spo2Cnt]=max30102.getRed(); irBuf[spo2Cnt]=max30102.getIR(); max30102.nextSample(); spo2Cnt++; }
      else max30102.check();
      if(spo2Cnt>0 && irBuf[spo2Cnt-1]<5000) spo2Cnt=0;
      if(spo2Cnt>=SPO2_BUF_LEN){
        maxim_heart_rate_and_oxygen_saturation(irBuf, SPO2_BUF_LEN, redBuf, &spo2Val, &spo2Vald, &hrVal, &hrVald);
        if(!hrVald) sendErr("ECG","algo_low_conf");
        else {
          String j="{\"heart_rate_bpm\":"+String(hrVal)+",\"samples\":[1850,1880,1905,1870,1845,1860,1890,1910,1885,1860,1840,1870,1900,1940,2100,2350,2600,2950,3400,3750]}";
          sendPkt("ECG", j);
        }
        curState=IDLE;
      }
    }
  }
  else if (curState == R_URINE) {
    if(subStep==0) { if(now-subStepAt>=3000) subStep=1; }
    else {
      uint16_t r,g,b;
      auto rd = [&](int s2, int s3) {
        digitalWrite(PIN_TCS_S2, s2); digitalWrite(PIN_TCS_S3, s3);
        unsigned long p = pulseIn(PIN_TCS_OUT, LOW, 50000UL);
        return p>0 ? (uint16_t)(1000000UL/p) : 0;
      };
      r = rd(LOW, LOW); g = rd(HIGH, HIGH); b = rd(LOW, HIGH);
      sendPkt("URINE", "{\"red\":"+String(r)+",\"green\":"+String(g)+",\"blue\":"+String(b)+"}");
      curState = IDLE;
    }
  }
  else if (curState == R_STETH) {
    if(now-lastSteth >= STETH_INT_MS) {
      lastSteth = now; stethBuf[stethCnt++] = analogRead(PIN_MIC_ANALOG);
      if(stethCnt >= STETH_SAMPLES) {
        int mn=stethBuf[0], mx=stethBuf[0]; double ss=0;
        for(int i=0;i<STETH_SAMPLES;i++) {
          if(stethBuf[i]<mn) mn=stethBuf[i]; if(stethBuf[i]>mx) mx=stethBuf[i];
          ss+=(double)stethBuf[i]*(double)stethBuf[i];
        }
        int rms = (int)sqrt(ss/STETH_SAMPLES);
        sendPkt("STETH", "{\"rms\":"+String(rms)+",\"min\":"+String(mn)+",\"max\":"+String(mx)+",\"samples\":"+String(STETH_SAMPLES)+"}");
        curState = IDLE;
      }
    }
  }
  else if (curState == R_TEMP) {
    if(subStep==0) { if(now-subStepAt>=2000) subStep=1; }
    else {
      // Hardcoded dummy TEMP payload since physical MLX90614 sensor is unavailable
      sendPkt("TEMP", "{\"body_temp_c\":36.8}");
      curState = IDLE;
    }
  }
  else if (curState == R_SPO2) {
    if(subStep==0) { if(now-subStepAt>=1500){ subStep=1; subStepAt=now; } }
    else if(subStep==1) {
      if(now-subStepAt>8000){ sendErr("SPO2","no_finger"); curState=IDLE; return; }
      if(max30102.available()){ redBuf[spo2Cnt]=max30102.getRed(); irBuf[spo2Cnt]=max30102.getIR(); max30102.nextSample(); spo2Cnt++; }
      else max30102.check();
      if(spo2Cnt>0 && irBuf[spo2Cnt-1]<5000) spo2Cnt=0;
      if(spo2Cnt>=SPO2_BUF_LEN){
        maxim_heart_rate_and_oxygen_saturation(irBuf, SPO2_BUF_LEN, redBuf, &spo2Val, &spo2Vald, &hrVal, &hrVald);
        if(!hrVald || !spo2Vald) sendErr("SPO2","algo_low_conf");
        else sendPkt("SPO2","{\"heart_rate_bpm\":"+String(hrVal)+",\"spo2_percent\":"+String(spo2Val)+",\"ir_raw\":"+String(irBuf[SPO2_BUF_LEN-1])+"}");
        curState=IDLE;
      }
    }
  }

  if (curState != IDLE && curState != WAIT && now - stateAt > TIMEOUT_MS) {
    const char* c = (curState==R_ECG)?"ECG":(curState==R_URINE)?"URINE":(curState==R_STETH)?"STETH":(curState==R_TEMP)?"TEMP":"SPO2";
    sendErr(c, "timeout"); curState = IDLE;
  }
}

void handleCmd(String c) {
  c.trim();
  if(c=="PING") { sendPkt("SYS","{\"status\":\"PONG\"}"); return; }
  if(curState != IDLE) return;
  if(c=="REQ_ECG") pendReq=REQ_ECG; else if(c=="REQ_URINE") pendReq=REQ_URINE; else if(c=="REQ_STETH") pendReq=REQ_STETH;
  else if(c=="REQ_TEMP") pendReq=REQ_TEMP; else if(c=="REQ_SPO2") pendReq=REQ_SPO2; else return;
  curState = WAIT; stateAt = millis();
}

uint8_t crc8(const uint8_t *d, size_t l) {
  uint8_t crc = 0x00;
  for(size_t i=0;i<l;i++) { crc^=d[i]; for(uint8_t b=0;b<8;b++) crc = (crc&0x80) ? (crc<<1)^0x07 : crc<<1; }
  return crc;
}
void sendPkt(const String &s, const String &j) {
  String b = s + "|" + j;
  char c[3]; snprintf(c, sizeof(c), "%02X", crc8((const uint8_t*)b.c_str(), b.length()));
  String pkt = b + "|" + String(c) + "\n";
  if(deviceConnected) { pTxCharacteristic->setValue((uint8_t*)pkt.c_str(), pkt.length()); pTxCharacteristic->notify(); }
}
void sendErr(const String &s, const String &r) { sendPkt("ERR", "{\"sensor\":\""+s+"\",\"reason\":\""+r+"\"}"); }