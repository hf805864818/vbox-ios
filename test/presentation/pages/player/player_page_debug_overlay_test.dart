/// UI-F6：播放器调试浮层接线（`show_debug_overlay` 开关消费）。
///
/// 对齐 iOS `VideoPlayerViewV2` L588-L635：开关开启且日志非空 → 返回键下方
/// 显示绿色等宽日志流浮层；关闭或无日志 → 不显示。
library;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/player/player.dart';
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

/// 假播放器控制器：open/play 记录调用（起播成功即产生调试日志）。
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

/// 初始化 PrefsManager（进程级单例：显式写开关值保证用例间确定性）。
Future<void> _initPrefs(bool debugOverlay) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'show_debug_overlay': debugOverlay,
  });
  FlutterSecureStorage.setMockInitialValues(<String, String>{});
  await PrefsManager.instance.init();
  await PrefsManager.instance.set('show_debug_overlay', debugOverlay);
}

void main() {
  testWidgets('开关开启：起播后浮层显示日志流（对齐 iOS showDebugOverlay）',
      (WidgetTester tester) async {
    await _initPrefs(true);

    final _FakePlayerController player = _FakePlayerController();
    await tester.pumpWidget(_host(PlayerPage(
      controller: player,
      source: const PlayerSource(url: 'http://x/y.m3u8'),
      title: '示例片',
      danmakuService: _offlineDanmaku(),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 日志流（打开播放源 / 起播成功）在浮层中可见。
    expect(find.textContaining('打开播放源'), findsOneWidget);
    expect(find.textContaining('起播成功'), findsOneWidget);
    // 浮层高度 126（对齐 iOS .frame(height: 126)）。
    final Finder overlayText = find.textContaining('打开播放源');
    final Size textSize = tester.getSize(overlayText);
    expect(textSize.height, lessThan(126));

    // 排空播放页计时器（避免测试结束仍有 pending timer）。
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('开关关闭：不显示浮层（对齐 iOS 默认 false）',
      (WidgetTester tester) async {
    await _initPrefs(false);

    final _FakePlayerController player = _FakePlayerController();
    await tester.pumpWidget(_host(PlayerPage(
      controller: player,
      source: const PlayerSource(url: 'http://x/y.m3u8'),
      title: '示例片',
      danmakuService: _offlineDanmaku(),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('打开播放源'), findsNothing);
    expect(find.textContaining('起播成功'), findsNothing);

    await tester.pump(const Duration(seconds: 4));
  });
}
