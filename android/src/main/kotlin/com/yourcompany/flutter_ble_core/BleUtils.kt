package com.yourcompany.flutter_ble_core

import android.bluetooth.BluetoothGattCharacteristic

object BleUtils {
    fun event(type: String, data: Map<String, Any?>): Map<String, Any?> {
        return mapOf("type" to type, "data" to data)
    }

    fun errorEvent(code: String, message: String?): Map<String, Any?> {
        return event("error", mapOf("code" to code, "message" to (message ?: "")))
    }

    fun bytesToIntList(value: ByteArray?): List<Int> {
        return value?.map { it.toInt() and 0xFF } ?: emptyList()
    }

    fun canRead(characteristic: BluetoothGattCharacteristic): Boolean {
        return characteristic.properties and BluetoothGattCharacteristic.PROPERTY_READ != 0
    }

    fun canWrite(characteristic: BluetoothGattCharacteristic): Boolean {
        val props = characteristic.properties
        return props and
            (
                BluetoothGattCharacteristic.PROPERTY_WRITE or
                    BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE
            ) != 0
    }

    fun canNotify(characteristic: BluetoothGattCharacteristic): Boolean {
        val props = characteristic.properties
        return props and
            (
                BluetoothGattCharacteristic.PROPERTY_NOTIFY or
                    BluetoothGattCharacteristic.PROPERTY_INDICATE
            ) != 0
    }
}
