/// Adapter-level Bluetooth state, mirrored from the native platform.
enum BluetoothState {
  unknown,
  unsupported,
  unauthorized,
  poweredOff,
  poweredOn,
}

BluetoothState bluetoothStateFromString(String value) {
  return BluetoothState.values.firstWhere(
    (state) => state.name == value,
    orElse: () => BluetoothState.unknown,
  );
}
