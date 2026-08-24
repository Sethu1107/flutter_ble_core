// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_ble_core/flutter_ble_core.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('initialize succeeds and reports an adapter state', (WidgetTester tester) async {
    final ble = BleManager();
    await ble.initialize();

    final state = await ble.bluetoothStateStream.first;
    expect(state, isNotNull);

    await ble.dispose();
  });
}
