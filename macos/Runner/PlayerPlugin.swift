//
//  PlayerPlugin.swift
//  Runner
//
//  macOS 播放器插件（AVPlayer 主后端 + Wave G · R-渲3 libmpv 复杂封装回退后端）。
//
//  对齐契约 §2.5 播放器能力矩阵 + A21.5 回退策略 + iOS `PlayerEngine` 协议（type/state/event）：
//    · MethodChannel `com.vbox.player/player`：open / play / pause / seekTo / setVolume / setSpeed / dispose
//    · EventChannel `com.vbox.player/player/events`：state / progress / videoSize / error
//  与 Android `PlayerPlugin.kt` / Windows `player_plugin.cpp` 共用同一 wire 协议
//  （Dart `ChannelPlayer._onEvent` 解析面）。
//
//  后端口径：
//    · 常规封装（mp4 / m3u8 / flv 软解 …）→ AVPlayer（主后端，原生硬解 / VideoToolbox）；
//    · 复杂封装（MKV / FLV / TS / RMVB / AVI / WMV / M2TS）→ libmpv 回退（R-渲3），
//      对齐 Android「复杂封装投 libVLC」口径；libmpv 不可用（D28 分发缺失）时上报
//      `E_BACKEND_UNAVAILABLE` 由 Dart `PlayerController` 处理。
//
//  libmpv 运行时（D28）：`libmpv.dylib` + 同组依赖 dylib 随 App `Contents/Frameworks`
//  分发（CI `build-release-assets.yml` 注入），运行期 `dlopen` 动态解析符号，构建期
//  不依赖第三方导入库（对齐 Windows `player_plugin.cpp` 的 `LoadLibraryW` 模式，故
//  无需改 Xcode 链接配置）。
//
//  渲染口径（R-渲1）：`vo=libmpv` + `gpu-api=opengl` + `mpv_render_context`
//  （`MPV_RENDER_API_TYPE_OPENGL`）：mpv 在 GPU 上跑完整色彩管线
//  （primaries / gamma / HDR tone-mapping，对齐 iOS）渲染到离屏 FBO，再 `glReadPixels`
//  回读 BGRA 装入 `CVPixelBuffer` 经 FlutterTexture 上屏；`open` 返回 `textureId`
//  交 Dart `Texture(textureId:)` 承载（UI 层与 iOS 一致，无 PlatformView）。
//

import AVFoundation
import AppKit
import CoreVideo
import Darwin
import FlutterMacOS
import Foundation
import QuartzCore

// ═══════════════ Wave G · R-渲3：libmpv C ABI（dlopen/dlsym 运行期解析）═══════════════
//
// `libmpv/client.h` / `render.h` 未随仓库分发（macOS Runner 无桥接头），此处按 mpv ABI
// 在 Swift 侧等值声明本插件用到的结构 / 枚举 / 函数指针子集；布局与官方头一一对应，
// 不得改动。枚举值见 mpv 官方 client.h / render.h。

private let mpvFormatFlag: Int32 = 3      // MPV_FORMAT_FLAG
private let mpvFormatInt64: Int32 = 4     // MPV_FORMAT_INT64
private let mpvFormatDouble: Int32 = 5    // MPV_FORMAT_DOUBLE

private let mpvEventShutdown: Int32 = 1
private let mpvEventLogMessage: Int32 = 2
private let mpvEventStartFile: Int32 = 6
private let mpvEventEndFile: Int32 = 7
private let mpvEventFileLoaded: Int32 = 8
private let mpvEventPlaybackRestart: Int32 = 21
private let mpvEventPropertyChange: Int32 = 22

private let mpvEndFileReasonEOF: Int32 = 0
private let mpvEndFileReasonError: Int32 = 4

private let mpvRenderParamAPIType: Int32 = 1
private let mpvRenderParamOpenGLInitParams: Int32 = 2
private let mpvRenderParamOpenGLFbo: Int32 = 3
private let mpvRenderParamFlipY: Int32 = 4
private let mpvRenderParamAdvancedControl: Int32 = 10
// 软件渲染（MPV_RENDER_API_TYPE_SW）参数：OpenGL 不可用时的兜底后端。
private let mpvRenderParamSwSize: Int32 = 17
private let mpvRenderParamSwFormat: Int32 = 18
private let mpvRenderParamSwStride: Int32 = 19
private let mpvRenderParamSwPointer: Int32 = 20
private let mpvRenderParamInvalid: Int32 = 0

/// mpv C 句柄（`mpv_handle*`）。
private typealias MpvHandle = OpaquePointer
/// mpv render C 句柄（`mpv_render_context*`）。
private typealias MpvRenderContext = OpaquePointer

/// `mpv_event`（client.h）。
private struct MpvEvent {
  var eventID: Int32
  var error: Int32
  var replyUserdata: UInt64
  var data: UnsafeMutableRawPointer?
}

/// `mpv_event_property`（client.h）。
private struct MpvEventProperty {
  var name: UnsafePointer<CChar>?
  var format: Int32
  var data: UnsafeMutableRawPointer?
}

/// `mpv_event_end_file`（client.h）。
private struct MpvEventEndFile {
  var reason: Int32
  var error: Int32
  var playlistEntryID: Int64
  var playlistInsertID: Int64
  var playlistInsertNumEntries: Int32
}

/// `mpv_event_log_message`（client.h）：mpv 内部日志（对齐 Windows 详细度）。
private struct MpvEventLogMessage {
  var prefix: UnsafePointer<CChar>?
  var level: UnsafePointer<CChar>?
  var text: UnsafePointer<CChar>?
  var logLevel: Int32
}

/// `mpv_render_param`（render.h）。
private struct MpvRenderParam {
  var type: Int32
  var data: UnsafeMutableRawPointer?
}

// ── OpenGL(GPU) render context ABI（render_gl.h；问题 5 桌面色彩管理对齐 iOS）──

/// `mpv_opengl_init_params`（render_gl.h）。
private typealias MpvGetProcAddressFn =
  @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?

private struct MpvOpenGLInitParams {
  var getProcAddress: MpvGetProcAddressFn?
  var getProcAddressCtx: UnsafeMutableRawPointer?
}

/// `mpv_opengl_fbo`（render_gl.h）。
private struct MpvOpenGLFbo {
  var fbo: Int32
  var width: Int32
  var height: Int32
  var internalFormat: Int32
}

// OpenGL 常量（gl.h / gl3.h 子集）。
private let glTexture2D: UInt32 = 0x0DE1
private let glTextureMinFilter: UInt32 = 0x2801
private let glTextureMagFilter: UInt32 = 0x2800
private let glLinear: Int32 = 0x2601
private let glRgba8: Int32 = 0x8058
private let glRgba: UInt32 = 0x1908
private let glUnsignedByte: UInt32 = 0x1401
private let glFramebuffer: UInt32 = 0x8D40
private let glColorAttachment0: UInt32 = 0x8CE0
private let glFramebufferComplete: UInt32 = 0x8CD5
private let glBgra: UInt32 = 0x80E1
private let glPackAlignment: UInt32 = 0x0D05

// OpenGL 入口函数指针（dlsym 运行期解析；构建期不链接 OpenGL.framework）。
private typealias FnGlReadPixels =
  @convention(c) (Int32, Int32, Int32, Int32, UInt32, UInt32, UnsafeMutableRawPointer?) -> Void
private typealias FnGlPixelStorei = @convention(c) (UInt32, Int32) -> Void
private typealias FnGlGenFramebuffers =
  @convention(c) (Int32, UnsafeMutablePointer<UInt32>?) -> Void
private typealias FnGlBindFramebuffer = @convention(c) (UInt32, UInt32) -> Void
private typealias FnGlFramebufferTexture2D =
  @convention(c) (UInt32, UInt32, UInt32, UInt32, Int32) -> Void
private typealias FnGlCheckFramebufferStatus = @convention(c) (UInt32) -> UInt32
private typealias FnGlDeleteFramebuffers =
  @convention(c) (Int32, UnsafePointer<UInt32>?) -> Void
private typealias FnGlGenTextures = @convention(c) (Int32, UnsafeMutablePointer<UInt32>?) -> Void
private typealias FnGlBindTexture = @convention(c) (UInt32, UInt32) -> Void
private typealias FnGlTexImage2D =
  @convention(c) (UInt32, Int32, Int32, Int32, Int32, Int32, UInt32, UInt32, UnsafeRawPointer?) -> Void
private typealias FnGlTexParameteri = @convention(c) (UInt32, UInt32, Int32) -> Void
private typealias FnGlDeleteTextures = @convention(c) (Int32, UnsafePointer<UInt32>?) -> Void

/// OpenGL 运行期符号表（`dlopen` + `dlsym` 解析）。
private struct MacGlApi {
  var readPixels: FnGlReadPixels?
  var pixelStorei: FnGlPixelStorei?
  var genFramebuffers: FnGlGenFramebuffers?
  var bindFramebuffer: FnGlBindFramebuffer?
  var framebufferTexture2D: FnGlFramebufferTexture2D?
  var checkFramebufferStatus: FnGlCheckFramebufferStatus?
  var deleteFramebuffers: FnGlDeleteFramebuffers?
  var genTextures: FnGlGenTextures?
  var bindTexture: FnGlBindTexture?
  var texImage2D: FnGlTexImage2D?
  var texParameteri: FnGlTexParameteri?
  var deleteTextures: FnGlDeleteTextures?
}

/// mpv OpenGL render context 的 `get_proc_address` 回调（`RTLD_DEFAULT` = -2）。
private func mpvGlGetProcAddress(
  _ ctx: UnsafeMutableRawPointer?,
  _ name: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
  guard let name = name else { return nil }
  return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
}

// libmpv C API 函数指针签名（与官方头一一对应；仅收录本插件用到的符号）。
private typealias FnMpvCreate = @convention(c) () -> MpvHandle?
private typealias FnMpvInitialize = @convention(c) (MpvHandle?) -> Int32
private typealias FnMpvTerminateDestroy = @convention(c) (MpvHandle?) -> Void
private typealias FnMpvCommand =
  @convention(c) (MpvHandle?, UnsafePointer<UnsafePointer<CChar>?>?) -> Int32
private typealias FnMpvSetOptionString =
  @convention(c) (MpvHandle?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
private typealias FnMpvSetProperty =
  @convention(c) (MpvHandle?, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?) -> Int32
private typealias FnMpvGetProperty = FnMpvSetProperty
private typealias FnMpvObserveProperty =
  @convention(c) (MpvHandle?, UInt64, UnsafePointer<CChar>?, Int32) -> Int32
// `@convention(c)` 只接受 C 可表示类型：Swift 自定义 struct（`MpvEvent` / `MpvRenderParam`）
// 作指针 pointee 会被判定为 "not representable in Objective-C" 而编译失败，故此处统一以
// `UnsafeMutableRawPointer?` 承载，调用点再用 `assumingMemoryBound` / 数组缓冲指针还原。
private typealias FnMpvWaitEvent =
  @convention(c) (MpvHandle?, Double) -> UnsafeMutableRawPointer?
private typealias FnMpvErrorString = @convention(c) (Int32) -> UnsafePointer<CChar>?
private typealias FnMpvRequestLogMessages =
  @convention(c) (MpvHandle?, UnsafePointer<CChar>?) -> Int32
private typealias FnMpvRenderCreate =
  @convention(c) (UnsafeMutableRawPointer?, MpvHandle?, UnsafeMutableRawPointer?) -> Int32
private typealias FnMpvRender =
  @convention(c) (MpvRenderContext?, UnsafeMutableRawPointer?) -> Int32
private typealias FnMpvRenderSetUpdate =
  @convention(c) (MpvRenderContext?, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?,
                  UnsafeMutableRawPointer?) -> Void
private typealias FnMpvRenderUpdate = @convention(c) (MpvRenderContext?) -> UInt64
private typealias FnMpvRenderFree = @convention(c) (MpvRenderContext?) -> Void

/// libmpv 运行期符号表（`dlopen` + `dlsym` 解析；缺失符号 → 相应能力为空）。
private struct MpvApi {
  var create: FnMpvCreate?
  var initialize: FnMpvInitialize?
  var terminateDestroy: FnMpvTerminateDestroy?
  var command: FnMpvCommand?
  var setOptionString: FnMpvSetOptionString?
  var setProperty: FnMpvSetProperty?
  var getProperty: FnMpvGetProperty?
  var observeProperty: FnMpvObserveProperty?
  var waitEvent: FnMpvWaitEvent?
  var errorString: FnMpvErrorString?
  // 日志面（可选：旧 dylib 缺失时为空，仅少了 mpv 内部日志上抛）。
  var requestLogMessages: FnMpvRequestLogMessages?
  // render API（R-渲1；可选增强：旧 dylib 缺失时为 nil → 无纹理输出，控制面仍可用）。
  var renderCreate: FnMpvRenderCreate?
  var render: FnMpvRender?
  var renderSetUpdate: FnMpvRenderSetUpdate?
  var renderUpdate: FnMpvRenderUpdate?
  var renderFree: FnMpvRenderFree?
}

/// render 更新回调（C 函数指针；`ctx` 为 `Unmanaged<PlayerPlugin>` 的 opaque 指针）。
private func mpvRenderUpdateCallback(_ ctx: UnsafeMutableRawPointer?) {
  guard let ctx = ctx else { return }
  let plugin = Unmanaged<PlayerPlugin>.fromOpaque(ctx).takeUnretainedValue()
  plugin.mpvRenderWake.signal()
}

@objc
public class PlayerPlugin: NSObject, FlutterPlugin {

  // MARK: - 通道与状态

  private var player: AVPlayer?
  private var timeObserver: Any?
  private var itemObservers: [NSKeyValueObservation] = []
  private var endTimeObserver: NSObjectProtocol?
  private var eventSink: FlutterEventSink?

  // MARK: - R-渲1：视频纹理输出面

  /// Flutter 纹理注册表（open 注册 texture、dispose 注销）。
  private var textureRegistry: FlutterTextureRegistry?
  /// 当前输出面纹理句柄（随 open 返回给 Dart）。
  private var textureId: Int64?
  /// AVPlayer 像素输出面（BGRA），供 FlutterTexture.copyPixelBuffer 取帧。
  private var videoOutput: AVPlayerItemVideoOutput?
  /// 取帧轮询定时器（约 60Hz）。
  private var frameTimer: Timer?
  /// 最近一帧（等待 Flutter 采样；跨线程，加锁）。
  private var latestPixelBuffer: CVPixelBuffer?
  private let pixelBufferLock = NSLock()

  // MARK: - Wave G · R-渲3：libmpv 回退后端状态

  /// libmpv 符号表（首次回退 open 时 dlopen 解析，进程内复用）。
  private var mpvApi: MpvApi?
  private var mpvHandle: MpvHandle?
  private var mpvRenderContext: MpvRenderContext?
  /// 当前是否由 libmpv 承载（play/pause/… 分派依据）。
  private var mpvActive = false
  /// libmpv 纹理句柄（render API 可用时才有值）。
  private var mpvTextureId: Int64?
  /// 事件 / 渲染线程运行标志。
  private var mpvRunning = false
  private var mpvRenderRunning = false
  /// 线程退出信号（shutdown 时等待退出，避免释放期仍在使用句柄）。
  private let mpvEventExited = DispatchSemaphore(value: 0)
  private let mpvRenderExited = DispatchSemaphore(value: 0)
  /// 渲染唤醒信号（mpv render update 回调 / 100ms 超时轮询）。
  fileprivate let mpvRenderWake = DispatchSemaphore(value: 0)
  private let mpvEventQueue = DispatchQueue(label: "com.vbox.player.mpv.event")
  private let mpvRenderQueue = DispatchQueue(label: "com.vbox.player.mpv.render")
  /// 最近一帧（libmpv 路径；与 AVPlayer 路径分开，避免互踩）。
  private var mpvLatestPixelBuffer: CVPixelBuffer?
  private let mpvFrameLock = NSLock()
  /// libmpv 状态去重（Buffering / Playing 高频属性变更不重复扰动 Dart 状态机）。
  private var mpvState = "idle"
  private var mpvLastVideoWidth = 0
  private var mpvLastVideoHeight = 0

  // R-渲1 · GPU：OpenGL 上下文（渲染线程亲和）+ 离屏 FBO（mpv 渲染目标）。
  private var glContext: NSOpenGLContext?
  private var glApi: MacGlApi?
  private var renderFbo: UInt32 = 0
  private var renderTexture: UInt32 = 0
  private var fboWidth = 0
  private var fboHeight = 0
  /// 当前生效的视频输出后端（opengl / software / none）。OpenGL 建不起来时
  /// 由 `mpvRenderLoop` 退到 software（对齐 Windows 问题 2 兜底）。
  private var mpvRenderBackend = "none"
  /// 软件渲染输出缓冲（BGRA8888；尺寸随视频变化重建，仅 software 后端使用）。
  private var swFrameBytes = [UInt8]()
  private var swFrameWidth = 0
  private var swFrameHeight = 0
  // 日志去重：首帧上屏 / 首次渲染失败只上报一次，避免刷屏。
  private var mpvLoggedFirstFrame = false
  private var mpvLoggedRenderFailure = false

  private static let methodChannelName = "com.vbox.player/player"
  private static let eventChannelName = "com.vbox.player/player/events"

  // MARK: - 插件注册

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: methodChannelName,
      binaryMessenger: registrar.messenger
    )
    let events = FlutterEventChannel(
      name: eventChannelName,
      binaryMessenger: registrar.messenger
    )
    let instance = PlayerPlugin()
    instance.textureRegistry = registrar.textures
    registrar.addMethodCallDelegate(instance, channel: channel)
    events.setStreamHandler(instance)
  }

  // MARK: - MethodChannel 处理

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "open":
      open(call, result: result)
    case "play":
      if mpvActive {
        mpvSetFlag("pause", 0)
      } else {
        player?.play()
      }
      result(nil)
    case "pause":
      if mpvActive {
        mpvSetFlag("pause", 1)
      } else {
        player?.pause()
      }
      result(nil)
    case "seekTo":
      seekTo(call, result: result)
    case "setVolume":
      setVolume(call, result: result)
    case "setSpeed":
      setSpeed(call, result: result)
    case "dispose":
      disposePlayer()
      shutdownMpv()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func open(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let urlString = args["url"] as? String,
          let url = URL(string: urlString) else {
      result(FlutterError(
        code: "E_INVALID_SOURCE",
        message: "无效的播放源",
        details: nil))
      return
    }

    // A21.5 / R-渲3：复杂封装 → libmpv 回退（不再直接 E_BACKEND_UNAVAILABLE）。
    if needsFallback(urlString) {
      openWithMpv(urlString, args: args, result: result)
      return
    }

    disposePlayer()
    shutdownMpv()

    var assetOptions: [String: Any] = [:]
    if let headers = args["headers"] as? [String: String], !headers.isEmpty {
      assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }
    let asset = AVURLAsset(url: url, options: assetOptions)
    let item = AVPlayerItem(asset: asset)
    // R-渲1：挂视频像素输出面（BGRA），经 FlutterTexture 上屏到 Dart `Texture`。
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    item.add(output)
    videoOutput = output
    let newPlayer = AVPlayer(playerItem: item)
    // 注：iOS 的 AVPlayer.automaticallyWaitsForMinimizeStallingPlayback 为 iOS-only 属性，
    // macOS 不存在该成员（CI Xcode 16.4 / macOS SDK 15.5 编译实证），默认策略即等待最小化卡顿，无需设置。
    player = newPlayer

    observe(newPlayer)
    startFramePolling()
    emitState("opening")
    // R-渲1：注册 Flutter 纹理，并把句柄随 open 返回值交给 Dart。
    // 注册失败（无纹理注册表）→ 返回 nil，Dart 侧 textureId=null → 深色占位。
    if let registry = textureRegistry {
      let id = registry.register(self)
      textureId = id
      result(["textureId": id])
    } else {
      result(nil)
    }
  }

  private func seekTo(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let positionMs = call.arguments as? Int else {
      result(FlutterError(code: "E_BAD_ARGUMENT", message: "seekTo 需毫秒整数", details: nil))
      return
    }
    if mpvActive {
      mpvSetDouble("time-pos", Double(positionMs) / 1000.0)
      emitMpvProgress()
      result(nil)
      return
    }
    let seconds = Double(positionMs) / 1000.0
    let target = CMTime(seconds: seconds, preferredTimescale: 600)
    player?.seek(
      to: target,
      toleranceBefore: CMTime.zero,
      toleranceAfter: CMTime.zero,
      completionHandler: { [weak self] _ in self?.emitProgress() }
    )
    result(nil)
  }

  private func setVolume(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let volume = call.arguments as? Double else {
      result(FlutterError(code: "E_BAD_ARGUMENT", message: "setVolume 需浮点数", details: nil))
      return
    }
    let clamped = min(max(volume, 0.0), 1.0)
    if mpvActive {
      mpvSetDouble("volume", clamped * 100.0)  // mpv 音量域 0~100
    } else {
      player?.volume = Float(clamped)
    }
    result(nil)
  }

  private func setSpeed(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let speed = call.arguments as? Double else {
      result(FlutterError(code: "E_BAD_ARGUMENT", message: "setSpeed 需浮点数", details: nil))
      return
    }
    let clamped = min(max(speed, 0.25), 4.0)
    if mpvActive {
      mpvSetDouble("speed", clamped)
    } else {
      player?.rate = Float(clamped)
    }
    result(nil)
  }

  // MARK: - 观察与事件

  private func observe(_ player: AVPlayer) {
    itemObservers.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
      guard let self = self, let p = self.player else { return }
      switch p.timeControlStatus {
      case .waitingToPlayAtSpecifiedRate:
        self.emitState("buffering")
      case .playing:
        self.emitState("playing")
      case .paused:
        self.emitState("paused")
      @unknown default:
        self.emitState("paused")
      }
    })
    itemObservers.append(player.observe(\.currentItem?.status, options: [.new]) { [weak self] _, _ in
      guard let self = self, let p = self.player else { return }
      switch p.currentItem?.status {
      case .readyToPlay:
        self.emitProgress()
      case .failed:
        self.emitError(p.currentItem?.error?.localizedDescription ?? "播放失败", fatal: true)
      case .none:
        self.emitState("idle")
      case .unknown?:
        break
      @unknown default:
        break
      }
    })
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
      queue: .main
    ) { [weak self] _ in
      self?.emitProgress()
    }
    if let item = player.currentItem {
      // R-渲1：视频尺寸上报（Dart 侧输出面按纵横比自适应，对齐 videoGravity=.resizeAspect）。
      itemObservers.append(item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
        let size = item.presentationSize
        if size.width > 0 && size.height > 0 {
          self?.emitVideoSize(Int(size.width), Int(size.height))
        }
      })
      endTimeObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime,
        object: item,
        queue: .main
      ) { [weak self] _ in
        self?.emitState("ended")
      }
    }
  }

  // MARK: - R-渲1：取帧与纹理输出

  /// 启动取帧轮询（约 60Hz；主线程定时器）。
  private func startFramePolling() {
    frameTimer?.invalidate()
    frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
      [weak self] _ in
      self?.pollFrame()
    }
  }

  /// 拉取 AVPlayerItemVideoOutput 的新帧并通知 Flutter 纹理可采样。
  private func pollFrame() {
    guard let output = videoOutput, player?.currentItem != nil else { return }
    let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
    guard output.hasNewPixelBuffer(forItemTime: itemTime),
          let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
    else { return }
    pixelBufferLock.lock()
    latestPixelBuffer = buffer
    pixelBufferLock.unlock()
    if let id = textureId {
      textureRegistry?.textureFrameAvailable(id)
    }
  }

  private func emitVideoSize(_ width: Int, _ height: Int) {
    eventSink?(["type": "videoSize", "width": width, "height": height])
  }

  private func emitState(_ value: String) {
    eventSink?(["type": "state", "value": value])
  }

  private func emitProgress() {
    guard let item = player?.currentItem else { return }
    let durationSeconds = CMTimeGetSeconds(item.duration)
    let positionSeconds = CMTimeGetSeconds(item.currentTime())
    let bufferedSeconds = item.loadedTimeRanges
      .last?.timeRangeValue.end.seconds ?? 0.0
    let isLive = durationSeconds.isNaN || durationSeconds.isInfinite
      || item.duration == .indefinite
    eventSink?([
      "type": "progress",
      "positionMs": Int(positionSeconds.isNaN ? 0 : positionSeconds * 1000.0),
      "durationMs": Int(durationSeconds.isNaN || isLive ? 0 : durationSeconds * 1000.0),
      "bufferedMs": Int(bufferedSeconds.isNaN ? 0 : bufferedSeconds * 1000.0),
      "isLive": isLive,
    ])
  }

  private func emitError(_ message: String, fatal: Bool) {
    eventSink?(["type": "error", "message": message, "fatal": fatal])
  }

  // MARK: - 释放

  private func disposePlayer() {
    frameTimer?.invalidate()
    frameTimer = nil
    if let item = player?.currentItem, let output = videoOutput {
      item.remove(output)
    }
    videoOutput = nil
    pixelBufferLock.lock()
    latestPixelBuffer = nil
    pixelBufferLock.unlock()
    if let id = textureId {
      textureRegistry?.unregisterTexture(id)
    }
    textureId = nil
    itemObservers.removeAll()
    if let observer = timeObserver {
      player?.removeTimeObserver(observer)
      timeObserver = nil
    }
    if let observer = endTimeObserver {
      NotificationCenter.default.removeObserver(observer)
      endTimeObserver = nil
    }
    player?.pause()
    player = nil
  }

  // MARK: - A21.5 判定（与 Dart `PlayerBackendSelector.needsFallback` 同清单）

  private func needsFallback(_ url: String) -> Bool {
    let lower = url.lowercased()
    for ext in [".mkv", ".flv", ".ts", ".rmvb", ".avi", ".wmv", ".m2ts"] {
      if lower.contains(ext) {
        return true
      }
    }
    return false
  }
}

// ═══════════════ Wave G · R-渲3：libmpv 回退后端实现 ═══════════════

extension PlayerPlugin {

  // MARK: - 符号加载（D28 随包分发）

  /// dlopen `libmpv.dylib` 并解析符号表；已加载则复用。失败返回 false。
  private func loadMpvApi() -> Bool {
    if mpvApi != nil { return true }
    var candidates: [String] = []
    if let frameworks = Bundle.main.privateFrameworksPath {
      candidates.append(frameworks + "/libmpv.dylib")
    }
    candidates.append(Bundle.main.bundlePath + "/Contents/Frameworks/libmpv.dylib")
    candidates.append("libmpv.dylib")

    var lib: UnsafeMutableRawPointer?
    for path in candidates {
      if let handle = dlopen(path, RTLD_NOW) {
        lib = handle
        break
      }
    }
    guard let library = lib else {
      NSLog("vbox: libmpv.dylib 加载失败（D28 分发缺失），复杂封装回退不可用")
      return false
    }

    func sym(_ name: String) -> UnsafeMutableRawPointer? { dlsym(library, name) }

    guard let createSym = sym("mpv_create"),
          let initSym = sym("mpv_initialize"),
          let destroySym = sym("mpv_terminate_destroy"),
          let commandSym = sym("mpv_command"),
          let setOptionSym = sym("mpv_set_option_string"),
          let setPropSym = sym("mpv_set_property"),
          let getPropSym = sym("mpv_get_property"),
          let observeSym = sym("mpv_observe_property"),
          let waitSym = sym("mpv_wait_event"),
          let errorSym = sym("mpv_error_string")
    else {
      NSLog("vbox: libmpv.dylib 核心符号不完整，复杂封装回退不可用")
      return false
    }

    var api = MpvApi()
    api.create = unsafeBitCast(createSym, to: FnMpvCreate.self)
    api.initialize = unsafeBitCast(initSym, to: FnMpvInitialize.self)
    api.terminateDestroy = unsafeBitCast(destroySym, to: FnMpvTerminateDestroy.self)
    api.command = unsafeBitCast(commandSym, to: FnMpvCommand.self)
    api.setOptionString = unsafeBitCast(setOptionSym, to: FnMpvSetOptionString.self)
    api.setProperty = unsafeBitCast(setPropSym, to: FnMpvSetProperty.self)
    api.getProperty = unsafeBitCast(getPropSym, to: FnMpvGetProperty.self)
    api.observeProperty = unsafeBitCast(observeSym, to: FnMpvObserveProperty.self)
    api.waitEvent = unsafeBitCast(waitSym, to: FnMpvWaitEvent.self)
    api.errorString = unsafeBitCast(errorSym, to: FnMpvErrorString.self)
    // 日志面为可选增强：缺失时仅少了 mpv 内部日志上抛。
    if let s = sym("mpv_request_log_messages") {
      api.requestLogMessages = unsafeBitCast(s, to: FnMpvRequestLogMessages.self)
    }
    // render API 为可选增强（R-渲1）：缺失时控制面可用但无纹理输出。
    if let s = sym("mpv_render_context_create") {
      api.renderCreate = unsafeBitCast(s, to: FnMpvRenderCreate.self)
    }
    if let s = sym("mpv_render_context_render") {
      api.render = unsafeBitCast(s, to: FnMpvRender.self)
    }
    if let s = sym("mpv_render_context_set_update_callback") {
      api.renderSetUpdate = unsafeBitCast(s, to: FnMpvRenderSetUpdate.self)
    }
    if let s = sym("mpv_render_context_update") {
      api.renderUpdate = unsafeBitCast(s, to: FnMpvRenderUpdate.self)
    }
    if let s = sym("mpv_render_context_free") {
      api.renderFree = unsafeBitCast(s, to: FnMpvRenderFree.self)
    }
    mpvApi = api
    return true
  }

  // MARK: - 打开（复杂封装回退）

  private func openWithMpv(
    _ urlString: String,
    args: [String: Any],
    result: @escaping FlutterResult
  ) {
    guard loadMpvApi(), let api = mpvApi else {
      result(FlutterError(
        code: "E_BACKEND_UNAVAILABLE",
        message: "libmpv 动态库加载失败（D28 分发缺失），复杂封装不可播",
        details: urlString))
      return
    }

    disposePlayer()
    shutdownMpv()

    guard let handle = api.create?() else {
      result(FlutterError(
        code: "E_BACKEND_UNAVAILABLE",
        message: "libmpv 初始化失败", details: urlString))
      return
    }

    // R-渲1：有 render API 时走 `vo=libmpv`（render_context 前置），否则退回 `vo=null`
    // （纯控制面，无纹理输出）。vo 属初始化前生效选项，必须早于 mpv_initialize。
    let canRender = api.renderCreate != nil
    _ = canRender
      ? api.setOptionString?(handle, "vo", "libmpv")
      : api.setOptionString?(handle, "vo", "null")
    // 问题 5：render context 走 OpenGL(GPU) 后端，mpv 在 GPU 上跑完整色彩管线
    // （primaries / gamma / HDR tone-mapping，对齐 iOS）；macOS 用桌面 GL，不设 opengl-es。
    if canRender {
      _ = api.setOptionString?(handle, "gpu-api", "opengl")
    }

    if (api.initialize?(handle) ?? -1) < 0 {
      api.terminateDestroy?(handle)
      result(FlutterError(
        code: "E_BACKEND_UNAVAILABLE",
        message: "libmpv 初始化失败", details: urlString))
      return
    }
    mpvHandle = handle
    mpvActive = true
    mpvState = "opening"
    // mpv 内部日志上抛（对齐 Windows / iOS 排查详细度）：info 及以上经
    // MPV_EVENT_LOG_MESSAGE 转 `log` 事件交 Dart AppLog。
    _ = "info".withCString { api.requestLogMessages?(handle, $0) }
    // open 日志只记 host（播放直链常带签名参数，不入日志，避免泄漏凭据）。
    emitLog("info", "open 请求：host=\(Self.hostOf(urlString))，urlLength=\(urlString.count)")
    emitLog(
      "info",
      "mpv 初始化完成（vo=\(canRender ? "libmpv" : "null")，"
        + "gpu-api=\(canRender ? "opengl" : "无")）")

    // 直播直接起播；点播保持暂停待 Dart play()（对齐 Android / Windows 口径）。
    let isLive = args["isLive"] as? Bool ?? false
    mpvSetFlag("pause", isLive ? 0 : 1)

    // 自定义请求头 → http-header-fields（loadfile 时生效）。
    if let headers = args["headers"] as? [String: String], !headers.isEmpty {
      let joined = headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
      joined.withCString { api.setOptionString?(handle, "http-header-fields", $0) }
    }

    // loadfile（replace：单文件播放，与 Android / Windows 语义一致）。
    let loadResult: Int32 = "loadfile".withCString { load in
      urlString.withCString { url in
        "replace".withCString { replace in
          var argv: [UnsafePointer<CChar>?] = [load, url, replace, nil]
          return api.command?(handle, &argv) ?? -1
        }
      }
    }
    if loadResult < 0 {
      shutdownMpv()
      result(FlutterError(
        code: "E_OPEN", message: "loadfile 命令失败", details: urlString))
      return
    }

    // 进度 / 状态由属性变更驱动（对齐契约 §2.5 能力矩阵）。
    _ = api.observeProperty?(handle, 0, "time-pos", mpvFormatDouble)
    _ = api.observeProperty?(handle, 0, "duration", mpvFormatDouble)
    _ = api.observeProperty?(handle, 0, "pause", mpvFormatFlag)
    _ = api.observeProperty?(handle, 0, "paused-for-cache", mpvFormatFlag)
    _ = api.observeProperty?(handle, 0, "demuxer-cache-time", mpvFormatDouble)

    if canRender {
      setupMpvRenderContext()
    }

    // 事件线程（0.1s 超时轮询，支持 mpvRunning 标志及时退出）。
    mpvRunning = true
    let runtime = self
    mpvEventQueue.async {
      runtime.mpvEventLoop()
      runtime.mpvEventExited.signal()
    }

    emitState("opening")
    if let id = mpvTextureId {
      result(["textureId": id])
    } else {
      result([String: Any]())
    }
  }

  // MARK: - 属性读写辅助

  private func mpvSetFlag(_ name: String, _ value: Int32) {
    guard let api = mpvApi, let handle = mpvHandle else { return }
    var flag = value
    withUnsafeMutablePointer(to: &flag) { pointer in
      name.withCString {
        api.setProperty?(handle, $0, mpvFormatFlag, UnsafeMutableRawPointer(pointer))
      }
    }
  }

  private func mpvSetDouble(_ name: String, _ value: Double) {
    guard let api = mpvApi, let handle = mpvHandle else { return }
    var number = value
    withUnsafeMutablePointer(to: &number) { pointer in
      name.withCString {
        api.setProperty?(handle, $0, mpvFormatDouble, UnsafeMutableRawPointer(pointer))
      }
    }
  }

  private func mpvGetDouble(_ name: String) -> Double? {
    guard let api = mpvApi, let handle = mpvHandle else { return nil }
    var value = 0.0
    let rc: Int32 = withUnsafeMutablePointer(to: &value) { pointer in
      name.withCString {
        api.getProperty?(handle, $0, mpvFormatDouble, UnsafeMutableRawPointer(pointer)) ?? -1
      }
    }
    return rc < 0 ? nil : value
  }

  private func mpvGetInt64(_ name: String) -> Int64? {
    guard let api = mpvApi, let handle = mpvHandle else { return nil }
    var value: Int64 = 0
    let rc: Int32 = withUnsafeMutablePointer(to: &value) { pointer in
      name.withCString {
        api.getProperty?(handle, $0, mpvFormatInt64, UnsafeMutableRawPointer(pointer)) ?? -1
      }
    }
    return rc < 0 ? nil : value
  }

  private func mpvGetFlag(_ name: String) -> Int32? {
    guard let api = mpvApi, let handle = mpvHandle else { return nil }
    var value: Int32 = 0
    let rc: Int32 = withUnsafeMutablePointer(to: &value) { pointer in
      name.withCString {
        api.getProperty?(handle, $0, mpvFormatFlag, UnsafeMutableRawPointer(pointer)) ?? -1
      }
    }
    return rc < 0 ? nil : value
  }

  // MARK: - 事件线程

  private func mpvEventLoop() {
    guard let api = mpvApi, let handle = mpvHandle else { return }
    while mpvRunning {
      guard let raw = api.waitEvent?(handle, 0.1) else { continue }
      let event = raw.assumingMemoryBound(to: MpvEvent.self).pointee
      if event.eventID == mpvEventShutdown { break }
      handleMpvEvent(event)
    }
  }

  private func handleMpvEvent(_ event: MpvEvent) {
    let api = mpvApi
    switch event.eventID {
    case mpvEventStartFile:
      mpvEmitState("opening")
    case mpvEventFileLoaded:
      let paused = mpvGetFlag("pause") ?? 0
      mpvEmitState(paused != 0 ? "paused" : "playing")
      // 记录媒体信息，便于判断「有声音无画面」是否因缺视频轨 / 解码失败。
      let duration = mpvGetDouble("duration") ?? -1
      let videoWidth = mpvGetInt64("width") ?? 0
      let videoHeight = mpvGetInt64("height") ?? 0
      let videoDesc =
        (videoWidth > 0 && videoHeight > 0)
        ? "\(videoWidth)x\(videoHeight)" : "无（纯音频）"
      emitLog("info", "文件已加载：时长=\(duration > 0 ? "\(Int(duration))秒" : "未知")，视频轨尺寸=\(videoDesc)")
      emitMpvProgress()
    case mpvEventPlaybackRestart:
      let paused = mpvGetFlag("pause") ?? 0
      mpvEmitState(paused != 0 ? "paused" : "playing")
    case mpvEventEndFile:
      guard let raw = event.data else { break }
      let endFile = raw.assumingMemoryBound(to: MpvEventEndFile.self).pointee
      if endFile.reason == mpvEndFileReasonError {
        var detail = "播放失败"
        if let cString = api?.errorString?(endFile.error) {
          detail = String(cString: cString)
        }
        emitLog("error", "播放中断：\(detail)")
        mpvEmitError(detail, fatal: true)
        mpvEmitState("error")
      } else if endFile.reason == mpvEndFileReasonEOF {
        emitLog("info", "播放到文件末尾")
        mpvEmitState("ended")
      }
    case mpvEventLogMessage:
      // mpv 内部日志（对齐 Windows 详细度）：前缀 + 文本上抛 Dart AppLog。
      guard let raw = event.data else { break }
      let logMessage = raw.assumingMemoryBound(to: MpvEventLogMessage.self).pointee
      guard let textPointer = logMessage.text else { break }
      let rawLevel = logMessage.level.map { String(cString: $0) } ?? "info"
      let mapped = Self.mapMpvLogLevel(rawLevel)
      let prefix = logMessage.prefix.map { String(cString: $0) } ?? "mpv"
      var text = String(cString: textPointer)
      while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
      emitLog(mapped, "[mpv/\(prefix)] \(text)")
    case mpvEventPropertyChange:
      guard let raw = event.data else { break }
      let property = raw.assumingMemoryBound(to: MpvEventProperty.self).pointee
      let name = property.name.map { String(cString: $0) } ?? ""
      switch name {
      case "time-pos", "duration":
        emitMpvProgress()
      case "pause":
        if property.format == mpvFormatFlag, let data = property.data {
          let paused = data.assumingMemoryBound(to: Int32.self).pointee
          mpvEmitState(paused != 0 ? "paused" : "playing")
        }
      case "paused-for-cache":
        if property.format == mpvFormatFlag, let data = property.data {
          let caching = data.assumingMemoryBound(to: Int32.self).pointee
          if caching != 0 {
            mpvEmitState("buffering")
          } else {
            let paused = mpvGetFlag("pause") ?? 0
            mpvEmitState(paused != 0 ? "paused" : "playing")
          }
        }
      default:
        break
      }
    default:
      break
    }
  }

  /// 状态去重上报（libmpv → Dart 事件，主线程同步）。
  private func mpvEmitState(_ value: String) {
    if mpvState == value { return }
    mpvState = value
    DispatchQueue.main.async { [weak self] in self?.emitState(value) }
  }

  private func mpvEmitError(_ message: String, fatal: Bool) {
    DispatchQueue.main.async { [weak self] in self?.emitError(message, fatal: fatal) }
  }

  /// 播放日志上报（可自任意队列调用；对齐 Windows `EmitLog` / iOS 排查详细度）。
  /// Dart 侧 `ChannelPlayer` 的 `log` 事件统一转入 `AppLog`（category=player）。
  private func emitLog(_ level: String, _ message: String) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(["type": "log", "level": level, "message": message])
    }
  }

  private func emitMpvProgress() {
    guard mpvHandle != nil else { return }
    let positionSeconds = mpvGetDouble("time-pos") ?? -1.0
    let durationSeconds = mpvGetDouble("duration") ?? -1.0
    let bufferedSeconds = mpvGetDouble("demuxer-cache-time") ?? -1.0
    let isLive = durationSeconds < 0.0
    let payload: [String: Any] = [
      "type": "progress",
      "positionMs": positionSeconds < 0 ? 0 : Int(positionSeconds * 1000.0),
      "durationMs": isLive ? 0 : Int(durationSeconds * 1000.0),
      "bufferedMs": bufferedSeconds < 0 ? 0 : Int(bufferedSeconds * 1000.0),
      "isLive": isLive,
    ]
    DispatchQueue.main.async { [weak self] in self?.eventSink?(payload) }
  }

  // MARK: - 渲染输出面（R-渲1 · GPU：OpenGL render context → 离屏 FBO → glReadPixels → CVPixelBuffer）

  /// 建立纹理输出面并拉起渲染线程；GL 上下文 / render_context 在渲染线程内创建
  /// （NSOpenGL 上下文有线程亲和，必须与 render 调用同线程）。
  private func setupMpvRenderContext() {
    guard let api = mpvApi, api.renderCreate != nil else { return }

    if let id = textureRegistry?.register(self) {
      mpvTextureId = id
    }

    mpvRenderRunning = true
    let runtime = self
    mpvRenderQueue.async {
      runtime.mpvRenderLoop()
      runtime.mpvRenderExited.signal()
    }
  }

  /// 渲染线程内建 NSOpenGL 上下文 + mpv render_context（OpenGL/GPU 后端）。
  private func createGlRenderContext() -> Bool {
    guard let api = mpvApi, let handle = mpvHandle,
          let create = api.renderCreate else {
      emitLog("error", "创建 GL 渲染上下文失败：render API 或 mpv 句柄不可用")
      return false
    }
    guard loadGlApi() else {
      emitLog("error", "创建 GL 渲染上下文失败：OpenGL 入口解析不全（FBO 需要 GL 3.2 core）")
      return false
    }

    let attributes: [NSOpenGLPixelFormatAttribute] = [
      NSOpenGLPixelFormatAttribute(NSOpenGLPFAAccelerated),
      NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
      NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize), 24,
      NSOpenGLPixelFormatAttribute(NSOpenGLPFAAlphaSize), 8,
      NSOpenGLPixelFormatAttribute(NSOpenGLPFADepthSize), 0,
      NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile),
      NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion3_2Core),
      0,
    ]
    guard let format = NSOpenGLPixelFormat(attributes: attributes),
          let context = NSOpenGLContext(format: format, share: nil) else {
      emitLog("error", "创建 GL 渲染上下文失败：NSOpenGL 像素格式 / 上下文创建失败")
      return false
    }
    context.makeCurrentContext()
    glContext = context

    var initParams = MpvOpenGLInitParams(
      getProcAddress: mpvGlGetProcAddress, getProcAddressCtx: nil)
    var advancedControl: Int32 = 1
    var created: MpvRenderContext?

    let rc: Int32 = "opengl".withCString { apiType -> Int32 in
      withUnsafeMutablePointer(to: &initParams) { initPtr -> Int32 in
        withUnsafeMutablePointer(to: &advancedControl) { advPtr -> Int32 in
          withUnsafeMutablePointer(to: &created) { ctxPtr -> Int32 in
            var params = [
              MpvRenderParam(type: mpvRenderParamAPIType,
                             data: UnsafeMutableRawPointer(mutating: apiType)),
              MpvRenderParam(type: mpvRenderParamOpenGLInitParams,
                             data: UnsafeMutableRawPointer(initPtr)),
              MpvRenderParam(type: mpvRenderParamAdvancedControl,
                             data: UnsafeMutableRawPointer(advPtr)),
              MpvRenderParam(type: mpvRenderParamInvalid, data: nil),
            ]
            return params.withUnsafeMutableBufferPointer { buffer in
              create(UnsafeMutableRawPointer(ctxPtr), handle,
                     UnsafeMutableRawPointer(buffer.baseAddress))
            }
          }
        }
      }
    }
    guard rc >= 0, let ctx = created else {
      var detail = "未知原因"
      if let cString = api.errorString?(rc) { detail = String(cString: cString) }
      emitLog("error", "mpv_render_context_create 失败（\(detail)），无视频输出")
      destroyGlRenderContext()
      return false
    }
    mpvRenderContext = ctx
    mpvRenderBackend = "opengl"
    api.renderSetUpdate?(
      ctx, mpvRenderUpdateCallback, Unmanaged.passUnretained(self).toOpaque())
    emitLog("info", "mpv OpenGL render context 创建成功，纹理输出已就绪")
    return true
  }

  /// 渲染线程内以 "sw" API 建 render context（libswscale 软渲染，无需 GL 上下文）。
  ///
  /// 用途（对齐 Windows 问题 2 兜底）：目标机 OpenGL 不可用（无加速 GL / 远程
  /// 会话 / GL 3.2 core 不可得）时，若直接放弃就会「有声音无画面」。SW 后端不
  /// 依赖 GPU，可保证画面仍能上屏；代价是无色彩管理（可能泛黄偏色）。
  private func createSwRenderContext() -> Bool {
    guard let api = mpvApi, let handle = mpvHandle, let create = api.renderCreate else {
      return false
    }
    var advancedControl: Int32 = 1
    var created: MpvRenderContext?
    let rc: Int32 = "sw".withCString { apiType -> Int32 in
      withUnsafeMutablePointer(to: &advancedControl) { advPtr -> Int32 in
        withUnsafeMutablePointer(to: &created) { ctxPtr -> Int32 in
          var params = [
            MpvRenderParam(type: mpvRenderParamAPIType,
                           data: UnsafeMutableRawPointer(mutating: apiType)),
            MpvRenderParam(type: mpvRenderParamAdvancedControl,
                           data: UnsafeMutableRawPointer(advPtr)),
            MpvRenderParam(type: mpvRenderParamInvalid, data: nil),
          ]
          return params.withUnsafeMutableBufferPointer { buffer in
            create(UnsafeMutableRawPointer(ctxPtr), handle,
                   UnsafeMutableRawPointer(buffer.baseAddress))
          }
        }
      }
    }
    guard rc >= 0, let ctx = created else {
      var detail = "未知原因"
      if let cString = api.errorString?(rc) { detail = String(cString: cString) }
      emitLog("error", "mpv 软件渲染上下文创建失败（\(detail)），无视频输出")
      return false
    }
    mpvRenderContext = ctx
    mpvRenderBackend = "software"
    api.renderSetUpdate?(
      ctx, mpvRenderUpdateCallback, Unmanaged.passUnretained(self).toOpaque())
    emitLog("info", "mpv 软件渲染（SW）已就绪，视频将由 CPU 渲染上屏（色彩表现不如 GPU 路径）")
    return true
  }

  /// 渲染线程内释放 render_context（GL 上下文需 current）+ 离屏 FBO/纹理 + 销毁 GL 上下文。
  /// 两个后端共用：software 后端只有 render_context，GL 资源为空时各守卫直接跳过。
  private func destroyGlRenderContext() {
    if let ctx = mpvRenderContext {
      mpvApi?.renderSetUpdate?(ctx, nil, nil)
      glContext?.makeCurrentContext()
      mpvApi?.renderFree?(ctx)
      mpvRenderContext = nil
    }
    mpvRenderBackend = "none"
    if let gl = glApi {
      if renderFbo != 0 {
        var fbo = renderFbo
        gl.deleteFramebuffers?(1, &fbo)
      }
      if renderTexture != 0 {
        var texture = renderTexture
        gl.deleteTextures?(1, &texture)
      }
    }
    renderFbo = 0
    renderTexture = 0
    fboWidth = 0
    fboHeight = 0
    NSOpenGLContext.clearCurrentContext()
    glContext = nil
  }

  /// 渲染线程内解析 OpenGL 入口（OpenGL.framework 运行期 dlopen + dlsym）。
  private func loadGlApi() -> Bool {
    guard let module = dlopen(
      "/System/Library/Frameworks/OpenGL.framework/OpenGL",
      RTLD_LAZY | RTLD_GLOBAL) else {
      emitLog("error", "OpenGL.framework 加载失败，无法离屏渲染")
      return false
    }
    func symbol<T>(_ name: String) -> T? {
      guard let pointer = dlsym(module, name) else { return nil }
      return unsafeBitCast(pointer, to: T.self)
    }
    var api = MacGlApi()
    api.readPixels = symbol("glReadPixels")
    api.pixelStorei = symbol("glPixelStorei")
    api.genFramebuffers = symbol("glGenFramebuffers")
    api.bindFramebuffer = symbol("glBindFramebuffer")
    api.framebufferTexture2D = symbol("glFramebufferTexture2D")
    api.checkFramebufferStatus = symbol("glCheckFramebufferStatus")
    api.deleteFramebuffers = symbol("glDeleteFramebuffers")
    api.genTextures = symbol("glGenTextures")
    api.bindTexture = symbol("glBindTexture")
    api.texImage2D = symbol("glTexImage2D")
    api.texParameteri = symbol("glTexParameteri")
    api.deleteTextures = symbol("glDeleteTextures")
    // 逐项登记缺失入口，便于区分「GL 基础入口缺失」与「FBO 扩展缺失」。
    var missing: [String] = []
    func note(_ name: String, _ present: Bool) {
      if !present { missing.append(name) }
    }
    note("glReadPixels", api.readPixels != nil)
    note("glPixelStorei", api.pixelStorei != nil)
    note("glGenFramebuffers", api.genFramebuffers != nil)
    note("glBindFramebuffer", api.bindFramebuffer != nil)
    note("glFramebufferTexture2D", api.framebufferTexture2D != nil)
    note("glCheckFramebufferStatus", api.checkFramebufferStatus != nil)
    note("glDeleteFramebuffers", api.deleteFramebuffers != nil)
    note("glGenTextures", api.genTextures != nil)
    note("glBindTexture", api.bindTexture != nil)
    note("glTexImage2D", api.texImage2D != nil)
    note("glTexParameteri", api.texParameteri != nil)
    note("glDeleteTextures", api.deleteTextures != nil)
    guard missing.isEmpty else {
      emitLog("error", "GL 入口缺失：\(missing.joined(separator: ", "))")
      return false
    }
    glApi = api
    emitLog("debug", "GL 入口解析完成（GL 3.2 core + FBO 齐全）")
    return true
  }

  /// 按视频尺寸（懒）建离屏 FBO + 颜色纹理（RGBA8）。
  private func ensureFbo(width: Int, height: Int) -> Bool {
    guard let gl = glApi else { return false }
    if renderFbo != 0 && width == fboWidth && height == fboHeight { return true }
    if renderFbo != 0 {
      var fbo = renderFbo
      gl.deleteFramebuffers?(1, &fbo)
      renderFbo = 0
    }
    if renderTexture != 0 {
      var texture = renderTexture
      gl.deleteTextures?(1, &texture)
      renderTexture = 0
    }

    var texture: UInt32 = 0
    gl.genTextures?(1, &texture)
    gl.bindTexture?(glTexture2D, texture)
    gl.texParameteri?(glTexture2D, glTextureMinFilter, glLinear)
    gl.texParameteri?(glTexture2D, glTextureMagFilter, glLinear)
    gl.texImage2D?(
      glTexture2D, 0, glRgba8, Int32(width), Int32(height), 0,
      glRgba, glUnsignedByte, nil)

    var fbo: UInt32 = 0
    gl.genFramebuffers?(1, &fbo)
    gl.bindFramebuffer?(glFramebuffer, fbo)
    gl.framebufferTexture2D?(glFramebuffer, glColorAttachment0, glTexture2D, texture, 0)
    let status = gl.checkFramebufferStatus?(glFramebuffer) ?? 0
    gl.bindFramebuffer?(glFramebuffer, 0)
    guard status == glFramebufferComplete else {
      var discardFbo = fbo
      gl.deleteFramebuffers?(1, &discardFbo)
      var discardTexture = texture
      gl.deleteTextures?(1, &discardTexture)
      return false
    }
    renderFbo = fbo
    renderTexture = texture
    fboWidth = width
    fboHeight = height
    return true
  }

  private func mpvRenderLoop() {
    // 渲染线程内建 GL 上下文 + render_context（NSOpenGL 上下文有线程亲和）。
    if !createGlRenderContext() {
      // 问题 2 兜底（对齐 Windows）：OpenGL 离屏渲染不可用（无加速 GL / 远程
      // 会话 / GL 3.2 core 不可得）→ 不再直接放弃，改走 libswscale 软渲染，
      // 保证仍有画面。失败原因已由 createGlRenderContext 逐环上报。
      destroyGlRenderContext()
      emitLog("warn", "OpenGL 视频输出不可用，回退 mpv 软件渲染（SW）")
      if !createSwRenderContext() {
        mpvLoggedRenderFailure = true
        mpvEmitError(
          "当前设备无法建立视频输出（OpenGL 与软件渲染均失败），画面暂不可用，音频正常",
          fatal: false)
        destroyGlRenderContext()
        return
      }
    }
    while mpvRenderRunning {
      _ = mpvRenderWake.wait(timeout: .now() + 0.1)
      if !mpvRenderRunning { break }
      guard let api = mpvApi, let ctx = mpvRenderContext else { continue }
      _ = api.renderUpdate?(ctx)
      renderMpvFrame()
    }
    // 渲染线程内释放（保持 GL 上下文 current，满足 mpv OpenGL 后端释放契约）。
    destroyGlRenderContext()
  }

  private func renderMpvFrame() {
    guard let api = mpvApi, let ctx = mpvRenderContext, api.render != nil else { return }

    // 视频目标尺寸：优先 coded 尺寸（width/height），回退 display 尺寸（dwidth/dheight）。
    var width = mpvGetInt64("width") ?? 0
    var height = mpvGetInt64("height") ?? 0
    if width <= 0 || height <= 0 {
      width = mpvGetInt64("dwidth") ?? 0
      height = mpvGetInt64("dheight") ?? 0
    }
    guard width > 0, height > 0 else { return }  // 尚未解出视频轨（纯音频 / 加载中）

    let pixelWidth = Int(width)
    let pixelHeight = Int(height)
    let sourceStride = pixelWidth * 4
    if mpvRenderBackend == "software" {
      renderMpvFrameSoftware(width: pixelWidth, height: pixelHeight)
      return
    }
    guard ensureFbo(width: pixelWidth, height: pixelHeight) else {
      if !mpvLoggedRenderFailure {
        mpvLoggedRenderFailure = true
        emitLog(
          "error",
          "离屏 FBO 创建失败（\(pixelWidth)x\(pixelHeight)），"
            + "视频帧无法上屏；请检查显卡驱动与 OpenGL 版本")
      }
      return
    }

    // mpv 在 GPU 上渲染到离屏 FBO（含完整色彩管理），随后 glReadPixels 回读 BGRA。
    var fbo = MpvOpenGLFbo(
      fbo: Int32(renderFbo), width: Int32(pixelWidth),
      height: Int32(pixelHeight), internalFormat: 0)
    var flipY: Int32 = 1

    let renderResult: Int32 = withUnsafeMutablePointer(to: &fbo) { fboPointer -> Int32 in
      withUnsafeMutablePointer(to: &flipY) { flipPointer -> Int32 in
        var params = [
          MpvRenderParam(
            type: mpvRenderParamOpenGLFbo,
            data: UnsafeMutableRawPointer(fboPointer)),
          MpvRenderParam(
            type: mpvRenderParamFlipY,
            data: UnsafeMutableRawPointer(flipPointer)),
          MpvRenderParam(type: mpvRenderParamInvalid, data: nil),
        ]
        return params.withUnsafeMutableBufferPointer { buffer in
          api.render?(ctx, UnsafeMutableRawPointer(buffer.baseAddress)) ?? -1
        }
      }
    }
    guard renderResult >= 0, let gl = glApi else {
      if !mpvLoggedRenderFailure {
        mpvLoggedRenderFailure = true
        emitLog("error", "mpv_render_context_render 失败（OpenGL），视频帧无法渲染")
      }
      return
    }

    var scratch = [UInt8](repeating: 0, count: sourceStride * pixelHeight)
    gl.pixelStorei?(glPackAlignment, 1)
    gl.bindFramebuffer?(glFramebuffer, renderFbo)
    scratch.withUnsafeMutableBytes { scratchBuffer in
      gl.readPixels?(
        0, 0, Int32(pixelWidth), Int32(pixelHeight),
        glBgra, glUnsignedByte, scratchBuffer.baseAddress)
    }
    gl.bindFramebuffer?(glFramebuffer, 0)

    publishMpvFrame(bytes: scratch, width: pixelWidth, height: pixelHeight, stride: sourceStride)
  }

  /// 软件渲染后端逐帧输出：libswscale 把视频帧直接写成 BGRA，无 GPU 依赖。
  ///
  /// 参数口径与改造前的 SW 路径一致（`SW_SIZE` / `SW_FORMAT="bgra"` / `SW_STRIDE`
  /// / `SW_POINTER`）：SW 后端输出本就为顶行在上，无需 `FLIP_Y`（该参数仅 OpenGL
  /// 路径需要，因为 GL 纹理原点在左下）。
  private func renderMpvFrameSoftware(width: Int, height: Int) {
    guard let api = mpvApi, let ctx = mpvRenderContext, api.render != nil else { return }
    let stride = width * 4
    let bytes = stride * height
    if swFrameWidth != width || swFrameHeight != height || swFrameBytes.count != bytes {
      swFrameBytes = [UInt8](repeating: 0, count: bytes)
      swFrameWidth = width
      swFrameHeight = height
    }
    var size: [Int32] = [Int32(width), Int32(height)]
    var swStride = stride
    var renderResult: Int32 = -1
    size.withUnsafeMutableBufferPointer { sizeBuffer -> Void in
      guard let sizeBase = sizeBuffer.baseAddress else { return }
      withUnsafeMutablePointer(to: &swStride) { stridePointer -> Void in
        swFrameBytes.withUnsafeMutableBytes { frameBuffer -> Void in
          guard let frameBase = frameBuffer.baseAddress else { return }
          "bgra".withCString { formatPointer -> Void in
            var params = [
              MpvRenderParam(
                type: mpvRenderParamSwSize,
                data: UnsafeMutableRawPointer(sizeBase)),
              MpvRenderParam(
                type: mpvRenderParamSwFormat,
                data: UnsafeMutableRawPointer(mutating: formatPointer)),
              MpvRenderParam(
                type: mpvRenderParamSwStride,
                data: UnsafeMutableRawPointer(stridePointer)),
              MpvRenderParam(
                type: mpvRenderParamSwPointer,
                data: frameBase),
              MpvRenderParam(type: mpvRenderParamInvalid, data: nil),
            ]
            renderResult = params.withUnsafeMutableBufferPointer { buffer in
              api.render?(ctx, UnsafeMutableRawPointer(buffer.baseAddress)) ?? -1
            }
          }
        }
      }
    }
    guard renderResult >= 0 else {
      if !mpvLoggedRenderFailure {
        mpvLoggedRenderFailure = true
        emitLog("error", "mpv 软件渲染失败（SW），视频帧无法渲染")
      }
      return
    }
    publishMpvFrame(bytes: swFrameBytes, width: width, height: height, stride: stride)
  }

  /// 两个渲染后端共用的上屏尾段：交 Flutter 纹理 → 首帧日志 → 尺寸上报。
  private func publishMpvFrame(bytes: [UInt8], width: Int, height: Int, stride: Int) {
    guard let pixelBuffer = Self.makePixelBuffer(
      from: bytes, width: width, height: height, sourceStride: stride)
    else { return }

    mpvFrameLock.lock()
    mpvLatestPixelBuffer = pixelBuffer
    mpvFrameLock.unlock()

    if let id = mpvTextureId {
      textureRegistry?.textureFrameAvailable(id)
    }

    if !mpvLoggedFirstFrame {
      mpvLoggedFirstFrame = true
      emitLog("info", "首帧已渲染上屏（\(width)x\(height)，后端=\(mpvRenderBackend)）")
    }

    // 视频尺寸变更上报（Dart 侧输出面纵横比自适应；去重避免抖动）。
    if width != mpvLastVideoWidth || height != mpvLastVideoHeight {
      mpvLastVideoWidth = width
      mpvLastVideoHeight = height
      DispatchQueue.main.async { [weak self] in
        self?.emitVideoSize(width, height)
      }
    }
  }

  /// 从播放直链提取 host（仅用于日志，避免把签名参数写进日志）。
  private static func hostOf(_ urlString: String) -> String {
    guard let range = urlString.range(of: "://") else { return urlString }
    let rest = urlString[range.upperBound...]
    guard let slash = rest.firstIndex(of: "/") else { return String(rest) }
    return String(rest[..<slash])
  }

  /// mpv 日志等级 → Dart `AppLog` 等级（fatal/error→error，v/debug/trace→debug）。
  private static func mapMpvLogLevel(_ level: String) -> String {
    switch level {
    case "fatal", "error": return "error"
    case "warn": return "warn"
    case "info": return "info"
    default: return "debug"
    }
  }

  /// BGRA 软渲染结果 → CVPixelBuffer（FlutterTexture 采样面）。
  private static func makePixelBuffer(
    from bytes: [UInt8],
    width: Int,
    height: Int,
    sourceStride: Int
  ) -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [String: Any] = [
      kCVPixelBufferCGImageCompatibilityKey as String: false,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: false,
    ]
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      attributes as CFDictionary, &pixelBuffer)
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let destinationStride = CVPixelBufferGetBytesPerRow(buffer)
    let copyBytes = min(sourceStride, destinationStride)
    bytes.withUnsafeBytes { source in
      guard let sourceBase = source.baseAddress else { return }
      for row in 0..<height {
        _ = memcpy(
          base.advanced(by: row * destinationStride),
          sourceBase.advanced(by: row * sourceStride),
          copyBytes)
      }
    }
    return buffer
  }

  // MARK: - libmpv 释放

  private func shutdownMpv() {
    // 1. 停渲染线程（渲染线程退出时会释放 render_context + GL 上下文）。
    if mpvRenderRunning {
      mpvRenderRunning = false
      mpvRenderWake.signal()
      _ = mpvRenderExited.wait(timeout: .now() + 2)
    }
    // 兜底：渲染线程异常提前退出时 render_context 仍可能残留（正常路径已置 nil）。
    if let ctx = mpvRenderContext {
      mpvApi?.renderSetUpdate?(ctx, nil, nil)
      mpvApi?.renderFree?(ctx)
      mpvRenderContext = nil
    }
    if let id = mpvTextureId {
      textureRegistry?.unregisterTexture(id)
      mpvTextureId = nil
    }
    mpvFrameLock.lock()
    mpvLatestPixelBuffer = nil
    mpvFrameLock.unlock()
    mpvLastVideoWidth = 0
    mpvLastVideoHeight = 0
    // 渲染后端与软渲染缓冲随会话释放；日志去重标记复位，避免上次失败导致
    // 本次不再上报关键日志。
    mpvRenderBackend = "none"
    swFrameBytes = []
    swFrameWidth = 0
    swFrameHeight = 0
    mpvLoggedFirstFrame = false
    mpvLoggedRenderFailure = false

    // 2. 停事件线程（0.1s 超时轮询 → 最迟 ~0.1s 退出）。
    if mpvRunning {
      mpvRunning = false
      _ = mpvEventExited.wait(timeout: .now() + 2)
    }
    if let handle = mpvHandle {
      mpvApi?.terminateDestroy?(handle)
      mpvHandle = nil
    }
    mpvActive = false
    mpvState = "idle"
  }
}

// MARK: - EventChannel

extension PlayerPlugin: FlutterStreamHandler {
  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    // 已有播放器时补发一次当前状态，避免 Dart 侧错过中间态。
    if mpvActive {
      emitMpvProgress()
    } else if player != nil {
      emitProgress()
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}

// MARK: - FlutterTexture（R-渲1）

extension PlayerPlugin: FlutterTexture {
  /// Flutter 采样回调（raster 线程）：交出最近一帧 BGRA 像素缓冲。
  ///
  /// 无新帧时返回 nil，引擎沿用上一帧画面；缓冲区以 `passRetained` 移交，
  /// 由引擎负责释放。AVPlayer / libmpv 两路各自独立缓冲，按当前后端取向。
  public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    if mpvActive {
      mpvFrameLock.lock()
      defer { mpvFrameLock.unlock() }
      guard let buffer = mpvLatestPixelBuffer else { return nil }
      mpvLatestPixelBuffer = nil
      return Unmanaged.passRetained(buffer)
    }
    pixelBufferLock.lock()
    defer { pixelBufferLock.unlock() }
    guard let buffer = latestPixelBuffer else { return nil }
    latestPixelBuffer = nil
    return Unmanaged.passRetained(buffer)
  }
}
