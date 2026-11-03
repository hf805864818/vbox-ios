/// G-02-A：MediaKitPlayer 控制转发 + 事件桥接（注入假 media_kit core，纯 Dart）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/platform/player/media_kit_player.dart';

/// 假 media_kit 平台实现：记录控制调用，经其广播流推事件。
class _FakePlatform extends mk.PlatformPlayer {
  _FakePlatform() : super(configuration: const mk.PlayerConfiguration());

  final List<String> calls = <String>[];
  double? volume;
  double? rate;
  int? seekMs;
  bool opened = false;

  @override
  Future<void> open(mk.Playable playable, {bool play = true}) async {
    opened = true;
    calls.add('open');
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seek(Duration duration) async {
    seekMs = duration.inMilliseconds;
    calls.add('seek');
  }

  @override
  Future<void> setVolume(double v) async {
    volume = v;
    calls.add('setVolume');
  }

  @override
  Future<void> setRate(double r) async {
    rate = r;
    calls.add('setRate');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await super.dispose();
  }

  // —— 事件注入（在子类内访问 @protected 广播控制器）——
  void emitPlaying(bool v) => playingController.add(v);
  void emitBuffering(bool v) => bufferingController.add(v);
  void emitCompleted(bool v) => completedController.add(v);
  void emitPosition(Duration d) => positionController.add(d);
  void emitDuration(Duration d) => durationController.add(d);
  void emitBuffer(Duration d) => bufferController.add(d);
  void emitWidth(int? w) => widthController.add(w);
  void emitHeight(int? h) => heightController.add(h);
  void emitError(String m) => errorController.add(m);
  void emitLog(mk.PlayerLog log) => logController.add(log);
}

/// 以假 core / 假纹理通知驱动构建 [MediaKitPlayer]。
///
/// 始终注入 `ValueNotifier<int?>`（缺省为 null），避免未提供 [textureId] 时真实
/// 构造 media_kit_video 的 `VideoController`（其构造阶段需 `WidgetsBinding`，
/// 在纯 `test()` 下会抛未处理 async 异常）。
MediaKitPlayer _build({_FakePlatform? platform, ValueListenable<int?>? textureId}) {
  platform ??= _FakePlatform();
  return MediaKitPlayer(
    backend: PlayerBackend.mediaKit,
    core: mk.Player(platformPlayer: platform),
    textureId: textureId ?? ValueNotifier<int?>(null),
  );
}

void main() {
  group('MediaKitPlayer 控制面', () {
    test('play/pause/seekTo/setVolume/setSpeed/dispose 依次转发', () async {
      final _FakePlatform platform = _FakePlatform();
      final MediaKitPlayer p = _build(platform: platform);
      // seekTo 前置守卫（问题 5 闪退）：媒体未打开（时长未知）时不下发 seek。
      // 先 open 并推一把时长，使 seek 进入合法转发区间，再验证控制面依次转发。
      await p.open(const PlayerSource(url: 'https://x/a.mp4'));
      platform.emitDuration(const Duration(milliseconds: 180000));
      await Future<void>.delayed(Duration.zero);
      await p.play();
      await p.pause();
      await p.seekTo(120000);
      await p.setVolume(0.5);
      await p.setSpeed(1.5);
      await p.dispose();
      expect(
        platform.calls,
        <String>[
          'open',
          'play',
          'pause',
          'seek',
          'setVolume',
          'setRate',
          'dispose',
        ],
      );
      expect(platform.seekMs, 120000);
      expect(platform.volume, 50.0);
      expect(platform.rate, 1.5);
    });

    test('setVolume：0..1 契约换算为 media_kit 0..100', () async {
      final _FakePlatform platform = _FakePlatform();
      final MediaKitPlayer p = _build(platform: platform);
      await p.setVolume(0.0);
      expect(platform.volume, 0.0);
      await p.setVolume(1.0);
      expect(platform.volume, 100.0);
      await p.setVolume(0.33);
      expect(platform.volume, closeTo(33.0, 0.001));
      await p.dispose();
    });

    test('open：转发并写 isLive；假 core 非 NativePlayer 时跳过 setProperty', () async {
      final _FakePlatform platform = _FakePlatform();
      final MediaKitPlayer p = _build(platform: platform);
      await p.open(const PlayerSource(url: 'https://x/live.m3u8', isLive: true));
      expect(platform.opened, true);
      expect(platform.calls, contains('open'));
      await p.dispose();
    });

    test('availableBackends 收敛为单元素链', () {
      final MediaKitPlayer p = _build();
      expect(p.availableBackends, <PlayerBackend>[PlayerBackend.mediaKit]);
    });
  });

  group('MediaKitPlayer 事件面', () {
    test('playing/buffering/completed → onStateChanged', () async {
      final _FakePlatform platform = _FakePlatform();
      final MediaKitPlayer p = _build(platform: platform);
      final List<PlayerState> states = <PlayerState>[];
      p.onStateChanged = states.add;
      platform.emitPlaying(true);
      platform.emitPlaying(false);
      platform.emitBuffering(true);
      platform.emitCompleted(true);
      await Future<void>.delayed(Duration.zero);
      expect(states, containsAll(<PlayerState>[
        PlayerState.playing,
        PlayerState.paused,
        PlayerState.buffering,
        PlayerState.ended,
      ]));
      await p.dispose();
    });

    test('position/duration/buffer → onProgress 合并（含 isLive）', () async {
      final _FakePlatform platform = _FakePlatform();
      final MediaKitPlayer p = _build(platform: platform);
      final List<PlaybackProgress> progress = <PlaybackProgress>[];
      p.onProgress = progress.add;
      await p.open(const PlayerSource(url: 'https://x/a.mp4', isLive: false));
      platform.emitDuration(const Duration(seconds: 60));
      platform.emitBuffer(const Duration(seconds: 45));
      platform.emitPosition(const Duration(seconds: 30));
      await Future<void>.delayed(Duration.zero);
      expect(progress, isNotEmpty);
      final PlaybackProgress last = progress.last;
      expect(last.positionMs, 30000);
      expect(last.durationMs, 60000);
      expect(last.bufferedMs, 45000);
      expect(last.isLive, false);
      await p.dispose();
    });

    test('width/height → onVideoSize；error → onError(fatal)', () async {
      final _FakePlatform platform = _FakePlatform();
      final MediaKitPlayer p = _build(platform: platform);
      int? w;
      int? h;
      p.onVideoSize = (int width, int height) {
        w = width;
        h = height;
      };
      String? message;
      bool? wasFatal;
      p.onError = (String m, {required bool fatal}) {
        message = m;
        wasFatal = fatal;
      };
      platform.emitWidth(1920);
      platform.emitHeight(1080);
      platform.emitError('解码失败');
      await Future<void>.delayed(Duration.zero);
      expect(w, 1920);
      expect(h, 1080);
      expect(message, '解码失败');
      expect(wasFatal, true);
      await p.dispose();
    });

    test('log → 按级别分派到 AppLog（不抛异常）', () async {
      final _FakePlatform platform = _FakePlatform();
      final MediaKitPlayer p = _build(platform: platform);
      platform.emitLog(const mk.PlayerLog(prefix: 'mpv', level: 'error', text: 'boom'));
      platform.emitLog(const mk.PlayerLog(prefix: 'mpv', level: 'warn', text: 'hmm'));
      platform.emitLog(const mk.PlayerLog(prefix: 'mpv', level: 'debug', text: 'dbg'));
      platform.emitLog(const mk.PlayerLog(prefix: 'mpv', level: 'info', text: 'ok'));
      await Future<void>.delayed(Duration.zero);
      // 仅验证 _log 分派不抛异常。
      await p.dispose();
    });
  });

  group('MediaKitPlayer 纹理面', () {
    test('textureId 取自注入的纹理通知；变化后触发 onTextureReady', () async {
      final ValueNotifier<int?> id = ValueNotifier<int?>(null);
      final MediaKitPlayer p = _build(textureId: id);
      expect(p.textureId, isNull);
      int? ready;
      p.onTextureReady = (int textureId) => ready = textureId;
      id.value = 7;
      await Future<void>.delayed(Duration.zero);
      expect(p.textureId, 7);
      expect(ready, 7);
      await p.dispose();
    });

    test('负句柄 / null 不触发 onTextureReady', () async {
      final ValueNotifier<int?> id = ValueNotifier<int?>(null);
      final MediaKitPlayer p = _build(textureId: id);
      int? ready;
      p.onTextureReady = (int textureId) => ready = textureId;
      id.value = -1;
      await Future<void>.delayed(Duration.zero);
      expect(ready, isNull);
      await p.dispose();
    });
  });

  // 云电脑「假性可用」：D3D11CreateDevice(HARDWARE) 探测通过，但实际 VA 能力
  // 不完整，libmpv 起播时报 Failed to allocate AVHWDeviceContext。此时必须自动
  // 降级软解（仅下调 hwdec=no，不重开媒体以规避并发竞态崩溃），而不是弹
  // 「加载失败」判死。
  group('MediaKitPlayer 硬解失败自动降级', () {
    test('stream.error 报 AVHWDeviceContext → 降级软解，不重开、不上报致命错误', () async {
      final _FakePlatform platform = _FakePlatform();
      final MediaKitPlayer p = _build(platform: platform);
      String? fatalMessage;
      p.onError = (String m, {required bool fatal}) => fatalMessage = m;

      await p.open(const PlayerSource(url: 'https://x/a.m3u8'));
      platform.calls.clear();

      platform.emitError('Failed to allocate AVHWDeviceContext.');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(fatalMessage, isNull, reason: '可恢复错误不应对用户弹加载失败');
      expect(platform.calls, isNot(contains('open')), reason: '降级只下调 hwdec，不应重开媒体（避免竞态崩溃）');
      await p.dispose();
    });

    test('mpv 日志流（不进 stream.error）的 AVHWDeviceContext 同样触发降级', () async {
      final _FakePlatform platform = _FakePlatform();
      final MediaKitPlayer p = _build(platform: platform);
      String? fatalMessage;
      p.onError = (String m, {required bool fatal}) => fatalMessage = m;

      await p.open(const PlayerSource(url: 'https://x/a.m3u8'));
      platform.calls.clear();

      platform.emitLog(const mk.PlayerLog(
        prefix: 'ffmpeg',
        level: 'error',
        text: 'Failed to allocate AVHWDeviceContext.',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(fatalMessage, isNull);
      expect(platform.calls, isNot(contains('open')));
      await p.dispose();
    });

    test('Could not create device 文案在 warn 级别同样触发降级', () async {
      final _FakePlatform platform = _FakePlatform();
      final MediaKitPlayer p = _build(platform: platform);
      String? fatalMessage;
      p.onError = (String m, {required bool fatal}) => fatalMessage = m;

      await p.open(const PlayerSource(url: 'https://x/b.mp4'));
      platform.calls.clear();

      platform.emitLog(const mk.PlayerLog(
        prefix: 'vo/d3d11',
        level: 'warn',
        text: 'Could not create device.',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(fatalMessage, isNull);
      expect(platform.calls, isNot(contains('open')));
      await p.dispose();
    });

    test('Failed to initialize a hardware decoder 文案同样触发降级', () async {
      final _FakePlatform platform = _FakePlatform();
      final MediaKitPlayer p = _build(platform: platform);
      String? fatalMessage;
      p.onError = (String m, {required bool fatal}) => fatalMessage = m;

      await p.open(const PlayerSource(url: 'https://x/c.mp4'));
      platform.calls.clear();

      platform.emitLog(const mk.PlayerLog(
        prefix: 'vd/ffmpeg',
        level: 'error',
        text: 'Failed to initialize a hardware decoder.',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(fatalMessage, isNull);
      expect(platform.calls, isNot(contains('open')));
      await p.dispose();
    });

    test('未 open（无播放源）时收到硬解错误 → 照常上报，不静默吞错误', () async {
      final _FakePlatform platform = _FakePlatform();
      final MediaKitPlayer p = _build(platform: platform);
      String? fatalMessage;
      p.onError = (String m, {required bool fatal}) => fatalMessage = m;

      platform.emitError('Failed to allocate AVHWDeviceContext.');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(fatalMessage, 'Failed to allocate AVHWDeviceContext.');
      await p.dispose();
    });

    test('降级后再次失败 → 正常上报致命错误（防抖，不无限重试）', () async {
      final _FakePlatform platform = _FakePlatform();
      final MediaKitPlayer p = _build(platform: platform);
      final List<String> messages = <String>[];
      p.onError = (String m, {required bool fatal}) => messages.add(m);

      await p.open(const PlayerSource(url: 'https://x/d.m3u8'));
      platform.emitError('Failed to allocate AVHWDeviceContext.');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(messages, isEmpty);

      platform.emitError('Failed to allocate AVHWDeviceContext.');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(messages, <String>['Failed to allocate AVHWDeviceContext.']);
      await p.dispose();
    });

    test('与硬解无关的错误 → 不触发降级，直接上报', () async {
      final _FakePlatform platform = _FakePlatform();
      final MediaKitPlayer p = _build(platform: platform);
      String? fatalMessage;
      p.onError = (String m, {required bool fatal}) => fatalMessage = m;

      await p.open(const PlayerSource(url: 'https://x/e.m3u8'));
      platform.calls.clear();

      platform.emitError('Failed to recognize file format.');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(fatalMessage, 'Failed to recognize file format.');
      expect(platform.calls, isNot(contains('open')));
      await p.dispose();
    });
  });
}