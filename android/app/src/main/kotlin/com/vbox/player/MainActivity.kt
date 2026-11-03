package com.vbox.player

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 批次 Q · Q-02：预加载 JSC 引擎模块（libvbox_jsc.so，DT_NEEDED→libjsc.so）。
        // 必须先于 Dart 侧 DynamicLibrary.open 触发（本回调先于 Dart 入口执行）。
        // 失败不 crash：Dart 侧 jsc_ffi 的 isAvailable=false，
        // 工厂按 D6 自动降级 QuickJS（降级可观测）。
        try {
            System.loadLibrary("vbox_jsc")
        } catch (e: UnsatisfiedLinkError) {
            Log.w("vbox", "libvbox_jsc 加载失败，JSC 将按 D6 降级 QuickJS: ${e.message}")
        }
        // G-02-A：注册播放器平台通道（Media3 主后端 + 事件流）
        PlayerPlugin.registerWith(flutterEngine)
        // G-02-C：注册系统信息平台通道（UiMode 三重判定）
        SystemPlugin.registerWith(flutterEngine)
        // 批次 D · D1：注册屏幕亮度/系统音量通道（窗口级亮度 + AudioManager STREAM_MUSIC）
        flutterEngine.plugins.add(ScreenControlsPlugin())
        // 批次 D · D2：注册应用内浮窗通道（截图快照承载 + 单击/双击/拖动手势回传）
        flutterEngine.plugins.add(FloatingWindowPlugin())
        // 批次 D · D3：注册音乐锁屏媒体会话通道（framework MediaSession 元数据/命令回传）
        MusicMediaSessionPlugin.registerWith(flutterEngine)
        // C-10：注册 Go 代理平台通道（经 engine.plugins.add 走 FlutterPlugin 生命周期；
        // 遗漏核查修复——C-10 交付插件文件但未在 MainActivity 接线）
        GoProxyPlugin.registerWith(flutterEngine)
        // C-05：注册系统画中画平台通道（ActivityAware，需 plugins.add 挂 Activity 生命周期）
        flutterEngine.plugins.add(PipPlugin())
        // C-05：注册后台播放平台通道（启动/停止前台媒体服务）
        BackgroundPlayPlugin.registerWith(flutterEngine)
        // 批次 E · E1-1：注册下载「保存到相册」通道（MediaExtractor+MediaMuxer
        // 转封装 + MediaStore 入库，Movies/VBox）
        flutterEngine.plugins.add(GallerySavePlugin())
        // E-04：注册直播本地文件导入/导出/分享通道（ActivityAware，需 plugins.add 挂 Activity 生命周期）
        flutterEngine.plugins.add(LiveFilePlugin())
        // K-01：注册自更新安装通道（ActivityAware，需 Activity 拉起系统安装器）
        flutterEngine.plugins.add(UpdatePlugin())
        // Wave G · RT-运1：注册 Python 运行时通道（Chaquopy 进程内解释器，
        // 供 Dart PythonBridgeEngine 在 Android 运行 `y_*` Python 蜘蛛脚本）
        PythonPlugin.registerWith(flutterEngine)
        // 批次 I · ND-01：注册 Node 常驻系统宿主通道（nodejs-mobile 进程内引擎，
        // 供 Dart NodeRuntimeManager 拉起 Node 宿主；未集成 AAR 时回 E_NODE_UNAVAILABLE 降级）
        NodePlugin.registerWith(flutterEngine)
    }
}
