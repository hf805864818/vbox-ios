package com.vbox.player

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 音乐锁屏媒体会话平台通道（批次 D · D3 —— Android/TV 腿）。
 *
 * 对齐 iOS `AudioPlayerManager`（AudioPlayerManager.swift:517-583）：
 *  - `updateNowPlayingInfo` → `MediaSession.setMetadata`（title/artist/album/
 *    duration/artwork URI）+ `setPlaybackState`（rate 1.0/0.0 + 进度）；
 *  - `MPRemoteCommandCenter` 六命令 → `MediaSession.Callback`
 *    （onPlay/onPause/onSkipToNext/onSkipToPrevious/onSeekTo）→ EventChannel
 *    回派 Dart `_handleMediaCommand`（分派逻辑已在 `MusicPlayerController` 就绪）。
 *
 * MethodChannel `com.vbox.player/music_media`：
 *  - `update`（title/artist/album/coverURL/durationMs/playing/positionMs）
 *  - `clear`（release 会话，对齐 iOS 停止清理 `nowPlayingInfo = nil`）
 *
 * EventChannel `com.vbox.player/music_media/events`：`{command: play|pause|toggle|
 * next|previous|seek, positionMs?}`。
 *
 * 会话生命周期口径：framework `MediaSession` 直挂 application context（骨架接线，
 * 真机锁屏面板展示依赖前台媒体服务——随音乐音频引擎真机批次收口，登记）。
 */
class MusicMediaSessionPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private var appContext: Context? = null
    private var session: MediaSession? = null
    private var sink: EventChannel.EventSink? = null

    // ─────────────── FlutterPlugin ───────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        val c = MethodChannel(binding.binaryMessenger, CHANNEL)
        c.setMethodCallHandler(this)
        val ec = EventChannel(binding.binaryMessenger, EVENTS_CHANNEL)
        ec.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        releaseSession()
        sink = null
    }

    // ─────────────── EventChannel ───────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        ensureSession()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    // ─────────────── MethodChannel ───────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "update" -> {
                update(call.arguments as? Map<*, *>)
                result.success(null)
            }
            "clear" -> {
                releaseSession()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun ensureSession(): MediaSession? {
        session?.let { return it }
        val ctx = appContext ?: return null
        val s = try {
            MediaSession(ctx, "vbox_music")
        } catch (e: Exception) {
            return null
        }
        s.setPlaybackToLocal(AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build())
        s.setCallback(object : MediaSession.Callback() {
            override fun onPlay() = emit("play")
            override fun onPause() = emit("pause")
            override fun onSkipToNext() = emit("next")
            override fun onSkipToPrevious() = emit("previous")
            override fun onSeekTo(pos: Long) {
                sink?.success(mapOf("command" to "seek", "positionMs" to pos))
            }
        })
        s.isActive = true
        session = s
        return s
    }

    private fun update(args: Map<*, *>?) {
        val s = ensureSession() ?: return
        val title = args?.get("title")?.toString() ?: ""
        val artist = args?.get("artist")?.toString() ?: ""
        val album = args?.get("album")?.toString()
        val coverUrl = args?.get("coverURL")?.toString()
        val durationMs = (args?.get("durationMs") as? Number)?.toLong() ?: 0L
        val playing = args?.get("playing") as? Boolean ?: false
        val positionMs = (args?.get("positionMs") as? Number)?.toLong() ?: 0L

        val md = MediaMetadata.Builder().apply {
            putString(MediaMetadata.METADATA_KEY_TITLE, title)
            putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
            if (!album.isNullOrEmpty()) {
                putString(MediaMetadata.METADATA_KEY_ALBUM, album)
            }
            if (!coverUrl.isNullOrEmpty()) {
                putString(MediaMetadata.METADATA_KEY_ART_URI, coverUrl)
            }
            putLong(MediaMetadata.METADATA_KEY_DURATION, durationMs)
        }.build()
        s.setMetadata(md)

        val state = PlaybackState.Builder()
            .setActions(
                PlaybackState.ACTION_PLAY or
                    PlaybackState.ACTION_PAUSE or
                    PlaybackState.ACTION_PLAY_PAUSE or
                    PlaybackState.ACTION_SKIP_TO_NEXT or
                    PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                    PlaybackState.ACTION_SEEK_TO,
            )
            .setState(
                if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                positionMs,
                if (playing) 1.0f else 0f,
            )
            .build()
        s.setPlaybackState(state)
    }

    private fun releaseSession() {
        session?.release()
        session = null
    }

    private fun emit(command: String) {
        sink?.success(mapOf("command" to command))
    }

    companion object {
        private const val CHANNEL = "com.vbox.player/music_media"
        private const val EVENTS_CHANNEL = "com.vbox.player/music_media/events"

        /** 供 [MainActivity.configureFlutterEngine] 手动注册（非插件工程无 registrant）。 */
        @JvmStatic
        fun registerWith(engine: FlutterEngine) {
            engine.plugins.add(MusicMediaSessionPlugin())
        }
    }
}
