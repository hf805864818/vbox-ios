/// 平台层：网盘播放兜底链（UI-F21）。
///
/// 唯一真相源：iOS `vbox/Views/PlayerViewsV2.swift`
///   - 状态字段 `quarkFallbackURL` / `quarkFallbackHeaders` / `quarkFallbackSource`
///     / `quarkFallbackAttempted` / `quarkFallbackTimeoutTask`（L1027-1031）；
///   - 解析结果进入播放器时装载兜底链（`playResolvedDriveVideo`，L2519-2536）；
///   - 切换兜底 `switchToQuarkFallback(reason:)`（L2538-2558）：未尝试过 + 兜底地址
///     非空 → 置 `attempted`、取消超时任务、headers 缺省空表、source 缺省
///     `v2-play-m3u8`，随后重开播放；
///   - 首帧超时任务 `scheduleQuarkPrimaryFallbackTimeout`（L2560-2576）：**8 秒**后仍
///     在加载且未 readyToPlay → 以「首帧超时」原因切换；
///   - 失败判据：`isHTTPForbidden`（L4406-4409，文本含 `403` / `forbidden`）、
///     `isQuarkConnectionLost`（L4503-4513，`NSURLErrorDomain` 码 `-1/-1005/
///     networkConnectionLost/cannotConnectToHost` 或文本含 `network connection
///     was lost` / `connection was lost` / `未知错误`）。
///
/// 与既有分层的分工：
/// - 兜底**线路**由各盘客户端（Quark / UC / Aliyun）按 iOS 主/兜底拓扑派生，
///   经 `CloudPlayItem` 缓存携带；
/// - 本文件只做**判据 + 状态机 + 线路落地**（Go 代理注册），不触网取链。
library;

import '../../domain/entities/player/player.dart';
import 'go_proxy_client.dart';
import 'playback_headers.dart';

/// 网盘播放线路（主线路与兜底线路共用同一描述）。
///
/// 对齐 iOS `PlayResult{url, headers, source, fallbackURL, fallbackHeaders,
/// fallbackSource}` 中「单条线路」的语义；[source] 为线路标记
/// （`download_url` / `v2-play-m3u8` / `v2-play` / `transcode`），决定夸克 Go
/// 代理的路径前缀（`quark-m3u8` / `quark-stream`，见 iOS L2533-2535 / L2514）。
class PanPlaybackLine {
  /// 构造。
  const PanPlaybackLine({
    required this.url,
    this.headers = const <String, String>{},
    this.source = '',
    this.useQuarkProxy = false,
    this.useStreamProxy = false,
  });

  /// 线路地址（上游直链，未注册代理）。
  final String url;

  /// 线路请求头（鉴权 / Referer；夸克走 Go 代理时由代理注入，此处仅作降级直链用）。
  final Map<String, String> headers;

  /// 线路标记（决定代理路径前缀 / 兼容性提示）。
  final String source;

  /// 是否走夸克 Go 代理（`registerQuarkStream`）；否则 HLS 走通用 `registerStream`。
  final bool useQuarkProxy;

  /// 是否**强制**走通用本地代理（`registerStream`），即使线路非 HLS。
  ///
  /// 对齐 iOS `playDriveVideo`（`PlayerViewsV2.swift:3814-3825`）：百度 PCS 直链
  /// （`baidupcs.com` / `d.pcs.baidu.com`）经本地代理（`provider:"baidu"`）注入合并
  /// 后的 Cookie / UA / Referer，而非播放器直连。非 HLS 且该标记为 false 时维持
  /// 「直链回落」语义。
  final bool useStreamProxy;

  /// 线路是否可用（地址非空）。
  bool get isUsable => url.isNotEmpty;

  /// 是否 HLS（m3u8）。
  bool get isHls => url.toLowerCase().contains('.m3u8');

  /// 线路标记（缺省按 URL 是否 HLS 推导，对齐 iOS 主线路标记
  /// `download_url` / `v2-play-m3u8`）。
  String get effectiveSource => source.isNotEmpty
      ? source
      : (isHls ? 'v2-play-m3u8' : 'download_url');

  @override
  String toString() => 'PanPlaybackLine($source, $url)';
}

/// 兜底触发原因（对齐 iOS `switchToQuarkFallback(reason:)` 的原因文案）。
enum PanFallbackTrigger {
  /// 原画线路 403（iOS「原画线路 403」）。
  forbidden('原画线路 403'),

  /// 原画线路连接中断（iOS「原画线路连接中断」）。
  connectionLost('原画线路连接中断'),

  /// 原画线路首帧超时（iOS「首帧超时」）。
  firstFrameTimeout('首帧超时');

  const PanFallbackTrigger(this.reason);

  /// 原因文案。
  final String reason;
}

/// 网盘播放兜底链状态机（对齐 iOS 五个 `quarkFallback*` 字段）。
///
/// [fallback] 为不可变的兜底线路；[attempted] 为可变的一次性标记
/// （对齐 iOS `quarkFallbackAttempted`，保证兜底只切一次）。
class PanFallbackChain {
  /// 构造。
  PanFallbackChain({this.fallback, this.attempted = false});

  /// 兜底线路（为 null 表示该资源无兜底链）。
  final PanPlaybackLine? fallback;

  /// 是否已尝试过兜底（对齐 iOS `quarkFallbackAttempted`）。
  bool attempted;

  /// 首帧超时阈值（对齐 iOS `scheduleQuarkPrimaryFallbackTimeout` 的 8 秒）。
  static const Duration firstFrameTimeout = Duration(seconds: 8);

  /// 是否具备可切换的兜底线路（对齐 iOS `guard !attempted, let url, !url.isEmpty`）。
  bool get available =>
      fallback != null && fallback!.isUsable && !attempted;

  /// 认领本次兜底切换（对齐 iOS：置 `attempted = true` 并取消超时任务）。
  ///
  /// 返回 false 表示不可切换（无兜底线路 / 已尝试过）——调用方不应切换。
  bool claim(PanFallbackTrigger trigger) {
    if (!available) return false;
    attempted = true;
    lastTrigger = trigger;
    return true;
  }

  /// 最近一次触发原因（可观测 / 日志）。
  PanFallbackTrigger? lastTrigger;

  /// 文本是否命中 HTTP 403 / forbidden（对齐 iOS `isHTTPForbidden`）。
  static bool isForbidden(String text) {
    final String t = text.toLowerCase();
    return t.contains('403') || t.contains('forbidden');
  }

  /// 文本是否命中「连接中断」（对齐 iOS `isQuarkConnectionLost` 的文本分支）。
  static bool isConnectionLost(String text) {
    final String t = text.toLowerCase();
    return t.contains('network connection was lost') ||
        t.contains('connection was lost') ||
        t.contains('未知错误') ||
        t.contains('连接中断') ||
        t.contains('连接被中断');
  }

  /// 文本是否命中「文件断流」（P2 播放中重新取链的判据）。
  ///
  /// 百度直链签名（time/expires/sign）或 Node 代理 `pst` 会话在拖进度/重连时
  /// 失效，内核表现为 `partial file` / `Failed to open` / `Seek failed`。
  /// 命中时**优先重新取链**（换一条新签名直链续播），而非切换缓存兜底线路。
  static bool isStreamBroken(String text) {
    final String t = text.toLowerCase();
    return t.contains('partial file') ||
        t.contains('failed to open') ||
        t.contains('seek failed');
  }

  /// 由错误文案归类兜底触发原因（对齐 iOS：先判 403，再判连接中断）。
  static PanFallbackTrigger? classifyFailure(String text) {
    if (isForbidden(text)) return PanFallbackTrigger.forbidden;
    if (isConnectionLost(text)) return PanFallbackTrigger.connectionLost;
    return null;
  }
}

/// 线路落地：把上游线路解析为可播放的 [PlayerSource]（对齐 iOS 线路注册语义）。
///
/// - 夸克线路：经 Go 代理 `registerQuarkStream`（`source` 决定 `quark-m3u8` /
///   `quark-stream` 前缀，对齐 iOS L2514 / L2533-2535）；代理接管后返回本地地址且
///   不带请求头（鉴权由 Go 层注入，对齐 iOS `playbackHeaders = [:]`）。
/// - 其余线路：HLS（m3u8）或显式 [PanPlaybackLine.useStreamProxy]（百度 PCS
///   直链，对齐 iOS `provider:"baidu"`）经通用 `registerStream`；其余非 HLS 直接
///   回落带原请求头。
/// - 代理未启动 / 不可用 / 未返回合法本地地址 → 一律回落直链并保留原请求头
///   （对齐 iOS `guard isRunning else { return upstreamURL }` 降级直链）。
Future<PlayerSource> resolvePanPlaybackLine(
  PanPlaybackLine line, {
  String? title,
  String? provider,
}) async {
  final String url = line.url;
  // 集中层固化「转码 m3u8 不注入 UA/Referer」（对齐 iOS 步骤7 特例，F-P12）：
  // 各盘取链与兜底线路落地共用同一判据，防特例在消费点遗漏。
  final Map<String, String> headers =
      PlaybackHeaders.guardTranscode(url: url, headers: line.headers);
  // F-P28：provider 随源透传（按盘内核策略的分派键，非网盘调用方为 null）。
  PlayerSource direct() => PlayerSource(
        url: url,
        headers: headers,
        title: title,
        provider: provider,
      );

  if (!line.isUsable) return direct();

  if (line.useQuarkProxy) {
    try {
      final GoProxyClient proxy = GoProxyRegistry.instance;
      if (!proxy.isRunning) {
        final String started = await proxy.start();
        if (!started.startsWith('ok')) return direct();
      }
      final String proxied = await proxy.registerQuarkStream(
        upstreamUrl: url,
        cookie: headers['Cookie'] ?? '',
        source: line.effectiveSource,
      );
      if (proxied.startsWith('http://127.0.0.1')) {
        return PlayerSource(url: proxied, title: title, provider: provider);
      }
    } catch (_) {
      // 代理异常 → 回落直链。
    }
    return direct();
  }

  if (!line.isHls && !line.useStreamProxy) return direct();
  try {
    final GoProxyClient proxy = GoProxyRegistry.instance;
    if (!proxy.isRunning) {
      final String started = await proxy.start();
      if (!started.startsWith('ok')) return direct();
    }
    final String proxied = await proxy.registerStream(
      upstreamUrl: url,
      headers: headers,
    );
    if (proxied.startsWith('http://127.0.0.1')) {
      return PlayerSource(url: proxied, title: title, provider: provider);
    }
  } catch (_) {
    // 代理异常 → 回落直链。
  }
  return direct();
}

/// 构造完整播放源（主线路经 Go 代理落地 + 携带兜底线路）。
///
/// 对齐 iOS `PlayResult` → 播放器装载语义：主线路按 [primary] 注册代理后作为
/// [PlayerSource.url]；[fallback]（若可用）**保持上游直链**，不做代理注册
/// （兜底触发时再由播放页经 [resolvePanPlaybackLine] 落地，避免与主线路共享
/// stream id，对齐 iOS L2529-L2539）。
Future<PlayerSource> resolvePanSource({
  required PanPlaybackLine primary,
  PanPlaybackLine? fallback,
  String? title,
  String? provider,
}) async {
  final PlayerSource main = await resolvePanPlaybackLine(
    primary,
    title: title,
    provider: provider,
  );
  // 仅保留「可用」的兜底线路（地址非空），否则视为无兜底。
  final PanPlaybackLine? fb =
      (fallback != null && fallback.isUsable) ? fallback : null;
  return PlayerSource(
    url: main.url,
    headers: main.headers,
    title: title,
    mimeType: main.mimeType,
    source: primary.effectiveSource,
    fallbackUrl: fb?.url,
    // 兜底线路同样过集中层特例守卫（承载到 [PlayerSource] 的兜底头）。
    fallbackHeaders: PlaybackHeaders.guardTranscode(
      url: fb?.url ?? '',
      headers: fb?.headers ?? const <String, String>{},
    ),
    fallbackSource: fb?.effectiveSource ?? '',
    fallbackUseQuarkProxy: fb?.useQuarkProxy ?? false,
    // F-P28：provider 随源透传（按盘内核策略的分派键）。
    provider: provider,
  );
}