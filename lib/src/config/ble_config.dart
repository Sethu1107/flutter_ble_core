/// Optional reconnect behavior for [BleManager.connect].
class BleConfig {
  final bool autoReconnect;
  final int maxReconnectAttempts;
  final Duration reconnectDelay;

  const BleConfig({
    this.autoReconnect = false,
    this.maxReconnectAttempts = 3,
    this.reconnectDelay = const Duration(seconds: 2),
  });
}
