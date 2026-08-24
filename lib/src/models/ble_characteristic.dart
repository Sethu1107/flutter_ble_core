/// A GATT characteristic within a [BleService].
class BleCharacteristic {
  final String uuid;
  final String serviceUuid;
  final bool canRead;
  final bool canWrite;
  final bool canNotify;

  const BleCharacteristic({
    required this.uuid,
    required this.serviceUuid,
    required this.canRead,
    required this.canWrite,
    required this.canNotify,
  });

  factory BleCharacteristic.fromMap(
    Map<dynamic, dynamic> map, {
    required String serviceUuid,
  }) {
    return BleCharacteristic(
      uuid: map['uuid'] as String,
      serviceUuid: serviceUuid,
      canRead: map['canRead'] as bool? ?? false,
      canWrite: map['canWrite'] as bool? ?? false,
      canNotify: map['canNotify'] as bool? ?? false,
    );
  }

  @override
  String toString() => 'BleCharacteristic(uuid: $uuid)';
}
