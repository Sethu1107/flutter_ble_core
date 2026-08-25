package com.github.sethu1107.flutter_ble_core

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test

/*
 * Run from the command line with `./gradlew testDebugUnitTest` in `example/android/`,
 * or directly from IDEs that support JUnit such as Android Studio.
 */

internal class FlutterBleCorePluginTest {
    @Test
    fun onMethodCall_unknownMethod_isNotImplemented() {
        val plugin = FlutterBleCorePlugin()

        val call = MethodCall("unknownMethod", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).notImplemented()
    }

    @Test
    fun onMethodCall_beforeInitialize_reportsNotInitialized() {
        val plugin = FlutterBleCorePlugin()

        val call = MethodCall("startScan", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).error("notInitialized", "Call initialize() first", null)
    }
}
