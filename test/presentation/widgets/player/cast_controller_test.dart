/// 表现层单测：投屏控制器（批次 C · C-09）。
///
/// 注入假 [CastService]，验证「发现 → 连接投送 → 断开」状态流转与降级
/// （网络/协议失败不抛异常）。无原生依赖、无 IO。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/player/cast/cast.dart';
import 'package:vbox/presentation/widgets/player/cast/cast_controller.dart';

/// 可编排的假投屏服务：逐方法注入返回，记录调用序列。
class _FakeCastService implements CastService {
  _FakeCastService({this.available = true});

  bool available;
  List<CastDevice> discoverResult = const <CastDevice>[];
  bool discoverThrows = false;
  bool connectResult = true;
  bool castResult = true;

  final List<String> calls = <String>[];
  CastSession? _session;

  @override
  bool get isAvailable => available;

  @override
  CastSession? get session => _session;

  @override
  void Function(CastSession session)? onSessionChanged;

  @override
  void Function(List<CastDevice> devices)? onDevicesChanged;

  @override
  Future<List<CastDevice>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    calls.add('discover');
    if (discoverThrows) throw StateError('boom');
    onDevicesChanged?.call(discoverResult);
    return discoverResult;
  }

  @override
  Future<bool> connect(CastDevice device) async {
    calls.add('connect');
    if (connectResult) {
      _session = CastSession(device: device, state: CastSessionState.connected);
      onSessionChanged?.call(_session!);
    }
    return connectResult;
  }

  @override
  Future<void> disconnect() async {
    calls.add('disconnect');
    _session = null;
    onSessionChanged?.call(const CastSession(state: CastSessionState.disconnected));
  }

  @override
  Future<bool> cast(CastMedia media) async {
    calls.add('cast');
    if (castResult && _session != null) {
      _session = _session!.copyWith(
        state: CastSessionState.playing,
        title: media.title,
      );
      onSessionChanged?.call(_session!);
    }
    return castResult;
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seekTo(int positionMs) async => calls.add('seekTo');

  @override
  Future<void> setVolume(double volume) async => calls.add('setVolume');

  @override
  Future<void> stop() async => calls.add('stop');
}

void main() {
  const CastDevice tv = CastDevice(id: 'tv-1', name: '客厅电视');
  const CastMedia media = CastMedia(url: 'http://x/1.m3u8', title: '片名');

  group('CastController', () {
    test('discover 更新设备列表并复位 discovering', () async {
      final _FakeCastService svc = _FakeCastService()
        ..discoverResult = <CastDevice>[tv];
      final CastController ctrl = CastController(service: svc);
      int notified = 0;
      ctrl.addListener(() => notified++);

      final List<CastDevice> devices = await ctrl.discover();

      expect(devices.single.id, 'tv-1');
      expect(ctrl.devices.single.name, '客厅电视');
      expect(ctrl.discovering, isFalse);
      // 开始（true）+ 结束（false）各一次
      expect(notified, greaterThanOrEqualTo(2));
    });

    test('discover 抛异常 → 降级空列表且不抛出', () async {
      final _FakeCastService svc = _FakeCastService()..discoverThrows = true;
      final CastController ctrl = CastController(service: svc);

      final List<CastDevice> devices = await ctrl.discover();

      expect(devices, isEmpty);
      expect(ctrl.devices, isEmpty);
      expect(ctrl.discovering, isFalse);
    });

    test('castTo 成功 → 会话活跃且暴露设备名', () async {
      final _FakeCastService svc = _FakeCastService();
      final CastController ctrl = CastController(service: svc);

      final bool ok = await ctrl.castTo(tv, media);

      expect(ok, isTrue);
      expect(ctrl.isCasting, isTrue);
      expect(ctrl.castingDeviceName, '客厅电视');
      expect(svc.calls, <String>['connect', 'cast']);
    });

    test('castTo 连接失败 → 不投送，返回 false', () async {
      final _FakeCastService svc = _FakeCastService()..connectResult = false;
      final CastController ctrl = CastController(service: svc);

      expect(await ctrl.castTo(tv, media), isFalse);
      expect(svc.calls, <String>['connect']);
      expect(ctrl.isCasting, isFalse);
    });

    test('castTo 投送失败 → 自动断开并返回 false', () async {
      final _FakeCastService svc = _FakeCastService()..castResult = false;
      final CastController ctrl = CastController(service: svc);

      expect(await ctrl.castTo(tv, media), isFalse);
      expect(svc.calls, <String>['connect', 'cast', 'disconnect']);
      expect(ctrl.isCasting, isFalse);
    });

    test('会话回调驱动 isCasting / castingDeviceName', () async {
      final _FakeCastService svc = _FakeCastService();
      final CastController ctrl = CastController(service: svc);

      svc.onSessionChanged?.call(
        const CastSession(device: tv, state: CastSessionState.playing),
      );
      expect(ctrl.isCasting, isTrue);
      expect(ctrl.castingDeviceName, '客厅电视');

      svc.onSessionChanged?.call(
        const CastSession(state: CastSessionState.disconnected),
      );
      expect(ctrl.isCasting, isFalse);
      expect(ctrl.castingDeviceName, isNull);
    });

    test('disconnect / 控制方法透传到底层服务', () async {
      final _FakeCastService svc = _FakeCastService();
      final CastController ctrl = CastController(service: svc);

      await ctrl.play();
      await ctrl.pause();
      await ctrl.seekTo(1000);
      await ctrl.stop();
      await ctrl.disconnect();

      expect(svc.calls, <String>['play', 'pause', 'seekTo', 'stop', 'disconnect']);
    });

    test('isAvailable 透传平台能力', () {
      expect(CastController(service: _FakeCastService(available: true)).isAvailable, isTrue);
      expect(CastController(service: _FakeCastService(available: false)).isAvailable, isFalse);
    });

    test('dispose 解绑底层回调', () {
      final _FakeCastService svc = _FakeCastService();
      final CastController ctrl = CastController(service: svc);
      ctrl.dispose();
      expect(svc.onSessionChanged, isNull);
      expect(svc.onDevicesChanged, isNull);
    });
  });
}