import 'ble_characteristic.dart';

/// A GATT service discovered on a connected [BleDevice].
class BleService {
  final String uuid;
  final List<BleCharacteristic> characteristics;

  const BleService({
    required this.uuid,
    required this.characteristics,
  });

  factory BleService.fromMap(Map<dynamic, dynamic> map) {
    final uuid = map['uuid'] as String;
    final rawCharacteristics =
        (map['characteristics'] as List?)?.cast<Map<dynamic, dynamic>>() ??
            const [];

    return BleService(
      uuid: uuid,
      characteristics: rawCharacteristics
          .map((c) => BleCharacteristic.fromMap(c, serviceUuid: uuid))
          .toList(),
    );
  }

  @override
  String toString() =>
      'BleService(uuid: $uuid, characteristics: ${characteristics.length})';
}
