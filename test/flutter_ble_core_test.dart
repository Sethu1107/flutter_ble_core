import 'package:flutter_ble_core/flutter_ble_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BleException', () {
    test('fromMap maps a known code', () {
      final exception = BleException.fromMap({
        'code': 'permissionDenied',
        'message': 'Bluetooth permission was denied',
      });

      expect(exception.code, BleErrorCode.permissionDenied);
      expect(exception.message, 'Bluetooth permission was denied');
    });

    test('fromMap falls back to unknown for an unrecognized code', () {
      final exception = BleException.fromMap({
        'code': 'somethingNew',
        'message': 'oops',
      });

      expect(exception.code, BleErrorCode.unknown);
    });
  });

  group('BleScanResult.fromMap', () {
    test('parses manufacturer data and service UUIDs', () {
      final result = BleScanResult.fromMap({
        'id': 'AA:BB:CC:DD:EE:FF',
        'name': 'Lock',
        'rssi': -54,
        'manufacturerData': {
          76: [1, 2, 3],
        },
        'serviceUuids': ['0000180f-0000-1000-8000-00805f9b34fb'],
      });

      expect(result.device.id, 'AA:BB:CC:DD:EE:FF');
      expect(result.rssi, -54);
      expect(result.manufacturerData, hasLength(1));
      expect(result.manufacturerData[76], [1, 2, 3]);
      expect(result.serviceUuids, ['0000180f-0000-1000-8000-00805f9b34fb']);
    });

    test('defaults manufacturer data and service UUIDs when absent', () {
      final result = BleScanResult.fromMap({
        'id': 'AA:BB:CC:DD:EE:FF',
        'name': 'Lock',
        'rssi': -54,
      });

      expect(result.manufacturerData, isEmpty);
      expect(result.serviceUuids, isEmpty);
    });
  });

  group('BleService.fromMap', () {
    test('parses nested characteristics', () {
      final service = BleService.fromMap({
        'uuid': 'service-uuid',
        'characteristics': [
          {
            'uuid': 'char-uuid',
            'canRead': true,
            'canWrite': false,
            'canNotify': true,
          },
        ],
      });

      expect(service.uuid, 'service-uuid');
      expect(service.characteristics, hasLength(1));
      expect(service.characteristics.single.serviceUuid, 'service-uuid');
      expect(service.characteristics.single.canRead, isTrue);
      expect(service.characteristics.single.canWrite, isFalse);
      expect(service.characteristics.single.canNotify, isTrue);
    });
  });
}
