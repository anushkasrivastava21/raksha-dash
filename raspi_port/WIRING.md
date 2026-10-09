| Sensor | Signal | ESP32 GPIO | Direction | Notes |
|---|---|---|---|---|
| MLX90614 (temp) | SDA | 21 | I2C | Shared with MAX30102 |
| MLX90614 (temp) | SCL | 22 | I2C | Shared with MAX30102 |
| MAX30102 (SpO2) | SDA | 21 | I2C | Shared with MLX90614 |
| MAX30102 (SpO2) | SCL | 22 | I2C | Shared with MAX30102 |
| MAX30102 (SpO2) | INT | 16 | Input | Interrupt pin |
| MAX4466 (steth) | OUT | 35 | ADC Input | ADC1_CH7, input-only |
| AD8232 (ECG) | OUTPUT | 34 | ADC Input | ADC1_CH6, input-only |
| AD8232 (ECG) | LO+ | 32 | Input | Leads-off detect |
| AD8232 (ECG) | LO- | 33 | Input | Leads-off detect |
| TCS3200 (urine) | S0 | 13 | Output | Frequency scaling |
| TCS3200 (urine) | S1 | 17 | Output | Frequency scaling |
| TCS3200 (urine) | S2 | 18 | Output | Color filter select |
| TCS3200 (urine) | S3 | 19 | Output | Color filter select |
| TCS3200 (urine) | OUT | 23 | Input | Frequency output |
