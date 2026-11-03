package com.vbox.player

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 系统信息平台通道（G-02-C：UiMode 真机判定）。
 *
 * 对齐方案 §T.1 三重判定（Android 侧）：
 *  - MethodChannel `com.vbox.system/system`：
 *    `getUiModeType`（UI_MODE_TYPE_TELEVISION）/ `hasLeanbackFeature` / `hasTouchscreen`
 *  - 三 API 均 ≥ API 21（minSdk 24），无需版本判断；
 *  - Dart 侧 [SystemBridge] 组合判定（见 `lib/platform/system/system_bridge.dart`）。
 */
class SystemPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var appContext: Context? = null
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        val c = MethodChannel(binding.binaryMessenger, CHANNEL)
        c.setMethodCallHandler(this)
        channel = c
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext
        if (ctx == null) {
            result.error("E_STATE", "插件未附着引擎", null)
            return
        }
        when (call.method) {
            "getUiModeType" -> {
                val m = ctx.getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                result.success(m.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION)
            }
            "hasLeanbackFeature" -> result.success(
                ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
            )
            "hasTouchscreen" -> result.success(
                ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)
            )
            else -> result.notImplemented()
        }
    }

    companion object {
        private const val CHANNEL = "com.vbox.system/system"

        /** 供 [MainActivity.configureFlutterEngine] 手动注册（非插件工程无 registrant）。 */
        @JvmStatic
        fun registerWith(engine: FlutterEngine) {
            engine.plugins.add(SystemPlugin())
        }
    }
}
