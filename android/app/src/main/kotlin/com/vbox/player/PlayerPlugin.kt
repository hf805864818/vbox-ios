package com.vbox.player

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.vbox.player.player.CodecCapability
import com.vbox.player.player.PlayerBackend
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.interfaces.IVLCVout

/**
 * 播放器平台通道（G-02-A：Media3 主后端；Wave A · R-渲1：视频纹理输出面；
 * Wave G · R-渲3：libVLC 复杂封装回退后端）。
 *
 * 对齐契约 §2.5 播放器能力矩阵 + A21.5 回退策略：
 *  - MethodChannel `com.vbox.player/player`：open / play / pause / seekTo /
 *    setVolume / setSpeed / dispose
 *  - EventChannel `com.vbox.player/player/events`：state / progress / videoSize / error
 *
 * 渲染输出面（R-渲1）：`open` 时经 [TextureRegistry.createSurfaceProducer] 建
 * Flutter 纹理，后端把画面写进该 Surface，并把 `textureId` 随 `open` 返回值交给
 * Dart（[io.flutter.view.TextureRegistry.SurfaceProducer.id]），由 Dart
 * `Texture(textureId:)` 承载。原生解出视频轨后经 `videoSize` 事件上报宽高，
 * Dart 侧按纵横比自适应（对齐 iOS `videoGravity = .resizeAspect`）。
 *
 * 后端策略（D6 / A21.5）：
 *  - `backend=media3` 且媒体无需回退 → ExoPlayer（主后端）；
 *  - `backend=media3` 但 [CodecCapability.selectBackend] 判为 libVLC → 返回
 *    `E_BACKEND_UNAVAILABLE`，由 Dart `PlayerController` 按降级链改投 libVLC
 *    （降级可观测，C-06）；
 *  - `backend=libVLC` → libVLC 后端（复杂封装 MKV / FLV / TS / RMVB / AVI /
 *    WMV / M2TS、HEVC 无硬解等）。libVLC 直接写 Flutter 纹理的 Surface
 *    （`IVLCVout.setVideoSurface(surface, null)`；holder 为 null 时仅要求
 *    surface 已 valid —— libvlc-android `AWindow#setSurface` 已实证）。
 */
class PlayerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private var appContext: Context? = null
    private var channel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var sink: EventChannel.EventSink? = null

    /** Flutter 纹理注册表（R-渲1：SurfaceProducer 输出面）。 */
    private var textureRegistry: TextureRegistry? = null

    // ─────────────── Media3 主线（R-渲1）───────────────
    private var exoPlayer: ExoPlayer? = null

    // ─────────────── libVLC 回退线（R-渲3）───────────────
    private var libVlc: LibVLC? = null
    private var vlcPlayer: MediaPlayer? = null
    private var vlcVout: IVLCVout? = null
    private var vlcMedia: Media? = null

    /** 当前后端（`media3` / `libVLC` / null）。 */
    private var currentBackend: String? = null

    /** 视频输出面（R-渲1）：open 建、teardown 释放；Dart 侧以 id 承载画面。 */
    private var surfaceProducer: TextureRegistry.SurfaceProducer? = null

    private val handler = Handler(Looper.getMainLooper())
    private val progressTick = object : Runnable {
        override fun run() {
            emitProgress()
            handler.postDelayed(this, 500L)
        }
    }

    /** 输出面生命周期：Flutter 重建/销毁 Surface 时同步（切后台回前台画面恢复）。 */
    private val surfaceCallback = object : TextureRegistry.SurfaceProducer.Callback {
        override fun onSurfaceAvailable() {
            when (currentBackend) {
                "libVLC" -> rebindVlcSurface()
                else -> exoPlayer?.setVideoSurface(surfaceProducer?.surface)
            }
        }

        override fun onSurfaceCleanup() {
            when (currentBackend) {
                "libVLC" -> vlcVout?.detachViews()
                else -> exoPlayer?.setVideoSurface(null)
            }
        }
    }

    private val listener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
            when (playbackState) {
                Player.STATE_IDLE -> emitState("idle")
                Player.STATE_BUFFERING -> emitState("buffering")
                Player.STATE_READY ->
                    emitState(if (exoPlayer?.playWhenReady == true) "playing" else "paused")
                Player.STATE_ENDED -> emitState("ended")
            }
        }

        override fun onVideoSizeChanged(videoSize: VideoSize) {
            val w = videoSize.width
            val h = videoSize.height
            if (w <= 0 || h <= 0) return
            // 输出面尺寸随视频轨（SurfaceProducer 不自动跟随），并按纵横比通知 Dart。
            surfaceProducer?.setSize(w, h)
            emitLog("info", "视频轨尺寸=${w}x$h")
            emitVideoSize(w, h)
        }

        override fun onPlayerError(error: PlaybackException) {
            emitLog("error", "ExoPlayer 播放错误：${error.errorCodeName}: ${error.message}")
            emitError(error.errorCodeName + ": " + error.message, fatal = true)
            emitState("error")
        }
    }

    // ─────────────── libVLC 事件（R-渲3）───────────────

    /** libVLC 状态机：去重缓冲态抖动（Buffering 事件高频且百分比不单调）。 */
    private var vlcState: String = "idle"

    private val vlcLayoutListener = IVLCVout.OnNewVideoLayoutListener { _, width, height, _, _, _, _ ->
        if (width > 0 && height > 0) {
            surfaceProducer?.setSize(width, height)
            emitLog("info", "libVLC 视频轨尺寸=${width}x$height")
            emitVideoSize(width, height)
        }
    }

    private val vlcEventListener = MediaPlayer.EventListener { event ->
        when (event.type) {
            MediaPlayer.Event.Opening -> emitVlcState("opening")
            MediaPlayer.Event.Buffering -> {
                // 起播前缓冲（< 100%）才上报 buffering，避免播放中高频抖动。
                if (event.buffering < 100f) emitVlcState("buffering") else emitVlcState("playing")
            }
            MediaPlayer.Event.Playing -> emitVlcState("playing")
            MediaPlayer.Event.Paused -> emitVlcState("paused")
            MediaPlayer.Event.Stopped -> emitVlcState("idle")
            MediaPlayer.Event.EndReached -> emitVlcState("ended")
            MediaPlayer.Event.EncounteredError -> {
                emitLog("error", "libVLC 播放错误（EncounteredError）")
                emitError("libVLC 播放错误", fatal = true)
                emitVlcState("error")
            }
            MediaPlayer.Event.TimeChanged,
            MediaPlayer.Event.LengthChanged,
            MediaPlayer.Event.Vout -> emitProgress()
            else -> Unit
        }
    }

    // ─────────────── FlutterPlugin ───────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        textureRegistry = binding.textureRegistry
        val c = MethodChannel(binding.binaryMessenger, CHANNEL)
        c.setMethodCallHandler(this)
        channel = c
        val ec = EventChannel(binding.binaryMessenger, EVENTS_CHANNEL)
        ec.setStreamHandler(this)
        eventChannel = ec
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        teardown()
        channel?.setMethodCallHandler(null)
        channel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        textureRegistry = null
        appContext = null
    }

    // ─────────────── MethodChannel ───────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "open" -> open(call, result)
            "play" -> {
                if (currentBackend == "libVLC") vlcPlayer?.play() else exoPlayer?.play()
                result.success(null)
            }
            "pause" -> {
                if (currentBackend == "libVLC") vlcPlayer?.pause() else exoPlayer?.pause()
                result.success(null)
            }
            "seekTo" -> {
                val ms = (call.arguments as Number).toLong()
                if (currentBackend == "libVLC") vlcPlayer?.setTime(ms)
                else exoPlayer?.seekTo(ms)
                result.success(null)
            }
            "setVolume" -> {
                val volume = (call.arguments as Number).toFloat().coerceIn(0f, 1f)
                if (currentBackend == "libVLC") {
                    // libVLC 音量域 0~100。
                    vlcPlayer?.setVolume((volume * 100f).toInt())
                } else {
                    exoPlayer?.volume = volume
                }
                result.success(null)
            }
            "setSpeed" -> {
                val speed = (call.arguments as Number).toFloat().coerceIn(0.25f, 4f)
                if (currentBackend == "libVLC") vlcPlayer?.setRate(speed)
                else exoPlayer?.setPlaybackSpeed(speed)
                result.success(null)
            }
            "dispose" -> {
                teardown()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ─────────────── EventChannel ───────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    // ─────────────── open / 内部 ───────────────

    private fun open(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val url = args?.get("url")?.toString()
        if (url.isNullOrEmpty()) {
            result.error("E_PARAM", "open 缺少 url", null)
            return
        }
        @Suppress("UNCHECKED_CAST")
        val headers = (args["headers"] as? Map<String, String>) ?: emptyMap()
        val backend = args["backend"]?.toString() ?: "media3"
        val isLive = args["isLive"] as? Boolean ?: false
        // 真实文件名 / 标题：网盘 / Node 代理流 URL 无扩展名，能力探测需据此补判。
        val resourceName = args["title"]?.toString()
        emitLog("info", "open 请求：backend=$backend，host=${hostOf(url)}，urlLength=${url.length}")

        // A21.5：复杂封装 / HEVC 无硬解 → libVLC。Dart 主后端仍投 media3 时上报
        // E_BACKEND_UNAVAILABLE，由 PlayerController 降级链改投 libVLC（可观测）。
        val needed = CodecCapability.selectBackend(url, resourceName)
        if (backend == "media3" && needed == PlayerBackend.LIBVLC) {
            emitLog("warn", "媒体需 libVLC 回退（复杂封装 / HEVC 无硬解），改投 libVLC 后端")
            result.error(
                "E_BACKEND_UNAVAILABLE",
                "该媒体需 libVLC 回退（$url），请改投 libVLC 后端",
                null,
            )
            return
        }
        if (backend == "libVLC") {
            openVlc(url, headers, isLive, result)
            return
        }
        if (backend != "media3") {
            result.error("E_BACKEND_UNAVAILABLE", "未知后端：$backend", null)
            return
        }
        openMedia3(url, headers, isLive, result)
    }

    private fun openMedia3(
        url: String,
        headers: Map<String, String>,
        isLive: Boolean,
        result: MethodChannel.Result,
    ) {
        teardown()
        val context = appContext ?: run {
            result.error("E_STATE", "插件未附着引擎", null)
            return
        }
        val registry = textureRegistry ?: run {
            result.error("E_STATE", "纹理注册表不可用", null)
            return
        }

        // 与 openVlc 同口径：Media3/ExoPlayer 构建、纹理创建、prepare 任一环节
        // 抛 JVM 异常都必须收敛为 result.error，否则 result 永不回调 →
        // Dart 侧 await open 永久挂起（表现为播放链卡死/闪退）。
        try {
            val producer = registry.createSurfaceProducer()
            producer.setCallback(surfaceCallback)

            // 对齐 iOS AVPlayer 的网络行为：允许 http↔https 跨协议重定向
            // （源站常见 http→https 跳转，Media3 默认禁止，会直接报建连失败）。
            val dataSourceFactory = DefaultHttpDataSource.Factory()
                .setDefaultRequestProperties(headers)
                .setAllowCrossProtocolRedirects(true)
            val p = ExoPlayer.Builder(context)
                .setMediaSourceFactory(
                    DefaultMediaSourceFactory(context).setDataSourceFactory(dataSourceFactory)
                )
                .build()
            p.setVideoSurface(producer.surface)
            p.setMediaItem(MediaItem.fromUri(Uri.parse(url)))
            p.prepare()
            p.addListener(listener)
            if (isLive) {
                // 直播流：直接起播（无 duration 边界）
                p.play()
            }
            exoPlayer = p
            surfaceProducer = producer
            currentBackend = "media3"
            emitState("opening")
            emitLog("info", "Media3/ExoPlayer 已就绪（textureId=${producer.id()}），等待视频轨")
            handler.post(progressTick)
            // R-渲1：返回纹理句柄（Dart 侧解析为 textureId → Texture(textureId:)）。
            result.success(mapOf("textureId" to producer.id()))
        } catch (t: Throwable) {
            teardown()
            emitLog("error", "Media3 后端初始化失败：${t.message}")
            result.error(
                "E_BACKEND_UNAVAILABLE",
                "Media3 后端初始化失败（$url）：${t.message}",
                null,
            )
        }
    }

    /**
     * R-渲3：libVLC 后端（复杂封装回退）。
     *
     * 输出面沿用 R-渲1 的 [TextureRegistry.SurfaceProducer]：libVLC 直接把画面写进
     * 该 Surface（`IVLCVout.setVideoSurface(surface, null)` + `attachViews`），
     * Dart 侧仍以 `Texture(textureId:)` 承载，无需 PlatformView（UI 层与 iOS 一致）。
     */
    private fun openVlc(
        url: String,
        headers: Map<String, String>,
        isLive: Boolean,
        result: MethodChannel.Result,
    ) {
        teardown()
        val context = appContext ?: run {
            result.error("E_STATE", "插件未附着引擎", null)
            return
        }
        val registry = textureRegistry ?: run {
            result.error("E_STATE", "纹理注册表不可用", null)
            return
        }

        val producer = registry.createSurfaceProducer()
        producer.setCallback(surfaceCallback)

        try {
            val vlc = LibVLC(context, emptyList())
            val mp = MediaPlayer(vlc)
            val vout = mp.vlcVout
            vout.setVideoSurface(producer.surface, null)
            vout.attachViews(vlcLayoutListener)

            val media = Media(vlc, Uri.parse(url))
            applyHeaders(media, headers)
            mp.media = media

            mp.setEventListener(vlcEventListener)

            libVlc = vlc
            vlcPlayer = mp
            vlcVout = vout
            vlcMedia = media
            surfaceProducer = producer
            currentBackend = "libVLC"
            vlcState = "opening"

            // 与 Windows libmpv 同口径：直播直接起播，点播起播后即暂停待 Dart play()，
            // 使媒体管线完成解析（时长/视频轨就绪）而不抢跑画面。
            mp.play()
            if (!isLive) mp.pause()

            emitState("opening")
            emitLog("info", "libVLC 已就绪（textureId=${producer.id()}），等待视频轨")
            handler.post(progressTick)
            result.success(mapOf("textureId" to producer.id()))
        } catch (t: Throwable) {
            teardown()
            emitLog("error", "libVLC 后端初始化失败：${t.message}")
            result.error(
                "E_BACKEND_UNAVAILABLE",
                "libVLC 后端初始化失败（$url）：${t.message}",
                null,
            )
        }
    }

    /** 请求头 → libVLC media 选项（libVLC 仅支持 Referer / User-Agent 两类透传）。 */
    private fun applyHeaders(media: Media, headers: Map<String, String>) {
        for ((key, value) in headers) {
            when (key.lowercase()) {
                "referer", "referrer" -> media.addOption(":http-referrer=$value")
                "user-agent" -> media.addOption(":http-user-agent=$value")
                else -> Unit
            }
        }
    }

    /** Flutter 输出面重建后重新绑定 libVLC 画面（切后台回前台）。 */
    private fun rebindVlcSurface() {
        val vout = vlcVout ?: return
        val surface = surfaceProducer?.surface ?: return
        try {
            vout.detachViews()
            vout.setVideoSurface(surface, null)
            vout.attachViews(vlcLayoutListener)
        } catch (_: Throwable) {
            // 输出面尚未就绪（Surface 无效）→ 等下一次 onSurfaceAvailable。
        }
    }

    private fun teardown() {
        handler.removeCallbacks(progressTick)
        // Media3
        exoPlayer?.removeListener(listener)
        exoPlayer?.setVideoSurface(null)
        exoPlayer?.release()
        exoPlayer = null
        // libVLC（先解绑输出面，再释放播放器，最后释放 LibVLC 实例）
        vlcPlayer?.setEventListener(null)
        try {
            vlcVout?.detachViews()
        } catch (_: Throwable) {
            // 输出面未绑定 → 忽略
        }
        vlcPlayer?.release()
        vlcPlayer = null
        vlcVout = null
        vlcMedia?.release()
        vlcMedia = null
        libVlc?.release()
        libVlc = null
        vlcState = "idle"
        // 输出面
        surfaceProducer?.release()
        surfaceProducer = null
        currentBackend = null
    }

    private fun emitState(value: String) {
        sink?.success(mapOf("type" to "state", "value" to value))
    }

    /** libVLC 状态去重上报（Buffering/Playing 高频事件不重复扰动 Dart 状态机）。 */
    private fun emitVlcState(value: String) {
        if (vlcState == value) return
        vlcState = value
        emitState(value)
    }

    private fun emitProgress() {
        if (currentBackend == "libVLC") {
            val p = vlcPlayer ?: return
            val position = p.time
            val duration = p.length
            sink?.success(
                mapOf(
                    "type" to "progress",
                    "positionMs" to position,
                    "durationMs" to if (duration > 0) duration else 0L,
                    "bufferedMs" to position,
                    "isLive" to (duration <= 0),
                ),
            )
            return
        }
        val p = exoPlayer ?: return
        val duration = p.duration
        sink?.success(
            mapOf(
                "type" to "progress",
                "positionMs" to p.currentPosition,
                "durationMs" to if (duration == C.TIME_UNSET) 0L else duration,
                "bufferedMs" to p.bufferedPosition,
                "isLive" to (duration == C.TIME_UNSET),
            ),
        )
    }

    private fun emitVideoSize(width: Int, height: Int) {
        sink?.success(
            mapOf("type" to "videoSize", "width" to width, "height" to height),
        )
    }

    private fun emitError(message: String, fatal: Boolean) {
        sink?.success(mapOf("type" to "error", "message" to message, "fatal" to fatal))
    }

    /**
     * 播放日志上报（对齐 Windows / macOS 的 `log` 事件）。
     *
     * Dart 侧 `ChannelPlayer` 收到后统一转入 `AppLog`（category=player），
     * 使三端日志详细度一致，便于排查「有声音无画面」这类问题。
     */
    private fun emitLog(level: String, message: String) {
        sink?.success(mapOf("type" to "log", "level" to level, "message" to message))
    }

    /** 从播放直链提取 host（仅用于日志，避免把签名参数写进日志）。 */
    private fun hostOf(url: String): String {
        val scheme = url.indexOf("://")
        val rest = if (scheme >= 0) url.substring(scheme + 3) else url
        val slash = rest.indexOf('/')
        return if (slash >= 0) rest.substring(0, slash) else rest
    }

    companion object {
        private const val CHANNEL = "com.vbox.player/player"
        private const val EVENTS_CHANNEL = "com.vbox.player/player/events"

        /** 供 [MainActivity.configureFlutterEngine] 手动注册（非插件工程无 registrant）。 */
        @JvmStatic
        fun registerWith(engine: FlutterEngine) {
            engine.plugins.add(PlayerPlugin())
        }
    }
}
