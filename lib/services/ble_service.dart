import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BleService {
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;
  BleService._internal();

  bool _isConnecting = false;
  bool _isIntentionalDisconnect = false;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 3;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxCharacteristic; // Write
  BluetoothCharacteristic? _txCharacteristic; // Notify
  
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription? _connectionStateSub;

  final StreamController<bool> _connectionStateController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStateStream => _connectionStateController.stream;

  final StreamController<String> _rawDataController = StreamController<String>.broadcast();
  Stream<String> get rawDataStream => _rawDataController.stream;

  bool get isConnected => _device != null && _device!.isConnected;

  // Custom Constants
  static const String targetDeviceName = "ESP32_VitalsRig_01";
  static final Guid serviceUuid = Guid("6fa41660-6244-4aa0-aee4-06d9377ad51b");
  static final Guid rxCharUuid = Guid("bf9dace6-017f-4793-abf9-5d117db16e55");
  static final Guid txCharUuid = Guid("41d5a28d-de2a-4ab4-aa6e-31ab8472925c");

  // Chunking Buffer State
  final Map<int, List<int>> _chunkBuffer = {};
  int _expectedChunks = 0;

  Future<bool> connectToEsp32() async {
    if (_isConnecting) return false;
    _isIntentionalDisconnect = false;
    
    try {
      _isConnecting = true;
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }

      Completer<bool> completer = Completer();
      
      // Filter scanning exclusively by the target Service UUID
      var subscription = FlutterBluePlus.scanResults.listen((results) async {
        for (ScanResult r in results) {
          final name = r.device.platformName;
          final advName = r.device.advName;
          
          if (name == targetDeviceName || advName == targetDeviceName) {
            await FlutterBluePlus.stopScan();
            
            if (_device == null || _device!.remoteId != r.device.remoteId) {
                _device = r.device;
                try {
                  // Bypass slow background discovery
                  await _device!.connect(autoConnect: false);
                  debugPrint('BLE connected to ${_device!.platformName}');
                  
                  // Negotiate High MTU immediately to minimize fragmentation
                  if (Platform.isAndroid) {
                    await _device!.requestMtu(512);
                    debugPrint('MTU negotiated up to 512');
                  }
                  
                  _connectionStateController.add(true);

                  _connectionStateSub = FlutterBluePlus.events.onConnectionStateChanged.listen((event) {
                    if (event.device.remoteId == _device?.remoteId &&
                        event.connectionState == BluetoothConnectionState.disconnected) {
                      _connectionStateController.add(false);
                      _cleanup();
                      if (!_isIntentionalDisconnect) {
                        _handleAutoReconnect();
                      }
                    }
                  });

                  // Trigger service discovery
                  List<BluetoothService> services = await _device!.discoverServices();
                  BluetoothService? targetService;
                  
                  for (BluetoothService s in services) {
                    if (s.serviceUuid == serviceUuid) {
                      targetService = s;
                      break;
                    }
                  }

                  if (targetService == null) {
                    debugPrint('FATAL: Target Service UUID $serviceUuid not found!');
                    if (!completer.isCompleted) completer.complete(false);
                    return;
                  }

                  // Bind Characteristics
                  for (BluetoothCharacteristic c in targetService.characteristics) {
                    if (c.characteristicUuid == rxCharUuid) {
                      _rxCharacteristic = c;
                    } else if (c.characteristicUuid == txCharUuid) {
                      _txCharacteristic = c;
                    }
                  }

                  if (_rxCharacteristic == null || _txCharacteristic == null) {
                    debugPrint('FATAL: Failed to bind RX or TX characteristics!');
                    if (!completer.isCompleted) completer.complete(false);
                    return;
                  }

                  // Subscribe to TX notifications
                  await _subscribeToTxCharacteristic();
                  
                  if (!completer.isCompleted) completer.complete(true);
                } catch (e) {
                  debugPrint('Error during connection/binding: $e');
                  if (!completer.isCompleted) completer.complete(false);
                }
            }
          }
        }
      });

      await FlutterBluePlus.startScan(
        withServices: [serviceUuid], 
        timeout: const Duration(seconds: 15)
      );

      bool connected = await completer.future.timeout(const Duration(seconds: 15), onTimeout: () => false);
      subscription.cancel();
      
      if (!connected) {
        _connectionStateController.add(false);
      }
      _isConnecting = false;
      return connected;
    } catch (e) {
      debugPrint('BLE scan/connect error: $e');
      _connectionStateController.add(false);
      _isConnecting = false;
      return false;
    }
  }

  Future<void> _handleAutoReconnect() async {
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint('FATAL: Max reconnect attempts reached. Giving up.');
      _isConnecting = false;
      _connectionStateController.add(false);
      return;
    }

    _reconnectAttempts++;
    final int delaySeconds = 1 << _reconnectAttempts; // 2^1=2, 2^2=4, 2^3=8
    debugPrint('Attempting auto-reconnect (Attempt $_reconnectAttempts of $_maxReconnectAttempts) in $delaySeconds seconds...');
    
    await Future.delayed(Duration(seconds: delaySeconds));
    
    bool success = await connectToEsp32();
    if (success) {
      debugPrint('Auto-reconnect successful!');
      _reconnectAttempts = 0; // Reset counter on success
    } else {
      // Retry recursively if this attempt failed
      _handleAutoReconnect();
    }
  }

  Future<void> _subscribeToTxCharacteristic() async {
    if (_txCharacteristic == null) return;
    
    await _txCharacteristic!.setNotifyValue(true);
    _notifySub = _txCharacteristic!.lastValueStream.listen((value) {
      if (value.isEmpty) return;
      
      // Implement Custom Chunking Parser
      int header = value[0];
      int totalChunks = header >> 4;
      int chunkIndex = header & 0x0F;

      if (totalChunks == 0) return; // Invalid header
      
      // Reset buffer if this is the start of a new packet sequence
      if (_expectedChunks == 0 || _expectedChunks != totalChunks || chunkIndex == 0) {
        _chunkBuffer.clear();
        _expectedChunks = totalChunks;
      }
      
      // Store payload fragment (strip byte[0] header)
      _chunkBuffer[chunkIndex] = value.sublist(1);
      
      // Check if all chunks have arrived
      if (_chunkBuffer.length == totalChunks) {
        List<int> fullPayload = [];
        for (int i = 0; i < totalChunks; i++) {
          if (_chunkBuffer.containsKey(i)) {
            fullPayload.addAll(_chunkBuffer[i]!);
          } else {
            debugPrint('Missing chunk index $i, dropping packet.');
            _chunkBuffer.clear();
            _expectedChunks = 0;
            return;
          }
        }
        
        _chunkBuffer.clear();
        _expectedChunks = 0;
        
        _processReassembledPayload(fullPayload);
      }
    });
  }

  void _processReassembledPayload(List<int> payloadBytes) {
    try {
      String rawStr = utf8.decode(payloadBytes);
      
      // Format: <SENSOR_CODE> | <json_payload> | <CRC8_hex>
      List<String> parts = rawStr.split('|').map((e) => e.trim()).toList();
      
      if (parts.length >= 3) {
        String sensorCode = parts[0];
        String jsonPayload = parts[1];
        String crcHex = parts[2];
        
        // Local CRC8 validation on json_payload
        int computedCrc = _computeCrc8(utf8.encode(jsonPayload));
        int receivedCrc = int.parse(crcHex, radix: 16);
        
        if (computedCrc == receivedCrc) {
          debugPrint('Valid Packet - Sensor: $sensorCode, Data: $jsonPayload');
          // Pass valid raw data downstream to UI
          _rawDataController.add(rawStr);
        } else {
          debugPrint('CRC mismatch! Computed: 0x${computedCrc.toRadixString(16)}, Received: 0x$crcHex');
        }
      } else {
        debugPrint('Malformed payload structure: $rawStr');
      }
    } catch (e) {
      debugPrint('Failed to process reassembled payload: $e');
    }
  }
  
  // Standard ATM/HEC CRC-8 implementation (Polynomial: 0x07)
  int _computeCrc8(List<int> data) {
    int crc = 0x00;
    for (int i = 0; i < data.length; i++) {
      crc ^= data[i];
      for (int j = 0; j < 8; j++) {
        if ((crc & 0x80) != 0) {
          crc = (crc << 1) ^ 0x07;
        } else {
          crc <<= 1;
        }
        crc &= 0xFF;
      }
    }
    return crc;
  }

  Future<void> sendCommand(String cmd) async {
    if (_rxCharacteristic != null && isConnected) {
      try {
        await _rxCharacteristic!.write(utf8.encode(cmd), withoutResponse: false);
        debugPrint('Sent command: $cmd');
      } catch (e) {
        debugPrint('Failed to send command: $e');
      }
    }
  }

  void _cleanup() {
    _notifySub?.cancel();
    _notifySub = null;
    _rxCharacteristic = null;
    _txCharacteristic = null;
    _chunkBuffer.clear();
    _expectedChunks = 0;
    _device = null;
  }

  Future<void> disconnect() async {
    _isIntentionalDisconnect = true;
    await _notifySub?.cancel();
    await _connectionStateSub?.cancel();
    if (_device != null) {
      await _device!.disconnect();
    }
    _cleanup();
    _connectionStateController.add(false);
  }
}
