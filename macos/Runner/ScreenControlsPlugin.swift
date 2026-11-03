//
//  ScreenControlsPlugin.swift
//  Runner
//
//  批次 D · D1：屏幕亮度 / 系统音量平台通道（macOS 腿）。
//
//  MethodChannel `com.vbox.player/screen_controls`（与 Dart
//  `MethodChannelScreenControlsBridge` / Android `ScreenControlsPlugin.kt`
//  同一 wire 协议）：getBrightness / setBrightness / getVolume / setVolume。
//
//  差异登记（对齐实施方案 D1）：
//   - 音量：Core Audio default output device 的
//     `kAudioDevicePropertyVolumeScalar`（对齐 iOS `MPVolumeView` 系统音量语义）；
//   - 亮度：macOS 无公开系统亮度 API（私有 CoreDisplay 不采用）→ 会话级
//     内存值（进程内一致，重启回默认；桌面亮度为会话级，登记）。
//

import CoreAudio
import FlutterMacOS
import Foundation

@objc public class ScreenControlsPlugin: NSObject, FlutterPlugin {
  private static var sessionBrightness: Double = 0.5

  private static func defaultOutputDevice() -> AudioDeviceID {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    return status == noErr ? deviceID : 0
  }

  private static func systemVolume() -> Double {
    let device = defaultOutputDevice()
    guard device != 0 else { return 0.5 }
    var volume = Float32(0)
    var size = UInt32(MemoryLayout<Float32>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyVolumeScalar,
      mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectGetPropertyData(
      device, &address, 0, nil, &size, &volume)
    guard status == noErr else { return 0.5 }
    return Double(volume)
  }

  private static func setSystemVolume(_ value: Double) {
    let device = defaultOutputDevice()
    guard device != 0 else { return }
    var volume = Float32(max(0, min(1, value)))
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyVolumeScalar,
      mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
    AudioObjectSetPropertyData(
      device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.vbox.player/screen_controls", binaryMessenger: registrar.messenger)
    let instance = ScreenControlsPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getBrightness":
      result(Self.sessionBrightness)
    case "setBrightness":
      let v = (call.arguments as? NSNumber)?.doubleValue ?? 0.5
      Self.sessionBrightness = max(0, min(1, v))
      result(nil)
    case "getVolume":
      result(Self.systemVolume())
    case "setVolume":
      Self.setSystemVolume((call.arguments as? NSNumber)?.doubleValue ?? 0.5)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
