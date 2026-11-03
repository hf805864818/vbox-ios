package com.vbox.player.player

import android.content.Intent
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/**
 * 前台媒体播放服务（G-02-C：后台 / 锁屏播放承载）。
 *
 * 对齐能力矩阵「后台音频 | ForegroundService | 前台服务+通知」：
 *  - Media3 `MediaSessionService` 宿主，自持 [ExoPlayer] 与 [MediaSession]；
 *  - manifest 声明 `foregroundServiceType="mediaPlayback"` + 媒体通知；
 *  - 控制走标准 Media3 `MediaSession.Controller`（play/pause/seek...），
 *    通知样式与真机端到端行为归 G-09 验收批次；
 *  - `onTaskRemoved`：用户划掉最近任务时，非播放态自停（防后台驻留）。
 */
class MediaPlaybackService : MediaSessionService() {

    private var exoPlayer: ExoPlayer? = null
    private var mediaSession: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        val p = ExoPlayer.Builder(this)
            .setMediaSourceFactory(
                DefaultMediaSourceFactory(this)
                    .setDataSourceFactory(DefaultHttpDataSource.Factory())
            )
            .build()
        exoPlayer = p
        mediaSession = MediaSession.Builder(this, p).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
        mediaSession

    override fun onTaskRemoved(rootIntent: Intent?) {
        val p = exoPlayer
        if (p == null || !p.playWhenReady || p.playbackState == Player.STATE_IDLE) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        mediaSession?.run {
            player.release()
            release()
        }
        mediaSession = null
        exoPlayer = null
        super.onDestroy()
    }
}
