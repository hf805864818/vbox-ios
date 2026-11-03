/// 批次 F · UI-F21：播放页兜底链接线（403 / 断连 / 首帧超时 → 切兜底）。
///
/// 对齐 iOS `PlayerViewsV2.swift`：
///   · `.failed` 分支 403 / 断连 → `switchToQuarkFallback`（L4226-L4235）；
///   · 首帧 8s 超时 → `switchToQuarkFallback(reason: "首帧超时")`（L2560-L2576）；
///   · 兜底不可用 / 已尝试过 → 回落错误视图（`failPlayback`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/platform/player/danmaku/danmaku_service.dart';
import 'package:vbox/platform/player/go_proxy_client.dart';
import 'package:vbox/platform/player/player_channel_bridge.dart';
import 'package:vbox/platform/player/player_controller.dart';
import 'package:vbox/platform/player/playback_route.dart';
import 'package:vbox/presentation/pages/player/player_page.dart';
import 'package:vbox/presentation/theme/theme.dart';
import 'package:vbox/presentation/widgets/player/player_error_view.dart';

class _NoopBridge implements PlayerChannelBridge {
  @override
  Future<Object?> invoke(String method, [Object? arguments]) async => null;

  @override
  Stream<Map<String, Object?>> events() =>
      const Stream<Map<String, Object?>>.empty();

  @override
  Future<void> dispose() async {}
}

/// 记录 `open` 的播放源，并可主动上报错误 / 首帧尺寸。
class _RecordingPlayerController extends PlayerController {
  _RecordingPlayerController()
      : super(
          bridge: _NoopBridge(),
          backendChain: const <PlayerBackend>[PlayerBackend.media3],
          selectInitialBackend: (_, PlaybackRoute route) => PlayerBackend.media3,
        );

  final List<PlayerSource> opened = <PlayerSource>[];

  @override
  Future<void> open(PlayerSource source, {PlaybackRoute? route}) async =>
      opened.add(source);

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seekTo(int positionMs) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setVolume(double volume) async {}

  void emitError(String message, {bool fatal = true}) =>
      onError?.call(message, fatal: fatal);

  void emitVideoSize(int width, int height) =>
      onVideoSize?.call(width, height);
}

/// 离线弹幕源（404 → 空结果，不触网）。
DanmakuService _offlineDanmaku() => DanmakuService(
      client: MockClient((http.Request r) async => http.Response('', 404)),
      baseUrl: 'https://dm.test',
    );

/// 带兜底线路的网盘源（主=原画 download_url，兜底=转码 m3u8）。
PlayerSource _panSourceWithFallback() => const PlayerSource(
      url: 'http://u/original.mp4',
      headers: <String, String>{'Cookie': 'ck'},
      source: 'download_url',
      fallbackUrl: 'http://u/transcode.m3u8',
      fallbackSource: 'v2-play-m3u8',
    );

Widget _host(Widget child) => MaterialApp(
      theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
      home: child,
    );

Future<void> _pumpPlayer(WidgetTester tester, _RecordingPlayerController p,
    PlayerSource source) async {
  await tester.pumpWidget(_host(PlayerPage(
    controller: p,
    source: source,
    title: '示例片',
    danmakuService: _offlineDanmaku(),
  )));
  // 让 `_enter` → `_openSource` 的异步链跑完（_openingInFlight 归位）。
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() {
    GoProxyRegistry.instance = const NoopGoProxyClient();
  });

  testWidgets('运行期 403 → 自动切兜底线路并重开播放', (WidgetTester tester) async {
    final _RecordingPlayerController player = _RecordingPlayerController();
    await _pumpPlayer(tester, player, _panSourceWithFallback());
    expect(player.opened.length, 1);
    expect(player.opened.first.url, 'http://u/original.mp4');

    player.emitError('后端 media3 打开失败：HTTP 403 Forbidden');
    await tester.pump();
    await tester.pump();

    expect(player.opened.length, 2);
    expect(player.opened.last.url, 'http://u/transcode.m3u8');
    // 切换成功 → 不显示错误视图。
    expect(find.byType(PlayerErrorWithLogsView), findsNothing);
  });

  testWidgets('运行期连接中断 → 自动切兜底线路', (WidgetTester tester) async {
    final _RecordingPlayerController player = _RecordingPlayerController();
    await _pumpPlayer(tester, player, _panSourceWithFallback());

    player.emitError('The network connection was lost');
    await tester.pump();
    await tester.pump();

    expect(player.opened.length, 2);
    expect(player.opened.last.url, 'http://u/transcode.m3u8');
  });

  testWidgets('首帧 8s 超时 → 切兜底线路', (WidgetTester tester) async {
    final _RecordingPlayerController player = _RecordingPlayerController();
    await _pumpPlayer(tester, player, _panSourceWithFallback());
    expect(player.opened.length, 1);

    // 推进 9s（> 8s 阈值，未上报首帧）。
    await tester.pump(const Duration(seconds: 9));
    await tester.pump();

    expect(player.opened.length, 2);
    expect(player.opened.last.url, 'http://u/transcode.m3u8');
  });

  testWidgets('首帧就绪 → 8s 后不切兜底', (WidgetTester tester) async {
    final _RecordingPlayerController player = _RecordingPlayerController();
    await _pumpPlayer(tester, player, _panSourceWithFallback());

    player.emitVideoSize(1920, 1080);
    await tester.pump();
    await tester.pump(const Duration(seconds: 9));
    await tester.pump();

    expect(player.opened.length, 1);
  });

  testWidgets('兜底全失败 → 出错误视图', (WidgetTester tester) async {
    final _RecordingPlayerController player = _RecordingPlayerController();
    await _pumpPlayer(tester, player, _panSourceWithFallback());

    // 首次 403 → 切兜底（已尝试）。
    player.emitError('HTTP 403');
    await tester.pump();
    await tester.pump();
    expect(player.opened.length, 2);

    // 兜底线路再次 403 → 不再切换，回落错误视图。
    player.emitError('HTTP 403');
    await tester.pump();
    await tester.pump();
    expect(player.opened.length, 2);
    expect(find.byType(PlayerErrorWithLogsView), findsOneWidget);
  });

  testWidgets('无兜底线路 → 403 直接出错误视图', (WidgetTester tester) async {
    final _RecordingPlayerController player = _RecordingPlayerController();
    await _pumpPlayer(
      tester,
      player,
      const PlayerSource(url: 'http://u/plain.mp4'),
    );

    player.emitError('HTTP 403');
    await tester.pump();
    await tester.pump();

    expect(player.opened.length, 1);
    expect(find.byType(PlayerErrorWithLogsView), findsOneWidget);
  });
}