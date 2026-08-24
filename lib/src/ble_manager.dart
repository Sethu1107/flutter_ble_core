import 'dart:async';

import 'package:flutter/services.dart';

import 'config/ble_config.dart';
import 'enums/ble_connection_state.dart';
import 'enums/bluetooth_state.dart';
import 'exceptions/ble_exception.dart';
import 'models/ble_scan_result.dart';
import 'models/ble_service.dart';

/// Public entry point for the flutter_ble_core BLE API.
///
/// Wraps a [MethodChannel] for one-shot commands and an [EventChannel] for
/// continuous native events (scan results, connection state, notifications).
class BleManager {
  static const MethodChannel _methodChannel =
      MethodChannel('flutter_ble/methods');

  static const EventChannel _eventChannel =
      EventChannel('flutter_ble/events');

  StreamSubscription? _eventSubscription;
  bool _initialized = false;

  final StreamController<BluetoothState> _bluetoothStateController =
      StreamController.broadcast();

  final StreamController<BleScanResult> _scanController =
      StreamController.broadcast();

  final StreamController<({String deviceId, BleConnectionState state})>
      _connectionController = StreamController.broadcast();

  final StreamController<
      ({String deviceId, String serviceUuid, String characteristicUuid, Uint8List value})>
      _notificationController = StreamController.broadcast();

  /// Emits whenever the adapter-level Bluetooth state changes.
  Stream<BluetoothState> get bluetoothStateStream =>
      _bluetoothStateController.stream;

  /// Emits one result per discovered advertisement while scanning.
  Stream<BleScanResult> get scanResults => _scanController.stream;

  /// Emits per-device GATT connection state transitions.
  Stream<({String deviceId, BleConnectionState state})>
      get connectionStateStream => _connectionController.stream;

  /// Emits notified/indicated characteristic values.
  Stream<({String deviceId, String serviceUuid, String characteristicUuid, Uint8List value})>
      get characteristicValueStream => _notificationController.stream;

  /// Sets up the native BLE stack and starts listening for events.
  ///
  /// Must be called before any other method. Does not request runtime
  /// permissions — the host app is responsible for that.
  Future<void> initialize() async {
    if (_initialized) return;

    await _invoke('initialize');
    _eventSubscription ??=
        _eventChannel.receiveBroadcastStream().listen(_handleEvent);
    _initialized = true;
  }

  Future<void> startScan() => _invoke('startScan');

  Future<void> stopScan() => _invoke('stopScan');

  Future<void> connect(String deviceId, {BleConfig config = const BleConfig()}) {
    return _invoke('connect', {
      'deviceId': deviceId,
      'autoReconnect': config.autoReconnect,
      'maxReconnectAttempts': config.maxReconnectAttempts,
      'reconnectDelayMs': config.reconnectDelay.inMilliseconds,
    });
  }

  Future<void> disconnect(String deviceId) {
    return _invoke('disconnect', {'deviceId': deviceId});
  }

  Future<List<BleService>> discoverServices(String deviceId) async {
    final result = await _invoke('discoverServices', {'deviceId': deviceId});
    final rawServices =
        (result as List?)?.cast<Map<dynamic, dynamic>>() ?? const [];
    return rawServices.map(BleService.fromMap).toList();
  }

  Future<Uint8List> readCharacteristic({
    required String deviceId,
    required String serviceUuid,
    required String characteristicUuid,
  }) async {
    final result = await _invoke('readCharacteristic', {
      'deviceId': deviceId,
      'serviceUuid': serviceUuid,
      'characteristicUuid': characteristicUuid,
    });
    return Uint8List.fromList((result as List).cast<int>());
  }

  Future<void> writeCharacteristic({
    required String deviceId,
    required String serviceUuid,
    required String characteristicUuid,
    required Uint8List value,
    bool withResponse = true,
  }) {
    return _invoke('writeCharacteristic', {
      'deviceId': deviceId,
      'serviceUuid': serviceUuid,
      'characteristicUuid': characteristicUuid,
      'value': value,
      'withResponse': withResponse,
    });
  }

  Future<void> setNotify({
    required String deviceId,
    required String serviceUuid,
    required String characteristicUuid,
    required bool enabled,
  }) {
    return _invoke('setNotify', {
      'deviceId': deviceId,
      'serviceUuid': serviceUuid,
      'characteristicUuid': characteristicUuid,
      'enabled': enabled,
    });
  }

  Future<dynamic> _invoke(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _methodChannel.invokeMethod(method, args);
    } on PlatformException catch (e) {
      throw BleException(
        code: bleErrorCodeFromString(e.code),
        message: e.message ?? 'Unknown BLE error',
      );
    }
  }

  void _handleEvent(dynamic event) {
    if (event is! Map) return;

    final type = event['type'] as String?;
    final data = event['data'];
    if (data is! Map) return;

    switch (type) {
      case 'bluetoothState':
        _bluetoothStateController.add(
          bluetoothStateFromString(data['state'] as String? ?? ''),
        );
        break;

      case 'scanResult':
        _scanController.add(BleScanResult.fromMap(data));
        break;

      case 'connectionState':
        _connectionController.add((
          deviceId: data['deviceId'] as String,
          state: bleConnectionStateFromString(data['state'] as String? ?? ''),
        ));
        break;

      case 'characteristicValue':
        _notificationController.add((
          deviceId: data['deviceId'] as String,
          serviceUuid: data['serviceUuid'] as String,
          characteristicUuid: data['characteristicUuid'] as String,
          value: Uint8List.fromList((data['value'] as List).cast<int>()),
        ));
        break;

      case 'error':
        final exception = BleException.fromMap(data);
        if (!_scanController.isClosed) {
          _scanController.addError(exception);
        }
        break;
    }
  }

  /// Cancels the event subscription and closes all streams.
  Future<void> dispose() async {
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    _initialized = false;
    await _bluetoothStateController.close();
    await _scanController.close();
    await _connectionController.close();
    await _notificationController.close();
  }
}
