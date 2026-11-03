package com.vbox.player

import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Go 代理平台通道（批次 C · C-10 Go 代理三端绑定 —— Android 侧）。
 *
 * MethodChannel `com.vbox.player/go_proxy`：
 *  - `start`（port）→ `ok:<实际端口>` 或 `error:<原因>`
 *  - `stop` → `ok`
 *  - `registerStream`（upstreamUrl + headers）→ 本地代理地址或原始 URL
 *  - `status` → 状态文本（含预取统计）
 *  - `clearCache` → `ok`
 *
 * 底层封装 gomobile 生成的 `quarkproxy.Quarkproxy`（`go-proxy/` 目录
 * `gomobile bind -target=android` 产物，libquarkproxy.so + Java 包装类）。
 * 前置：构建脚本就位 libquarkproxy.so（jniLibs，AGP 随 APK 打包）；
 * 缺失时本插件优雅降级（所有调用返回 error / 原 URL），Dart 侧
 * [GoProxyClient] 按降级直链语义处理，不 crash。
 */
class GoProxyPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var channel: MethodChannel? = null
    private var proxyAvailable = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val c = MethodChannel(binding.binaryMessenger, CHANNEL)
        c.setMethodCallHandler(this)
        channel = c
        // 尝试加载 gomobile 生成的库；失败标记不可用（Dart 侧降级直链）。
        proxyAvailable = tryLoadLibrary()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(call, result)
            "stop" -> result.success(invoke("stopProxy"))
            "registerStream" -> registerStream(call, result)
            "status" -> result.success(invoke("proxyStatus"))
            "clearCache" -> result.success(invoke("clearCache"))
            else -> result.notImplemented()
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        if (!proxyAvailable) {
            result.success("error:quarkproxy library not loaded")
            return
        }
        val port = (call.argument<Number>("port")?.toInt()) ?: 10078
        val r = invoke("startProxy", port)
        result.success(r)
    }

    private fun registerStream(call: MethodCall, result: MethodChannel.Result) {
        if (!proxyAvailable) {
            // 对齐 Dart 降级直链：返回原始 URL。
            result.success(call.argument<String>("upstreamUrl") ?: "")
            return
        }
        val upstreamUrl = call.argument<String>("upstreamUrl") ?: ""
        val headersJson = headersToJson(call.argument<Map<*, *>>("headers"))
        result.success(invoke("registerStream", upstreamUrl, headersJson))
    }

    private fun headersToJson(headers: Map<*, *>?): String {
        if (headers.isNullOrEmpty()) return ""
        val sb = StringBuilder("{")
        var first = true
        for ((k, v) in headers) {
            if (!first) sb.append(",")
            first = false
            sb.append(quote(k.toString())).append(":").append(quote(v.toString()))
        }
        sb.append("}")
        return sb.toString()
    }

    private fun quote(s: String): String =
        "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

    /**
     * 反射调用 quarkproxy.Quarkproxy 静态方法（避免编译期依赖未就位的库）。
     * 每次调用容错：任何异常返回 "error:" 前缀，Dart 侧据此降级。
     */
    private fun invoke(method: String, vararg args: Any): String {
        if (!proxyAvailable) return "error:quarkproxy not available"
        return try {
            val cls = Class.forName("quarkproxy.Quarkproxy")
            val paramTypes = args.map { it.javaClass }.toTypedArray()
            val m = cls.getMethod(method, *paramTypes)
            (m.invoke(null, *args) as? String) ?: "ok"
        } catch (e: Throwable) {
            Log.w("vbox", "GoProxy invoke $method 失败: ${e.message}")
            "error:${e.message}"
        }
    }

    private fun tryLoadLibrary(): Boolean {
        return try {
            System.loadLibrary("quarkproxy")
            true
        } catch (e: UnsatisfiedLinkError) {
            Log.w("vbox", "libquarkproxy 加载失败，Go 代理降级直链: ${e.message}")
            false
        }
    }

    companion object {
        const val CHANNEL = "com.vbox.player/go_proxy"

        /** 注册到引擎（MainActivity 调用，与 PlayerPlugin/SystemPlugin 同模式）。 */
        @JvmStatic
        fun registerWith(engine: io.flutter.embedding.engine.FlutterEngine) {
            val c = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            val plugin = GoProxyPlugin()
            c.setMethodCallHandler(plugin)
            plugin.channel = c
            plugin.proxyAvailable = plugin.tryLoadLibrary()
        }
    }
}
