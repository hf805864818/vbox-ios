/// 第 5 批 · UI-F18：播放页加载层接线（进入加载 / 首帧收起 / 跳转加载）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/platform/player/danmaku/danmaku_service.dart';
import 'package:vbox/platform/player/player_channel_bridge.dart';
import 'package:vbox/platform/player/player_controller.dart';
import 'package:vbox/platform/player/playback_route.dart';
import 'package:vbox/presentation/pages/player/player_page.dart';
import 'package:vbox/presentation/theme/theme.dart';
import 'package:vbox/presentation/widgets/player/player_loading_overlay.dart';

class _NoopBridge implements PlayerChannelBridge {
  @override
  Future<Object?> invoke(String method, [Object? arguments]) async => null;

  @override
  Stream<Map<String, Object?>> events() =>
      const Stream<Map<String, Object?>>.empty();

  @override
  Future<void> dispose() async {}
}

/// 假播放器控制器：可主动上报首帧尺寸 / 播放状态 / 进度。
class _FakePlayerController extends PlayerController {
  _FakePlayerController()
      : super(
          bridge: _NoopBridge(),
          backendChain: const <PlayerBackend>[PlayerBackend.media3],
          selectInitialBackend: (_, PlaybackRoute route) => PlayerBackend.media3,
        );

  final List<int> seeks = <int>[];

  @override
  Future<void> open(PlayerSource source, {PlaybackRoute? route}) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seekTo(int positionMs) async => seeks.add(positionMs);

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setVolume(double volume) async {}

  /// 上报首帧尺寸（加载层应收起）。
  void emitVideoSize(int width, int height) =>
      onVideoSize?.call(width, height);

  /// 上报播放状态。
  void emitState(PlayerState state) => onStateChanged?.call(state);

  /// 上报进度（跳转加载的完成回执）。
  void emitProgress({required int positionMs, required int durationMs}) {
    onProgress?.call(PlaybackProgress(
      positionMs: positionMs,
      durationMs: durationMs,
      bufferedMs: 0,
    ));
  }
}

/// 离线弹幕源（404 → 空结果，不触网）。
DanmakuService _offlineDanmaku() => DanmakuService(
      client: MockClient((http.Request r) async => http.Response('', 404)),
      baseUrl: 'https://dm.test',
    );

Widget _host(Widget child) => MaterialApp(
      theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
      home: child,
    );

void main() {
  testWidgets('进入播放页显示加载层；首帧上报后收起', (WidgetTester tester) async {
    final _FakePlayerController player = _FakePlayerController();
    await tester.pumpWidget(_host(PlayerPage(
      controller: player,
      source: const PlayerSource(url: 'http://x/y.m3u8'),
      title: '示例片',
      danmakuService: _offlineDanmaku(),
    )));
    await tester.pump();

    expect(find.byType(PlayerLoadingOverlay), findsOneWidget);
    expect(find.text('正在解析播放地址...'), findsOneWidget);

    player.emitVideoSize(1920, 1080);
    await tester.pump();
    expect(find.byType(PlayerLoadingOverlay), findsNothing);
  });

  testWidgets('横滑跳转显示加载层；进度回执后收起', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final _FakePlayerController player = _FakePlayerController();
    await tester.pumpWidget(_host(PlayerPage(
      controller: player,
      source: const PlayerSource(url: 'http://x/y.m3u8'),
      title: '示例片',
      danmakuService: _offlineDanmaku(),
    )));
    await tester.pump();
    // 首帧就绪 → 收起初始加载层。
    player.emitVideoSize(1920, 1080);
    player.emitProgress(positionMs: 100000, durationMs: 1000000);
    await tester.pump();
    expect(find.byType(PlayerLoadingOverlay), findsNothing);

    // 横滑 → 松手提交跳转 → 跳转加载层。
    final TestGesture g = await tester.startGesture(const Offset(400, 300));
    for (int i = 0; i < 4; i++) {
      await g.moveBy(const Offset(40, 0));
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    expect(find.textContaining('正在跳转到'), findsOneWidget);

    // 进度回执 → 收起跳转加载层。
    player.emitProgress(positionMs: 120000, durationMs: 1000000);
    await tester.pump();
    expect(find.byType(PlayerLoadingOverlay), findsNothing);

    await tester.pump(const Duration(milliseconds: 500));
  });
}
