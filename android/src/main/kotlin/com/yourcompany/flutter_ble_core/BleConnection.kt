package com.yourcompany.flutter_ble_core

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.content.Context
import io.flutter.plugin.common.MethodChannel.Result
import java.util.UUID

/** Manages per-device GATT connections: connect/disconnect, discovery, read/write/notify. */
class BleConnection(
    private val context: Context,
    private val adapter: BluetoothAdapter,
    private val onEvent: (Map<String, Any?>) -> Unit,
) {
    private val gattMap = mutableMapOf<String, BluetoothGatt>()
    private val pendingServiceDiscovery = mutableMapOf<String, Result>()
    private val pendingReads = mutableMapOf<String, Result>()
    private val pendingWrites = mutableMapOf<String, Result>()

    fun connect(deviceId: String, result: Result) {
        try {
            val device = adapter.getRemoteDevice(deviceId)
            val gatt = device.connectGatt(context, false, gattCallback(deviceId))
            gattMap[deviceId] = gatt
            result.success(null)
        } catch (e: IllegalArgumentException) {
            result.error("connectionFailed", "Invalid device id: $deviceId", null)
        } catch (e: SecurityException) {
            result.error("permissionDenied", e.message, null)
        }
    }

    fun disconnect(deviceId: String, result: Result) {
        val gatt = gattMap.remove(deviceId)
        if (gatt != null) {
            try {
                gatt.disconnect()
                gatt.close()
            } catch (e: SecurityException) {
                result.error("permissionDenied", e.message, null)
                return
            }
        }
        result.success(null)
    }

    fun discoverServices(deviceId: String, result: Result) {
        val gatt = gattMap[deviceId] ?: return result.error("connectionFailed", "Device not connected", null)
        pendingServiceDiscovery[deviceId] = result
        try {
            gatt.discoverServices()
        } catch (e: SecurityException) {
            pendingServiceDiscovery.remove(deviceId)
            result.error("permissionDenied", e.message, null)
        }
    }

    fun readCharacteristic(deviceId: String, serviceUuid: String, characteristicUuid: String, result: Result) {
        val gatt = gattMap[deviceId] ?: return result.error("connectionFailed", "Device not connected", null)
        val characteristic =
            findCharacteristic(gatt, serviceUuid, characteristicUuid)
                ?: return result.error("characteristicNotFound", "Characteristic not found", null)

        pendingReads[key(deviceId, characteristic)] = result
        try {
            gatt.readCharacteristic(characteristic)
        } catch (e: SecurityException) {
            pendingReads.remove(key(deviceId, characteristic))
            result.error("permissionDenied", e.message, null)
        }
    }

    fun writeCharacteristic(
        deviceId: String,
        serviceUuid: String,
        characteristicUuid: String,
        value: ByteArray,
        withResponse: Boolean,
        result: Result,
    ) {
        val gatt = gattMap[deviceId] ?: return result.error("connectionFailed", "Device not connected", null)
        val characteristic =
            findCharacteristic(gatt, serviceUuid, characteristicUuid)
                ?: return result.error("characteristicNotFound", "Characteristic not found", null)

        characteristic.writeType =
            if (withResponse) {
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            } else {
                BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            }
        characteristic.value = value

        pendingWrites[key(deviceId, characteristic)] = result
        try {
            gatt.writeCharacteristic(characteristic)
        } catch (e: SecurityException) {
            pendingWrites.remove(key(deviceId, characteristic))
            result.error("permissionDenied", e.message, null)
        }
    }

    fun setNotify(
        deviceId: String,
        serviceUuid: String,
        characteristicUuid: String,
        enabled: Boolean,
        result: Result,
    ) {
        val gatt = gattMap[deviceId] ?: return result.error("connectionFailed", "Device not connected", null)
        val characteristic =
            findCharacteristic(gatt, serviceUuid, characteristicUuid)
                ?: return result.error("characteristicNotFound", "Characteristic not found", null)

        try {
            gatt.setCharacteristicNotification(characteristic, enabled)
            val cccd = characteristic.getDescriptor(CCCD_UUID)
            if (cccd != null) {
                cccd.value =
                    if (enabled) {
                        BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    } else {
                        BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                    }
                gatt.writeDescriptor(cccd)
            }
            result.success(null)
        } catch (e: SecurityException) {
            result.error("permissionDenied", e.message, null)
        }
    }

    fun disconnectAll() {
        gattMap.values.forEach {
            try {
                it.disconnect()
                it.close()
            } catch (e: SecurityException) {
                // Best-effort cleanup; nothing to report to.
            }
        }
        gattMap.clear()
    }

    private fun findCharacteristic(
        gatt: BluetoothGatt,
        serviceUuid: String,
        characteristicUuid: String,
    ): BluetoothGattCharacteristic? {
        val service = gatt.getService(UUID.fromString(serviceUuid)) ?: return null
        return service.getCharacteristic(UUID.fromString(characteristicUuid))
    }

    private fun key(deviceId: String, characteristic: BluetoothGattCharacteristic) =
        "$deviceId|${characteristic.service.uuid}|${characteristic.uuid}"

    private fun gattCallback(deviceId: String) =
        object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                val state =
                    when (newState) {
                        BluetoothProfile.STATE_CONNECTING -> "connecting"
                        BluetoothProfile.STATE_CONNECTED -> "connected"
                        BluetoothProfile.STATE_DISCONNECTING -> "disconnecting"
                        else -> "disconnected"
                    }
                onEvent(BleUtils.event("connectionState", mapOf("deviceId" to deviceId, "state" to state)))

                if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    try {
                        gatt.close()
                    } catch (e: SecurityException) {
                        // Ignore; the connection is already gone.
                    }
                    gattMap.remove(deviceId)
                }
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                val result = pendingServiceDiscovery.remove(deviceId) ?: return
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    result.error("operationFailed", "Service discovery failed with status $status", null)
                    return
                }
                val services =
                    gatt.services.map { service ->
                        mapOf(
                            "uuid" to service.uuid.toString(),
                            "characteristics" to
                                service.characteristics.map { c ->
                                    mapOf(
                                        "uuid" to c.uuid.toString(),
                                        "canRead" to BleUtils.canRead(c),
                                        "canWrite" to BleUtils.canWrite(c),
                                        "canNotify" to BleUtils.canNotify(c),
                                    )
                                },
                        )
                    }
                result.success(services)
            }

            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                val result = pendingReads.remove(key(deviceId, characteristic)) ?: return
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    result.success(BleUtils.bytesToIntList(characteristic.value))
                } else {
                    result.error("operationFailed", "Read failed with status $status", null)
                }
            }

            override fun onCharacteristicWrite(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                val result = pendingWrites.remove(key(deviceId, characteristic)) ?: return
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    result.success(null)
                } else {
                    result.error("operationFailed", "Write failed with status $status", null)
                }
            }

            override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
                onEvent(
                    BleUtils.event(
                        "characteristicValue",
                        mapOf(
                            "deviceId" to deviceId,
                            "serviceUuid" to characteristic.service.uuid.toString(),
                            "characteristicUuid" to characteristic.uuid.toString(),
                            "value" to BleUtils.bytesToIntList(characteristic.value),
                        ),
                    ),
                )
            }
        }

    companion object {
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
