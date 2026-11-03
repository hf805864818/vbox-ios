/// 平台层：media_kit 播放器内核（实现 [Player]）。
///
/// 纯 Dart 直连 media_kit（底层 libmpv，FFmpeg 解码 + libmpv 上屏），不经
/// MethodChannel。替代 Windows/macOS 自研 mpv 渲染桥（OpenGL FBO + libswscale
/// 软渲染，云电脑上「有声无画」）。
///
/// 硬解 / 软解**自适应**：正常用户机器硬解优先（d3d11va / VideoToolbox）；经
/// [HardwareGpuProbe] 探测到无硬件 GPU（云电脑测试环境，ANGLE/EGL 渲染表面会
/// 创建失败并连带起播崩溃）时自动切软解。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show ValueListenable, visibleForTesting;
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkv;

import '../../core/utils/logger.dart';
import '../../domain/entities/player/player.dart';
import 'hardware_gpu_probe.dart';
import 'media_kit_profile.dart';

/// media_kit 内核（单后端实例）。
///
/// 一个 [MediaKitPlayer] 绑定 [PlayerBackend.mediaKit]；与 [ChannelPlayer] 一样由
/// [PlayerController] 创建，未来插回多内核时由降级链逐个重开。
class MediaKitPlayer implements Player {
  MediaKitPlayer({
    required this.backend,
    @visibleForTesting mk.Player? core,
    @visibleForTesting ValueListenable<int?>? textureId,
    @visibleForTesting bool? hardwareAcceleration,
  }) {
    _mpv = core ?? _createPlayer();
    _resolveHardwareAcceleration(hardwareAcceleration);
    _textureId = textureId ??
        mkv.VideoController(
          _mpv,
          configuration: mkv.VideoControllerConfiguration(
            enableHardwareAcceleration: _hwAccel,
          ),
        ).id;
    _bindStreams();
    _textureId.addListener(_onTextureId);
    AppLog.info(
      'player-media_kit',
      '内核解码配置：${_hwAccel ? '硬解优先' : '软解'} —— $_hwAccelReason',
      category: LogCategory.player,
    );
  }

  bool _hwAccel = true;
  String _hwAccelReason = '';

  /// 是否已因硬解设备分配失败降级过（每次实例生命周期内最多降级一次，防抖）。
  bool _hwdecFailed = false;

  /// 最近一次 [open] 的播放源，供硬解失败后软解重开媒体使用。
  PlayerSource? _currentSource;

  /// 自适应判定是否启用硬件解码（GPU 渲染）。
  ///
  /// 正常用户机器硬解优先；经 [HardwareGpuProbe] 探测无硬件 GPU（云电脑测试
  /// 环境）时切软解，避免 d3d11va + ANGLE/EGL 渲染表面创建失败导致的起播崩溃。
  void _resolveHardwareAcceleration(bool? forced) {
    if (forced != null) {
      _hwAccel = forced;
      _hwAccelReason = '强制指定（测试注入）';
      return;
    }
    if (!Platform.isWindows) {
      _hwAccel = true;
      _hwAccelReason = '非 Windows，硬解优先（VideoToolbox 自带软件回退）';
      return;
    }
    switch (HardwareGpuProbe.probe()) {
      case GpuProbeVerdict.available:
        _hwAccel = true;
        _hwAccelReason = 'Windows 探测到硬件 GPU，硬解优先';
        return;
      case GpuProbeVerdict.unavailable:
        _hwAccel = false;
        _hwAccelReason = 'Windows 未探测到硬件 GPU（云电脑/无 GPU），切软解';
        return;
      case GpuProbeVerdict.unknown:
        _hwAccel = false;
        _hwAccelReason = 'Windows GPU 探测不可用（d3d11.dll 缺失或异常），保守软解';
        return;
    }
  }

  static mk.Player _createPlayer() {
    mk.MediaKit.ensureInitialized();
    return mk.Player();
  }

  @override
  final PlayerBackend backend;

  late final mk.Player _mpv;
  late final ValueListenable<int?> _textureId;

  final List<StreamSubscription<Object?>> _subs = <StreamSubscription<Object?>>[];

  // 进度合并缓存：media_kit 的 position/duration/buffer 独立成流，据此合成
  // [PlaybackProgress]（对齐 ChannelPlayer 的 progress 事件口径）。
  int _positionMs = 0;
  int _durationMs = 0;
  int _bufferedMs = 0;
  int _width = 0;
  int _height = 0;
  bool _isLive = false;
  bool _disposed = false;

  @override
  int? get textureId => _textureId.value;

  @override
  List<PlayerBackend> get availableBackends => <PlayerBackend>[backend];

  @override
  void Function(PlayerState)? onStateChanged;

  @override
  void Function(PlaybackProgress)? onProgress;

  @override
  void Function(int width, int height)? onVideoSize;

  @override
  void Function(int textureId)? onTextureReady;

  @override
  void Function(String message, {required bool fatal})? onError;

  // ─────────────── 控制面 ───────────────

  @override
  Future<void> open(PlayerSource source) async {
    _isLive = source.isLive;
    _currentSource = source;
    // 诊断「Failed to recognize file format」：记录实际下发的播放地址与鉴权头，
    // 判断是缺少 Referer/UA/Cookie 被判盗链返回 HTML，还是地址本身非直链。
    final String? referer = _lookupHeader(source.headers, 'Referer');
    final String? ua = _lookupHeader(source.headers, 'User-Agent');
    final bool hasCookie = _lookupHeader(source.headers, 'Cookie') != null;
    AppLog.info(
      'player-media_kit',
      '打开媒体：${source.url}（isLive=${source.isLive}, '
          'mimeType=${source.mimeType ?? '-'}, referer=${referer ?? '-'}, '
          'ua=${ua ?? '-'}, cookie=$hasCookie）',
      category: LogCategory.player,
    );
    final mk.Media media = mk.Media(
      source.url,
      httpHeaders: source.headers.isEmpty ? null : source.headers,
    );
    await _applyTuning(source);
    await _mpv.open(media, play: false);
  }

  /// 硬解「假性可用」的自动降级：探测说 D3D11 设备可用，但实际解码设备分配
  /// 失败（日志 `Failed to allocate AVHWDeviceContext`，常见于部分云电脑/虚拟化
  /// 环境——`D3D11CreateDevice(HARDWARE)` 能成功，却拿不到完整的 VA 能力）。
  ///
  /// 处理策略：只把解码端 `hwdec` 幂等下调到 `no`，**不再 stop + 二次 loadfile
  /// 重开媒体**——
  ///   1. `hwdec=auto-safe` 本身就会安全回退软解，无需重开即可继续播；
  ///   2. 历史实现重开媒体会与前端 `open`/`_applyTuning` 并发交错，使 mpv 同时
  ///      收到 stop/setProperty/两次 loadfile，命令回复 userdata 被释放后仍被访问，
  ///      触发 `MPV_EVENT_COMMAND_REPLY` 的空指针崩溃（日志 `event:5 Pointer`），
  ///      是百度 Node/网盘播放闪退的直接根因。
  /// **不重建 `VideoController`**——纹理句柄保持不变，播放页无需重绑，风险最小。
  /// 降级在实例生命周期内只执行一次（[_hwdecFailed] 防抖），失败后由
  /// `error` 流正常上报致命错误，避免无限重试。
  Future<void> _fallbackToSoftwareDecode() async {
    if (_hwdecFailed) return;
    final PlayerSource? source = _currentSource;
    if (source == null) return;
    _hwdecFailed = true;
    _hwAccel = false;
    _hwAccelReason = '运行时检测到硬件解码/渲染失败，已自动降级软解';
    AppLog.warn(
      'player-media_kit',
      '硬件解码/渲染失败，自动降级软解（hwdec=no，不重开媒体，auto-safe 已自行回退）：'
      '${source.url}',
      category: LogCategory.player,
    );
    // 幂等下调 hwdec=no，防止后续 seek/重连再尝试硬解。不触碰 stop/loadfile，
    // 与前端 open 并发也安全（mpv 命令队列按序处理 setProperty，无 use-after-free）。
    final mk.PlatformPlayer? platform = _mpv.platform;
    if (platform is mk.NativePlayer) {
      try {
        await platform.setProperty('hwdec', 'no');
      } catch (e) {
        // 属性下发失败不阻断；`_hwAccel=false` 已保证后续 open 走软解。
        AppLog.warn(
          'player-media_kit',
          '降级时下发 hwdec=no 失败：$e',
          category: LogCategory.player,
        );
      }
    }
  }

  /// 大小写不敏感读取自定义请求头（诊断鉴权头是否缺 Referer/UA/Cookie）。
  static String? _lookupHeader(Map<String, String> headers, String name) {
    if (headers.containsKey(name)) return headers[name];
    final String lower = name.toLowerCase();
    for (final MapEntry<String, String> e in headers.entries) {
      if (e.key.toLowerCase() == lower) return e.value;
    }
    return null;
  }

  @override
  Future<void> play() => _mpv.play();

  @override
  Future<void> pause() => _mpv.pause();

  @override
  Future<void> seekTo(int positionMs) async {
    if (_disposed) return;
    // 前置守卫（问题 5 闪退 · 异常 seek）：媒体未真正打开（时长未知）或目标越界
    // 时不下发 seek——原生 mpv 对非法 seek（size<0 / 越界）可能触发空指针崩溃。
    if (_durationMs <= 0) return;
    if (positionMs < 0 || positionMs > _durationMs) return;
    try {
      await _mpv.seek(Duration(milliseconds: positionMs));
    } catch (_) {
      // 媒体未真正打开（loadfile 排队期）或已释放的竞态下，原生 seek 可能抛错
      // 甚至空指针；此处吞掉，避免崩溃传播（真正严谨的是上层首帧就绪后才 seek）。
    }
  }

  /// [Player.setVolume] 契约是 0.0 ~ 1.0，media_kit 的 [mk.Player.setVolume] 是
  /// 0.0 ~ 100.0，此处转换。
  @override
  Future<void> setVolume(double volume) =>
      _mpv.setVolume((volume * 100.0).clamp(0.0, 100.0).toDouble());

  @override
  Future<void> setSpeed(double speed) => _mpv.setRate(speed);

  @override
  Future<void> dispose() async {
    _disposed = true;
    _textureId.removeListener(_onTextureId);
    for (final StreamSubscription<Object?> s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _mpv.dispose();
  }

  // ─────────────── 调优 ───────────────

  /// 对齐 uz 逆向下发的 libmpv 起播调优（hr-seek + demuxer 缓存）。
  Future<void> _applyTuning(PlayerSource source) async {
    final mk.PlatformPlayer? platform = _mpv.platform;
    if (platform is! mk.NativePlayer) return;
    final MediaKitProfile profile = MediaKitProfile.forSource(source);
    // 显式控制硬件**解码**（hwdec）。它与渲染表面（enableHardwareAcceleration）
    // 是两条独立路径：此前只控渲染、不控 hwdec，libmpv 默认 hwdec=auto 会在无真
    // GPU 的云电脑上反复尝试 dxva2_vld / CUDA，失败后才回退软解（日志里的
    // dxva2/CUDA/AVHWDeviceContext churn），造成起播卡顿（「一卡一卡」）与硬件
    // 回退错误被误判。软解时 hwdec=no 直接关闭解码端硬件探测；硬解时 auto-safe
    // 失败安全回退软解而非报错终止。
    final String hwdec = _hwAccel ? 'auto-safe' : 'no';
    await platform.setProperty('hwdec', hwdec);
    AppLog.info(
      'player-media_kit',
      '内核解码：hwdec=$hwdec',
      category: LogCategory.player,
    );
    await platform.setProperty('hr-seek', 'yes');
    await platform.setProperty(
      'demuxer-max-bytes',
      profile.demuxerMaxBytes.toString(),
    );
    await platform.setProperty(
      'demuxer-readahead-secs',
      profile.demuxerReadaheadSecs.toString(),
    );
  }

  // ─────────────── 事件面 ───────────────

  void _bindStreams() {
    _subs.add(_mpv.stream.playing.listen((bool playing) {
      onStateChanged?.call(playing ? PlayerState.playing : PlayerState.paused);
    }));
    _subs.add(_mpv.stream.buffering.listen((bool buffering) {
      if (buffering) onStateChanged?.call(PlayerState.buffering);
    }));
    _subs.add(_mpv.stream.completed.listen((bool completed) {
      if (completed) onStateChanged?.call(PlayerState.ended);
    }));
    _subs.add(_mpv.stream.position.listen((Duration d) {
      _positionMs = d.inMilliseconds;
      _emitProgress();
    }));
    _subs.add(_mpv.stream.duration.listen((Duration d) {
      _durationMs = d.inMilliseconds;
      _emitProgress();
    }));
    _subs.add(_mpv.stream.buffer.listen((Duration d) {
      _bufferedMs = d.inMilliseconds;
      _emitProgress();
    }));
    _subs.add(_mpv.stream.width.listen((int? w) {
      if (w != null) _width = w;
      _emitVideoSize();
    }));
    _subs.add(_mpv.stream.height.listen((int? h) {
      if (h != null) _height = h;
      _emitVideoSize();
    }));
    _subs.add(_mpv.stream.error.listen((String message) {
      // 硬解设备分配失败是可自动恢复的（auto-safe 已自行回退软解即可播），
      // 不能直接判死：先触发一次软解降级（仅下调 hwdec=no，不重开媒体，
      // 避免重开与前端 open 并发竞态导致崩溃），避免「明明能播却弹加载失败」。
      // 无播放源可重开时不拦，照常上报，避免把错误静默吞掉。
      if (!_hwdecFailed &&
          _hwAccel &&
          _currentSource != null &&
          _isHardwareFailure(message)) {
        AppLog.warn(
          'player-media_kit',
          '收到硬件解码/渲染失败错误，触发自动软解降级：$message',
          category: LogCategory.player,
        );
        unawaited(_fallbackToSoftwareDecode());
        return;
      }
      onError?.call(message, fatal: true);
    }));
    _subs.add(_mpv.stream.log.listen(_log));
  }

  void _emitProgress() {
    onProgress?.call(PlaybackProgress(
      positionMs: _positionMs,
      durationMs: _durationMs,
      bufferedMs: _bufferedMs,
      isLive: _isLive,
    ));
  }

  void _emitVideoSize() {
    if (_width > 0 && _height > 0) {
      onVideoSize?.call(_width, _height);
    }
  }

  void _onTextureId() {
    final int? id = _textureId.value;
    if (id != null && id >= 0) {
      onTextureReady?.call(id);
    }
  }

  /// 判定一条 mpv 日志/错误是否为「硬件路径失败」（可降级恢复，不应判死）。
  ///
  /// 覆盖 libmpv / FFmpeg 的硬件解码分配失败（Windows d3d11va 的
  /// `Failed to allocate AVHWDeviceContext.`、`Could not create device`）与硬件
  /// 渲染表面失败（`Failed to create EGL surface`，虚拟化 GPU 假性可用）。
  static bool _isHardwareFailure(String text) {
    if (text.contains('AVHWDeviceContext')) return true;
    if (text.contains('Could not create device')) return true;
    if (text.contains('Failed to initialize a hardware decoder')) return true;
    if (text.contains('Failed to create EGL surface')) return true;
    return false;
  }

  void _log(mk.PlayerLog log) {
    if (log.text.isEmpty) return;
    // 硬解设备分配失败：mpv 只把它打在日志流里（不进 stream.error），
    // 因此必须在此处也做拦截，否则会一直重试硬解并最终起播失败。
    if (!_hwdecFailed &&
        _hwAccel &&
        _currentSource != null &&
        (log.level == 'error' || log.level == 'fatal' || log.level == 'warn') &&
        _isHardwareFailure(log.text)) {
      AppLog.warn(
        'player-media_kit',
        'mpv 报告硬件解码/渲染失败，触发自动软解降级：${log.text}',
        category: LogCategory.player,
      );
      unawaited(_fallbackToSoftwareDecode());
      return;
    }
    switch (log.level) {
      case 'error':
      case 'fatal':
        AppLog.error('player-media_kit', log.text, category: LogCategory.player);
        return;
      case 'warn':
      case 'warning':
        AppLog.warn('player-media_kit', log.text, category: LogCategory.player);
        return;
      case 'v':
      case 'debug':
      case 'trace':
        AppLog.debug('player-media_kit', log.text, category: LogCategory.player);
        return;
      default:
        AppLog.info('player-media_kit', log.text, category: LogCategory.player);
    }
  }
}