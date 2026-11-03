/// 第 5 批 · UI-F22：前后台恢复保护（退后台暂停 + 强制落库 + 回前台宽限恢复）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/platform/player/danmaku/danmaku_service.dart';
import 'package:vbox/platform/player/playback_progress.dart';
import 'package:vbox/platform/player/playback_route.dart';
import 'package:vbox/platform/player/player_channel_bridge.dart';
import 'package:vbox/platform/player/player_controller.dart';
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

  final List<String> calls = <String>[];

  @override
  Future<void> open(PlayerSource source, {PlaybackRoute? route}) async =>
      calls.add('open');

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seekTo(int positionMs) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setVolume(double volume) async {}

  void emitState(PlayerState state) => onStateChanged?.call(state);

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
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('退后台：未开后台播放且播放中 → 暂停 + 强制落库（跳过节流）',
      (WidgetTester tester) async {
    final _FakePlayerController player = _FakePlayerController();
    await _pumpPage(tester, player);
    player.emitState(PlayerState.playing);
    await tester.pump();

    // 第一条进度落库；第二条在 5s 节流窗口内被丢弃。
    player.emitProgress(positionMs: 60000, durationMs: 1000000);
    await tester.pump();
    player.emitProgress(positionMs: 90000, durationMs: 1000000);
    await tester.pump();
    expect(await PlaybackProgressStore.load('v1'), 60.0);

    player.calls.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(player.calls, contains('pause'));
    // 强制落库：最新进度 90s 已写入。
    expect(await PlaybackProgressStore.load('v1'), 90.0);
  });

  testWidgets('回前台：800ms 宽限后恢复播放', (WidgetTester tester) async {
    final _FakePlayerController player = _FakePlayerController();
    await _pumpPage(tester, player);
    player.emitState(PlayerState.playing);
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(player.calls, contains('pause'));

    player.calls.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    // 宽限期内不恢复。
    expect(player.calls, isNot(contains('play')));
    // 越过 800ms 宽限 → 恢复播放。
    await tester.pump(const Duration(milliseconds: 900));
    expect(player.calls, contains('play'));
  });

  testWidgets('回前台：未因后台暂停（用户主动暂停）→ 不自动恢复',
      (WidgetTester tester) async {
    final _FakePlayerController player = _FakePlayerController();
    await _pumpPage(tester, player);
    // 未进入播放态：退后台不会暂停，因而回前台也不恢复。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(player.calls, isNot(contains('pause')));

    player.calls.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 900));
    expect(player.calls, isNot(contains('play')));
  });

  // 注意：`PrefsManager` 为**缓存单例**且未初始化时抛错（→ 回契约默认），
  // 故「已开后台播放」用例必须放在**文件末尾**并显式 `init()`，
  // 否则会污染同文件其余用例的默认值。
  testWidgets('退后台：已开后台播放 → 不暂停', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'player_background_play': true,
    });
    await PrefsManager.instance.init();

    final _FakePlayerController player = _FakePlayerController();
    await _pumpPage(tester, player);
    player.emitState(PlayerState.playing);
    await tester.pump();

    player.calls.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(player.calls, isNot(contains('pause')));
  });
}
