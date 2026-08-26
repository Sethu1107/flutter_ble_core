/// Connect/reconnect behavior for [BleManager.connect].
class BleConfig {
  /// Retry automatically if the connection drops unexpectedly (i.e. not via
  /// an explicit [BleManager.disconnect] call).
  final bool autoReconnect;

  /// Cap on reconnect attempts before giving up.
  final int maxReconnectAttempts;

  /// Delay between each reconnect attempt.
  final Duration reconnectDelay;

  /// How long to wait for the platform to confirm the connection before
  /// [BleManager.connect] fails with [BleErrorCode.timeout]. Applies to each
  /// individual attempt, including reconnects.
  final Duration connectTimeout;

  const BleConfig({
    this.autoReconnect = false,
    this.maxReconnectAttempts = 3,
    this.reconnectDelay = const Duration(seconds: 2),
    this.connectTimeout = const Duration(seconds: 10),
  });
}
