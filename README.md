# flutter_ble_core

A lightweight Bluetooth Low Energy (BLE) plugin for Flutter with hand-written native
implementations — no third-party BLE library, no `plugin_platform_interface`, zero
extra runtime dependencies beyond the Flutter SDK.

## Features

- Scan for nearby BLE devices, with optional service-UUID filtering and an
  auto-stop timeout
- Manufacturer-specific advertisement data and advertised service UUIDs on every
  scan result
- Connect / disconnect, with results that wait for the real platform
  confirmation (not just the request being sent) and a configurable timeout
  for each (`BleConfig.connectTimeout`, `disconnect(..., timeout:)`)
- Discover services and characteristics
- Read / write characteristics (with or without response)
- Subscribe to notifications and indications
- Request a larger ATT MTU (Android; no-op on iOS, which negotiates it
  automatically)
- Request a connection priority / interval tradeoff (Android; no-op on iOS)
- Optional auto-reconnect on unexpected disconnects, driven from Dart so the
  retry policy is identical on both platforms
- Structured errors (`BleException`) that carry both a portable `BleErrorCode`
  and, where the platform provides one, the raw native status code

## How Bluetooth is handled per platform

No cross-platform BLE library sits underneath this package — each platform talks
to its own native Bluetooth stack directly, bridged to Dart over Flutter platform
channels (`flutter_ble/methods` for one-shot calls, `flutter_ble/events` for
scan results, connection state, and notifications).

**Android** — `android.bluetooth.*`
- `BluetoothManager` / `BluetoothAdapter` for adapter access and power state
- `BluetoothLeScanner` + `ScanCallback` + `ScanFilter`/`ScanSettings` for scanning
  ([`BleScanner.kt`](android/src/main/kotlin/com/github/sethu1107/flutter_ble_core/BleScanner.kt))
- `BluetoothGatt` + `BluetoothGattCallback` for connect, service/characteristic
  discovery, read/write, and notify/indicate via the CCCD descriptor
  ([`BleConnection.kt`](android/src/main/kotlin/com/github/sethu1107/flutter_ble_core/BleConnection.kt))
- A `BroadcastReceiver` on `ACTION_STATE_CHANGED` so `bluetoothStateStream` keeps
  firing after the adapter is toggled off/on mid-session

**iOS** — `CoreBluetooth`
- `CBCentralManager` + `CBCentralManagerDelegate` for scanning, connect
  lifecycle, and adapter state
  ([`FlutterBleCorePlugin.swift`](ios/flutter_ble_core/Sources/flutter_ble_core/FlutterBleCorePlugin.swift))
- `CBPeripheral` + `CBPeripheralDelegate` for service/characteristic discovery,
  read/write, and notify/indicate
  ([`BleConnection.swift`](ios/flutter_ble_core/Sources/flutter_ble_core/BleConnection.swift))

Platform differences worth knowing about:

| Behavior | Android | iOS |
|---|---|---|
| MTU | Real negotiation via `requestMtu()` | No request API — returns the value CoreBluetooth already negotiated |
| Connection priority | Real request via `requestConnectionPriority()` | No API — no-op, OS manages it |
| Notify vs. indicate | Package picks the correct CCCD value automatically | Handled internally by CoreBluetooth |
| `BleException.platformCode` | Raw `BluetoothGatt` status int (e.g. 133, 8, 22, 6) | `NSError.code` from `CBError`/`CBATTError` — a different numbering scheme, not comparable to Android's |

## Getting started

### Android

The plugin's manifest already declares the Bluetooth permissions
(`BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT` for API 31+; legacy `BLUETOOTH`,
`BLUETOOTH_ADMIN`, `ACCESS_FINE_LOCATION` for older devices). Requesting them at
runtime is the host app's job — this package does not do it for you. A denied
permission surfaces as a `BleException` with `BleErrorCode.permissionDenied`.

### iOS

Add a usage description to your app's `Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app uses Bluetooth to scan for and connect to nearby BLE devices.</string>
```

## Usage

```dart
import 'package:flutter_ble_core/flutter_ble_core.dart';

final ble = BleManager();

await ble.initialize();

ble.bluetoothStateStream.listen((state) => print('Adapter: $state'));

// Scan, optionally filtered by service UUID and auto-stopped after a timeout.
ble.scanResults.listen((result) {
  print('${result.device.name} (${result.device.id}) rssi=${result.rssi}');
});
await ble.startScan(timeout: const Duration(seconds: 10));

// Connect — resolves once the platform confirms the connection, not just
// once the request is sent. BleConfig also controls auto-reconnect and how
// long to wait before failing with BleErrorCode.timeout.
await ble.connect(
  deviceId,
  config: const BleConfig(
    autoReconnect: true,
    maxReconnectAttempts: 3,
    reconnectDelay: Duration(seconds: 2),
    connectTimeout: Duration(seconds: 10),
  ),
);

final services = await ble.discoverServices(deviceId);

final value = await ble.readCharacteristic(
  deviceId: deviceId,
  serviceUuid: serviceUuid,
  characteristicUuid: characteristicUuid,
);

await ble.writeCharacteristic(
  deviceId: deviceId,
  serviceUuid: serviceUuid,
  characteristicUuid: characteristicUuid,
  value: Uint8List.fromList([0x01]),
);

await ble.setNotify(
  deviceId: deviceId,
  serviceUuid: serviceUuid,
  characteristicUuid: characteristicUuid,
  enabled: true,
);
ble.characteristicValueStream.listen((event) {
  print('${event.characteristicUuid}: ${event.value}');
});

// disconnect() also has its own timeout, independent of connectTimeout.
await ble.disconnect(deviceId, timeout: const Duration(seconds: 5));
await ble.dispose();
```

### Handling errors

```dart
try {
  await ble.connect(deviceId);
} on BleException catch (e) {
  switch (e.code) {
    case BleErrorCode.permissionDenied:
      // prompt the user to grant Bluetooth permissions
      break;
    case BleErrorCode.timeout:
      // connect attempt timed out — device may be out of range
      break;
    default:
      // e.platformCode carries the raw native status when the platform
      // gives one (see the table above for what it means per platform)
      print('${e.code} (platformCode: ${e.platformCode}): ${e.message}');
  }
}
```

See `example/lib/main.dart` for a full scan → connect → service/characteristic
tree with read/write/notify controls.

## Additional information

This package intentionally keeps a small, fixed API surface — see
[`lib/src/ble_manager.dart`](lib/src/ble_manager.dart) for the complete public
interface. It does not implement bonding/pairing, generic descriptor
read/write beyond the CCCD notify toggle, or background scanning — add those
only if your use case actually needs them.
