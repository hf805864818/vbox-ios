//
//  MusicMediaSessionPlugin.swift
//  Runner
//
//  批次 D · D3：音乐锁屏媒体会话平台通道（macOS 腿）。
//
//  对齐 iOS `AudioPlayerManager`（AudioPlayerManager.swift:517-583）：
//   - `updateNowPlaying` → `MPNowPlayingInfoCenter.nowPlayingInfo`
//     （title/artist/album/duration/elapsed/rate + 封面经 MPMediaItemArtwork）；
//   - `MPRemoteCommandCenter` 六命令（play/pause/toggle/next/previous/seek）
//     → EventChannel 回派 Dart `_handleMediaCommand`（分派逻辑已在
//     `MusicPlayerController` 就绪）；
//   - `clear` → `nowPlayingInfo = nil` + 命令移除（对齐 iOS 停止清理）。
//
//  MethodChannel `com.vbox.player/music_media`：update / clear。
//  EventChannel `com.vbox.player/music_media/events`：
//  {command: play|pause|toggle|next|previous|seek, positionMs?}。
//

import AppKit
import FlutterMacOS
import MediaPlayer

@objc public class MusicMediaSessionPlugin: NSObject, FlutterPlugin,
  FlutterStreamHandler
{
  private var eventSink: FlutterEventSink?
  // (命令对, target)：clear 时配对移除（对齐 iOS addTarget/removeTarget 语义）。
  // `addTarget(handler:)` 返回 `Any`（ObjC id），故按 Any 持有。
  private var registrations: [(MPRemoteCommand, Any)] = []

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = MusicMediaSessionPlugin()
    let channel = FlutterMethodChannel(
      name: "com.vbox.player/music_media", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(instance, channel: channel)
    let eventChannel = FlutterEventChannel(
      name: "com.vbox.player/music_media/events",
      binaryMessenger: registrar.messenger)
    eventChannel.setStreamHandler(instance)
  }

  // ─────────────── FlutterStreamHandler ───────────────

  public func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    setupRemoteCommands()
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  // ─────────────── MethodChannel ───────────────

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "update":
      updateNowPlaying(call.arguments as? [String: Any])
      result(nil)
    case "clear":
      clearNowPlaying()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func updateNowPlaying(_ args: [String: Any]?) {
    guard let args = args else { return }
    let durationMs = (args["durationMs"] as? NSNumber)?.doubleValue ?? 0
    let positionMs = (args["positionMs"] as? NSNumber)?.doubleValue ?? 0
    let playing = args["playing"] as? Bool ?? false

    var info: [String: Any] = [
      MPMediaItemPropertyTitle: args["title"] as? String ?? "",
      MPMediaItemPropertyArtist: args["artist"] as? String ?? "",
      MPMediaItemPropertyPlaybackDuration: durationMs / 1000.0,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: positionMs / 1000.0,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
    ]
    if let album = args["album"] as? String, !album.isEmpty {
      info[MPMediaItemPropertyAlbumTitle] = album
    }
    if let coverURL = args["coverURL"] as? String, let url = URL(string: coverURL) {
      // 封面（对齐 iOS MPMediaItemArtwork；异步加载网络图，失败忽略）。
      let placeholder = NSImage(size: NSSize(width: 1, height: 1))
      info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: placeholder.size) { _ in
        placeholder
      }
      DispatchQueue.global(qos: .utility).async {
        guard let data = try? Data(contentsOf: url),
          let image = NSImage(data: data)
        else { return }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        updated[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
      }
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private func clearNowPlaying() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    for (command, target) in registrations {
      command.removeTarget(target)
    }
    registrations = []
  }

  // ─────────────── MPRemoteCommandCenter（对齐 AudioPlayerManager:533-574）───

  private func setupRemoteCommands() {
    guard registrations.isEmpty else { return }
    let cc = MPRemoteCommandCenter.shared()

    func add(_ command: MPRemoteCommand, _ name: String) {
      let target = command.addTarget { [weak self] _ in
        self?.eventSink?(["command": name])
        return .success
      }
      registrations.append((command, target))
    }

    add(cc.playCommand, "play")
    add(cc.pauseCommand, "pause")
    add(cc.togglePlayPauseCommand, "toggle")
    add(cc.nextTrackCommand, "next")
    add(cc.previousTrackCommand, "previous")
    let seekTarget = cc.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let e = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      self?.eventSink?([
        "command": "seek",
        "positionMs": Int(e.positionTime * 1000),
      ])
      return .success
    }
    registrations.append((cc.changePlaybackPositionCommand, seekTarget))
  }
}
