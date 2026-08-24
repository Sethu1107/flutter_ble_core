/// A BLE peripheral identity.
///
/// [id] is platform-specific: a MAC address on Android, a UUID on iOS.
class BleDevice {
  final String id;
  final String name;

  const BleDevice({
    required this.id,
    required this.name,
  });

  factory BleDevice.fromMap(Map<dynamic, dynamic> map) {
    return BleDevice(
      id: map['id'] as String,
      name: map['name'] as String? ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is BleDevice && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'BleDevice(id: $id, name: $name)';
}
