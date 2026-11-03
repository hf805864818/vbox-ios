package com.vbox.player

import android.app.PictureInPictureParams
import android.os.Build
import android.util.Log
import android.util.Rational
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.embedding.engine.plugins.lifecycle.HiddenLifecycleReference
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 系统画中画平台通道（批次 C · C-05 PiP 多策略 —— Android 系统腿）。
 *
 * MethodChannel `com.vbox.player/pip`：
 *  - `isSupported` → API 26+ 且 Activity 已声明 `supportsPictureInPicture`
 *  - `enterPip`（width/height 可选）→ `enterPictureInPictureMode`
 *  - `exitPip` → `moveTaskToBack(true)`（退出系统画中画）
 *  - `isInPip` → 当前是否处于系统画中画
 *
 * EventChannel `com.vbox.player/pip/events`：`{type: pipChanged, value: bool}`
 * 进入/退出系统画中画时上抛（Dart 侧 [PipController] 同步状态）。
 *
 * 生命周期口径：系统进入 PiP 会先回调 `onPictureInPictureModeChanged(true)`
 * 再 `onPause`，故在 `ON_PAUSE` 处读取 `isInPictureInPictureMode` 判进入；
 * `ON_RESUME` 且已不在 PiP 判退出（含用户点全屏按钮手动退出）。
 */
class PipPlugin : FlutterPlugin, ActivityAware,
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private var activityBinding: ActivityPluginBinding? = null
    private var lifecycle: Lifecycle? = null
    private var channel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private var inPip = false

    private val lifecycleObserver = object : DefaultLifecycleObserver {
        override fun onPause(owner: LifecycleOwner) {
            val activity = activityBinding?.activity ?: return
            if (Build.VERSION.SDK_INT >= 26 && activity.isInPictureInPictureMode) {
                inPip = true
                emit("pipChanged", true)
            }
        }

        override fun onResume(owner: LifecycleOwner) {
            val activity = activityBinding?.activity ?: return
            val still =
                Build.VERSION.SDK_INT >= 26 && activity.isInPictureInPictureMode
            if (!still && inPip) {
                inPip = false
                emit("pipChanged", false)
            }
        }
    }

    // ─────────────── FlutterPlugin ───────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val c = MethodChannel(binding.binaryMessenger, CHANNEL)
        c.setMethodCallHandler(this)
        channel = c
        val ec = EventChannel(binding.binaryMessenger, EVENTS_CHANNEL)
        ec.setStreamHandler(this)
        eventChannel = ec
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        sink = null
    }

    // ─────────────── ActivityAware ───────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        lifecycle = (binding.lifecycle as HiddenLifecycleReference).lifecycle
        lifecycle?.addObserver(lifecycleObserver)
    }

    override fun onDetachedFromActivity() {
        lifecycle?.removeObserver(lifecycleObserver)
        lifecycle = null
        activityBinding = null
        inPip = false
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity()
    }

    // ─────────────── MethodChannel ───────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(isSupported())
            "enterPip" -> enterPip(call, result)
            "exitPip" -> exitPip(result)
            "isInPip" -> result.success(inPip)
            else -> result.notImplemented()
        }
    }

    private fun isSupported(): Boolean {
        val activity = activityBinding?.activity ?: return false
        return Build.VERSION.SDK_INT >= 26 &&
            activity.packageManager.hasSystemFeature(
                android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE
            )
    }

    private fun enterPip(call: MethodCall, result: MethodChannel.Result) {
        val activity = activityBinding?.activity
        if (activity == null || Build.VERSION.SDK_INT < 26) {
            result.success(false)
            return
        }
        try {
            val w = call.argument<Int>("width")
            val h = call.argument<Int>("height")
            val builder = PictureInPictureParams.Builder()
            if (w != null && h != null && w > 0 && h > 0) {
                builder.setAspectRatio(Rational(w, h))
            } else {
                builder.setAspectRatio(Rational(16, 9))
            }
            val ok = activity.enterPictureInPictureMode(builder.build())
            if (ok) {
                inPip = true
                emit("pipChanged", true)
            }
            result.success(ok)
        } catch (e: Exception) {
            Log.w("vbox", "enterPictureInPictureMode 失败: ${e.message}")
            result.success(false)
        }
    }

    private fun exitPip(result: MethodChannel.Result) {
        val activity = activityBinding?.activity
        if (activity == null || Build.VERSION.SDK_INT < 26 ||
            !activity.isInPictureInPictureMode
        ) {
            result.success(false)
            return
        }
        activity.moveTaskToBack(true)
        result.success(true)
    }

    // ─────────────── EventChannel ───────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        emit("pipChanged", inPip)
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(event: String, value: Any) {
        sink?.success(mapOf("type" to event, "value" to value))
    }

    companion object {
        const val CHANNEL = "com.vbox.player/pip"
        const val EVENTS_CHANNEL = "com.vbox.player/pip/events"
    }
}
