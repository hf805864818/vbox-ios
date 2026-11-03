package com.vbox.player

import android.app.Activity
import android.content.Context
import android.media.AudioManager
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 屏幕亮度 / 系统音量平台通道（批次 D · D1 —— Android/TV 腿）。
 *
 * MethodChannel `com.vbox.player/screen_controls`（方法名与 Dart
 * [MethodChannelScreenControlsBridge] 已定协议一一对应）：
 *  - `getBrightness` → `activity.window.attributes.screenBrightness`；
 *    未覆写（<0，BRIGHTNESS_OVERRIDE_NONE）时回读
 *    `Settings.System.SCREEN_BRIGHTNESS / 255`；
 *  - `setBrightness` → attributes.screenBrightness = value + updateAttributes()
 *    （窗口级亮度：App 内生效，退后台不持久的等价体验，与 iOS
 *    `UIScreen.brightness` 系统级语义差异已登记）；
 *  - `getVolume` / `setVolume` → `AudioManager` STREAM_MUSIC
 *    `getStreamVolume / getStreamMaxVolume / setStreamVolume`（对齐 iOS
 *    `SystemVolumeController`（MPVolumeView）系统音量语义）。
 */
class ScreenControlsPlugin : FlutterPlugin, ActivityAware,
    MethodChannel.MethodCallHandler {

    private var activity: Activity? = null
    private var appContext: Context? = null
    private var channel: MethodChannel? = null

    // ─────────────── FlutterPlugin ───────────────

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

    // ─────────────── ActivityAware ───────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    // ─────────────── MethodChannel ───────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getBrightness" -> result.success(getBrightness())
            "setBrightness" -> {
                setBrightness((call.arguments as? Number)?.toDouble() ?: 0.5)
                result.success(null)
            }
            "getVolume" -> result.success(getVolume())
            "setVolume" -> {
                setVolume((call.arguments as? Number)?.toDouble() ?: 0.5)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun getBrightness(): Double {
        val win = activity?.window
        if (win != null) {
            val attr = win.attributes
            if (attr.screenBrightness in 0f..1f) {
                return attr.screenBrightness.toDouble()
            }
        }
        // 未覆写窗口亮度 → 读系统亮度（0~255 归一化）。
        val ctx = appContext ?: return 0.5
        return try {
            Settings.System.getInt(
                ctx.contentResolver,
                Settings.System.SCREEN_BRIGHTNESS,
            ) / 255.0
        } catch (e: Exception) {
            0.5
        }
    }

    private fun setBrightness(value: Double) {
        val win = activity?.window ?: return
        val v = value.coerceIn(0.0, 1.0).toFloat()
        val attr = win.attributes
        attr.screenBrightness = v
        win.attributes = attr
    }

    private fun getVolume(): Double {
        val ctx = appContext ?: return 0.5
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            ?: return 0.5
        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max <= 0) return 0.5
        return am.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max
    }

    private fun setVolume(value: Double) {
        val ctx = appContext ?: return
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            ?: return
        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max <= 0) return
        val target = (value.coerceIn(0.0, 1.0) * max).toInt()
        try {
            am.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
        } catch (e: SecurityException) {
            // TV 等设备可能拒调：静默（手势不因调节失败而中断）。
        }
    }

    companion object {
        private const val CHANNEL = "com.vbox.player/screen_controls"

        /** 供 [MainActivity.configureFlutterEngine] 手动注册（非插件工程无 registrant）。 */
        @JvmStatic
        fun registerWith(engine: FlutterEngine) {
            engine.plugins.add(ScreenControlsPlugin())
        }
    }
}
