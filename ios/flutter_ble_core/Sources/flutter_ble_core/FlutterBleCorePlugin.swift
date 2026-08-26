import CoreBluetooth
import Flutter
import UIKit

public class FlutterBleCorePlugin: NSObject, FlutterPlugin, FlutterStreamHandler, CBCentralManagerDelegate {
    private var eventSink: FlutterEventSink?
    private var central: CBCentralManager?
    private var scanner: BleScanner?
    private var connection: BleConnection?
    private var pendingInitialize: FlutterResult?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FlutterBleCorePlugin()

        let methodChannel = FlutterMethodChannel(name: "flutter_ble/methods", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let eventChannel = FlutterEventChannel(name: "flutter_ble/events", binaryMessenger: registrar.messenger())
        eventChannel.setStreamHandler(instance)
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private func emit(_ event: [String: Any]) {
        eventSink?(event)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        switch call.method {
        case "initialize":
            initialize(result: result)

        case "startScan":
            let serviceUuids = args?["serviceUuids"] as? [String] ?? []
            withReady(result) { self.scanner!.start(serviceUuids: serviceUuids); result(nil) }

        case "stopScan":
            withReady(result) { self.scanner!.stop(); result(nil) }

        case "connect":
            guard let deviceId = args?["deviceId"] as? String else { return missingArg(result, "deviceId") }
            let connectTimeoutMs = (args?["timeoutMs"] as? Int) ?? Self.defaultConnectTimeoutMs
            withReady(result) {
                self.connection!.connect(deviceId: deviceId, timeoutMs: connectTimeoutMs, result: result)
            }

        case "disconnect":
            guard let deviceId = args?["deviceId"] as? String else { return missingArg(result, "deviceId") }
            let disconnectTimeoutMs = (args?["timeoutMs"] as? Int) ?? Self.defaultDisconnectTimeoutMs
            withReady(result) {
                self.connection!.disconnect(deviceId: deviceId, timeoutMs: disconnectTimeoutMs, result: result)
            }

        case "discoverServices":
            guard let deviceId = args?["deviceId"] as? String else { return missingArg(result, "deviceId") }
            withReady(result) { self.connection!.discoverServices(deviceId: deviceId, result: result) }

        case "requestMtu":
            guard let deviceId = args?["deviceId"] as? String else { return missingArg(result, "deviceId") }
            withReady(result) { self.connection!.requestMtu(deviceId: deviceId, result: result) }

        case "requestConnectionPriority":
            guard let deviceId = args?["deviceId"] as? String else { return missingArg(result, "deviceId") }
            withReady(result) { self.connection!.requestConnectionPriority(deviceId: deviceId, result: result) }

        case "readCharacteristic":
            guard let deviceId = args?["deviceId"] as? String,
                let serviceUuid = args?["serviceUuid"] as? String,
                let characteristicUuid = args?["characteristicUuid"] as? String
            else { return missingArg(result, "deviceId/serviceUuid/characteristicUuid") }
            withReady(result) {
                self.connection!.readCharacteristic(
                    deviceId: deviceId, serviceUuid: serviceUuid, characteristicUuid: characteristicUuid, result: result)
            }

        case "writeCharacteristic":
            guard let deviceId = args?["deviceId"] as? String,
                let serviceUuid = args?["serviceUuid"] as? String,
                let characteristicUuid = args?["characteristicUuid"] as? String
            else { return missingArg(result, "deviceId/serviceUuid/characteristicUuid") }
            let value = BleUtils.bytes(from: args?["value"] as? FlutterStandardTypedData)
            let withResponse = (args?["withResponse"] as? Bool) ?? true
            withReady(result) {
                self.connection!.writeCharacteristic(
                    deviceId: deviceId, serviceUuid: serviceUuid, characteristicUuid: characteristicUuid,
                    value: value, withResponse: withResponse, result: result)
            }

        case "setNotify":
            guard let deviceId = args?["deviceId"] as? String,
                let serviceUuid = args?["serviceUuid"] as? String,
                let characteristicUuid = args?["characteristicUuid"] as? String
            else { return missingArg(result, "deviceId/serviceUuid/characteristicUuid") }
            let enabled = (args?["enabled"] as? Bool) ?? false
            withReady(result) {
                self.connection!.setNotify(
                    deviceId: deviceId, serviceUuid: serviceUuid, characteristicUuid: characteristicUuid,
                    enabled: enabled, result: result)
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func initialize(result: @escaping FlutterResult) {
        if central != nil {
            result(nil)
            return
        }
        pendingInitialize = result
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private func withReady(_ result: @escaping FlutterResult, _ block: () -> Void) {
        guard scanner != nil, connection != nil else {
            result(FlutterError(code: "notInitialized", message: "Call initialize() first", details: nil))
            return
        }
        block()
    }

    private func missingArg(_ result: @escaping FlutterResult, _ name: String) {
        result(FlutterError(code: "operationFailed", message: "Missing argument: \(name)", details: nil))
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let stateString: String
        switch central.state {
        case .poweredOn: stateString = "poweredOn"
        case .poweredOff: stateString = "poweredOff"
        case .unauthorized: stateString = "unauthorized"
        case .unsupported: stateString = "unsupported"
        default: stateString = "unknown"
        }

        if scanner == nil {
            let scanner = BleScanner(central: central) { [weak self] event in self?.emit(event) }
            let connection = BleConnection(central: central) { [weak self] event in self?.emit(event) }
            self.scanner = scanner
            self.connection = connection
        }

        emit(BleUtils.event("bluetoothState", ["state": stateString]))

        if let pending = pendingInitialize {
            pendingInitialize = nil
            pending(nil)
        }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        connection?.noteDiscovered(peripheral)
        scanner?.handleDiscovery(peripheral: peripheral, advertisementData: advertisementData, rssi: RSSI)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connection?.handleConnected(peripheral: peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connection?.handleFailedToConnect(peripheral: peripheral, error: error)
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        connection?.handleDisconnected(peripheral: peripheral, error: error)
    }

    // Only used if the Dart side omits timeoutMs — BleManager always sends one,
    // these exist purely so a stale/mismatched Dart binary doesn't misbehave.
    private static let defaultConnectTimeoutMs = 10_000
    private static let defaultDisconnectTimeoutMs = 5_000
}
