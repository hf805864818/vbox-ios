/// 第 5 批 · UI-F17：播放页下一集预取（近结尾预解析 + 切集命中缓存）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/domain/entities/playback/playback_detail.dart';
import 'package:vbox/platform/player/danmaku/danmaku_service.dart';
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

/// 假播放器控制器：记录 open 的地址，并可回填进度。
class _FakePlayerController extends PlayerController {
  _FakePlayerController()
      : super(
          bridge: _NoopBridge(),
          backendChain: const <PlayerBackend>[PlayerBackend.media3],
          selectInitialBackend: (_, PlaybackRoute route) => PlayerBackend.media3,
        );

  final List<String> openedUrls = <String>[];

  @override
  Future<void> open(PlayerSource source, {PlaybackRoute? route}) async =>
      openedUrls.add(source.url);

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

  void emitProgress({required int positionMs, required int durationMs}) {
    onProgress?.call(PlaybackProgress(
      positionMs: positionMs,
      durationMs: durationMs,
      bufferedMs: 0,
    ));
  }

  void emitState(PlayerState state) => onStateChanged?.call(state);
}

DanmakuService _offlineDanmaku() => DanmakuService(
      client: MockClient((http.Request r) async => http.Response('', 404)),
      baseUrl: 'https://dm.test',
    );

const List<PlaybackEpisode> _episodes = <PlaybackEpisode>[
  PlaybackEpisode(name: '第1集', url: 'https://src/1'),
  PlaybackEpisode(name: '第2集', url: 'https://src/2'),
];

Widget _host(Widget child) => MaterialApp(
      theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
      home: child,
    );

void main() {
  testWidgets('剩余 > 30s 不预取；进入 30s 内预取下一集一次', (WidgetTester tester) async {
    final _FakePlayerController player = _FakePlayerController();
    final List<String> resolved = <String>[];
    Future<PlayerSource?> resolver(PlaybackEpisode e) async {
      resolved.add(e.name);
      return PlayerSource(url: 'https://cdn/${e.name}.m3u8', title: e.name);
    }

    await tester.pumpWidget(_host(PlayerPage(
      controller: player,
      source: const PlayerSource(url: 'https://cdn/第1集.m3u8'),
      title: '示例片',
      episodes: _episodes,
      initialEpisodeIndex: 0,
      onResolveEpisode: resolver,
      danmakuService: _offlineDanmaku(),
    )));
    await tester.pump();

    // 剩余 50s → 不预取。
    player.emitProgress(positionMs: 50000, durationMs: 100000);
    await tester.pump();
    expect(resolved, isEmpty);

    // 剩余 20s → 预取下一集（第2集）。
    player.emitProgress(positionMs: 80000, durationMs: 100000);
    await tester.pump();
    await tester.pump();
    expect(resolved, <String>['第2集']);

    // 继续推进不重复预取。
    player.emitProgress(positionMs: 90000, durationMs: 100000);
    await tester.pump();
    expect(resolved, <String>['第2集']);
  });

  testWidgets('切集命中预取缓存 → 不再重复解析', (WidgetTester tester) async {
    final _FakePlayerController player = _FakePlayerController();
    final List<String> resolved = <String>[];
    Future<PlayerSource?> resolver(PlaybackEpisode e) async {
      resolved.add(e.name);
      return PlayerSource(url: 'https://cdn/${e.name}.m3u8', title: e.name);
    }

    await tester.pumpWidget(_host(PlayerPage(
      controller: player,
      source: const PlayerSource(url: 'https://cdn/第1集.m3u8'),
      title: '示例片',
      episodes: _episodes,
      initialEpisodeIndex: 0,
      onResolveEpisode: resolver,
      danmakuService: _offlineDanmaku(),
    )));
    await tester.pump();

    player.emitProgress(positionMs: 80000, durationMs: 100000);
    await tester.pump();
    await tester.pump();
    expect(resolved, <String>['第2集']);

    // 自动连播（`ended`）切到下一集 → 命中缓存，解析器不再被调用。
    player.emitState(PlayerState.ended);
    await tester.pump();
    await tester.pump();
    expect(resolved, <String>['第2集']);
    expect(player.openedUrls.last, 'https://cdn/第2集.m3u8');
  });

  testWidgets('预取失败静默降级：切集时按常规重新解析', (WidgetTester tester) async {
    final _FakePlayerController player = _FakePlayerController();
    final List<String> resolved = <String>[];
    bool first = true;
    Future<PlayerSource?> resolver(PlaybackEpisode e) async {
      resolved.add(e.name);
      if (first) {
        first = false;
        throw StateError('预取失败');
      }
      return PlayerSource(url: 'https://cdn/${e.name}.m3u8', title: e.name);
    }

    await tester.pumpWidget(_host(PlayerPage(
      controller: player,
      source: const PlayerSource(url: 'https://cdn/第1集.m3u8'),
      title: '示例片',
      episodes: _episodes,
      initialEpisodeIndex: 0,
      onResolveEpisode: resolver,
      danmakuService: _offlineDanmaku(),
    )));
    await tester.pump();

    player.emitProgress(positionMs: 80000, durationMs: 100000);
    await tester.pump();
    await tester.pump();
    expect(resolved, <String>['第2集']);

    // 缓存为空 → 切集重新解析（第 2 次调用，本次成功）。
    player.emitState(PlayerState.ended);
    await tester.pump();
    await tester.pump();
    expect(resolved, <String>['第2集', '第2集']);
    expect(player.openedUrls.last, 'https://cdn/第2集.m3u8');
  });
}
