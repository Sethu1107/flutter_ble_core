/// Requested link interval/latency tradeoff for a connection (Android only).
///
/// CoreBluetooth on iOS has no equivalent API — the OS manages this
/// automatically — so [BleManager.requestConnectionPriority] is a no-op
/// there that resolves immediately.
enum BleConnectionPriority {
  /// Default balance of throughput and power use.
  balanced,

  /// Shorter connection interval for higher throughput, at the cost of
  /// battery life.
  high,

  /// Longer connection interval to save power, at the cost of throughput.
  lowPower,
}
