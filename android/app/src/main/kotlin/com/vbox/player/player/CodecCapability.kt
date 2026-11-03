package com.vbox.player.player

import android.media.MediaCodecInfo
import android.media.MediaCodecList

/**
 * 编解码能力探测（方案 A21.5 落地）。
 *
 * `selectBackend(url, resourceName)`：复杂封装（MKV 等）/ HEVC 无硬解 → libVLC
 * 回退，否则走 Media3（ExoPlayer）。纯 JVM 实现，无 NDK / 平台绑定。
 *
 * [resourceName] 为真实文件名 / 标题（网盘 / Node 代理流 URL 无扩展名时用于补判
 * 封装与编码，避免 4K HEVC MKV 被误投 Media3 → open 成功但解码失败）。
 */
object CodecCapability {

    fun supportsHevcHardware(): Boolean {
        val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        return list.codecInfos.any { info ->
            !info.isEncoder && info.supportedTypes.any { it.equals("video/hevc", true) }
        }
    }

    fun selectBackend(url: String, resourceName: String? = null): PlayerBackend {
        // 真实文件名优先（无扩展名代理 URL 只能靠它判定封装 / 编码）。
        val name = (resourceName ?: "").lowercase()
        val ext = url.substringAfterLast('.', "").lowercase()
        val hevc = isHevc(url) || isHevc(name)
        return when {
            ext == "mkv" || name.contains(".mkv") -> PlayerBackend.LIBVLC // MKV 保守走 VLC
            hevc && !supportsHevcHardware() -> PlayerBackend.LIBVLC // 无硬解
            else -> PlayerBackend.MEDIA3
        }
    }

    private fun isHevc(text: String) =
        text.contains("hevc", true) || text.contains("h265", true) ||
            text.contains("x265", true)
}

/** 播放器后端（Android 侧，与 Dart `PlayerBackend` 的 media3 / libVLC 对齐）。 */
enum class PlayerBackend { MEDIA3, LIBVLC }
