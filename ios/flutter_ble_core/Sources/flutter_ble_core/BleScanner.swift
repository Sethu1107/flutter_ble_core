import CoreBluetooth

/// Wraps [CBCentralManager] scanning and forwards discoveries as events.
class BleScanner {
    private weak var central: CBCentralManager?
    private let onEvent: ([String: Any]) -> Void
    private var scanning = false

    init(central: CBCentralManager, onEvent: @escaping ([String: Any]) -> Void) {
        self.central = central
        self.onEvent = onEvent
    }

    func start(serviceUuids: [String]) {
        guard let central = central, central.state == .poweredOn else {
            onEvent(BleUtils.errorEvent("bluetoothUnavailable", "Bluetooth is not powered on"))
            return
        }
        guard !scanning else { return }
        scanning = true
        let uuids = serviceUuids.map { CBUUID(string: $0) }
        central.scanForPeripherals(withServices: uuids.isEmpty ? nil : uuids, options: nil)
    }

    func stop() {
        guard scanning else { return }
        scanning = false
        central?.stopScan()
    }

    func handleDiscovery(peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""

        var manufacturerData: [Int: [Int]] = [:]
        if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 2 {
            let companyId = Int(data[0]) | (Int(data[1]) << 8)
            let payload = data.subdata(in: 2..<data.count)
            manufacturerData[companyId] = [UInt8](payload).map { Int($0) }
        }

        let serviceUuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map { $0.uuidString } ?? []

        onEvent(
            BleUtils.event(
                "scanResult",
                [
                    "id": peripheral.identifier.uuidString,
                    "name": name,
                    "rssi": rssi.intValue,
                    "manufacturerData": manufacturerData,
                    "serviceUuids": serviceUuids,
                ]
            )
        )
    }
}
