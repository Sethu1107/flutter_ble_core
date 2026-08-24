package com.yourcompany.flutter_ble_core

import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings

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
                onEvent(
                    BleUtils.event(
                        "scanResult",
                        mapOf(
                            "id" to device.address,
                            "name" to (device.name ?: result.scanRecord?.deviceName ?: ""),
                            "rssi" to result.rssi,
                        ),
                    ),
                )
            }

            override fun onScanFailed(errorCode: Int) {
                scanning = false
                onEvent(BleUtils.errorEvent("scanFailed", "Scan failed with code $errorCode"))
            }
        }

    fun start() {
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

        try {
            scanning = true
            leScanner.startScan(null, settings, scanCallback)
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
