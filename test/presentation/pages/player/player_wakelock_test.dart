/// UI-D2：屏幕常亮按播放状态驱动（对齐 iOS `isIdleTimerDisabled` 语义）。
///
/// iOS 基准：三内核 `play()` 开启 / `pause()`·`stop()` 恢复，
/// UI 层 `updateIdleTimer()` 按 `isPlaying` 收口；暂停时显式恢复
/// （后台场景系统可能重置 idle timer）。Flutter 端等价实现：
///  - `onStateChanged(playing)` → enable；其余状态 → disable；
///  - 页面 dispose 兜底 disable（防状态回调丢失）；
///  - 平台通道异常静默（wakelock 不可用不影响播放）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/platform/player/danmaku/danmaku_service.dart';
import 'package:vbox/platform/player/player_channel_bridge.dart';
import 'package:vbox/platform/player/player_controller.dart';
import 'package:vbox/platform/player/playback_route.dart';
import 'package:vbox/platform/player/wake_lock.dart';
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

/// 记录调用序列的常亮控制器假实现。
class _RecordingWakeLock implements WakeLockController {
  final List<String> calls = <String>[];

  @override
  Future<void> enable() async => calls.add('enable');

  @override
  Future<void> disable() async => calls.add('disable');
}

Widget _host(Widget child) => MaterialApp(
      theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
      home: child,
    );

Future<PlayerPage> _page(_FakePlayerController player,
        {WakeLockController? wakeLock}) async =>
    PlayerPage(
      controller: player,
      source: const PlayerSource(url: 'http://x/y.m3u8'),
      title: '示例片',
      vodId: 'v1',
      danmakuService: DanmakuService(
        client: MockClient((http.Request r) async => http.Response('', 404)),
        baseUrl: 'https://dm.test',
      ),
      wakeLock: wakeLock,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('播放状态驱动：playing → enable / paused → disable',
      (WidgetTester tester) async {
    final _FakePlayerController player = _FakePlayerController();
    final _RecordingWakeLock wake = _RecordingWakeLock();
    await tester.pumpWidget(_host(await _page(player, wakeLock: wake)));
    await tester.pump();

    // 首帧进入播放（对齐 iOS 内核 play() → isIdleTimerDisabled = true）。
    player.onStateChanged?.call(PlayerState.playing);
    await tester.pump();
    expect(wake.calls, <String>['enable']);

    // 暂停 → 显式恢复（对齐 iOS pause() + updateIdleTimer）。
    player.onStateChanged?.call(PlayerState.paused);
    await tester.pump();
    expect(wake.calls, <String>['enable', 'disable']);

    // 恢复播放 → 再次开启。
    player.onStateChanged?.call(PlayerState.playing);
    await tester.pump();
    expect(wake.calls, <String>['enable', 'disable', 'enable']);
  });

  testWidgets('退出播放页 dispose 兜底恢复锁屏',
      (WidgetTester tester) async {
    final _FakePlayerController player = _FakePlayerController();
    final _RecordingWakeLock wake = _RecordingWakeLock();
    await tester.pumpWidget(_host(await _page(player, wakeLock: wake)));
    await tester.pump();
    wake.calls.clear();

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    // 路由退场（MaterialPageRoute ~300ms）完成后 State 才 dispose；
    // 零时长 pump 不够，分步推进至退场完成（探针实测 200ms 未退、600ms 已退）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(wake.calls, <String>['disable'],
        reason: '退出播放页应兜底恢复锁屏（对齐 iOS dismiss 后内核 stop）');
  });

  test('WakelockPlusController 平台异常静默（不影响播放主链路）', () async {
    // 测试宿主无 wakelock 平台通道 → MissingPluginException 应被吞掉。
    await const WakelockPlusController().enable();
    await const WakelockPlusController().disable();
  });
}
