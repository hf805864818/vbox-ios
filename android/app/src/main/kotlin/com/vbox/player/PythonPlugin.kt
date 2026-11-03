package com.vbox.player

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlin.concurrent.thread

/**
 * Python 运行时平台通道（Wave G · RT-运1 —— Android 侧 Chaquopy 接入）。
 *
 * ## 背景
 * Dart `PythonBridgeEngine` 原以 `Process.start("python3", …)` 起常驻子进程跑蜘蛛脚本，
 * 但 Android 无 `python3` 可执行文件 → 8 个 `y_*` Python 站点在 Android / TV 全不可用。
 * Chaquopy 把 CPython 解释器随 APK 打包，本插件据此在**进程内**运行脚本。
 *
 * ## 协议（MethodChannel `com.vbox.python/python`）
 *  - `launch`（`script` / `timeoutMs`）→ `null`；加载脚本并等待 `READY`
 *  - `request`（`line` / `timeoutMs`）→ 一行 JSON 响应；超时或脚本退出 → `PlatformException`
 *  - `shutdown` → `null`
 *
 * ## 调用模型（v2 · 对齐 iOS `PythonBridge.m` 的对象调用）
 * 真实 TVBox py 源是标准 `Spider` 类定义脚本（无 READY/stdio 循环），v1 的
 * 「脚本自实现 stdio ABI」模型永远等不到 READY → 分类数据「暂无数据」。
 * v2 由 Python 侧 `vbox_python_bridge.run()` 承担 ABI 循环：exec 脚本 → 校验
 * `Spider` 类 → READY → 逐请求实例化 Spider 并按 TVBox 标准签名调用方法
 * （与 iOS callSpider 一致）。本插件的 stdio 桥（[StdioBridge]）语义不变，
 * 只是输出方从「脚本自身」变为「桥模块」。
 *
 * ## 线程模型
 *  - 脚本运行在常驻线程 `vbox-python-spider`，阻塞于 [StdioBridge.readLine]；
 *  - MethodChannel 回调在平台主线程，故 `launch` / `request` 的重活派发到单线程
 *    [work] 执行器（保序），结果再回投主线程（避免阻塞主线程触发 ANR）。
 */
class PythonPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var channel: MethodChannel? = null
    private var appContext: Context? = null

    /** Dart 请求行 → 脚本；[EOF] 表示关闭（唤醒 [StdioBridge.readLine] 返回 null）。 */
    private val inbound = LinkedBlockingQueue<String>()

    /** 脚本输出行 → Dart；[EOF] 表示脚本已退出。 */
    private val outbound = LinkedBlockingQueue<String>()

    /** `write()` 可能收到半行，按 `\n` 切分后再入队。 */
    private val writeBuffer = StringBuilder()

    @Volatile
    private var runner: Thread? = null

    private val work = Executors.newSingleThreadExecutor { r ->
        Thread(r, "vbox-python-work").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())

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
        shutdownBridge()
        work.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "launch" -> {
                val script = call.argument<String>("script").orEmpty()
                val timeoutMs = call.argument<Number>("timeoutMs")?.toLong() ?: DEFAULT_TIMEOUT_MS
                work.execute {
                    try {
                        launchRuntime(script, timeoutMs)
                        main.post { result.success(null) }
                    } catch (t: Throwable) {
                        main.post { result.error("E_PY_RUNTIME", t.message ?: "Python 运行时启动失败", null) }
                    }
                }
            }

            "request" -> {
                val line = call.argument<String>("line").orEmpty()
                val timeoutMs = call.argument<Number>("timeoutMs")?.toLong() ?: DEFAULT_TIMEOUT_MS
                work.execute {
                    try {
                        val resp = roundTrip(line, timeoutMs)
                        main.post { result.success(resp) }
                    } catch (t: TimeoutException) {
                        main.post { result.error("E_TIMEOUT", t.message, null) }
                    } catch (t: Throwable) {
                        main.post { result.error("E_PY_RUNTIME", t.message ?: "Python 运行时调用失败", null) }
                    }
                }
            }

            "shutdown" -> work.execute {
                shutdownBridge()
                main.post { result.success(null) }
            }

            else -> result.notImplemented()
        }
    }

    // ─────────────── 运行时 ───────────────

    /** 启动运行时并等待脚本 `READY`（失败即抛，Dart 侧映射 `E_SCRIPT_LOAD`）。 */
    private fun launchRuntime(script: String, timeoutMs: Long) {
        shutdownBridge()
        ensurePythonStarted()
        val module = Python.getInstance().getModule(BRIDGE_MODULE)
        val io = StdioBridge()

        runner = thread(name = RUNNER_THREAD, isDaemon = true) {
            try {
                module.callAttr("run", script, io)
            } catch (t: Throwable) {
                Log.w(TAG, "Python 蜘蛛脚本异常退出：${t.message}", t)
            } finally {
                // 脚本结束（EOF / 异常）→ 唤醒可能阻塞的 request 等待者。
                outbound.offer(EOF)
            }
        }

        val first: String? = try {
            outbound.poll(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            null
        }
        when {
            first == null -> {
                shutdownBridge()
                throw IllegalStateException("Python 桥启动超时：脚本未输出 READY")
            }
            first == EOF -> {
                shutdownBridge()
                throw IllegalStateException("Python 桥启动失败：脚本异常退出（无 READY）")
            }
            first != READY_LINE -> {
                shutdownBridge()
                throw IllegalStateException("Python 桥启动失败：首个输出为「$first」")
            }
        }
    }

    /** 一次请求 → 一行响应（[inbound] 投递、[outbound] 取回，一一配对）。 */
    private fun roundTrip(line: String, timeoutMs: Long): String {
        if (runner == null) throw IllegalStateException("Python 桥未启动：请先 launch")
        inbound.put(line)
        val resp: String? = try {
            outbound.poll(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            null
        }
        if (resp == null) throw TimeoutException("Python 桥响应超时（${timeoutMs}ms）")
        if (resp == EOF) throw IllegalStateException("Python 桥已结束：脚本已退出")
        return resp
    }

    /** 关闭脚本线程与队列（幂等）。 */
    @Synchronized
    private fun shutdownBridge() {
        inbound.clear()
        outbound.clear()
        synchronized(writeBuffer) { writeBuffer.setLength(0) }
        val t = runner ?: return
        runner = null
        inbound.offer(EOF)
        try {
            t.join(SHUTDOWN_JOIN_MS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun ensurePythonStarted() {
        if (Python.isStarted()) return
        val ctx = appContext ?: throw IllegalStateException("Python 运行时未附着引擎")
        Python.start(AndroidPlatform(ctx))
    }

    /**
     * Python 侧 stdio 桥：`sys.stdin` / `sys.stdout` 落到本对象的两个方法上。
     *
     * Chaquopy 直接把本 Kotlin 对象传入 Python，`io.readLine()` / `io.write(s)` 逐次调用
     * 即落到此处（`readLine` 由脚本线程调用、阻塞于 [inbound]；`write` 同线程写入 [outbound]）。
     */
    inner class StdioBridge {
        /** `sys.stdin.readline()`；返回 null 表示 EOF（脚本据此 break 退出循环）。 */
        fun readLine(): String? = try {
            val line = inbound.take()
            if (line == EOF) null else line
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            null
        }

        /** `sys.stdout.write(s)`：按行切分入 [outbound]（`print` 会分两次 write，须缓冲）。 */
        fun write(s: String) {
            synchronized(writeBuffer) {
                writeBuffer.append(s)
                var idx = writeBuffer.indexOf("\n")
                while (idx >= 0) {
                    outbound.offer(writeBuffer.substring(0, idx).trimEnd('\r'))
                    writeBuffer.delete(0, idx + 1)
                    idx = writeBuffer.indexOf("\n")
                }
            }
        }
    }

    companion object {
        const val CHANNEL = "com.vbox.python/python"

        private const val TAG = "vbox"
        private const val BRIDGE_MODULE = "vbox_python_bridge"
        private const val RUNNER_THREAD = "vbox-python-spider"
        private const val READY_LINE = "READY"
        private const val DEFAULT_TIMEOUT_MS = 15_000L
        private const val SHUTDOWN_JOIN_MS = 500L
        private const val EOF = "\u0000VBOX_PY_EOF\u0000"

        /** 注册到引擎（MainActivity 调用，与 PlayerPlugin/GoProxyPlugin 同模式）。 */
        @JvmStatic
        fun registerWith(engine: FlutterEngine) {
            engine.plugins.add(PythonPlugin())
        }
    }
}
