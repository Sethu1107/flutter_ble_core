import 'ble_device.dart';

/// One advertisement seen during a scan.
class BleScanResult {
  final BleDevice device;
  final int rssi;

  const BleScanResult({
    required this.device,
    required this.rssi,
  });

  factory BleScanResult.fromMap(Map<dynamic, dynamic> map) {
    return BleScanResult(
      device: BleDevice.fromMap(map),
      rssi: map['rssi'] as int? ?? 0,
    );
  }

  @override
  String toString() => 'BleScanResult(device: $device, rssi: $rssi)';
}
