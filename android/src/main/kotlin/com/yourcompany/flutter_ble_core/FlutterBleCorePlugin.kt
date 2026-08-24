package com.yourcompany.flutter_ble_core

import android.bluetooth.BluetoothManager
import android.content.Context
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

    private fun emit(event: Map<String, Any?>) {
        eventSink?.success(event)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            when (call.method) {
                "initialize" -> initialize(result)
                "startScan" -> withReady(result) { scanner!!.start(); result.success(null) }
                "stopScan" -> withReady(result) { scanner!!.stop(); result.success(null) }
                "connect" -> withReady(result) { connection!!.connect(requireArg(call, "deviceId"), result) }
                "disconnect" -> withReady(result) { connection!!.disconnect(requireArg(call, "deviceId"), result) }
                "discoverServices" ->
                    withReady(result) {
                        connection!!.discoverServices(requireArg(call, "deviceId"), result)
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
        val adapter = manager?.adapter
        if (adapter == null) {
            result.error("bluetoothUnavailable", "This device does not support Bluetooth", null)
            return
        }
        scanner = BleScanner(adapter) { emit(it) }
        connection = BleConnection(context, adapter) { emit(it) }
        emit(
            BleUtils.event(
                "bluetoothState",
                mapOf("state" to if (adapter.isEnabled) "poweredOn" else "poweredOff"),
            ),
        )
        result.success(null)
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
}
