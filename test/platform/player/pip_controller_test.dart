/// 批次 C · C-05：PipController 多策略编排 + PipStrategyResolver 判定（纯 Dart）。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/platform/player/floating/floating_window.dart';
import 'package:vbox/platform/player/pip/pip_bridge.dart';
import 'package:vbox/platform/player/pip/pip_controller.dart';
import 'package:vbox/platform/player/pip/pip_lifecycle.dart';
import 'package:vbox/platform/player/pip/pip_strategy.dart';

/// 内存假系统桥：记录调用、可注入结果与事件流。
class FakePipBridge implements PipPlatformBridge {
  bool supported = true;
  bool enterResult = true;
  bool inPip = false;
  final List<String> calls = <String>[];
  final List<PipSystemEvent> pushed = <PipSystemEvent>[];

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<bool> enterPip({int? width, int? height}) async {
    calls.add('enterPip($width,$height)');
    if (enterResult) inPip = true;
    return enterResult;
  }

  @override
  Future<void> exitPip() async {
    calls.add('exitPip');
    inPip = false;
  }

  @override
  bool get isInPip => inPip;

  @override
  Stream<PipSystemEvent> events() => Stream<PipSystemEvent>.fromIterable(pushed);

  @override
  Future<void> dispose() async {}

  /// 模拟用户侧手动退出系统画中画（原生事件上抛）。
  void pushExit() => pushed.add(const PipSystemEvent(inPip: false));
}

/// 内存假浮窗：记录调用、可注入 show 结果。
class FakeFloatingWindow implements FloatingWindow {
  bool showResult = true;
  final List<String> calls = <String>[];
  FloatingWindowInfo _info = const FloatingWindowInfo();

  @override
  bool get isAvailable => true;

  @override
  FloatingWindowInfo get info => _info;

  @override
  void Function(FloatingWindowInfo info)? onChanged;

  @override
  Future<bool> show({double? width, double? height}) async {
    calls.add('show($width,$height)');
    if (showResult) {
      _info = _info.copyWith(state: FloatingWindowState.visible);
    }
    return showResult;
  }

  @override
  Future<void> hide() async {
    calls.add('hide');
    _info = const FloatingWindowInfo();
  }

  @override
  Future<void> setMedia({String? title, bool? isLive}) async {
    calls.add('setMedia($title,$isLive)');
    _info = _info.copyWith(title: title, isLive: isLive);
  }

  @override
  Future<void> updateProgress(int positionMs, int durationMs) async {
    calls.add('updateProgress($positionMs,$durationMs)');
    _info = _info.copyWith(positionMs: positionMs, durationMs: durationMs);
  }

  @override
  void Function(String gesture)? onGesture;

  @override
  Future<void> updateSnapshot(Uint8List? png) async {
    calls.add('updateSnapshot(${png?.length ?? -1})');
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  group('PipStrategyResolver.resolve', () {
    test('未启用 → none（无论平台）', () {
      expect(
        PipStrategyResolver.resolve(
          enabled: false,
          platform: 'android',
          backend: PlayerBackend.media3,
          systemPipAvailable: true,
        ),
        PipStrategy.none,
      );
    });

    test('android + media3 + 系统可用 → mdk', () {
      expect(
        PipStrategyResolver.resolve(
          enabled: true,
          platform: 'android',
          backend: PlayerBackend.media3,
          systemPipAvailable: true,
        ),
        PipStrategy.mdk,
      );
    });

    test('android + 回退后端（libVLC/libmpv）+ 系统可用 → mpv', () {
      expect(
        PipStrategyResolver.resolve(
          enabled: true,
          platform: 'android',
          backend: PlayerBackend.libVLC,
          systemPipAvailable: true,
        ),
        PipStrategy.mpv,
      );
    });

    test('android + 系统不可用 → viewCapture', () {
      expect(
        PipStrategyResolver.resolve(
          enabled: true,
          platform: 'android',
          backend: PlayerBackend.media3,
          systemPipAvailable: false,
        ),
        PipStrategy.viewCapture,
      );
    });

    test('windows / linux → mpv（libmpv 浮窗承载）', () {
      for (final String p in <String>['windows', 'linux']) {
        expect(
          PipStrategyResolver.resolve(
            enabled: true,
            platform: p,
            backend: null,
            systemPipAvailable: false,
          ),
          PipStrategy.mpv,
        );
      }
    });

    test('macos / ios → avPlayer（系统可用）或 viewCapture（兜底）', () {
      expect(
        PipStrategyResolver.resolve(
          enabled: true,
          platform: 'macos',
          backend: null,
          systemPipAvailable: true,
        ),
        PipStrategy.avPlayer,
      );
      expect(
        PipStrategyResolver.resolve(
          enabled: true,
          platform: 'ios',
          backend: null,
          systemPipAvailable: false,
        ),
        PipStrategy.viewCapture,
      );
    });

    test('未知平台 → none', () {
      expect(
        PipStrategyResolver.resolve(
          enabled: true,
          platform: 'web',
          backend: null,
          systemPipAvailable: true,
        ),
        PipStrategy.none,
      );
    });
  });

  group('PipStrategy.isSystemBased', () {
    test('mdk / vt / avPlayer 走系统承载', () {
      expect(PipStrategy.mdk.isSystemBased, isTrue);
      expect(PipStrategy.vt.isSystemBased, isTrue);
      expect(PipStrategy.avPlayer.isSystemBased, isTrue);
    });

    test('mpv / viewCapture / none 走浮窗承载', () {
      expect(PipStrategy.mpv.isSystemBased, isFalse);
      expect(PipStrategy.viewCapture.isSystemBased, isFalse);
      expect(PipStrategy.none.isSystemBased, isFalse);
    });
  });

  group('PipController（系统策略）', () {
    test('enter → 调系统桥并转 active', () async {
      final FakePipBridge bridge = FakePipBridge();
      final PipController c = PipController(
        enabled: true,
        strategy: PipStrategy.mdk,
        systemBridge: bridge,
        floating: FakeFloatingWindow(),
      );
      final bool ok = await c.enter();
      expect(ok, isTrue);
      expect(bridge.calls, contains('enterPip(null,null)'));
      expect(c.state, PipState.active);
      expect(c.isInPip, isTrue);
    });

    test('enter 失败 → 保持 hidden', () async {
      final FakePipBridge bridge = FakePipBridge()..enterResult = false;
      final PipController c = PipController(
        enabled: true,
        strategy: PipStrategy.mdk,
        systemBridge: bridge,
        floating: FakeFloatingWindow(),
      );
      expect(await c.enter(), isFalse);
      expect(c.state, PipState.hidden);
    });

    test('exit → 调系统桥并转 hidden', () async {
      final FakePipBridge bridge = FakePipBridge();
      final PipController c = PipController(
        enabled: true,
        strategy: PipStrategy.mdk,
        systemBridge: bridge,
        floating: FakeFloatingWindow(),
      );
      await c.enter();
      await c.exit();
      expect(bridge.calls, contains('exitPip'));
      expect(c.isInPip, isFalse);
    });

    test('用户侧退出系统 PiP（事件）→ 状态同步 hidden', () async {
      final FakePipBridge bridge = FakePipBridge()..pushExit();
      final PipController c = PipController(
        enabled: true,
        strategy: PipStrategy.mdk,
        systemBridge: bridge,
        floating: FakeFloatingWindow(),
      );
      // 事件流为 fromIterable，构造即收到
      await Future<void>.delayed(Duration.zero);
      expect(c.state, PipState.hidden);
    });
  });

  group('PipController（浮窗策略）', () {
    test('enter → 调浮窗 show + setMedia', () async {
      final FakeFloatingWindow floating = FakeFloatingWindow();
      final PipController c = PipController(
        enabled: true,
        strategy: PipStrategy.viewCapture,
        systemBridge: FakePipBridge(),
        floating: floating,
      );
      final bool ok = await c.enter(title: '直播', isLive: true, width: 360, height: 640);
      expect(ok, isTrue);
      expect(floating.calls, contains('show(360.0,640.0)'));
      expect(floating.calls, contains('setMedia(直播,true)'));
      expect(c.isInPip, isTrue);
    });

    test('浮窗 show 失败 → 不置 active', () async {
      final FakeFloatingWindow floating = FakeFloatingWindow()..showResult = false;
      final PipController c = PipController(
        enabled: true,
        strategy: PipStrategy.viewCapture,
        systemBridge: FakePipBridge(),
        floating: floating,
      );
      expect(await c.enter(), isFalse);
      expect(c.isInPip, isFalse);
    });

    test('updateProgress → 浮窗转发；系统策略忽略', () async {
      final FakeFloatingWindow floating = FakeFloatingWindow();
      final PipController floatingC = PipController(
        enabled: true,
        strategy: PipStrategy.viewCapture,
        systemBridge: FakePipBridge(),
        floating: floating,
      );
      await floatingC.enter();
      await floatingC.updateProgress(123, 1000);
      expect(floating.calls, contains('updateProgress(123,1000)'));

      final FakePipBridge bridge = FakePipBridge();
      final PipController systemC = PipController(
        enabled: true,
        strategy: PipStrategy.mdk,
        systemBridge: bridge,
        floating: FakeFloatingWindow(),
      );
      await systemC.enter();
      await systemC.updateProgress(123, 1000);
      expect(bridge.calls, isNot(contains('updateProgress')));
    });

    test('exit → 浮窗 hide', () async {
      final FakeFloatingWindow floating = FakeFloatingWindow();
      final PipController c = PipController(
        enabled: true,
        strategy: PipStrategy.viewCapture,
        systemBridge: FakePipBridge(),
        floating: floating,
      );
      await c.enter();
      await c.exit();
      expect(floating.calls, contains('hide'));
      expect(c.isInPip, isFalse);
    });
  });

  group('PipController（none / 未启用）', () {
    test('enabled=false → enter 返回 false 且不调用任何承载', () async {
      final FakePipBridge bridge = FakePipBridge();
      final FakeFloatingWindow floating = FakeFloatingWindow();
      final PipController c = PipController(
        enabled: false,
        strategy: PipStrategy.none,
        systemBridge: bridge,
        floating: floating,
      );
      expect(await c.enter(), isFalse);
      expect(bridge.calls, isEmpty);
      expect(floating.calls, isEmpty);
    });
  });

  group('PipController（生命周期联动）', () {
    test('后台 + 播放中 → 自动进入', () async {
      final FakePipBridge bridge = FakePipBridge();
      final PipController c = PipController(
        enabled: true,
        strategy: PipStrategy.mdk,
        systemBridge: bridge,
        floating: FakeFloatingWindow(),
      );
      await c.handleLifecycle(PlaybackLifecycle.background, isPlaying: true);
      expect(c.isInPip, isTrue);
      expect(bridge.calls, contains('enterPip(null,null)'));
    });

    test('后台 + 未播放 → 不进入', () async {
      final FakePipBridge bridge = FakePipBridge();
      final PipController c = PipController(
        enabled: true,
        strategy: PipStrategy.mdk,
        systemBridge: bridge,
        floating: FakeFloatingWindow(),
      );
      await c.handleLifecycle(PlaybackLifecycle.background, isPlaying: false);
      expect(c.isInPip, isFalse);
    });

    test('前台 + 画中画中 → 自动退出', () async {
      final FakePipBridge bridge = FakePipBridge();
      final PipController c = PipController(
        enabled: true,
        strategy: PipStrategy.mdk,
        systemBridge: bridge,
        floating: FakeFloatingWindow(),
      );
      await c.enter();
      await c.handleLifecycle(PlaybackLifecycle.foreground, isPlaying: true);
      expect(c.isInPip, isFalse);
      expect(bridge.calls, contains('exitPip'));
    });

    test('未启用 → 生命周期不动作', () async {
      final FakePipBridge bridge = FakePipBridge();
      final PipController c = PipController(
        enabled: false,
        strategy: PipStrategy.none,
        systemBridge: bridge,
        floating: FakeFloatingWindow(),
      );
      await c.handleLifecycle(PlaybackLifecycle.background, isPlaying: true);
      expect(bridge.calls, isEmpty);
    });
  });

  group('PipController.resolveAndCreate', () {
    test('先探测系统能力再解析策略', () async {
      final PipController c = await PipController.resolveAndCreate(
        enabled: true,
        platform: 'android',
        backend: PlayerBackend.media3,
        systemBridge: FakePipBridge()..supported = true,
        floating: FakeFloatingWindow(),
      );
      expect(c.strategy, PipStrategy.mdk);
    });

    test('系统不可用 → viewCapture', () async {
      final PipController c = await PipController.resolveAndCreate(
        enabled: true,
        platform: 'android',
        backend: PlayerBackend.media3,
        systemBridge: FakePipBridge()..supported = false,
        floating: FakeFloatingWindow(),
      );
      expect(c.strategy, PipStrategy.viewCapture);
    });
  });

  group('P-芯7 仅后台声音降级', () {
    test('系统 PiP 不可用 + 后台播放开 → backgroundAudioOnly', () {
      expect(
        PipStrategyResolver.resolve(
          enabled: true,
          platform: 'ios',
          backend: null,
          systemPipAvailable: false,
          backgroundPlayEnabled: true,
        ),
        PipStrategy.backgroundAudioOnly,
      );
      expect(
        PipStrategyResolver.resolve(
          enabled: true,
          platform: 'android',
          backend: PlayerBackend.media3,
          systemPipAvailable: false,
          backgroundPlayEnabled: true,
        ),
        PipStrategy.backgroundAudioOnly,
      );
    });

    test('未开后台播放 → 维持 viewCapture 兜底', () {
      expect(
        PipStrategyResolver.resolve(
          enabled: true,
          platform: 'android',
          backend: PlayerBackend.media3,
          systemPipAvailable: false,
        ),
        PipStrategy.viewCapture,
      );
    });

    test('backgroundAudioOnly：isSystemBased=false / showsVisualPip=false', () {
      expect(PipStrategy.backgroundAudioOnly.isSystemBased, isFalse);
      expect(PipStrategy.backgroundAudioOnly.showsVisualPip, isFalse);
      expect(PipStrategy.backgroundAudioOnly.isAudioOnly, isTrue);
      expect(PipStrategy.mdk.showsVisualPip, isTrue);
    });

    test('backgroundAudioOnly：enter 返回 false 且不调任何承载', () async {
      final FakePipBridge bridge = FakePipBridge();
      final FakeFloatingWindow floating = FakeFloatingWindow();
      final PipController c = PipController(
        enabled: true,
        strategy: PipStrategy.backgroundAudioOnly,
        systemBridge: bridge,
        floating: floating,
      );
      expect(await c.enter(), isFalse);
      expect(bridge.calls, isEmpty);
      expect(floating.calls, isEmpty);
      expect(c.isInPip, isFalse);
      expect(c.isAudioOnlyFallback, isTrue);
    });

    test('resolveAndCreate 透传 backgroundPlayEnabled', () async {
      final PipController c = await PipController.resolveAndCreate(
        enabled: true,
        platform: 'android',
        backend: PlayerBackend.media3,
        systemBridge: FakePipBridge()..supported = false,
        floating: FakeFloatingWindow(),
        backgroundPlayEnabled: true,
      );
      expect(c.strategy, PipStrategy.backgroundAudioOnly);
    });
  });
}
