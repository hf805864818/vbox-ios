package com.vbox.player

import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.vbox.player.player.MediaPlaybackService

/**
 * 后台播放平台通道（批次 C · C-05 后台播放 —— Android 腿）。
 *
 * MethodChannel `com.vbox.player/background`：
 *  - `start` → 启动前台媒体服务（`MediaPlaybackService`，Media3
 *    `MediaSessionService` 宿主，manifest `foregroundServiceType=mediaPlayback`）
 *  - `stop` → 停止服务（回前台交还应用内播放）
 *  - `isActive` → 承载是否激活
 *
 * 控制面语义：Dart 侧 [BackgroundPlayController] 在「退后台 + 播放中」时
 * 调用 `start`，回前台调用 `stop`。真机端到端（锁屏控制 / 通知样式 /
 * 播放器实例交还）归 J 批次真机验收。
 */
class BackgroundPlayPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var appContext: Context? = null
    private var channel: MethodChannel? = null
    private var active = false

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
        active = false
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                startService()
                result.success(null)
            }
            "stop" -> {
                stopService()
                result.success(null)
            }
            "isActive" -> result.success(active)
            else -> result.notImplemented()
        }
    }

    private fun startService() {
        val ctx = appContext ?: return
        val intent = Intent(ctx, MediaPlaybackService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                ctx.startForegroundService(intent)
            } else {
                ctx.startService(intent)
            }
            active = true
        } catch (e: Exception) {
            Log.w("vbox", "后台播放服务启动失败: ${e.message}")
            active = false
        }
    }

    private fun stopService() {
        val ctx = appContext ?: return
        try {
            ctx.stopService(Intent(ctx, MediaPlaybackService::class.java))
        } catch (e: Exception) {
            Log.w("vbox", "后台播放服务停止失败: ${e.message}")
        }
        active = false
    }

    companion object {
        const val CHANNEL = "com.vbox.player/background"

        /** 注册到引擎（MainActivity 调用，与 PlayerPlugin/SystemPlugin 同模式）。 */
        @JvmStatic
        fun registerWith(engine: FlutterEngine) {
            engine.plugins.add(BackgroundPlayPlugin())
        }
    }
}
