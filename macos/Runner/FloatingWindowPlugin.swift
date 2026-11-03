//
//  FloatingWindowPlugin.swift
//  Runner
//
//  批次 D · D2：应用内浮窗平台通道（macOS 腿，桌面唯一 PiP 兜底形态）。
//
//  对齐 iOS `PiPHelper.showFloatingWindow`（PlayerViewsV2.swift:328-509）：
//   - 浮窗承载 Dart 传来的播放器截图（RepaintBoundary → PNG bytes），
//     `update` 换图模拟播放；
//   - 手势三件套：单击 → toggle 播放 / 双击 → 恢复全屏 / 拖动 → 自由移动 +
//     松手吸附最近左右边缘；
//   - 右上关闭按钮（对齐 xmark.circle.fill closeBtn）。
//
//  MethodChannel `com.vbox.player/floating`：isAvailable / show / update /
//  hide / dispose（setMedia / updateProgress 接口对齐，浮窗不消费）。
//  EventChannel `com.vbox.player/floating/events`：{type: tap|doubleTap|close}。
//
//  桌面无悬浮权限概念：isAvailable 恒 true（窗口创建失败由 show 返回 false）。
//

import AppKit
import FlutterMacOS

@objc public class FloatingWindowPlugin: NSObject, FlutterPlugin,
  FlutterStreamHandler, NSGestureRecognizerDelegate
{
  private var window: NSWindow?
  private var snapshotView: NSImageView?
  private var eventSink: FlutterEventSink?
  private var panOrigin: NSPoint = .zero

  private var windowWidth: CGFloat = 200
  private var windowHeight: CGFloat = 112

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FloatingWindowPlugin()
    let channel = FlutterMethodChannel(
      name: "com.vbox.player/floating", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(instance, channel: channel)
    let eventChannel = FlutterEventChannel(
      name: "com.vbox.player/floating/events", binaryMessenger: registrar.messenger)
    eventChannel.setStreamHandler(instance)
  }

  // ─────────────── FlutterStreamHandler ───────────────

  public func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  // ─────────────── MethodChannel ───────────────

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(true)
    case "show":
      let args = call.arguments as? [String: Any]
      let bytes = args?["bytes"] as? FlutterStandardTypedData
      if let w = args?["width"] as? NSNumber { windowWidth = CGFloat(w.doubleValue) }
      if let h = args?["height"] as? NSNumber { windowHeight = CGFloat(h.doubleValue) }
      result(showWindow(png: bytes?.data))
    case "update":
      let args = call.arguments as? [String: Any]
      if let data = (args?["bytes"] as? FlutterStandardTypedData)?.data {
        applySnapshot(data)
      }
      result(nil)
    case "hide", "dispose":
      closeWindow()
      result(nil)
    case "setMedia", "updateProgress":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func showWindow(png: Data?) -> Bool {
    closeWindow()
    guard let screen = NSScreen.main else { return false }

    let width = min(windowWidth, screen.frame.width - 16)
    let height = min(windowHeight, screen.frame.height - 16)
    // 初始位：屏幕右侧偏上（对齐 iOS (screenW-220, 80)）。
    let frame = NSRect(
      x: screen.frame.maxX - width - 20,
      y: screen.frame.maxY - height - 80,
      width: width, height: height)

    // 无边框置顶小窗（对齐 iOS windowLevel alert+10 → .floating）。
    let win = NSWindow(
      contentRect: frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false)
    win.level = .floating
    win.backgroundColor = .clear
    win.isOpaque = false
    win.hasShadow = true
    win.ignoresMouseEvents = false

    let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.black.cgColor
    container.layer?.cornerRadius = 12
    container.layer?.masksToBounds = true

    let snapshot = NSImageView(frame: container.bounds)
    snapshot.autoresizingMask = [.width, .height]
    snapshot.imageScaling = .scaleProportionallyUpOrDown
    container.addSubview(snapshot)

    // 关闭按钮（对齐 iOS xmark.circle.fill）。
    let close = NSButton(frame: NSRect(
      x: frame.size.width - 28, y: frame.size.height - 28, width: 28, height: 28))
    close.isBordered = false
    close.title = ""
    close.image = NSImage(
      systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭")
    close.contentTintColor = .white
    close.target = self
    close.action = #selector(closeTapped)
    container.addSubview(close)

    // 手势：单击 toggle / 双击恢复全屏 / 拖动移动窗口 + 松手吸附。
    let single = NSClickGestureRecognizer(
      target: self, action: #selector(singleTapped(_:)))
    single.numberOfClicksRequired = 1
    single.delegate = self
    container.addGestureRecognizer(single)
    let double = NSClickGestureRecognizer(
      target: self, action: #selector(doubleTapped(_:)))
    double.numberOfClicksRequired = 2
    container.addGestureRecognizer(double)
    let pan = NSPanGestureRecognizer(
      target: self, action: #selector(panned(_:)))
    container.addGestureRecognizer(pan)

    win.contentView = container
    if let png = png { applySnapshot(png, to: snapshot) }

    win.makeKeyAndOrderFront(nil)
    window = win
    snapshotView = snapshot
    return true
  }

  private func applySnapshot(_ data: Data, to view: NSImageView? = nil) {
    guard let target = view ?? snapshotView else { return }
    target.image = NSImage(data: data)
  }

  private func closeWindow() {
    window?.orderOut(nil)
    window = nil
    snapshotView = nil
  }

  @objc private func closeTapped() {
    emit("close")
  }

  @objc private func singleTapped(_ g: NSClickGestureRecognizer) {
    emit("tap")
  }

  @objc private func doubleTapped(_ g: NSClickGestureRecognizer) {
    emit("doubleTap")
  }

  // 单击让位于双击（对齐 iOS tapGesture.require(toFail: doubleTap)）。
  public func gestureRecognizer(
    _ gestureRecognizer: NSGestureRecognizer,
    shouldAttemptToRecognizeWith event: NSEvent
  ) -> Bool {
    if let click = gestureRecognizer as? NSClickGestureRecognizer,
      click.numberOfClicksRequired == 1
    {
      for other in (gestureRecognizer.view?.gestureRecognizers ?? []) {
        if let d = other as? NSClickGestureRecognizer,
          d.numberOfClicksRequired == 2
        {
          return !d.state.isActive
        }
      }
    }
    return true
  }

  @objc private func panned(_ g: NSPanGestureRecognizer) {
    guard let win = window, let screen = NSScreen.main else { return }
    switch g.state {
    case .began:
      panOrigin = win.frame.origin
    case .changed:
      let t = g.translation(in: win.contentView)
      win.setFrameOrigin(
        NSPoint(x: panOrigin.x + t.x, y: panOrigin.y - t.y))
    case .ended:
      // 吸附最近左右边缘（对齐 iOS handlePan ended：x = w/2+8 或 screenW-w/2-8）。
      var origin = win.frame.origin
      let screenW = screen.frame.width
      let centerX = origin.x + win.frame.width / 2
      origin.x = centerX < screenW / 2 ? 8 : screenW - win.frame.width - 8
      // y 限制在屏内（对齐 iOS minY = h/2+50 / maxY = screenH-h/2-50）。
      let minY = 50.0
      let maxY = screen.frame.height - win.frame.height - 50
      origin.y = min(max(origin.y, minY), max(maxY, minY))
      win.setFrameOrigin(origin)
    default:
      break
    }
  }

  private func emit(_ type: String) {
    eventSink?(["type": type])
  }
}

extension NSGestureRecognizer.State {
  var isActive: Bool {
    self == .began || self == .changed
  }
}
