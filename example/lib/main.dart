import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_ble_core/flutter_ble_core.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _ble = BleManager();

  BluetoothState _adapterState = BluetoothState.unknown;
  bool _scanning = false;
  final Map<String, BleScanResult> _scanResults = {};

  String? _connectedDeviceId;
  BleConnectionState? _connectionState;
  List<BleService> _services = [];

  StreamSubscription? _bluetoothStateSub;
  StreamSubscription? _scanSub;
  StreamSubscription? _connectionSub;
  StreamSubscription? _notifySub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final granted = await _requestPermissions();
    if (!granted) {
      _showError(
        'Bluetooth/location permission denied — scanning will find nothing '
        'until granted in system settings.',
      );
    }

    try {
      await _ble.initialize();
    } on BleException catch (e) {
      _showError(e.message);
      return;
    }

    _bluetoothStateSub = _ble.bluetoothStateStream.listen((state) {
      setState(() => _adapterState = state);
    });

    _scanSub = _ble.scanResults.listen(
      (result) => setState(() => _scanResults[result.device.id] = result),
      onError: (e) => _showError(e is BleException ? e.message : e.toString()),
    );

    _connectionSub = _ble.connectionStateStream.listen((event) {
      if (event.deviceId != _connectedDeviceId) return;
      setState(() => _connectionState = event.state);
      if (event.state == BleConnectionState.disconnected) {
        setState(() {
          _connectedDeviceId = null;
          _services = [];
        });
      }
    });

    _notifySub = _ble.characteristicValueStream.listen((event) {
      _showError(
        'Notify ${event.characteristicUuid}: ${event.value}',
        isError: false,
      );
    });
  }

  /// Requests everything a BLE scan needs to actually return results:
  /// - Android 12+: BLUETOOTH_SCAN / BLUETOOTH_CONNECT
  /// - Android <=11: location, or scans silently return zero results
  /// - iOS: the Bluetooth authorization prompt (driven by Info.plist)
  Future<bool> _requestPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.bluetooth,
    ].request();
    return statuses.values.every((status) => status.isGranted || status.isLimited);
  }

  Future<void> _toggleScan() async {
    if (_scanning) {
      await _ble.stopScan();
      setState(() => _scanning = false);
      return;
    }
    setState(() {
      _scanResults.clear();
      _scanning = true;
    });
    try {
      await _ble.startScan();
    } on BleException catch (e) {
      setState(() => _scanning = false);
      _showError(e.message);
    }
  }

  Future<void> _connect(BleDevice device) async {
    try {
      await _ble.connect(device.id);
      setState(() => _connectedDeviceId = device.id);
      final services = await _ble.discoverServices(device.id);
      setState(() => _services = services);
    } on BleException catch (e) {
      _showError(e.message);
    }
  }

  Future<void> _disconnect() async {
    final deviceId = _connectedDeviceId;
    if (deviceId == null) return;
    await _ble.disconnect(deviceId);
    setState(() {
      _connectedDeviceId = null;
      _services = [];
    });
  }

  Future<void> _read(BleCharacteristic characteristic) async {
    final deviceId = _connectedDeviceId;
    if (deviceId == null) return;
    try {
      final value = await _ble.readCharacteristic(
        deviceId: deviceId,
        serviceUuid: characteristic.serviceUuid,
        characteristicUuid: characteristic.uuid,
      );
      _showError('Read ${characteristic.uuid}: $value', isError: false);
    } on BleException catch (e) {
      _showError(e.message);
    }
  }

  Future<void> _write(BleCharacteristic characteristic) async {
    final deviceId = _connectedDeviceId;
    if (deviceId == null) return;
    try {
      await _ble.writeCharacteristic(
        deviceId: deviceId,
        serviceUuid: characteristic.serviceUuid,
        characteristicUuid: characteristic.uuid,
        value: Uint8List.fromList([0x01]),
      );
      _showError('Wrote ${characteristic.uuid}', isError: false);
    } on BleException catch (e) {
      _showError(e.message);
    }
  }

  Future<void> _toggleNotify(BleCharacteristic characteristic, bool enabled) async {
    final deviceId = _connectedDeviceId;
    if (deviceId == null) return;
    try {
      await _ble.setNotify(
        deviceId: deviceId,
        serviceUuid: characteristic.serviceUuid,
        characteristicUuid: characteristic.uuid,
        enabled: enabled,
      );
    } on BleException catch (e) {
      _showError(e.message);
    }
  }

  void _showError(String message, {bool isError = true}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
      ),
    );
  }

  @override
  void dispose() {
    _bluetoothStateSub?.cancel();
    _scanSub?.cancel();
    _connectionSub?.cancel();
    _notifySub?.cancel();
    _ble.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: Text('flutter_ble_core (${_adapterState.name})')),
        body: _connectedDeviceId == null ? _buildScanView() : _buildDeviceView(),
        floatingActionButton: _connectedDeviceId == null
            ? FloatingActionButton.extended(
                onPressed: _toggleScan,
                label: Text(_scanning ? 'Stop scan' : 'Start scan'),
                icon: Icon(_scanning ? Icons.stop : Icons.search),
              )
            : null,
      ),
    );
  }

  Widget _buildScanView() {
    final results = _scanResults.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));

    if (results.isEmpty) {
      return Center(child: Text(_scanning ? 'Scanning...' : 'No devices found yet'));
    }

    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, index) {
        final result = results[index];
        return ListTile(
          title: Text(result.device.name.isEmpty ? '(unnamed)' : result.device.name),
          subtitle: Text(result.device.id),
          trailing: Text('${result.rssi} dBm'),
          onTap: () => _connect(result.device),
        );
      },
    );
  }

  Widget _buildDeviceView() {
    return Column(
      children: [
        ListTile(
          title: Text(_connectedDeviceId!),
          subtitle: Text(_connectionState?.name ?? ''),
          trailing: TextButton(onPressed: _disconnect, child: const Text('Disconnect')),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: [
              for (final service in _services)
                ExpansionTile(
                  title: Text(service.uuid),
                  children: [
                    for (final characteristic in service.characteristics)
                      ListTile(
                        title: Text(characteristic.uuid),
                        subtitle: Text(
                          [
                            if (characteristic.canRead) 'read',
                            if (characteristic.canWrite) 'write',
                            if (characteristic.canNotify) 'notify',
                          ].join(', '),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (characteristic.canRead)
                              IconButton(
                                icon: const Icon(Icons.download),
                                onPressed: () => _read(characteristic),
                              ),
                            if (characteristic.canWrite)
                              IconButton(
                                icon: const Icon(Icons.upload),
                                onPressed: () => _write(characteristic),
                              ),
                            if (characteristic.canNotify)
                              Switch(
                                value: false,
                                onChanged: (enabled) =>
                                    _toggleNotify(characteristic, enabled),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}
