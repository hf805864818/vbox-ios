/// 首开失败诊断文案（C-12）：后端不可用透传原生原因，不被 URL 探测覆盖。
///
/// Windows 真机场景：libmpv 依赖缺失（如 vulkan-1.dll）→ 插件报
/// `E_BACKEND_UNAVAILABLE`；诊断曾把「后端不可用」误归因为「网络错误」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/platform/player/channel_player.dart';
import 'package:vbox/platform/player/danmaku/danmaku_service.dart';
import 'package:vbox/platform/player/go_proxy_client.dart';
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

/// open 直接抛后端不可用的假控制器。
class _BackendUnavailableController extends PlayerController {
  _BackendUnavailableController(this.error)
      : super(
          bridge: _NoopBridge(),
          backendChain: const <PlayerBackend>[PlayerBackend.media3],
          selectInitialBackend: (_, PlaybackRoute route) => PlayerBackend.media3,
        );

  final PlayerOpenException error;

  @override
  Future<void> open(PlayerSource source, {PlaybackRoute? route}) =>
      Future<void>.error(error);

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}
}

Widget _host(Widget child) => MaterialApp(
      theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
      home: child,
    );

void main() {
  setUp(() {
    GoProxyRegistry.instance = const NoopGoProxyClient();
  });

  testWidgets('E_BACKEND_UNAVAILABLE：错误视图显示原生原因（不误报网络错误）',
      (WidgetTester tester) async {
    final PlayerController player = _BackendUnavailableController(
      const PlayerOpenException(
        'E_BACKEND_UNAVAILABLE',
        '后端 libmpv 打开失败：mpv-2.dll 依赖的运行库缺失，libmpv 不可用',
      ),
    );
    await tester.pumpWidget(_host(PlayerPage(
      controller: player,
      source: const PlayerSource(url: 'http://u/index.m3u8'),
      title: '示例片',
      danmakuService: DanmakuService(
        client: MockClient((http.Request r) async => http.Response('', 404)),
        baseUrl: 'https://dm.test',
      ),
    )));
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining('mpv-2.dll 依赖的运行库缺失'),
      findsWidgets,
      reason: '后端不可用应原样透传原生原因',
    );
    expect(find.textContaining('播放地址不可达'), findsNothing,
        reason: '后端不可用不应被 URL 探测覆盖为网络错误');
  });
}
