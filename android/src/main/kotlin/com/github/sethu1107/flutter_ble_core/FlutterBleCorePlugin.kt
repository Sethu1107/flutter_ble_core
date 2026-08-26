package com.github.sethu1107.flutter_ble_core

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** FlutterBleCorePlugin: bridges [BleScanner]/[BleConnection] to Flutter via platform channels. */
class FlutterBleCorePlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler {
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var context: Context

    private var eventSink: EventChannel.EventSink? = null
    private var scanner: BleScanner? = null
    private var connection: BleConnection? = null
    private var adapter: BluetoothAdapter? = null
    private var stateReceiver: BroadcastReceiver? = null

    // Lazy so plain-JVM unit tests that construct FlutterBleCorePlugin() without an Android
    // runtime don't crash on Looper.getMainLooper() before any event is ever emitted.
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "flutter_ble/methods")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "flutter_ble/events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        stateReceiver?.let { context.unregisterReceiver(it) }
        stateReceiver = null
        scanner?.stop()
        connection?.disconnectAll()
        eventSink = null
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        eventSink = sink
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // Called from various callback threads (ScanCallback, BluetoothGattCallback,
    // BroadcastReceiver) as well as the main thread — EventSink.success() is only
    // valid on the main thread, so always post there rather than calling directly.
    private fun emit(event: Map<String, Any?>) {
        mainHandler.post { eventSink?.success(event) }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            when (call.method) {
                "initialize" -> initialize(result)
                "startScan" ->
                    withReady(result) {
                        val serviceUuids = call.argument<List<String>>("serviceUuids") ?: emptyList()
                        val scanMode = scanModeFromString(call.argument<String>("scanMode"))
                        scanner!!.start(serviceUuids, scanMode)
                        result.success(null)
                    }
                "stopScan" -> withReady(result) { scanner!!.stop(); result.success(null) }
                "connect" ->
                    withReady(result) {
                        val timeoutMs = call.argument<Int>("timeoutMs")?.toLong() ?: DEFAULT_CONNECT_TIMEOUT_MS
                        connection!!.connect(requireArg(call, "deviceId"), timeoutMs, result)
                    }
                "disconnect" ->
                    withReady(result) {
                        val timeoutMs = call.argument<Int>("timeoutMs")?.toLong() ?: DEFAULT_DISCONNECT_TIMEOUT_MS
                        connection!!.disconnect(requireArg(call, "deviceId"), timeoutMs, result)
                    }
                "discoverServices" ->
                    withReady(result) {
                        connection!!.discoverServices(requireArg(call, "deviceId"), result)
                    }
                "requestMtu" ->
                    withReady(result) {
                        val mtu = call.argument<Int>("mtu") ?: throw IllegalArgumentException("Missing argument: mtu")
                        connection!!.requestMtu(requireArg(call, "deviceId"), mtu, result)
                    }
                "requestConnectionPriority" ->
                    withReady(result) {
                        val priority = connectionPriorityFromString(requireArg(call, "priority"))
                        connection!!.requestConnectionPriority(requireArg(call, "deviceId"), priority, result)
                    }
                "readCharacteristic" ->
                    withReady(result) {
                        connection!!.readCharacteristic(
                            requireArg(call, "deviceId"),
                            requireArg(call, "serviceUuid"),
                            requireArg(call, "characteristicUuid"),
                            result,
                        )
                    }
                "writeCharacteristic" ->
                    withReady(result) {
                        val value = call.argument<ByteArray>("value") ?: ByteArray(0)
                        connection!!.writeCharacteristic(
                            requireArg(call, "deviceId"),
                            requireArg(call, "serviceUuid"),
                            requireArg(call, "characteristicUuid"),
                            value,
                            call.argument<Boolean>("withResponse") ?: true,
                            result,
                        )
                    }
                "setNotify" ->
                    withReady(result) {
                        connection!!.setNotify(
                            requireArg(call, "deviceId"),
                            requireArg(call, "serviceUuid"),
                            requireArg(call, "characteristicUuid"),
                            call.argument<Boolean>("enabled") ?: false,
                            result,
                        )
                    }
                else -> result.notImplemented()
            }
        } catch (e: IllegalArgumentException) {
            result.error("operationFailed", e.message, null)
        }
    }

    private fun initialize(result: Result) {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val btAdapter = manager?.adapter
        if (btAdapter == null) {
            result.error("bluetoothUnavailable", "This device does not support Bluetooth", null)
            return
        }
        adapter = btAdapter
        scanner = BleScanner(btAdapter) { emit(it) }
        connection = BleConnection(context, btAdapter) { emit(it) }

        registerStateReceiver()

        emit(BleUtils.event("bluetoothState", mapOf("state" to adapterStateString(btAdapter))))
        result.success(null)
    }

    // BluetoothAdapter has no state-change callback of its own; ACTION_STATE_CHANGED is the
    // only way to learn the adapter was toggled off/on after initialize() already ran.
    private fun registerStateReceiver() {
        if (stateReceiver != null) return
        val receiver =
            object : BroadcastReceiver() {
                override fun onReceive(receivedContext: Context?, intent: Intent?) {
                    val btAdapter = adapter ?: return
                    emit(BleUtils.event("bluetoothState", mapOf("state" to adapterStateString(btAdapter))))
                }
            }
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
        stateReceiver = receiver
    }

    private fun adapterStateString(btAdapter: BluetoothAdapter): String {
        return when (btAdapter.state) {
            BluetoothAdapter.STATE_ON -> "poweredOn"
            BluetoothAdapter.STATE_OFF -> "poweredOff"
            BluetoothAdapter.STATE_TURNING_ON, BluetoothAdapter.STATE_TURNING_OFF -> "unknown"
            else -> "unknown"
        }
    }

    private inline fun withReady(result: Result, block: () -> Unit) {
        if (scanner == null || connection == null) {
            result.error("notInitialized", "Call initialize() first", null)
            return
        }
        block()
    }

    private fun requireArg(call: MethodCall, name: String): String =
        call.argument<String>(name) ?: throw IllegalArgumentException("Missing argument: $name")

    private fun connectionPriorityFromString(value: String): Int =
        when (value) {
            "high" -> BluetoothGatt.CONNECTION_PRIORITY_HIGH
            "lowPower" -> BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER
            else -> BluetoothGatt.CONNECTION_PRIORITY_BALANCED
        }

    private fun scanModeFromString(value: String?): Int =
        when (value) {
            "lowPower" -> ScanSettings.SCAN_MODE_LOW_POWER
            "balanced" -> ScanSettings.SCAN_MODE_BALANCED
            else -> ScanSettings.SCAN_MODE_LOW_LATENCY
        }

    companion object {
        // Only used if the Dart side omits timeoutMs — BleManager always sends one,
        // these exist purely so a stale/mismatched Dart binary doesn't crash the call.
        private const val DEFAULT_CONNECT_TIMEOUT_MS = 10_000L
        private const val DEFAULT_DISCONNECT_TIMEOUT_MS = 5_000L
    }
}
