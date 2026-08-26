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
    private var pendingConnectTimeouts: [String: DispatchWorkItem] = [:]
    private var pendingDisconnects: [String: FlutterResult] = [:]
    private var pendingDisconnectTimeouts: [String: DispatchWorkItem] = [:]
    private var pendingServiceDiscovery: [String: FlutterResult] = [:]
    private var pendingServiceCounts: [String: Int] = [:]
    private var pendingReads: [String: FlutterResult] = [:]
    private var pendingWrites: [String: FlutterResult] = [:]

    // Writes without response can outrun CoreBluetooth's internal transmit
    // buffer; when canSendWriteWithoutResponse is false we queue here and
    // drain from peripheralIsReady(toSendWriteWithoutResponse:).
    private var writeWithoutResponseQueues: [String: [(CBCharacteristic, Data, FlutterResult)]] = [:]

    init(central: CBCentralManager, onEvent: @escaping ([String: Any]) -> Void) {
        self.central = central
        self.onEvent = onEvent
    }

    /// Caches peripherals seen while scanning so `connect` can find them by id.
    func noteDiscovered(_ peripheral: CBPeripheral) {
        discoveredPeripherals[peripheral.identifier.uuidString] = peripheral
    }

    func connect(deviceId: String, timeoutMs: Int, result: @escaping FlutterResult) {
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

        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingConnectTimeouts.removeValue(forKey: deviceId)
            guard let pending = self.pendingConnects.removeValue(forKey: deviceId) else { return }
            self.central.cancelPeripheralConnection(peripheral)
            self.connectedPeripherals.removeValue(forKey: deviceId)
            pending(FlutterError(code: "timeout", message: "Timed out connecting to \(deviceId)", details: nil))
        }
        pendingConnectTimeouts[deviceId] = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timeoutWork)

        central.connect(peripheral, options: nil)
    }

    /// Resolves once the platform confirms disconnection, not merely once it's requested.
    func disconnect(deviceId: String, timeoutMs: Int, result: @escaping FlutterResult) {
        guard let peripheral = connectedPeripherals[deviceId] else {
            result(nil)
            return
        }

        pendingDisconnects[deviceId] = result
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingDisconnectTimeouts.removeValue(forKey: deviceId)
            guard let pending = self.pendingDisconnects.removeValue(forKey: deviceId) else { return }
            self.connectedPeripherals.removeValue(forKey: deviceId)
            pending(FlutterError(code: "timeout", message: "Timed out disconnecting from \(deviceId)", details: nil))
        }
        pendingDisconnectTimeouts[deviceId] = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timeoutWork)

        central.cancelPeripheralConnection(peripheral)
    }

    func discoverServices(deviceId: String, result: @escaping FlutterResult) {
        guard let peripheral = connectedPeripherals[deviceId] else {
            result(FlutterError(code: "connectionFailed", message: "Device not connected", details: nil))
            return
        }
        pendingServiceDiscovery[deviceId] = result
        peripheral.discoverServices(nil)
    }

    /// CoreBluetooth negotiates the ATT MTU automatically at connect time; there is no
    /// API to request a specific value on iOS. This reports the value already in effect.
    func requestMtu(deviceId: String, result: @escaping FlutterResult) {
        guard let peripheral = connectedPeripherals[deviceId] else {
            result(FlutterError(code: "connectionFailed", message: "Device not connected", details: nil))
            return
        }
        result(peripheral.maximumWriteValueLength(for: .withoutResponse) + 3)
    }

    /// CoreBluetooth has no connection-priority API — the OS manages connection
    /// interval/latency automatically. This is a no-op that resolves immediately
    /// once the device is known to be connected, mirroring how other BLE plugins
    /// treat this call on iOS.
    func requestConnectionPriority(deviceId: String, result: @escaping FlutterResult) {
        guard connectedPeripherals[deviceId] != nil else {
            result(FlutterError(code: "connectionFailed", message: "Device not connected", details: nil))
            return
        }
        result(nil)
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

        if withResponse {
            pendingWrites[key(deviceId, characteristic)] = result
            peripheral.writeValue(value, for: characteristic, type: .withResponse)
            return
        }

        if peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(value, for: characteristic, type: .withoutResponse)
            result(nil)
        } else {
            writeWithoutResponseQueues[deviceId, default: []].append((characteristic, value, result))
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
        // CoreBluetooth chooses notify vs. indicate automatically based on the
        // characteristic's properties, unlike Android where the CCCD value must
        // be picked explicitly.
        peripheral.setNotifyValue(enabled, for: characteristic)
        result(nil)
    }

    func disconnectAll() {
        pendingConnectTimeouts.values.forEach { $0.cancel() }
        pendingConnectTimeouts.removeAll()
        pendingDisconnectTimeouts.values.forEach { $0.cancel() }
        pendingDisconnectTimeouts.removeAll()
        connectedPeripherals.values.forEach { central.cancelPeripheralConnection($0) }
        connectedPeripherals.removeAll()
        writeWithoutResponseQueues.removeAll()
    }

    // MARK: - Central manager driven lifecycle

    func handleConnected(peripheral: CBPeripheral) {
        let deviceId = peripheral.identifier.uuidString
        onEvent(BleUtils.event("connectionState", ["deviceId": deviceId, "state": "connected"]))

        pendingConnectTimeouts.removeValue(forKey: deviceId)?.cancel()
        if let result = pendingConnects.removeValue(forKey: deviceId) {
            result(nil)
        }
    }

    func handleFailedToConnect(peripheral: CBPeripheral, error: Error?) {
        let deviceId = peripheral.identifier.uuidString
        connectedPeripherals.removeValue(forKey: deviceId)

        pendingConnectTimeouts.removeValue(forKey: deviceId)?.cancel()
        if let result = pendingConnects.removeValue(forKey: deviceId) {
            result(
                FlutterError(
                    code: "connectionFailed", message: error?.localizedDescription, details: Self.platformCode(error)))
        } else {
            onEvent(BleUtils.errorEvent("connectionFailed", error?.localizedDescription))
        }
    }

    func handleDisconnected(peripheral: CBPeripheral, error: Error? = nil) {
        let deviceId = peripheral.identifier.uuidString
        connectedPeripherals.removeValue(forKey: deviceId)
        onEvent(BleUtils.event("connectionState", ["deviceId": deviceId, "state": "disconnected"]))

        pendingConnectTimeouts.removeValue(forKey: deviceId)?.cancel()
        if let result = pendingConnects.removeValue(forKey: deviceId) {
            result(
                FlutterError(
                    code: "connectionFailed", message: "Disconnected before connect completed",
                    details: Self.platformCode(error)))
        }

        pendingDisconnectTimeouts.removeValue(forKey: deviceId)?.cancel()
        if let result = pendingDisconnects.removeValue(forKey: deviceId) {
            result(nil)
        }

        if let queue = writeWithoutResponseQueues.removeValue(forKey: deviceId) {
            for (_, _, pendingResult) in queue {
                pendingResult(
                    FlutterError(code: "connectionFailed", message: "Device disconnected before write completed", details: nil))
            }
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let deviceId = peripheral.identifier.uuidString
        guard let result = pendingServiceDiscovery[deviceId] else { return }

        if let error = error {
            pendingServiceDiscovery.removeValue(forKey: deviceId)
            result(
                FlutterError(
                    code: "operationFailed", message: error.localizedDescription, details: Self.platformCode(error)))
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
                result(
                    FlutterError(
                        code: "operationFailed", message: error.localizedDescription, details: Self.platformCode(error)))
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
            result(
                FlutterError(
                    code: "operationFailed", message: error.localizedDescription, details: Self.platformCode(error)))
        } else {
            result(nil)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        let deviceId = peripheral.identifier.uuidString
        guard var queue = writeWithoutResponseQueues[deviceId], !queue.isEmpty else { return }

        while !queue.isEmpty, peripheral.canSendWriteWithoutResponse {
            let (characteristic, value, result) = queue.removeFirst()
            peripheral.writeValue(value, for: characteristic, type: .withoutResponse)
            result(nil)
        }
        writeWithoutResponseQueues[deviceId] = queue
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

    /// CoreBluetooth's error codes (CBError/CBATTError domains) use a different
    /// numbering scheme than Android's raw GATT status ints — this is not the
    /// same "133/8/22" scale, just the closest thing iOS exposes.
    private static func platformCode(_ error: Error?) -> Int? {
        guard let error = error else { return nil }
        return (error as NSError).code
    }
}
