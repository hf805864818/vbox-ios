/// 平台层：Go 代理客户端抽象（批次 C · C-10 Go 代理三端绑定）。
///
/// 对齐 iOS `GoProxyManager.swift`（封装 gomobile 生成的 Quarkproxy 框架）：
///  - `start` / `stop`：启动 / 停止本地 HTTP 代理（默认端口 10078）
///  - `registerStream` / `registerQuarkStream`：注册上游流（m3u8 / 直链），
///    返回本地代理地址（分片重写 + Base64 + 磁盘/内存缓存由 Go 侧完成）
///  - `status` / `clearCache`：状态查询 / 缓存清理
///
/// 三端绑定：
///  - Android / TV：`GoProxyPlugin.kt`（MethodChannel `com.vbox.player/go_proxy`，
///    加载 gomobile 生成的 `libquarkproxy.so`）
///  - macOS：`GoProxyPlugin.swift`（MethodChannel 同名字段，封装 Quarkproxy.xcframework）
///  - Windows：`go_proxy_plugin.cpp`（MethodChannel 同名字段，经 C ABI 调 Go DLL）
///  - iOS：原生侧已有 `GoProxyManager.swift`（不迁移，仅作语义对齐）
///
/// 未接线 / 原生不可用时：降级 [NoopGoProxyClient] —— `registerStream` 返回原始
/// URL（对齐 iOS `guard isRunning else { return upstreamURL }` 降级直链语义）。
library;

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Go 代理客户端抽象（可注入）。
abstract class GoProxyClient {
  /// 默认端口（对齐 iOS GoProxyManager.port = 10078）。
  static const int kDefaultPort = 10078;

  /// 是否已启动。
  bool get isRunning;

  /// 启动本地代理（[port] 缺省 [kDefaultPort]）。
  ///
  /// 返回 `ok:<实际端口>` 或 `error:<原因>`（与 iOS QuarkproxyStartProxy 同格式）。
  Future<String> start({int port = kDefaultPort});

  /// 停止代理。
  Future<void> stop();

  /// 注册通用播放流（阿里云盘等非夸克网盘）。
  ///
  /// 返回本地代理地址；未运行时返回 [upstreamUrl]（降级直链）。
  Future<String> registerStream({
    required String upstreamUrl,
    required Map<String, String> headers,
  });

  /// 注册夸克播放流（对齐 iOS `registerQuarkStream`）。
  ///
  /// 按 [source] 标记返回 `quark-m3u8` / `quark-stream` 路径前缀，
  /// 供上层区分解码器；未运行时返回 [upstreamUrl]（降级直链）。
  Future<String> registerQuarkStream({
    required String upstreamUrl,
    required String cookie,
    String? deviceID,
    String source = '',
  });

  /// 查询状态（含预取统计；未启动返回 `stopped`）。
  Future<String> status();

  /// 清空磁盘缓存。
  Future<void> clearCache();
}

/// 夸克桌面 UA（对齐 iOS GoProxyManager.quarkDesktopUA 抓包值）。
const String kQuarkDesktopUA =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) quark-cloud-drive/2.5.20 '
    'Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 '
    'Safari/537.36 Channel/pckk_other_ch';

/// 未接线 / 原生不可用时的降级客户端。
///
/// `isRunning=false`；`registerStream` / `registerQuarkStream` 返回原始 URL
/// （对齐 iOS `guard isRunning else { return upstreamURL }` 降级直链）。
class NoopGoProxyClient implements GoProxyClient {
  /// 构造。
  const NoopGoProxyClient();

  @override
  bool get isRunning => false;

  @override
  Future<String> start({int port = GoProxyClient.kDefaultPort}) async =>
      'error:go proxy not integrated';

  @override
  Future<void> stop() async {}

  @override
  Future<String> registerStream({
    required String upstreamUrl,
    required Map<String, String> headers,
  }) async =>
      upstreamUrl;

  @override
  Future<String> registerQuarkStream({
    required String upstreamUrl,
    required String cookie,
    String? deviceID,
    String source = '',
  }) async =>
      upstreamUrl;

  @override
  Future<String> status() async => 'stopped';

  @override
  Future<void> clearCache() async {}
}

/// Go 代理通道桥（可注入；测试注入 fake 桥）。
abstract class GoProxyBridge {
  /// 调用原生 Go 代理方法（`start` / `stop` / `registerStream` /
  /// `registerQuarkStream` / `status` / `clearCache`）。
  Future<String> invoke(String method, [Map<String, Object?>? arguments]);
}

/// 真实平台通道实现（Android / macOS / Windows 原生插件 ↔ Dart）。
class MethodChannelGoProxyBridge implements GoProxyBridge {
  /// 构造。
  MethodChannelGoProxyBridge()
      : _channel = const MethodChannel('com.vbox.player/go_proxy');

  final MethodChannel _channel;

  @override
  Future<String> invoke(String method, [Map<String, Object?>? arguments]) async {
    final Object? result = await _channel.invokeMethod<Object?>(method, arguments);
    if (result == null) return '';
    return result.toString();
  }
}

/// 平台通道 Go 代理客户端实现。
///
/// 端口选择与 iOS 对齐：优先 [GoProxyClient.kDefaultPort]（10078），
/// 失败时依次尝试备用端口（10079 / 18080 / 18082 / 19090）。
class MethodChannelGoProxyClient implements GoProxyClient {
  /// 构造（[bridge] 可注入测试假桥；[defaultPort] 覆盖默认端口便于测试）。
  MethodChannelGoProxyClient({GoProxyBridge? bridge, this.defaultPort = GoProxyClient.kDefaultPort})
      : _bridge = bridge ?? MethodChannelGoProxyBridge();

  /// 备用端口序列（对齐 iOS GoProxyManager.tryFallbackPorts）。
  static const List<int> kFallbackPorts = <int>[10079, 18080, 18082, 19090];

  final GoProxyBridge _bridge;
  final int defaultPort;

  bool _running = false;

  @override
  bool get isRunning => _running;

  @override
  Future<String> start({int port = GoProxyClient.kDefaultPort}) async {
    final int target = port == GoProxyClient.kDefaultPort ? defaultPort : port;
    String result = await _bridge.invoke('start', <String, Object?>{'port': target});
    if (result.startsWith('ok')) {
      _running = true;
      return result;
    }
    // 备用端口
    for (final int fallback in kFallbackPorts) {
      result = await _bridge.invoke('start', <String, Object?>{'port': fallback});
      if (result.startsWith('ok')) {
        _running = true;
        return result;
      }
    }
    _running = false;
    return result;
  }

  @override
  Future<void> stop() async {
    await _bridge.invoke('stop');
    _running = false;
  }

  @override
  Future<String> registerStream({
    required String upstreamUrl,
    required Map<String, String> headers,
  }) async {
    if (!_running) return upstreamUrl;
    final String proxyUrl = await _bridge.invoke(
      'registerStream',
      <String, Object?>{
        'upstreamUrl': upstreamUrl,
        'headers': headers,
      },
    );
    return _validProxyUrl(proxyUrl) ? proxyUrl : upstreamUrl;
  }

  @override
  Future<String> registerQuarkStream({
    required String upstreamUrl,
    required String cookie,
    String? deviceID,
    String source = '',
  }) async {
    if (!_running) return upstreamUrl;
    final Map<String, String> headers = <String, String>{
      'Cookie': cookie,
      'User-Agent': kQuarkDesktopUA,
      'Referer': 'https://pan.quark.cn/',
      'Origin': 'https://pan.quark.cn',
      'Accept': '*/*',
      'Accept-Encoding': 'br, gzip, deflate',
      if (deviceID != null && deviceID.isNotEmpty) 'X-Device-Id': deviceID,
    };
    final String proxyUrl = await _bridge.invoke(
      'registerStream',
      <String, Object?>{
        'upstreamUrl': upstreamUrl,
        'headers': headers,
      },
    );
    if (!_validProxyUrl(proxyUrl)) return upstreamUrl;
    // 按 source 标记路径前缀（对齐 iOS：v2-play-m3u8 → quark-m3u8，其余 → quark-stream）。
    final String prefix =
        source == 'v2-play-m3u8' ? 'quark-m3u8' : 'quark-stream';
    return proxyUrl.replaceFirst('/play?', '/$prefix/play?');
  }

  @override
  Future<String> status() async => _bridge.invoke('status');

  @override
  Future<void> clearCache() async {
    await _bridge.invoke('clearCache');
  }

  /// 是否合法本地代理地址（`http://127.0.0.1` 前缀）。
  bool _validProxyUrl(String url) => url.startsWith('http://127.0.0.1');
}

/// 按平台解析默认 Go 代理客户端。
///
/// Android / macOS / Windows 走原生通道（[MethodChannelGoProxyClient]，
/// 对齐 iOS `GoProxyManager` 的三端绑定）；iOS / Linux 等无原生绑定 → 降级
/// [NoopGoProxyClient]（`registerStream` 原样返回上游，播放不受影响）。
GoProxyClient createDefaultGoProxyClient() {
  if (Platform.isAndroid || Platform.isWindows || Platform.isMacOS) {
    return MethodChannelGoProxyClient();
  }
  return const NoopGoProxyClient();
}

/// Go 代理客户端注册表：app / 播放链路共享单例（首个消费方懒创建并按平台分派）。
///
/// 对齐 iOS `GoProxyManager.shared`（全局唯一，启动后复用）；懒创建等价 iOS
/// 「启动即拉起」——首次播放前完成，语义一致且不阻塞首屏。
class GoProxyRegistry {
  GoProxyRegistry._();

  static GoProxyClient? _instance;

  /// 共享客户端（懒创建 + 按平台分派）。
  static GoProxyClient get instance =>
      _instance ??= createDefaultGoProxyClient();

  /// 注入替身（测试 / 自定义绑定）。
  static set instance(GoProxyClient value) => _instance = value;
}
