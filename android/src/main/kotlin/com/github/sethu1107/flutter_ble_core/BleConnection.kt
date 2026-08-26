package com.github.sethu1107.flutter_ble_core

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel.Result
import java.util.UUID

/** Manages per-device GATT connections: connect/disconnect, discovery, read/write/notify. */
class BleConnection(
    private val context: Context,
    private val adapter: BluetoothAdapter,
    private val onEvent: (Map<String, Any?>) -> Unit,
) {
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    private val gattMap = mutableMapOf<String, BluetoothGatt>()
    private val pendingConnects = mutableMapOf<String, Result>()
    private val pendingConnectTimeouts = mutableMapOf<String, Runnable>()
    private val pendingDisconnects = mutableMapOf<String, Result>()
    private val pendingDisconnectTimeouts = mutableMapOf<String, Runnable>()
    private val pendingServiceDiscovery = mutableMapOf<String, Result>()
    private val pendingReads = mutableMapOf<String, Result>()
    private val pendingWrites = mutableMapOf<String, Result>()
    private val pendingMtu = mutableMapOf<String, Result>()

    fun connect(deviceId: String, timeoutMs: Long, result: Result) {
        try {
            val device = adapter.getRemoteDevice(deviceId)
            val gatt = device.connectGatt(context, false, gattCallback(deviceId))
            gattMap[deviceId] = gatt
            pendingConnects[deviceId] = result

            val timeoutRunnable =
                Runnable {
                    pendingConnectTimeouts.remove(deviceId)
                    val pending = pendingConnects.remove(deviceId) ?: return@Runnable
                    gattMap.remove(deviceId)?.let {
                        try {
                            it.disconnect()
                            it.close()
                        } catch (e: SecurityException) {
                            // Best-effort cleanup.
                        }
                    }
                    pending.error("timeout", "Timed out connecting to $deviceId", null)
                }
            pendingConnectTimeouts[deviceId] = timeoutRunnable
            mainHandler.postDelayed(timeoutRunnable, timeoutMs)
        } catch (e: IllegalArgumentException) {
            result.error("connectionFailed", "Invalid device id: $deviceId", null)
        } catch (e: SecurityException) {
            result.error("permissionDenied", e.message, null)
        }
    }

    /** Resolves once the platform confirms disconnection, not merely once it's requested. */
    fun disconnect(deviceId: String, timeoutMs: Long, result: Result) {
        val gatt = gattMap[deviceId]
        if (gatt == null) {
            result.success(null)
            return
        }

        pendingDisconnects[deviceId] = result
        val timeoutRunnable =
            Runnable {
                pendingDisconnectTimeouts.remove(deviceId)
                val pending = pendingDisconnects.remove(deviceId) ?: return@Runnable
                gattMap.remove(deviceId)?.let {
                    try {
                        it.close()
                    } catch (e: SecurityException) {
                        // Best-effort cleanup.
                    }
                }
                pending.error("timeout", "Timed out disconnecting from $deviceId", null)
            }
        pendingDisconnectTimeouts[deviceId] = timeoutRunnable
        mainHandler.postDelayed(timeoutRunnable, timeoutMs)

        try {
            gatt.disconnect()
        } catch (e: SecurityException) {
            clearPendingDisconnect(deviceId)
            pendingDisconnects.remove(deviceId)
            result.error("permissionDenied", e.message, null)
        }
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

    fun requestMtu(deviceId: String, mtu: Int, result: Result) {
        val gatt = gattMap[deviceId] ?: return result.error("connectionFailed", "Device not connected", null)
        pendingMtu[deviceId] = result
        try {
            if (!gatt.requestMtu(mtu)) {
                pendingMtu.remove(deviceId)
                result.error("operationFailed", "MTU request rejected", null)
            }
        } catch (e: SecurityException) {
            pendingMtu.remove(deviceId)
            result.error("permissionDenied", e.message, null)
        }
    }

    /// [priority] is one of [android.bluetooth.BluetoothGatt]'s CONNECTION_PRIORITY_* constants.
    /// There's no callback for this on Android — it's fire-and-forget, so success just
    /// means the request was accepted, not that the link parameters actually changed.
    fun requestConnectionPriority(deviceId: String, priority: Int, result: Result) {
        val gatt = gattMap[deviceId] ?: return result.error("connectionFailed", "Device not connected", null)
        try {
            if (gatt.requestConnectionPriority(priority)) {
                result.success(null)
            } else {
                result.error("operationFailed", "Connection priority request rejected", null)
            }
        } catch (e: SecurityException) {
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
                // Some peripherals only expose INDICATE (no NOTIFY) and reject the
                // notification CCCD value in that case, so pick indicate when it's
                // the only option.
                val indicateOnly =
                    characteristic.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY == 0 &&
                        characteristic.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0

                cccd.value =
                    when {
                        !enabled -> BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                        indicateOnly -> BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                        else -> BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    }
                gatt.writeDescriptor(cccd)
            }
            result.success(null)
        } catch (e: SecurityException) {
            result.error("permissionDenied", e.message, null)
        }
    }

    fun disconnectAll() {
        pendingConnectTimeouts.values.forEach { mainHandler.removeCallbacks(it) }
        pendingConnectTimeouts.clear()
        pendingDisconnectTimeouts.values.forEach { mainHandler.removeCallbacks(it) }
        pendingDisconnectTimeouts.clear()
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

    private fun clearPendingConnect(deviceId: String) {
        pendingConnectTimeouts.remove(deviceId)?.let { mainHandler.removeCallbacks(it) }
    }

    private fun clearPendingDisconnect(deviceId: String) {
        pendingDisconnectTimeouts.remove(deviceId)?.let { mainHandler.removeCallbacks(it) }
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

    // BluetoothGattCallback methods fire on a Binder thread, not the main thread — but
    // MethodChannel.Result/EventChannel.EventSink calls are only valid on the main thread,
    // and the pending* maps are plain HashMaps shared with onMethodCall (which runs on the
    // main thread). Every override posts its body to mainHandler so callbacks are handled
    // on the same thread as everything else, avoiding both an illegal-thread Result call
    // (which silently leaves the Dart Future to time out) and a data race on the maps.
    private fun gattCallback(deviceId: String) =
        object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                mainHandler.post { handleConnectionStateChange(deviceId, gatt, status, newState) }
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                mainHandler.post { handleServicesDiscovered(deviceId, gatt, status) }
            }

            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                mainHandler.post { handleCharacteristicRead(deviceId, characteristic, status) }
            }

            override fun onCharacteristicWrite(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                mainHandler.post { handleCharacteristicWrite(deviceId, characteristic, status) }
            }

            override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
                mainHandler.post { handleCharacteristicChanged(deviceId, characteristic) }
            }

            override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                mainHandler.post { handleMtuChanged(deviceId, mtu, status) }
            }
        }

    private fun handleConnectionStateChange(deviceId: String, gatt: BluetoothGatt, status: Int, newState: Int) {
        val state =
            when (newState) {
                BluetoothProfile.STATE_CONNECTING -> "connecting"
                BluetoothProfile.STATE_CONNECTED -> "connected"
                BluetoothProfile.STATE_DISCONNECTING -> "disconnecting"
                else -> "disconnected"
            }
        onEvent(BleUtils.event("connectionState", mapOf("deviceId" to deviceId, "state" to state)))

        if (newState == BluetoothProfile.STATE_CONNECTED) {
            clearPendingConnect(deviceId)
            pendingConnects.remove(deviceId)?.success(null)
        }

        if (newState == BluetoothProfile.STATE_DISCONNECTED) {
            try {
                gatt.close()
            } catch (e: SecurityException) {
                // Ignore; the connection is already gone.
            }
            gattMap.remove(deviceId)

            clearPendingConnect(deviceId)
            pendingConnects.remove(deviceId)?.error(
                "connectionFailed",
                "Disconnected before connect completed (status $status)",
                status,
            )

            clearPendingDisconnect(deviceId)
            pendingDisconnects.remove(deviceId)?.success(null)
        }
    }

    private fun handleServicesDiscovered(deviceId: String, gatt: BluetoothGatt, status: Int) {
        val result = pendingServiceDiscovery.remove(deviceId) ?: return
        if (status != BluetoothGatt.GATT_SUCCESS) {
            result.error("operationFailed", "Service discovery failed with status $status", status)
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

    private fun handleCharacteristicRead(deviceId: String, characteristic: BluetoothGattCharacteristic, status: Int) {
        val result = pendingReads.remove(key(deviceId, characteristic)) ?: return
        if (status == BluetoothGatt.GATT_SUCCESS) {
            result.success(BleUtils.bytesToIntList(characteristic.value))
        } else {
            result.error("operationFailed", "Read failed with status $status", status)
        }
    }

    private fun handleCharacteristicWrite(deviceId: String, characteristic: BluetoothGattCharacteristic, status: Int) {
        val result = pendingWrites.remove(key(deviceId, characteristic)) ?: return
        if (status == BluetoothGatt.GATT_SUCCESS) {
            result.success(null)
        } else {
            result.error("operationFailed", "Write failed with status $status", status)
        }
    }

    private fun handleCharacteristicChanged(deviceId: String, characteristic: BluetoothGattCharacteristic) {
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

    private fun handleMtuChanged(deviceId: String, mtu: Int, status: Int) {
        val result = pendingMtu.remove(deviceId) ?: return
        if (status == BluetoothGatt.GATT_SUCCESS) {
            result.success(mtu)
        } else {
            result.error("operationFailed", "MTU negotiation failed with status $status", status)
        }
    }

    companion object {
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
