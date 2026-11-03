/// 第 5 批 · UI-F16：播放页续播（读取上次进度 → 首帧就绪后 seek → 节流落库）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/platform/player/danmaku/danmaku_service.dart';
import 'package:vbox/platform/player/playback_progress.dart';
import 'package:vbox/platform/player/player_channel_bridge.dart';
import 'package:vbox/platform/player/player_controller.dart';
import 'package:vbox/platform/player/playback_route.dart';
import 'package:vbox/presentation/pages/player/player_page.dart';
import 'package:vbox/presentation/theme/theme.dart';

class _NoopBridge implements PlayerChannelBridge {
  @override
  Future<Object?> invoke(String method, [Object? arguments]) async => null;

  @override
  Stream<Map<String, Object?>> events() =>
      const Stream<Map<String, Object?>>.empty();

  @override
  Future<void> dispose() async {}
}

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

  void emitVideoSize(int width, int height) =>
      onVideoSize?.call(width, height);

  void emitProgress({required int positionMs, required int durationMs}) {
    onProgress?.call(PlaybackProgress(
      positionMs: positionMs,
      durationMs: durationMs,
      bufferedMs: 0,
    ));
  }
}

DanmakuService _offlineDanmaku() => DanmakuService(
      client: MockClient((http.Request r) async => http.Response('', 404)),
      baseUrl: 'https://dm.test',
    );

Widget _host(Widget child) => MaterialApp(
      theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
      home: child,
    );

Future<void> _pumpPage(WidgetTester tester, _FakePlayerController player) async {
  await tester.pumpWidget(_host(PlayerPage(
    controller: player,
    source: const PlayerSource(url: 'http://x/y.m3u8'),
    title: '示例片',
    vodId: 'v1',
    danmakuService: _offlineDanmaku(),
  )));
  // 让 `_enter` 内的进度读取完成。
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('已存进度 > 10s → 首帧就绪后 seek 到该位置', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(
      <String, Object>{PlaybackProgressStore.keyOf('v1', 0): 60.0},
    );
    final _FakePlayerController player = _FakePlayerController();
    await _pumpPage(tester, player);

    expect(player.seeks, isEmpty);
    player.emitVideoSize(1920, 1080);
    await tester.pump();
    expect(player.seeks, <int>[60000]);

    // 幂等：再次首帧上报不重复 seek。
    player.emitProgress(positionMs: 60000, durationMs: 1000000);
    await tester.pump();
    expect(player.seeks, <int>[60000]);
  });

  testWidgets('已存进度 ≤ 10s → 不续播', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(
      <String, Object>{PlaybackProgressStore.keyOf('v1', 0): 8.0},
    );
    final _FakePlayerController player = _FakePlayerController();
    await _pumpPage(tester, player);

    player.emitVideoSize(1920, 1080);
    await tester.pump();
    expect(player.seeks, isEmpty);
  });

  testWidgets('进度 > 5s → 节流落库', (WidgetTester tester) async {
    final _FakePlayerController player = _FakePlayerController();
    await _pumpPage(tester, player);

    player.emitProgress(positionMs: 20000, durationMs: 1000000);
    await tester.pump();
    expect(await PlaybackProgressStore.load('v1'), 20.0);
  });

  testWidgets('进度 < 5s → 不落库', (WidgetTester tester) async {
    final _FakePlayerController player = _FakePlayerController();
    await _pumpPage(tester, player);

    player.emitProgress(positionMs: 3000, durationMs: 1000000);
    await tester.pump();
    expect(await PlaybackProgressStore.load('v1'), 0);
  });

  testWidgets('接近片尾（距结尾 < 15s）→ 清除进度', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(
      <String, Object>{PlaybackProgressStore.keyOf('v1', 0): 900.0},
    );
    final _FakePlayerController player = _FakePlayerController();
    await _pumpPage(tester, player);

    // 距结尾 5s → 视为看完，清除。
    player.emitProgress(positionMs: 995000, durationMs: 1000000);
    await tester.pump();
    expect(await PlaybackProgressStore.load('v1'), 0);
  });
}
