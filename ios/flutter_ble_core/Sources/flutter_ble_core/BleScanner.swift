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

    func start() {
        guard let central = central, central.state == .poweredOn else {
            onEvent(BleUtils.errorEvent("bluetoothUnavailable", "Bluetooth is not powered on"))
            return
        }
        guard !scanning else { return }
        scanning = true
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func stop() {
        guard scanning else { return }
        scanning = false
        central?.stopScan()
    }

    func handleDiscovery(peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        onEvent(
            BleUtils.event(
                "scanResult",
                [
                    "id": peripheral.identifier.uuidString,
                    "name": name,
                    "rssi": rssi.intValue,
                ]
            )
        )
    }
}
