package com.vbox.player

import android.annotation.SuppressLint
import android.content.ContentValues
import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.util.UUID

/**
 * 批次 E · E1-1：下载完成行「保存到相册」原生通道。
 *
 * 对齐 iOS `DownloadOverlayViews.swift` performSaveToPhotos / convertAndSaveToPhotos：
 *  - mp4/mov/m4v 直接入库；其余（如 .ts）先 `MediaExtractor`+`MediaMuxer`
 *    转封装（copy 编码不转码，对齐 iOS `AVAssetExportPresetPassthrough`）；
 *  - 入库走 MediaStore（API 29+ 免权限；API 24-28 需 WRITE_EXTERNAL_STORAGE，
 *    无权限时返回 `PERMISSION_DENIED`，Dart 层提示，登记不做运行时弹窗申请）；
 *  - 失败语义：Dart 层 toast「视频转换失败」（对齐 iOS L689/L706）。
 */
class GallerySavePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var applicationContext: Context? = null
    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        applicationContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "save" -> {
                val path = call.argument<String>("path")
                val name = call.argument<String>("name")
                if (path.isNullOrEmpty()) {
                    result.error("EINVAL", "path is required", null)
                    return
                }
                // remux + IO 在后台线程执行，结果回主线程。
                Thread {
                    try {
                        val saved = saveToGallery(path, name ?: File(path).name)
                        mainHandler.post { result.success(saved) }
                    } catch (e: SecurityException) {
                        mainHandler.post { result.error("PERMISSION_DENIED", e.message, null) }
                    } catch (e: Exception) {
                        mainHandler.post { result.error("SAVE_FAILED", e.message, null) }
                    }
                }.start()
            }
            else -> result.notImplemented()
        }
    }

    /// 保存入口：非 mp4 系先转封装，再插入媒体库。
    @SuppressLint("SdCardPath")
    private fun saveToGallery(srcPath: String, displayName: String): String {
        val ctx = applicationContext ?: throw IOException("context unavailable")
        val ext = srcPath.substringAfterLast('.', "").lowercase()
        val needsRemux = ext != "mp4" && ext != "mov" && ext != "m4v"
        var tempMp4: File? = null
        var finalPath = srcPath
        try {
            if (needsRemux) {
                tempMp4 = File(ctx.cacheDir, "vbox_export_${UUID.randomUUID()}.mp4")
                remuxToMp4(srcPath, tempMp4)
                finalPath = tempMp4.absolutePath
            }
            return insertToGallery(ctx, finalPath, displayName)
        } finally {
            tempMp4?.delete()
        }
    }

    /// TS → MP4 转封装（copy 编码，对齐 iOS Passthrough）。
    private fun remuxToMp4(src: String, dst: File) {
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            extractor.setDataSource(src)
            var videoTrack = -1
            var audioTrack = -1
            var videoFormat: MediaFormat? = null
            var audioFormat: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/") && videoTrack < 0) {
                    videoTrack = i; videoFormat = f
                } else if (mime.startsWith("audio/") && audioTrack < 0) {
                    audioTrack = i; audioFormat = f
                }
            }
            if (videoTrack < 0) throw IllegalStateException("no video track")
            muxer = MediaMuxer(dst.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val muxVideo = muxer.addTrack(videoFormat!!)
            val muxAudio = if (audioTrack >= 0) muxer.addTrack(audioFormat!!) else -1
            muxer.start()
            val buffer = ByteBuffer.allocate(1024 * 1024)
            val info = MediaCodec.BufferInfo()
            if (videoTrack >= 0) writeTrack(extractor, muxer, muxVideo, buffer, info, videoTrack)
            if (audioTrack >= 0) writeTrack(extractor, muxer, muxAudio, buffer, info, audioTrack)
        } finally {
            try { muxer?.stop() } catch (_: Exception) {}
            try { muxer?.release() } catch (_: Exception) {}
            try { extractor.release() } catch (_: Exception) {}
        }
    }

    /// 单轨道拷贝（对齐 sampleFlags/sampleTime 直通）。
    private fun writeTrack(
        extractor: MediaExtractor,
        muxer: MediaMuxer,
        muxTrack: Int,
        buffer: ByteBuffer,
        info: MediaCodec.BufferInfo,
        trackIndex: Int,
    ) {
        extractor.selectTrack(trackIndex)
        while (true) {
            val size = extractor.readSampleData(buffer, 0)
            if (size < 0) break
            info.offset = 0
            info.size = size
            info.presentationTimeUs = extractor.sampleTime
            info.flags = extractor.sampleFlags
            muxer.writeSampleData(muxTrack, buffer, info)
            extractor.advance()
        }
        extractor.unselectTrack(trackIndex)
    }

    /// 插入媒体库：API 29+ MediaStore 免权限；24-28 公共目录 + 扫描（需写权限）。
    private fun insertToGallery(ctx: Context, srcPath: String, displayName: String): String {
        val safeName = displayName.substringBeforeLast('.') + ".mp4"
        return if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, safeName)
                put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                put(MediaStore.Video.Media.RELATIVE_PATH,
                    Environment.DIRECTORY_MOVIES + "/" + GALLERY_DIR)
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
            val resolver = ctx.contentResolver
            val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IOException("MediaStore insert failed")
            try {
                resolver.openOutputStream(uri)?.use { out ->
                    File(srcPath).inputStream().use { it.copyTo(out) }
                } ?: throw IOException("openOutputStream failed")
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
            resolver.update(
                uri,
                ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) },
                null, null,
            )
            uri.toString()
        } else {
            val dir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES),
                GALLERY_DIR,
            )
            if (!dir.exists() && !dir.mkdirs()) throw IOException("mkdirs failed")
            val dst = File(dir, safeName)
            File(srcPath).copyTo(dst, overwrite = true)
            MediaScannerConnection.scanFile(ctx, arrayOf(dst.absolutePath), arrayOf("video/mp4"), null)
            dst.absolutePath
        }
    }

    companion object {
        /// 通道名。
        const val CHANNEL = "com.vbox.player/gallery_save"

        /// 相册子目录（Movies/VBox）。
        const val GALLERY_DIR = "VBox"
    }
}
