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
