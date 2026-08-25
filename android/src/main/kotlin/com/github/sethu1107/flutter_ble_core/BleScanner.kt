package com.github.sethu1107.flutter_ble_core

import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.os.ParcelUuid
import java.util.UUID

/** Wraps [BluetoothAdapter.getBluetoothLeScanner] and forwards results as events. */
class BleScanner(
    private val adapter: BluetoothAdapter,
    private val onEvent: (Map<String, Any?>) -> Unit,
) {
    private var scanning = false

    private val scanCallback =
        object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val device = result.device
                val record = result.scanRecord

                val manufacturerData = mutableMapOf<Int, List<Int>>()
                record?.manufacturerSpecificData?.let { sparse ->
                    for (i in 0 until sparse.size()) {
                        val companyId = sparse.keyAt(i)
                        manufacturerData[companyId] = BleUtils.bytesToIntList(sparse.valueAt(i))
                    }
                }

                val serviceUuids = record?.serviceUuids?.map { it.uuid.toString() } ?: emptyList()

                onEvent(
                    BleUtils.event(
                        "scanResult",
                        mapOf(
                            "id" to device.address,
                            "name" to (device.name ?: record?.deviceName ?: ""),
                            "rssi" to result.rssi,
                            "manufacturerData" to manufacturerData,
                            "serviceUuids" to serviceUuids,
                        ),
                    ),
                )
            }

            override fun onScanFailed(errorCode: Int) {
                scanning = false
                onEvent(BleUtils.errorEvent("scanFailed", "Scan failed with code $errorCode"))
            }
        }

    fun start(serviceUuids: List<String>) {
        val leScanner = adapter.bluetoothLeScanner
        if (leScanner == null) {
            onEvent(BleUtils.errorEvent("bluetoothUnavailable", "BLE scanner unavailable"))
            return
        }
        if (scanning) return

        val settings =
            ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .build()

        val filters =
            serviceUuids.mapNotNull { uuid ->
                try {
                    ScanFilter.Builder().setServiceUuid(ParcelUuid(UUID.fromString(uuid))).build()
                } catch (e: IllegalArgumentException) {
                    null
                }
            }

        try {
            scanning = true
            leScanner.startScan(filters.ifEmpty { null }, settings, scanCallback)
        } catch (e: SecurityException) {
            scanning = false
            onEvent(BleUtils.errorEvent("permissionDenied", e.message))
        }
    }

    fun stop() {
        if (!scanning) return
        scanning = false
        try {
            adapter.bluetoothLeScanner?.stopScan(scanCallback)
        } catch (e: SecurityException) {
            onEvent(BleUtils.errorEvent("permissionDenied", e.message))
        }
    }
}
