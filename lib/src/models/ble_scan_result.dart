import 'dart:typed_data';

import 'ble_device.dart';

/// One advertisement seen during a scan.
class BleScanResult {
  final BleDevice device;
  final int rssi;

  /// Manufacturer-specific advertisement payloads, keyed by company id.
  final Map<int, Uint8List> manufacturerData;

  /// Service UUIDs advertised alongside this result.
  final List<String> serviceUuids;

  const BleScanResult({
    required this.device,
    required this.rssi,
    this.manufacturerData = const {},
    this.serviceUuids = const [],
  });

  factory BleScanResult.fromMap(Map<dynamic, dynamic> map) {
    final rawManufacturerData =
        (map['manufacturerData'] as Map?)?.cast<dynamic, dynamic>() ?? const {};
    final rawServiceUuids = (map['serviceUuids'] as List?)?.cast<dynamic>() ?? const [];

    return BleScanResult(
      device: BleDevice.fromMap(map),
      rssi: map['rssi'] as int? ?? 0,
      manufacturerData: rawManufacturerData.map(
        (key, value) => MapEntry(
          key is int ? key : int.parse(key.toString()),
          Uint8List.fromList((value as List).cast<int>()),
        ),
      ),
      serviceUuids: rawServiceUuids.cast<String>(),
    );
  }

  @override
  String toString() =>
      'BleScanResult(device: $device, rssi: $rssi, serviceUuids: $serviceUuids)';
}
