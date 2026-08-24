import CoreBluetooth
import Flutter

enum BleUtils {
    static func event(_ type: String, _ data: [String: Any?]) -> [String: Any] {
        return ["type": type, "data": data]
    }

    static func errorEvent(_ code: String, _ message: String?) -> [String: Any] {
        return event("error", ["code": code, "message": message ?? ""])
    }

    static func bytes(from data: FlutterStandardTypedData?) -> Data {
        return data?.data ?? Data()
    }

    static func canRead(_ characteristic: CBCharacteristic) -> Bool {
        return characteristic.properties.contains(.read)
    }

    static func canWrite(_ characteristic: CBCharacteristic) -> Bool {
        return characteristic.properties.contains(.write)
            || characteristic.properties.contains(.writeWithoutResponse)
    }

    static func canNotify(_ characteristic: CBCharacteristic) -> Bool {
        return characteristic.properties.contains(.notify)
            || characteristic.properties.contains(.indicate)
    }
}
