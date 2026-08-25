/// Error codes surfaced by the native BLE layer.
enum BleErrorCode {
  notInitialized,
  bluetoothUnavailable,
  permissionDenied,
  scanFailed,
  connectionFailed,
  serviceNotFound,
  characteristicNotFound,
  operationFailed,
  timeout,
  unknown,
}

BleErrorCode bleErrorCodeFromString(String value) {
  return BleErrorCode.values.firstWhere(
    (code) => code.name == value,
    orElse: () => BleErrorCode.unknown,
  );
}

/// Thrown for any BLE failure raised by the native Android/iOS layer.
class BleException implements Exception {
  final BleErrorCode code;
  final String message;

  /// The raw platform status code, when the native layer has one to give.
  ///
  /// On Android this is the `BluetoothGatt` status int (e.g. 133 for a
  /// stale/racy connect failure, 8 for a timeout, 22 for an unexpected
  /// disconnect) — the same numbers you'd see from `onConnectionStateChange`
  /// or `onCharacteristicRead`/`onCharacteristicWrite`. On iOS it's the
  /// `NSError.code` from CoreBluetooth's `CBError`/`CBATTError` domains,
  /// which uses a different numbering scheme entirely. Null when the
  /// failure never reached a platform GATT call (e.g. `notInitialized`,
  /// `permissionDenied`) or the platform didn't report one.
  final int? platformCode;

  const BleException({
    required this.code,
    required this.message,
    this.platformCode,
  });

  factory BleException.fromMap(Map<dynamic, dynamic> map) {
    return BleException(
      code: bleErrorCodeFromString(map['code'] as String? ?? ''),
      message: map['message'] as String? ?? 'Unknown BLE error',
      platformCode: map['platformCode'] as int?,
    );
  }

  @override
  String toString() =>
      'BleException(${code.name}${platformCode != null ? ', platformCode: $platformCode' : ''}): $message';
}
