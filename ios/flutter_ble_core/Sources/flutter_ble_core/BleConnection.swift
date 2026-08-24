import CoreBluetooth
import Flutter

/// Manages per-device peripheral connections: connect/disconnect, discovery, read/write/notify.
///
/// Acts as its own `CBPeripheralDelegate` once connected, while connect/disconnect
/// lifecycle events are driven by the plugin's `CBCentralManagerDelegate` callbacks.
class BleConnection: NSObject, CBPeripheralDelegate {
    private let central: CBCentralManager
    private let onEvent: ([String: Any]) -> Void

    private var discoveredPeripherals: [String: CBPeripheral] = [:]
    private var connectedPeripherals: [String: CBPeripheral] = [:]

    private var pendingConnects: [String: FlutterResult] = [:]
    private var pendingServiceDiscovery: [String: FlutterResult] = [:]
    private var pendingServiceCounts: [String: Int] = [:]
    private var pendingReads: [String: FlutterResult] = [:]
    private var pendingWrites: [String: FlutterResult] = [:]

    init(central: CBCentralManager, onEvent: @escaping ([String: Any]) -> Void) {
        self.central = central
        self.onEvent = onEvent
    }

    /// Caches peripherals seen while scanning so `connect` can find them by id.
    func noteDiscovered(_ peripheral: CBPeripheral) {
        discoveredPeripherals[peripheral.identifier.uuidString] = peripheral
    }

    func connect(deviceId: String, result: @escaping FlutterResult) {
        guard let uuid = UUID(uuidString: deviceId) else {
            result(FlutterError(code: "connectionFailed", message: "Invalid device id: \(deviceId)", details: nil))
            return
        }
        let peripheral = discoveredPeripherals[deviceId]
            ?? central.retrievePeripherals(withIdentifiers: [uuid]).first
        guard let peripheral = peripheral else {
            result(FlutterError(code: "connectionFailed", message: "Unknown device: \(deviceId)", details: nil))
            return
        }
        peripheral.delegate = self
        connectedPeripherals[deviceId] = peripheral
        pendingConnects[deviceId] = result
        central.connect(peripheral, options: nil)
    }

    func disconnect(deviceId: String, result: @escaping FlutterResult) {
        if let peripheral = connectedPeripherals[deviceId] {
            central.cancelPeripheralConnection(peripheral)
        }
        result(nil)
    }

    func discoverServices(deviceId: String, result: @escaping FlutterResult) {
        guard let peripheral = connectedPeripherals[deviceId] else {
            result(FlutterError(code: "connectionFailed", message: "Device not connected", details: nil))
            return
        }
        pendingServiceDiscovery[deviceId] = result
        peripheral.discoverServices(nil)
    }

    func readCharacteristic(deviceId: String, serviceUuid: String, characteristicUuid: String, result: @escaping FlutterResult) {
        guard let peripheral = connectedPeripherals[deviceId] else {
            result(FlutterError(code: "connectionFailed", message: "Device not connected", details: nil))
            return
        }
        guard let characteristic = findCharacteristic(peripheral, serviceUuid, characteristicUuid) else {
            result(FlutterError(code: "characteristicNotFound", message: "Characteristic not found", details: nil))
            return
        }
        pendingReads[key(deviceId, characteristic)] = result
        peripheral.readValue(for: characteristic)
    }

    func writeCharacteristic(
        deviceId: String,
        serviceUuid: String,
        characteristicUuid: String,
        value: Data,
        withResponse: Bool,
        result: @escaping FlutterResult
    ) {
        guard let peripheral = connectedPeripherals[deviceId] else {
            result(FlutterError(code: "connectionFailed", message: "Device not connected", details: nil))
            return
        }
        guard let characteristic = findCharacteristic(peripheral, serviceUuid, characteristicUuid) else {
            result(FlutterError(code: "characteristicNotFound", message: "Characteristic not found", details: nil))
            return
        }

        let writeType: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
        if withResponse {
            pendingWrites[key(deviceId, characteristic)] = result
        }
        peripheral.writeValue(value, for: characteristic, type: writeType)
        if !withResponse {
            result(nil)
        }
    }

    func setNotify(
        deviceId: String,
        serviceUuid: String,
        characteristicUuid: String,
        enabled: Bool,
        result: @escaping FlutterResult
    ) {
        guard let peripheral = connectedPeripherals[deviceId] else {
            result(FlutterError(code: "connectionFailed", message: "Device not connected", details: nil))
            return
        }
        guard let characteristic = findCharacteristic(peripheral, serviceUuid, characteristicUuid) else {
            result(FlutterError(code: "characteristicNotFound", message: "Characteristic not found", details: nil))
            return
        }
        peripheral.setNotifyValue(enabled, for: characteristic)
        result(nil)
    }

    func disconnectAll() {
        connectedPeripherals.values.forEach { central.cancelPeripheralConnection($0) }
        connectedPeripherals.removeAll()
    }

    // MARK: - Central manager driven lifecycle

    func handleConnected(peripheral: CBPeripheral) {
        let deviceId = peripheral.identifier.uuidString
        onEvent(BleUtils.event("connectionState", ["deviceId": deviceId, "state": "connected"]))
        if let result = pendingConnects.removeValue(forKey: deviceId) {
            result(nil)
        }
    }

    func handleFailedToConnect(peripheral: CBPeripheral, error: Error?) {
        let deviceId = peripheral.identifier.uuidString
        connectedPeripherals.removeValue(forKey: deviceId)
        if let result = pendingConnects.removeValue(forKey: deviceId) {
            result(FlutterError(code: "connectionFailed", message: error?.localizedDescription, details: nil))
        } else {
            onEvent(BleUtils.errorEvent("connectionFailed", error?.localizedDescription))
        }
    }

    func handleDisconnected(peripheral: CBPeripheral) {
        let deviceId = peripheral.identifier.uuidString
        connectedPeripherals.removeValue(forKey: deviceId)
        onEvent(BleUtils.event("connectionState", ["deviceId": deviceId, "state": "disconnected"]))
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let deviceId = peripheral.identifier.uuidString
        guard let result = pendingServiceDiscovery[deviceId] else { return }

        if let error = error {
            pendingServiceDiscovery.removeValue(forKey: deviceId)
            result(FlutterError(code: "operationFailed", message: error.localizedDescription, details: nil))
            return
        }

        let services = peripheral.services ?? []
        if services.isEmpty {
            pendingServiceDiscovery.removeValue(forKey: deviceId)
            result([])
            return
        }

        pendingServiceCounts[deviceId] = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let deviceId = peripheral.identifier.uuidString
        let remaining = (pendingServiceCounts[deviceId] ?? 1) - 1
        pendingServiceCounts[deviceId] = remaining
        guard remaining <= 0 else { return }

        pendingServiceCounts.removeValue(forKey: deviceId)
        guard let result = pendingServiceDiscovery.removeValue(forKey: deviceId) else { return }

        let services = (peripheral.services ?? []).map { service -> [String: Any] in
            let characteristics = (service.characteristics ?? []).map { characteristic -> [String: Any] in
                [
                    "uuid": characteristic.uuid.uuidString,
                    "canRead": BleUtils.canRead(characteristic),
                    "canWrite": BleUtils.canWrite(characteristic),
                    "canNotify": BleUtils.canNotify(characteristic),
                ]
            }
            return ["uuid": service.uuid.uuidString, "characteristics": characteristics]
        }
        result(services)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let deviceId = peripheral.identifier.uuidString
        let characteristicKey = key(deviceId, characteristic)

        if let result = pendingReads.removeValue(forKey: characteristicKey) {
            if let error = error {
                result(FlutterError(code: "operationFailed", message: error.localizedDescription, details: nil))
            } else {
                result([UInt8](characteristic.value ?? Data()))
            }
            return
        }

        guard error == nil else {
            onEvent(BleUtils.errorEvent("operationFailed", error?.localizedDescription))
            return
        }

        onEvent(
            BleUtils.event(
                "characteristicValue",
                [
                    "deviceId": deviceId,
                    "serviceUuid": characteristic.service?.uuid.uuidString ?? "",
                    "characteristicUuid": characteristic.uuid.uuidString,
                    "value": [UInt8](characteristic.value ?? Data()),
                ]
            )
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let deviceId = peripheral.identifier.uuidString
        guard let result = pendingWrites.removeValue(forKey: key(deviceId, characteristic)) else { return }

        if let error = error {
            result(FlutterError(code: "operationFailed", message: error.localizedDescription, details: nil))
        } else {
            result(nil)
        }
    }

    // MARK: - Helpers

    private func findCharacteristic(_ peripheral: CBPeripheral, _ serviceUuid: String, _ characteristicUuid: String) -> CBCharacteristic? {
        let targetService = CBUUID(string: serviceUuid)
        let targetCharacteristic = CBUUID(string: characteristicUuid)
        guard let service = peripheral.services?.first(where: { $0.uuid == targetService }) else { return nil }
        return service.characteristics?.first(where: { $0.uuid == targetCharacteristic })
    }

    private func key(_ deviceId: String, _ characteristic: CBCharacteristic) -> String {
        let serviceUuid = characteristic.service?.uuid.uuidString ?? ""
        return "\(deviceId)|\(serviceUuid)|\(characteristic.uuid.uuidString)"
    }
}
