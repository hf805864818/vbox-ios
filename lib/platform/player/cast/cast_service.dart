/// 平台层：投屏抽象（批次 C · C-09 投屏 / AirPlay 等价）。
///
/// 对齐 iOS 侧 `AVRoutePickerView` / 系统投屏语义的 Flutter 等价抽象：
/// 发现投屏目标 → 连接 → 投送媒体 → 会话内播放控制（播放/暂停/跳转/音量）
/// → 断开。四端差异：
///  - Android / TV：DLNA / Chromecast 类目标（原生插件实现）
///  - Windows / macOS：系统投屏（Windows 混音器投屏 / macOS AirPlay）或插件实现
///  - 未接线/不可用：降级 [NoopCastService]（`isAvailable=false`，调用方隐藏入口）
///
/// 与 [PlayerChannelBridge] 同模式：抽象注入点，测试注入 fake。
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// 投屏目标设备类型。
enum CastDeviceKind {
  /// AirPlay（macOS 系统投屏）。
  airplay,

  /// DLNA 设备。
  dlna,

  /// Chromecast。
  chromecast,

  /// 未知/通用。
  unknown;

  static CastDeviceKind fromWire(String? v) => switch (v) {
        'airplay' => CastDeviceKind.airplay,
        'dlna' => CastDeviceKind.dlna,
        'chromecast' => CastDeviceKind.chromecast,
        _ => CastDeviceKind.unknown,
      };
}

/// 投屏目标设备。
class CastDevice {
  /// 构造。
  const CastDevice({
    required this.id,
    required this.name,
    this.kind = CastDeviceKind.unknown,
  });

  /// 设备唯一标识。
  final String id;

  /// 设备显示名。
  final String name;

  /// 设备类型。
  final CastDeviceKind kind;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'kind': kind.name,
      };

  factory CastDevice.fromJson(Map<String, Object?> j) => CastDevice(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        kind: CastDeviceKind.fromWire(j['kind']?.toString()),
      );
}

/// 待投送的媒体（对齐 [PlayerSource] 的投屏侧投影）。
class CastMedia {
  /// 构造。
  const CastMedia({
    required this.url,
    this.title,
    this.poster,
    this.headers = const <String, String>{},
    this.isLive = false,
    this.positionMs = 0,
    this.mimeType,
  });

  /// 媒体地址。
  final String url;

  /// 显示标题。
  final String? title;

  /// 封面图。
  final String? poster;

  /// 鉴权头（DLNA 等部分目标需要）。
  final Map<String, String> headers;

  /// 是否直播流。
  final bool isLive;

  /// 续播位置（毫秒）。
  final int positionMs;

  /// MIME 类型。
  final String? mimeType;

  Map<String, Object?> toJson() => <String, Object?>{
        'url': url,
        if (title != null) 'title': title,
        if (poster != null) 'poster': poster,
        if (headers.isNotEmpty) 'headers': headers,
        'isLive': isLive,
        'positionMs': positionMs,
        if (mimeType != null) 'mimeType': mimeType,
      };
}

/// 投屏会话状态。
enum CastSessionState {
  /// 空闲（无目标）。
  idle,

  /// 连接中。
  connecting,

  /// 已连接（待投送）。
  connected,

  /// 投送中（播放中）。
  playing,

  /// 投送中（已暂停）。
  paused,

  /// 已断开。
  disconnected,
}

/// 投屏会话快照。
class CastSession {
  /// 构造。
  const CastSession({
    this.device,
    this.state = CastSessionState.idle,
    this.title,
    this.positionMs = 0,
    this.durationMs = 0,
    this.isLive = false,
  });

  /// 当前目标设备（未连接为 null）。
  final CastDevice? device;

  /// 会话状态。
  final CastSessionState state;

  /// 正在投送的媒体标题。
  final String? title;

  /// 目标端进度（毫秒）。
  final int positionMs;

  /// 目标端时长（毫秒）。
  final int durationMs;

  /// 是否直播。
  final bool isLive;

  /// 是否已建立会话（连接中/已连接/播放/暂停）。
  bool get isActive =>
      state == CastSessionState.connecting ||
      state == CastSessionState.connected ||
      state == CastSessionState.playing ||
      state == CastSessionState.paused;

  CastSession copyWith({
    CastDevice? device,
    CastSessionState? state,
    String? title,
    int? positionMs,
    int? durationMs,
    bool? isLive,
  }) =>
      CastSession(
        device: device ?? this.device,
        state: state ?? this.state,
        title: title ?? this.title,
        positionMs: positionMs ?? this.positionMs,
        durationMs: durationMs ?? this.durationMs,
        isLive: isLive ?? this.isLive,
      );

  factory CastSession.fromJson(Map<String, Object?> j) {
    final Map<String, Object?>? deviceJson = j['device'] as Map<String, Object?>?;
    return CastSession(
      device: deviceJson == null ? null : CastDevice.fromJson(deviceJson),
      state: CastSessionState.values.asNameMap()[j['state']] ??
          CastSessionState.idle,
      title: j['title']?.toString(),
      positionMs: (j['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
      isLive: j['isLive'] as bool? ?? false,
    );
  }
}

/// 投屏服务抽象（可注入）。
///
/// 调用约定：
///  - `discover` 发现目标 → 调用方展示列表；
///  - `connect` + `cast` 建立会话并投送；
///  - 播放控制在投送成功后调用；`disconnect` 结束会话。
abstract class CastService {
  /// 是否可用（平台未接线 / 无投屏能力时 false）。
  bool get isAvailable;

  /// 当前会话（未连接为 null）。
  CastSession? get session;

  /// 会话变化回调（连接/断开/状态切换）。
  void Function(CastSession session)? onSessionChanged;

  /// 设备列表变化回调（发现结果增量推送）。
  void Function(List<CastDevice> devices)? onDevicesChanged;

  /// 发现投屏目标（[timeout] 为发现窗口）。
  Future<List<CastDevice>> discover({Duration timeout = const Duration(seconds: 5)});

  /// 连接目标设备。
  Future<bool> connect(CastDevice device);

  /// 断开当前会话。
  Future<void> disconnect();

  /// 投送媒体到当前目标（需先 [connect]）。
  Future<bool> cast(CastMedia media);

  /// 播放 / 恢复。
  Future<void> play();

  /// 暂停。
  Future<void> pause();

  /// 跳转（毫秒）。
  Future<void> seekTo(int positionMs);

  /// 设置音量（0.0 ~ 1.0）。
  Future<void> setVolume(double volume);

  /// 停止投送（保持连接）。
  Future<void> stop();
}

/// 未接线 / 平台不可用时的降级投屏服务。
///
/// `isAvailable=false`、[discover] 返回空、[connect]/[cast] 返回 false，
/// 其余控制为 no-op。调用方（播放器控制层）应据此隐藏投屏入口。
class NoopCastService implements CastService {
  /// 构造。
  NoopCastService();

  @override
  bool get isAvailable => false;

  @override
  CastSession? get session => null;

  @override
  void Function(CastSession session)? onSessionChanged;

  @override
  void Function(List<CastDevice> devices)? onDevicesChanged;

  @override
  Future<List<CastDevice>> discover({Duration timeout = const Duration(seconds: 5)}) async =>
      const <CastDevice>[];

  @override
  Future<bool> connect(CastDevice device) async => false;

  @override
  Future<void> disconnect() async {}

  @override
  Future<bool> cast(CastMedia media) async => false;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seekTo(int positionMs) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {}
}

/// 投屏通道桥（可注入；测试注入 fake 桥）。
abstract class CastChannelBridge {
  /// 调用原生投屏方法（`discover` / `connect` / `disconnect` / `cast` /
  /// `play` / `pause` / `seekTo` / `setVolume` / `stop` / `isAvailable`）。
  Future<Object?> invoke(String method, [Object? arguments]);

  /// 原生会话/设备事件流（`session` / `devices`）。
  Stream<Map<String, Object?>> events();

  /// 释放桥资源。
  Future<void> dispose();
}

/// 真实平台通道实现（Android / macOS 原生投屏插件 ↔ Dart）。
class MethodChannelCastBridge implements CastChannelBridge {
  /// 构造。
  MethodChannelCastBridge()
      : _channel = const MethodChannel('com.vbox.player/cast'),
        _events = const EventChannel('com.vbox.player/cast/events');

  final MethodChannel _channel;
  final EventChannel _events;

  @override
  Future<Object?> invoke(String method, [Object? arguments]) =>
      _channel.invokeMethod(method, arguments);

  @override
  Stream<Map<String, Object?>> events() => _events
      .receiveBroadcastStream()
      .map((Object? e) => (e as Map).cast<String, Object?>());

  @override
  Future<void> dispose() async {}
}

/// 平台通道投屏服务实现。
class MethodChannelCastService implements CastService {
  /// 构造（[bridge] 可注入测试假桥）。
  MethodChannelCastService({CastChannelBridge? bridge}) : _bridge = bridge ?? MethodChannelCastBridge() {
    _sub = _bridge.events().listen(_onEvent);
  }

  final CastChannelBridge _bridge;
  late final StreamSubscription<Map<String, Object?>> _sub;

  CastSession? _session;

  @override
  bool get isAvailable {
    // 懒探测：isAvailable 由原生返回；未知时尝试查询一次（失败视为不可用）。
    return _available ?? false;
  }

  bool? _available;

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
    try {
      final Object? result = await _bridge.invoke('discover', <String, Object?>{
        'timeoutMs': timeout.inMilliseconds,
      });
      _available = true;
      return _parseDevices(result);
    } on PlatformException {
      _available = false;
      return const <CastDevice>[];
    }
  }

  @override
  Future<bool> connect(CastDevice device) async {
    try {
      final Object? ok = await _bridge.invoke('connect', device.toJson());
      if (ok == true) {
        _session = CastSession(device: device, state: CastSessionState.connecting);
        onSessionChanged?.call(_session!);
      }
      return ok == true;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      await _bridge.invoke('disconnect');
    } on PlatformException {
      // 忽略
    }
    _session = null;
    onSessionChanged?.call(const CastSession(state: CastSessionState.disconnected));
  }

  @override
  Future<bool> cast(CastMedia media) async {
    try {
      final Object? ok = await _bridge.invoke('cast', media.toJson());
      if (ok == true && _session != null) {
        _session = _session!.copyWith(
          state: CastSessionState.playing,
          title: media.title,
          isLive: media.isLive,
        );
        onSessionChanged?.call(_session!);
      }
      return ok == true;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> play() => _invoke('play');

  @override
  Future<void> pause() => _invoke('pause');

  @override
  Future<void> seekTo(int positionMs) => _invoke('seekTo', positionMs);

  @override
  Future<void> setVolume(double volume) => _invoke('setVolume', volume);

  @override
  Future<void> stop() => _invoke('stop');

  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _bridge.invoke(method, arguments);
    } on PlatformException {
      // 控制类方法失败不阻断
    }
  }

  void _onEvent(Map<String, Object?> e) {
    switch ((e['type'] ?? '').toString()) {
      case 'session':
        _session = CastSession.fromJson(
          (e['value'] as Map? ?? const <String, Object?>{}).cast<String, Object?>(),
        );
        onSessionChanged?.call(_session!);
      case 'devices':
        onDevicesChanged?.call(_parseDevices(e['value']));
    }
  }

  List<CastDevice> _parseDevices(Object? value) {
    if (value is! List) return const <CastDevice>[];
    return value
        .whereType<Map>()
        .map((Object? m) =>
            CastDevice.fromJson((m as Map).cast<String, Object?>()))
        .toList();
  }

  Future<void> dispose() async {
    await _sub.cancel();
    await _bridge.dispose();
  }
}
