/// Per-device GATT connection state.
enum BleConnectionState {
  connecting,
  connected,
  disconnecting,
  disconnected,
}

BleConnectionState bleConnectionStateFromString(String value) {
  return BleConnectionState.values.firstWhere(
    (state) => state.name == value,
    orElse: () => BleConnectionState.disconnected,
  );
}
