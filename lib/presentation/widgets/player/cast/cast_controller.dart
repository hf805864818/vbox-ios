/// 表现层：投屏控制器（批次 C · C-09）。
///
/// 包装 [CastService]，向 UI 暴露「设备列表 / 搜索中 / 会话状态」与
/// 「发现 → 连接投送 → 断开」动作（对齐 iOS `AVRoutePickerView` 的交互语义）。
/// 网络与协议失败一律降级（空列表 / false），不抛异常。
library;

import 'package:flutter/foundation.dart';

import '../../../../platform/player/cast/cast.dart';

/// 投屏控制器（UI 侧状态容器）。
class CastController extends ChangeNotifier {
  /// 构造（接管 [service] 的会话 / 设备回调）。
  CastController({required CastService service}) : _service = service {
    _service.onSessionChanged = _onSession;
    _service.onDevicesChanged = _onDevices;
  }

  final CastService _service;

  CastSession? _session;
  List<CastDevice> _devices = const <CastDevice>[];
  bool _discovering = false;

  /// 底层投屏服务。
  CastService get service => _service;

  /// 当前平台是否具备投屏能力（false 时调用方隐藏入口）。
  bool get isAvailable => _service.isAvailable;

  /// 当前会话（未连接为 null）。
  CastSession? get session => _session ?? _service.session;

  /// 已发现设备列表。
  List<CastDevice> get devices => _devices;

  /// 是否正在搜索设备。
  bool get discovering => _discovering;

  /// 是否正在投屏（会话活跃）。
  bool get isCasting => session?.isActive ?? false;

  /// 正在投屏的设备名（未投屏为 null）。
  String? get castingDeviceName => isCasting ? session?.device?.name : null;

  /// 发现设备（[timeout] 为发现窗口）；失败降级为空列表。
  Future<List<CastDevice>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _discovering = true;
    notifyListeners();
    try {
      _devices = await _service.discover(timeout: timeout);
      return _devices;
    } catch (_) {
      _devices = const <CastDevice>[];
      return _devices;
    } finally {
      _discovering = false;
      notifyListeners();
    }
  }

  /// 连接并投送媒体；任一步失败 → 断开并返回 false。
  Future<bool> castTo(CastDevice device, CastMedia media) async {
    final bool connected = await _service.connect(device);
    if (!connected) return false;
    final bool ok = await _service.cast(media);
    if (!ok) {
      await _service.disconnect();
      return false;
    }
    return true;
  }

  /// 断开当前会话。
  Future<void> disconnect() async {
    await _service.disconnect();
  }

  /// 停止投送（保持连接）。
  Future<void> stop() => _service.stop();

  /// 播放 / 恢复目标端。
  Future<void> play() => _service.play();

  /// 暂停目标端。
  Future<void> pause() => _service.pause();

  /// 目标端跳转（毫秒）。
  Future<void> seekTo(int positionMs) => _service.seekTo(positionMs);

  void _onSession(CastSession session) {
    _session = session;
    notifyListeners();
  }

  void _onDevices(List<CastDevice> devices) {
    _devices = devices;
    notifyListeners();
  }

  @override
  void dispose() {
    _service.onSessionChanged = null;
    _service.onDevicesChanged = null;
    super.dispose();
  }
}