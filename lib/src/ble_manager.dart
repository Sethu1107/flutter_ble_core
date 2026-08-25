import 'dart:async';

import 'package:flutter/services.dart';

import 'config/ble_config.dart';
import 'enums/ble_connection_priority.dart';
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
  Timer? _scanTimeoutTimer;

  // Auto-reconnect is driven entirely from Dart: it just watches
  // connectionStateStream and re-invokes connect() on unexpected drops.
  // This keeps the retry policy identical on both platforms without
  // duplicating timer logic in native code.
  final Map<String, BleConfig> _autoReconnectConfigs = {};
  final Map<String, int> _reconnectAttempts = {};

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

  /// Starts scanning for nearby BLE advertisements.
  ///
  /// [serviceUuids], if non-empty, filters results to devices advertising at
  /// least one of those services — pushing the filter into the native
  /// scanner instead of scanning everything and discarding client-side.
  /// [timeout], if given, calls [stopScan] automatically after the duration.
  Future<void> startScan({
    List<String> serviceUuids = const [],
    Duration? timeout,
  }) async {
    _scanTimeoutTimer?.cancel();
    _scanTimeoutTimer = null;

    await _invoke('startScan', {'serviceUuids': serviceUuids});

    if (timeout != null) {
      _scanTimeoutTimer = Timer(timeout, stopScan);
    }
  }

  Future<void> stopScan() {
    _scanTimeoutTimer?.cancel();
    _scanTimeoutTimer = null;
    return _invoke('stopScan');
  }

  /// Connects to [deviceId].
  ///
  /// When [config].autoReconnect is set, an unexpected disconnect (i.e. one
  /// not caused by calling [disconnect]) triggers automatic reconnect
  /// attempts, up to [BleConfig.maxReconnectAttempts], spaced by
  /// [BleConfig.reconnectDelay].
  Future<void> connect(String deviceId, {BleConfig config = const BleConfig()}) {
    if (config.autoReconnect) {
      _autoReconnectConfigs[deviceId] = config;
    } else {
      _autoReconnectConfigs.remove(deviceId);
    }
    _reconnectAttempts[deviceId] = 0;
    return _invoke('connect', {'deviceId': deviceId});
  }

  Future<void> disconnect(String deviceId) {
    _autoReconnectConfigs.remove(deviceId);
    _reconnectAttempts.remove(deviceId);
    return _invoke('disconnect', {'deviceId': deviceId});
  }

  Future<List<BleService>> discoverServices(String deviceId) async {
    final result = await _invoke('discoverServices', {'deviceId': deviceId});
    final rawServices =
        (result as List?)?.cast<Map<dynamic, dynamic>>() ?? const [];
    return rawServices.map(BleService.fromMap).toList();
  }

  /// Requests a larger ATT MTU (Android). On iOS, CoreBluetooth negotiates
  /// the MTU automatically at connect time — this just returns the value
  /// already in effect and does not attempt to change it.
  Future<int> requestMtu({required String deviceId, required int mtu}) async {
    final result = await _invoke('requestMtu', {'deviceId': deviceId, 'mtu': mtu});
    return result as int;
  }

  /// Requests a connection interval/latency tradeoff (Android only — see
  /// [BleConnectionPriority]). Resolves immediately as a no-op on iOS.
  Future<void> requestConnectionPriority({
    required String deviceId,
    required BleConnectionPriority priority,
  }) {
    return _invoke('requestConnectionPriority', {
      'deviceId': deviceId,
      'priority': priority.name,
    });
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
        platformCode: e.details is int ? e.details as int : null,
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
        final deviceId = data['deviceId'] as String;
        final state = bleConnectionStateFromString(data['state'] as String? ?? '');
        _connectionController.add((deviceId: deviceId, state: state));

        if (state == BleConnectionState.connected) {
          _reconnectAttempts[deviceId] = 0;
        } else if (state == BleConnectionState.disconnected) {
          _maybeReconnect(deviceId);
        }
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

  void _maybeReconnect(String deviceId) {
    final config = _autoReconnectConfigs[deviceId];
    if (config == null) return;

    final attempts = _reconnectAttempts[deviceId] ?? 0;
    if (attempts >= config.maxReconnectAttempts) {
      _autoReconnectConfigs.remove(deviceId);
      _reconnectAttempts.remove(deviceId);
      return;
    }
    _reconnectAttempts[deviceId] = attempts + 1;

    Future.delayed(config.reconnectDelay, () async {
      // Cancelled (disconnect()/connect() called again) while we waited.
      if (!_autoReconnectConfigs.containsKey(deviceId)) return;
      try {
        await _invoke('connect', {'deviceId': deviceId});
      } catch (_) {
        _maybeReconnect(deviceId);
      }
    });
  }

  /// Cancels the event subscription and closes all streams.
  Future<void> dispose() async {
    _scanTimeoutTimer?.cancel();
    _scanTimeoutTimer = null;
    _autoReconnectConfigs.clear();
    _reconnectAttempts.clear();
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    _initialized = false;
    await _bluetoothStateController.close();
    await _scanController.close();
    await _connectionController.close();
    await _notificationController.close();
  }
}
