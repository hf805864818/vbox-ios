/// 平台层：非 AVPlayer 内核浮窗抽象（批次 C · C-09）。
///
/// 对齐 iOS `MDKPipManager` / `MPVPiPManager` / `VTPiPManager` /
/// `ViewCapturePiPManager` 等画中画/浮窗语义的 Flutter 等价抽象：
/// 把正在播放的媒体以系统级小窗形式呈现（离开页面继续观看）。
///
/// 四端差异：
///  - Android / TV：系统画中画（PiP，对齐 `player_pip_enabled`）或悬浮窗
///  - Windows / macOS：应用内置顶小窗（无系统级 PiP API）
///  - 未接线/不可用：降级 [NoopFloatingWindow]（`isAvailable=false`）
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// 浮窗状态。
enum FloatingWindowState {
  /// 隐藏。
  hidden,

  /// 可见（挂载中）。
  visible,

  /// 浮窗内播放中。
  playing,

  /// 浮窗内已暂停。
  paused,
}

/// 浮窗快照。
class FloatingWindowInfo {
  /// 构造。
  const FloatingWindowInfo({
    this.state = FloatingWindowState.hidden,
    this.title,
    this.positionMs = 0,
    this.durationMs = 0,
    this.isLive = false,
  });

  /// 浮窗状态。
  final FloatingWindowState state;

  /// 媒体标题。
  final String? title;

  /// 进度（毫秒）。
  final int positionMs;

  /// 时长（毫秒）。
  final int durationMs;

  /// 是否直播。
  final bool isLive;

  /// 是否可见。
  bool get isVisible => state != FloatingWindowState.hidden;

  FloatingWindowInfo copyWith({
    FloatingWindowState? state,
    String? title,
    int? positionMs,
    int? durationMs,
    bool? isLive,
  }) =>
      FloatingWindowInfo(
        state: state ?? this.state,
        title: title ?? this.title,
        positionMs: positionMs ?? this.positionMs,
        durationMs: durationMs ?? this.durationMs,
        isLive: isLive ?? this.isLive,
      );

  factory FloatingWindowInfo.fromJson(Map<String, Object?> j) {
    final String? raw = j['state']?.toString();
    return FloatingWindowInfo(
      state: FloatingWindowState.values.asNameMap()[raw] ??
          FloatingWindowState.hidden,
      title: j['title']?.toString(),
      positionMs: (j['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
      isLive: j['isLive'] as bool? ?? false,
    );
  }
}

/// 浮窗控制器抽象（可注入）。
abstract class FloatingWindow {
  /// 是否可用（平台未接线 / 系统不支持时 false）。
  bool get isAvailable;

  /// 最近浮窗快照。
  FloatingWindowInfo get info;

  /// 浮窗状态/进度变化回调。
  void Function(FloatingWindowInfo info)? onChanged;

  /// 浮窗手势回调（对齐 iOS `PiPHelper` 三手势：`tap` → toggle 播放、
  /// `doubleTap` → 恢复全屏、`close` → 关闭浮窗；原生端回传）。
  void Function(String gesture)? onGesture;

  /// 显示浮窗（[width]/[height] 为初始尺寸，可缺省走平台默认）。
  Future<bool> show({double? width, double? height});

  /// 隐藏浮窗（不销毁媒体会话）。
  Future<void> hide();

  /// 更新标题与媒体元信息。
  Future<void> setMedia({String? title, bool? isLive});

  /// 进度上报（原生浮窗可能消费）。
  Future<void> updateProgress(int positionMs, int durationMs);

  /// 更新浮窗截图快照（对齐 iOS `updateFloatingSnapshot`：RepaintBoundary →
  /// PNG bytes → 原生浮窗换图；原生未传 bytes 时 no-op）。
  Future<void> updateSnapshot(Uint8List? png);

  /// 释放浮窗（销毁媒体会话）。
  Future<void> dispose();
}

/// 未接线 / 平台不支持时的降级浮窗控制器。
class NoopFloatingWindow implements FloatingWindow {
  /// 构造。
  NoopFloatingWindow();

  @override
  bool get isAvailable => false;

  @override
  FloatingWindowInfo get info => const FloatingWindowInfo();

  @override
  void Function(FloatingWindowInfo info)? onChanged;

  @override
  void Function(String gesture)? onGesture;

  @override
  Future<bool> show({double? width, double? height}) async => false;

  @override
  Future<void> hide() async {}

  @override
  Future<void> setMedia({String? title, bool? isLive}) async {}

  @override
  Future<void> updateProgress(int positionMs, int durationMs) async {}

  @override
  Future<void> updateSnapshot(Uint8List? png) async {}

  @override
  Future<void> dispose() async {}
}

/// 浮窗通道桥（可注入；测试注入 fake 桥）。
abstract class FloatingWindowBridge {
  /// 调用原生浮窗方法（`show` / `hide` / `setMedia` / `updateProgress` /
  /// `dispose` / `isAvailable`）。
  Future<Object?> invoke(String method, [Object? arguments]);

  /// 原生浮窗事件流（`info`）。
  Stream<Map<String, Object?>> events();

  /// 释放桥资源。
  Future<void> dispose();
}

/// 真实平台通道实现（Android / macOS 原生浮窗插件 ↔ Dart）。
class MethodChannelFloatingBridge implements FloatingWindowBridge {
  /// 构造。
  MethodChannelFloatingBridge()
      : _channel = const MethodChannel('com.vbox.player/floating'),
        _events = const EventChannel('com.vbox.player/floating/events');

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

/// 平台通道浮窗控制器实现。
class MethodChannelFloatingWindow implements FloatingWindow {
  /// 构造（[bridge] 可注入测试假桥）。
  MethodChannelFloatingWindow({FloatingWindowBridge? bridge})
      : _bridge = bridge ?? MethodChannelFloatingBridge() {
    // 缺插件（桌面 / 单测）时事件流会抛错：兜住，避免未处理异步异常。
    _sub = _bridge.events().listen(_onEvent, onError: (Object _) {});
  }

  final FloatingWindowBridge _bridge;
  late final StreamSubscription<Map<String, Object?>> _sub;

  FloatingWindowInfo _info = const FloatingWindowInfo();

  @override
  bool get isAvailable {
    return _available ?? false;
  }

  bool? _available;

  @override
  FloatingWindowInfo get info => _info;

  @override
  void Function(FloatingWindowInfo info)? onChanged;

  @override
  void Function(String gesture)? onGesture;

  @override
  Future<bool> show({double? width, double? height}) async {
    try {
      final Object? ok = await _bridge.invoke('show', <String, Object?>{
        if (width != null) 'width': width,
        if (height != null) 'height': height,
      });
      _available = true;
      if (ok == true) {
        _info = _info.copyWith(state: FloatingWindowState.visible);
        onChanged?.call(_info);
      }
      return ok == true;
    } on PlatformException {
      _available = false;
      return false;
    }
  }

  @override
  Future<void> hide() async {
    try {
      await _bridge.invoke('hide');
    } on PlatformException {
      // 忽略
    }
    _info = _info.copyWith(state: FloatingWindowState.hidden);
    onChanged?.call(_info);
  }

  @override
  Future<void> setMedia({String? title, bool? isLive}) async {
    _info = _info.copyWith(title: title, isLive: isLive);
    try {
      await _bridge.invoke('setMedia', <String, Object?>{
        if (title != null) 'title': title,
        if (isLive != null) 'isLive': isLive,
      });
    } on PlatformException {
      // 忽略
    }
    onChanged?.call(_info);
  }

  @override
  Future<void> updateProgress(int positionMs, int durationMs) async {
    _info = _info.copyWith(positionMs: positionMs, durationMs: durationMs);
    try {
      await _bridge.invoke('updateProgress', <String, Object?>{
        'positionMs': positionMs,
        'durationMs': durationMs,
      });
    } on PlatformException {
      // 忽略
    }
    onChanged?.call(_info);
  }

  @override
  Future<void> updateSnapshot(Uint8List? png) async {
    try {
      await _bridge.invoke('update', <String, Object?>{
        if (png != null) 'bytes': png,
      });
    } on PlatformException {
      // 忽略
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await _bridge.invoke('dispose');
    } on PlatformException {
      // 忽略
    }
    await _sub.cancel();
    await _bridge.dispose();
    _info = const FloatingWindowInfo();
    onChanged?.call(_info);
  }

  void _onEvent(Map<String, Object?> e) {
    final String type = (e['type'] ?? '').toString();
    // 浮窗手势事件（原生端回传：tap / doubleTap / close）→ 转发消费方。
    if (type == 'tap' || type == 'doubleTap' || type == 'close') {
      onGesture?.call(type);
      return;
    }
    if (type != 'info') return;
    final Map<String, Object?> value =
        (e['value'] as Map? ?? const <String, Object?>{}).cast<String, Object?>();
    _info = FloatingWindowInfo.fromJson(value);
    onChanged?.call(_info);
  }
}
