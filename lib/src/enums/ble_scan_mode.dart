/// Scan power/latency tradeoff (Android only).
///
/// CoreBluetooth on iOS has no equivalent setting — the OS manages scan
/// behavior automatically based on app state — so this has no effect there.
enum BleScanMode {
  /// Lowest power use, slowest to discover devices.
  lowPower,

  /// Default balance of power use and discovery speed.
  balanced,

  /// Fastest discovery, highest power use.
  lowLatency,
}
