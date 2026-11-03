/// 批次 F · UI-F21：网盘播放兜底链（判据 / 状态机 / 线路落地）。
///
/// 对齐 iOS `PlayerViewsV2.swift`：
///   · `isHTTPForbidden`（L4406） / `isQuarkConnectionLost`（L4503）判据；
///   · `switchToQuarkFallback(reason:)`（L2539，仅切一次）+ 8s 首帧超时（L2560）；
///   · `PlayResult` 主/兜底线路装载语义（L2519）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/platform/player/go_proxy_client.dart';
import 'package:vbox/platform/player/pan_fallback_chain.dart';

/// 记录 `registerStream` 调用的 Go 代理替身（返回固定本地地址）。
///
/// 用于断言「百度 PCS 直链经通用本地代理落地」—— 对齐 iOS `playDriveVideo`
/// 的 `provider:"baidu"` 分支。
class _RecordingGoProxyClient implements GoProxyClient {
  _RecordingGoProxyClient();

  final String proxyUrl = 'http://127.0.0.1:10078/play?id=abc';
  final List<Map<String, String>> streamCalls = <Map<String, String>>[];
  bool _running = true;

  @override
  bool get isRunning => _running;

  @override
  Future<String> start({int port = GoProxyClient.kDefaultPort}) async {
    _running = true;
    return 'ok:$port';
  }

  @override
  Future<void> stop() async => _running = false;

  @override
  Future<String> registerStream({
    required String upstreamUrl,
    required Map<String, String> headers,
  }) async {
    streamCalls.add(<String, String>{'url': upstreamUrl, ...headers});
    return proxyUrl;
  }

  @override
  Future<String> registerQuarkStream({
    required String upstreamUrl,
    required String cookie,
    String? deviceID,
    String source = '',
  }) async =>
      proxyUrl;

  @override
  Future<String> status() async => 'running';

  @override
  Future<void> clearCache() async {}
}

void main() {
  group('判据分类（classifyFailure）', () {
    test('HTTP 403 / forbidden → forbidden（优先于连接中断）', () {
      expect(
        PanFallbackChain.classifyFailure('后端 media3 打开失败：HTTP 403'),
        PanFallbackTrigger.forbidden,
      );
      expect(
        PanFallbackChain.classifyFailure('Forbidden'),
        PanFallbackTrigger.forbidden,
      );
    });

    test('连接中断文本 → connectionLost', () {
      for (final String text in <String>[
        'The network connection was lost',
        'connection was lost',
        '未知错误',
        '连接中断',
      ]) {
        expect(
          PanFallbackChain.classifyFailure(text),
          PanFallbackTrigger.connectionLost,
          reason: text,
        );
      }
    });

    test('无关错误 → null（不误触发兜底）', () {
      expect(PanFallbackChain.classifyFailure('解码失败'), isNull);
      expect(PanFallbackChain.classifyFailure('地址不可达（网络错误）'), isNull);
    });
  });

  group('状态机（PanFallbackChain）', () {
    test('无兜底线路 → 不可用，claim 返回 false', () {
      final PanFallbackChain chain = PanFallbackChain();
      expect(chain.available, isFalse);
      expect(chain.claim(PanFallbackTrigger.forbidden), isFalse);
    });

    test('有兜底线路 → 仅可切换一次（对齐 iOS quarkFallbackAttempted）', () {
      final PanFallbackChain chain = PanFallbackChain(
        fallback: const PanPlaybackLine(url: 'http://u/fallback.m3u8'),
      );
      expect(chain.available, isTrue);
      expect(chain.claim(PanFallbackTrigger.forbidden), isTrue);
      expect(chain.lastTrigger, PanFallbackTrigger.forbidden);
      // 已尝试 → 不再可切换（防重复切换 / 死循环）。
      expect(chain.available, isFalse);
      expect(chain.claim(PanFallbackTrigger.connectionLost), isFalse);
    });

    test('首帧超时阈值为 8s（对齐 iOS Task.sleep 8_000_000_000）', () {
      expect(PanFallbackChain.firstFrameTimeout, const Duration(seconds: 8));
    });

    test('线路标记缺省按 URL 推导（m3u8 → v2-play-m3u8，否则 download_url）', () {
      expect(
        const PanPlaybackLine(url: 'http://u/a.m3u8').effectiveSource,
        'v2-play-m3u8',
      );
      expect(
        const PanPlaybackLine(url: 'http://u/a.mp4').effectiveSource,
        'download_url',
      );
      // 显式标记优先。
      expect(
        const PanPlaybackLine(url: 'http://u/a.mp4', source: 'uc_tv_token')
            .effectiveSource,
        'uc_tv_token',
      );
    });
  });

  group('线路落地（resolvePanPlaybackLine / resolvePanSource）', () {
    setUp(() {
      // 测试宿主为 Linux → 默认 NoopGoProxyClient（start 失败 → 降级直链）。
      GoProxyRegistry.instance = const NoopGoProxyClient();
    });

    test('代理不可用 → 降级直链并保留原请求头', () async {
      final PlayerSource source = await resolvePanPlaybackLine(
        const PanPlaybackLine(
          url: 'http://u/transcode.m3u8',
          headers: <String, String>{'Referer': 'https://pan.quark.cn/'},
        ),
        title: '示例片',
      );
      expect(source.url, 'http://u/transcode.m3u8');
      expect(source.headers['Referer'], 'https://pan.quark.cn/');
      expect(source.title, '示例片');
    });

    test('resolvePanSource 携带兜底线路（主线路代理落地 + 兜底直链）', () async {
      final PlayerSource source = await resolvePanSource(
        primary: const PanPlaybackLine(
          url: 'http://u/original.mp4',
          headers: <String, String>{'Cookie': 'ck'},
        ),
        fallback: const PanPlaybackLine(
          url: 'http://u/transcode.m3u8',
          source: 'v2-play-m3u8',
        ),
        title: '示例片',
      );
      expect(source.url, 'http://u/original.mp4');
      expect(source.source, 'download_url');
      expect(source.hasFallback, isTrue);
      expect(source.fallbackUrl, 'http://u/transcode.m3u8');
      expect(source.fallbackSource, 'v2-play-m3u8');
    });

    test('无兜底线路 → hasFallback 为 false', () async {
      final PlayerSource source = await resolvePanSource(
        primary: const PanPlaybackLine(url: 'http://u/original.mp4'),
      );
      expect(source.hasFallback, isFalse);
      expect(source.fallbackSource, isEmpty);
    });

    test('百度 PCS 直链（非 HLS + useStreamProxy）→ 经本地代理落地（F-P09）', () async {
      final _RecordingGoProxyClient proxy = _RecordingGoProxyClient();
      GoProxyRegistry.instance = proxy;
      final PlayerSource source = await resolvePanPlaybackLine(
        const PanPlaybackLine(
          url: 'https://d.pcs.baidu.com/file/abc.mp4',
          headers: <String, String>{
            'Cookie': 'BDUSS=x; STOKEN=y',
            'User-Agent': 'netdisk',
            'Referer': 'https://pan.baidu.com/',
          },
          useStreamProxy: true,
        ),
        title: '百度示例',
      );
      expect(source.url, 'http://127.0.0.1:10078/play?id=abc');
      expect(proxy.streamCalls, hasLength(1));
      expect(
        proxy.streamCalls.single['url'],
        'https://d.pcs.baidu.com/file/abc.mp4',
      );
      expect(proxy.streamCalls.single['Cookie'], 'BDUSS=x; STOKEN=y');
      // 代理接管后不再携带请求头（鉴权由本地代理注入）。
      expect(source.headers, isEmpty);
    });

    test('非 HLS 且未标记 useStreamProxy → 直链回落（不注册代理）', () async {
      final _RecordingGoProxyClient proxy = _RecordingGoProxyClient();
      GoProxyRegistry.instance = proxy;
      final PlayerSource source = await resolvePanPlaybackLine(
        const PanPlaybackLine(
          url: 'https://d.pcs.baidu.com/file/abc.mp4',
          headers: <String, String>{'Cookie': 'ck'},
        ),
      );
      expect(source.url, 'https://d.pcs.baidu.com/file/abc.mp4');
      expect(source.headers['Cookie'], 'ck');
      expect(proxy.streamCalls, isEmpty);
    });
  });
}