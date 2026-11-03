/// UI-E5：返回手势拦截核对——播放页返回恢复系统 UI / 全方向
/// （对齐 iOS `onDisappear` 的 `lockOrientation(.portrait)` + `cleanup` 语义）。
///
/// 说明：Flutter 端播放页为独立路由，返回即退出页面（= iOS `dismiss()`），
/// 无「页内全屏态」；弹层（`showModalBottomSheet`）返回键天然先关弹层不退页，
/// 两者与 iOS 行为一致，无需额外拦截。本测试锁定「pop 后恢复系统 UI 与方向」。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/platform/player/danmaku/danmaku_service.dart';
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

  @override
  Future<void> open(PlayerSource source, {PlaybackRoute? route}) async {}

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
}

Widget _host(Widget child) => MaterialApp(
      theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
      home: child,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('播放页 pop → 恢复 SystemUiMode.edgeToEdge + 全方向',
      (WidgetTester tester) async {
    final List<MethodCall> platformCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        platformCalls.add(call);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(_host(PlayerPage(
      controller: _FakePlayerController(),
      source: const PlayerSource(url: 'http://x/y.m3u8'),
      title: '示例片',
      vodId: 'v1',
      danmakuService: DanmakuService(
        client: MockClient((http.Request r) async => http.Response('', 404)),
        baseUrl: 'https://dm.test',
      ),
    )));
    await tester.pump();
    await tester.pump();

    platformCalls.clear();
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump();

    expect(
      platformCalls.map((MethodCall c) => c.method),
      containsAll(<String>[
        'SystemChrome.setEnabledSystemUIMode',
        'SystemChrome.setPreferredOrientations',
      ]),
      reason: '返回后应恢复系统 UI 与方向（对齐 iOS onDisappear）',
    );
    // 方向恢复为全方向（iOS 端 lockOrientation(.portrait) 在 Flutter 端的等价口径）。
    final MethodCall orientationCall = platformCalls.firstWhere(
      (MethodCall c) => c.method == 'SystemChrome.setPreferredOrientations',
    );
    expect(
      (orientationCall.arguments as List<Object?>).length,
      DeviceOrientation.values.length,
      reason: '应恢复全部方向，而非锁定单方向',
    );
  });
}
