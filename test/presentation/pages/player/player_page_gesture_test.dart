/// 第 3 批 · UI-F1：播放页视频区手势接线（横滑 seek / 左半屏亮度 / 右半屏音量）。
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
import 'package:vbox/presentation/widgets/player/gesture_hud.dart';

class _NoopBridge implements PlayerChannelBridge {
  @override
  Future<Object?> invoke(String method, [Object? arguments]) async => null;

  @override
  Stream<Map<String, Object?>> events() =>
      const Stream<Map<String, Object?>>.empty();

  @override
  Future<void> dispose() async {}
}

/// 假播放器控制器：记录 seek，并可回填进度（供手势必填时长）。
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

  /// 触发一次进度事件（回填控制层的位置 / 时长）。
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

/// 多步拖动：**首步**用于越过手势识别阈值（该步位移被识别器丢弃），
/// 后续步才产生 `onPanUpdate`。
Future<TestGesture> _drag(
  WidgetTester tester,
  Offset start,
  Offset step, {
  int steps = 4,
}) async {
  final TestGesture g = await tester.startGesture(start);
  for (int i = 0; i < steps; i++) {
    await g.moveBy(step);
    await tester.pump();
  }
  return g;
}

/// 松手并排空双击识别器的收尾计时器。
Future<void> _release(WidgetTester tester, TestGesture g) async {
  await g.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('横屏横滑 → seek HUD 显示并在松手时提交跳转', (WidgetTester tester) async {
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
    player.emitProgress(positionMs: 100000, durationMs: 1000000);
    await tester.pump();

    final TestGesture g =
        await _drag(tester, const Offset(400, 300), const Offset(40, 0));

    expect(find.byType(PlayerGestureHud), findsOneWidget);
    // 时长来自进度事件（16:40 = 1000s）；位置为起点 + 已累计位移对应增量。
    expect(find.textContaining('/ 16:40'), findsOneWidget);

    await _release(tester, g);
    expect(find.byType(PlayerGestureHud), findsNothing);
    expect(player.seeks, hasLength(1));
    expect(player.seeks.single, greaterThan(100000));
    expect(player.seeks.single, lessThanOrEqualTo(130000));
  });

  testWidgets('左半屏纵滑 → 亮度 HUD', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_host(PlayerPage(
      controller: _FakePlayerController(),
      source: const PlayerSource(url: 'http://x/y.m3u8'),
      title: '示例片',
      danmakuService: _offlineDanmaku(),
    )));
    await tester.pump();

    final TestGesture g =
        await _drag(tester, const Offset(100, 400), const Offset(0, -30));

    expect(find.byType(PlayerGestureHud), findsOneWidget);
    expect(find.textContaining('亮度'), findsOneWidget);

    await _release(tester, g);
    expect(find.byType(PlayerGestureHud), findsNothing);
  });

  testWidgets('右半屏纵滑 → 音量 HUD', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_host(PlayerPage(
      controller: _FakePlayerController(),
      source: const PlayerSource(url: 'http://x/y.m3u8'),
      title: '示例片',
      danmakuService: _offlineDanmaku(),
    )));
    await tester.pump();

    final TestGesture g =
        await _drag(tester, const Offset(300, 400), const Offset(0, 30));

    expect(find.byType(PlayerGestureHud), findsOneWidget);
    expect(find.textContaining('音量'), findsOneWidget);

    await _release(tester, g);
    expect(find.byType(PlayerGestureHud), findsNothing);
  });
}
