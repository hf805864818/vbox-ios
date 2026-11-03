import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 批次 Q · Q-04：JSC 引擎模块预加载（与 Android MainActivity.loadLibrary 对称）。
    // 先于 Dart FFI open("libvbox_jsc.dylib") 触发：经 App 主二进制
    // @executable_path/../Frameworks rpath 命中 bundle-jsc-macos.sh 拷入的 dylib。
    // 失败不 crash：Dart 侧 jsc_ffi 的 isAvailable=false，工厂按 D6 自动降级 QuickJS。
    if dlopen("libvbox_jsc.dylib", RTLD_NOW) == nil {
      NSLog("vbox: libvbox_jsc 加载失败，JSC 将按 D6 降级 QuickJS")
    }

    // G-02-B：播放器插件（非插件工程手动注册，与 Android MainActivity 同模式）。
    // Flutter 3.47.5+ 起 registrar(forPlugin:) 返回非可选 any FlutterPluginRegistrar，直接取值。
    let registrar = flutterViewController.registrar(forPlugin: "PlayerPlugin")
    PlayerPlugin.register(with: registrar)

    // 批次 D · D1：屏幕亮度 / 系统音量通道（Core Audio 系统音量 + 会话级亮度）。
    let screenControlsRegistrar = flutterViewController.registrar(
      forPlugin: "ScreenControlsPlugin")
    ScreenControlsPlugin.register(with: screenControlsRegistrar)

    // 批次 D · D2：应用内浮窗通道（置顶无边框小窗承载截图快照 + 三手势回传）。
    let floatingRegistrar = flutterViewController.registrar(
      forPlugin: "FloatingWindowPlugin")
    FloatingWindowPlugin.register(with: floatingRegistrar)

    // 批次 D · D3：音乐锁屏媒体会话通道（MPNowPlayingInfoCenter + MPRemoteCommandCenter）。
    let mediaSessionRegistrar = flutterViewController.registrar(
      forPlugin: "MusicMediaSessionPlugin")
    MusicMediaSessionPlugin.register(with: mediaSessionRegistrar)

    super.awakeFromNib()
  }
}
