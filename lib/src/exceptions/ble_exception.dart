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

  const BleException({
    required this.code,
    required this.message,
  });

  factory BleException.fromMap(Map<dynamic, dynamic> map) {
    return BleException(
      code: bleErrorCodeFromString(map['code'] as String? ?? ''),
      message: map['message'] as String? ?? 'Unknown BLE error',
    );
  }

  @override
  String toString() => 'BleException(${code.name}): $message';
}
