/// 平台层：播放器统一控制层（映射 iOS `PlayerEngineController`）。
///
/// 职责：
///  - 持有当前播放器实例 + 后端降级链（契约 §2.5 + A21.5 的 Dart 侧语义）
///  - `open` 失败时按链回退（A21.5 selectBackend：复杂封装 / HEVC 无硬解走 libVLC）
///  - 状态 / 进度 / 错误回调转发（对齐 iOS `PlayerEngineState` + `PlayerEngineEvent`）
///  - 批次 C · C-01：路由（影视/直播/网盘/音乐/本地）→ 三端差异化后端选择
///  - 批次 C · C-06：降级可观测（[onBackendFallback] 事件 + debugPrint 日志）
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../domain/entities/player/player.dart';
import 'channel_player.dart';
import 'media_kit_player.dart';
import 'playback_route.dart';
import 'player_channel_bridge.dart';

/// 播放器控制层。
class PlayerController {
  PlayerController({
    required PlayerChannelBridge bridge,
    required List<PlayerBackend> backendChain,
    required PlayerBackend Function(PlayerSource source, PlaybackRoute route)
        selectInitialBackend,
  })  : _bridge = bridge,
        _backendChain = List<PlayerBackend>.unmodifiable(backendChain),
        _selectInitialBackend = selectInitialBackend;

  final PlayerChannelBridge _bridge;
  final List<PlayerBackend> _backendChain;
  final PlayerBackend Function(PlayerSource source, PlaybackRoute route)
      _selectInitialBackend;

  static PlayerController? _instance;

  /// 全局实例（app 启动接线；测试用 [overrideForTest] 注入假实现）。
  static PlayerController get instance =>
      _instance ??= _createDefault();

  @visibleForTesting
  static void overrideForTest(PlayerController controller) {
    _instance = controller;
  }

  static PlayerController _createDefault() {
    final List<PlayerBackend> chain =
        PlayerBackendSelector.chainFor(Platform.operatingSystem);
    return PlayerController(
      bridge: MethodChannelPlayerBridge(),
      backendChain: chain,
      selectInitialBackend: (PlayerSource source, PlaybackRoute route) {
        // F-P28：网盘源先按盘分派（对齐 iOS `preferredCompatibilityEngineName`
        // 的 `.auto` 门闸——UC/百度/139 等按盘内核策略**优先于**源特征判定，
        // `PlayerViewsV2.swift:3911-4117`）。命中即取按盘链中平台可用的首位；
        // 未命中（null）回落下方既有「源特征」逻辑。
        final String? provider = source.provider;
        if (route == PlaybackRoute.pan && provider != null && provider.isNotEmpty) {
          final List<PlayerBackend>? driveChain =
              PlayerBackendSelector.driveChainFor(
            provider: provider,
            url: source.url,
            resourceName: source.title,
          );
          if (driveChain != null) {
            final PlayerBackend? picked = PlayerBackendSelector.pickDriveBackend(
              driveChain: driveChain,
              available: chain,
            );
            if (picked != null) return picked;
          }
        }
        // 直播 FLV / 复杂封装（MKV/FLV/TS…）需全格式后端 → libVLC 优先（复杂封装
        // 回退）；网盘 / Node 代理流 URL 无扩展名，故以真实标题（[source.title]）
        // 补判，避免 4K HEVC MKV 被误投 Media3（open 成功但解码失败）。
        final bool needsFullFormat =
            PlayerBackendSelector.needsFallback(source.url,
                    resourceName: source.title) ||
                (route == PlaybackRoute.live && _isFlv(source.url));
        return PlayerBackendSelector.initialBackend(
          chain: chain,
          needsFullFormat: needsFullFormat,
        );
      },
    );
  }

  /// 是否 FLV 直播/点播流。
  static bool _isFlv(String url) => url.toLowerCase().contains('.flv');

  Player? _player;
  PlayerState? _state;
  PlaybackRoute? _route;
  PlayerSource? _lastSource;

  /// 当前生效的后端降级链（运行期错误降级据此定位「下一个后端」）。
  List<PlayerBackend>? _activeChain;

  /// 运行期降级进行中（防止 error 回调重入触发二次降级）。
  bool _fallbackInProgress = false;

  /// 当前播放器（未 open 为 null）。
  Player? get player => _player;

  /// 当前后端（未 open 为 null）。
  PlayerBackend? get backend => _player?.backend;

  /// 视频纹理输出面（R-渲1）：当前播放器的 Flutter textureId。
  ///
  /// `null` = 未开播或该后端无纹理输出；播放页据此选择 [VideoSurface] 承载。
  int? get textureId => _player?.textureId;

  /// 最近状态。
  PlayerState? get state => _state;

  /// 当前播放路由（未 open 为 null；C-01）。
  PlaybackRoute? get route => _route;

  /// 可用后端链（P-芯2：内核选择面板数据源）。
  List<PlayerBackend> get availableBackends => _backendChain;

  /// 最近一次打开的播放源（P-芯2：切换内核时重开用）。
  PlayerSource? get lastSource => _lastSource;

  void Function(PlayerState)? onStateChanged;

  void Function(PlaybackProgress)? onProgress;

  /// 输出面变更（R-渲1）：open 成功 / 释放时触发，携带新 textureId（可为 null）。
  ///
  /// 播放页据此刷新 [VideoSurface]（后端回退 / 选集重开都会换纹理句柄）。
  void Function(int? textureId)? onSurfaceChanged;

  /// 视频尺寸变更（R-渲1：输出面纵横比自适应）。
  void Function(int width, int height)? onVideoSize;

  /// 后端降级事件（C-06：from → to + 原因；可观测/埋点目标）。
  void Function(PlayerBackend from, PlayerBackend to, String reason)?
      onBackendFallback;

  void Function(String message, {required bool fatal})? _onError;

  void Function(String message, {required bool fatal})? get onError =>
      _onError;

  set onError(void Function(String message, {required bool fatal})? handler) {
    _onError = handler;
    // 已 attach 的播放器同步新处理器（open 之后再设置也生效）。统一走内部
    // [_handleRuntimeError]，以保留「运行期解码失败 → 内核降级」拦截。
    _player?.onError = _handleRuntimeError;
  }

  // ─────────────── 控制面 ───────────────

  /// 打开媒体：按后端降级链逐个尝试（失败回退下一后端）。
  ///
  /// C-01：打开前先解析播放路由并据此排序后端；C-06：每次回退触发
  /// [onBackendFallback] 事件并写降级日志。
  ///
  /// [route] 为显式路由覆盖（批次 F · F-08 网盘播放：直链特征无法自证 pan 路由，
  /// 由调用方显式传入）；为 null 时按 [PlaybackRouteResolver] 从源推导。
  Future<void> open(PlayerSource source, {PlaybackRoute? route}) async {
    final PlaybackRoute resolved = route ?? PlaybackRouteResolver.resolve(source);
    _lastSource = source;
    await _openWithChain(source, resolved, _orderedChain(source, resolved));
  }

  /// 按候选线路优先级打开（P-芯1）：从高优先级候选起逐个尝试，全失败抛最后一个错误。
  ///
  /// 同一资源多条线路（原画 / 流畅 / localProxy 转封装）时使用；每候选的
  /// `headers` 随线路下发播放后端。
  Future<void> openCandidates(
    List<PlaybackRouteCandidate> candidates, {
    PlaybackRoute? route,
  }) async {
    if (candidates.isEmpty) {
      throw const PlayerOpenException('E_NO_CANDIDATE', '无候选线路');
    }
    PlayerOpenException? last;
    for (final PlaybackRouteCandidate c
        in PlaybackRouteResolver.rank(candidates)) {
      try {
        await open(c.toSource(), route: route ?? c.route);
        return;
      } on PlayerOpenException catch (e) {
        last = e;
      }
    }
    throw last ?? const PlayerOpenException('E_NO_CANDIDATE', '全部候选线路打开失败');
  }

  /// 切换播放内核（P-芯2）：以当前播放源在指定后端上重开。
  ///
  /// 对齐 iOS `PlayerEngineController.switchEngine(reloadCurrentRoute:)`；
  /// 未打开过媒体时为空操作。
  Future<void> switchBackend(PlayerBackend backend) async {
    final PlayerSource? source = _lastSource;
    if (source == null) return;
    if (_player?.backend == backend) return;
    final PlaybackRoute resolved =
        _route ?? PlaybackRouteResolver.resolve(source);
    final List<PlayerBackend> chain = <PlayerBackend>[
      backend,
      ..._backendChain.where((PlayerBackend b) => b != backend),
    ];
    await _openWithChain(source, resolved, chain);
  }

  Future<void> _openWithChain(
    PlayerSource source,
    PlaybackRoute resolved,
    List<PlayerBackend> chain,
  ) async {
    await _disposePlayer();
    _route = resolved;
    _activeChain = chain;
    PlayerOpenException? last;
    PlayerBackend? previous;
    for (final PlayerBackend backend in chain) {
      if (previous != null) {
        // 上一后端失败，本次尝试即降级：先记降级事件再试新后端（C-06）。
        final String reason = last?.message ?? '';
        debugPrint(
          '[PlayerController] 后端降级：${previous.name} → ${backend.name}'
          '（route=${resolved.name}，$reason）',
        );
        onBackendFallback?.call(previous, backend, reason);
      }
      final Player p = _createPlayer(backend);
      _attach(p);
      _player = p;
      try {
        await p.open(source);
        _state = PlayerState.opening;
        // R-渲1：open 后原生已创建输出面，先同步 textureId 再报状态，避免
        // 控制层先于画面就绪渲染（后端回退时旧纹理已随上一实例释放）。
        onSurfaceChanged?.call(p.textureId);
        onStateChanged?.call(_state!);
        return;
      } on PlayerOpenException catch (e) {
        last = e;
        onError?.call('后端 ${backend.name} 打开失败：${e.message}', fatal: true);
        await _disposePlayer();
      } catch (e) {
        // 兜底：任何非预期异常都收敛为可回退的打开失败，绝不裸抛中断后端链。
        last = PlayerOpenException('E_OPEN', '后端 ${backend.name} 打开异常：$e');
        onError?.call('后端 ${backend.name} 打开异常：$e', fatal: true);
        await _disposePlayer();
      }
      previous = backend;
    }
    _route = null;
    throw last ??
        const PlayerOpenException('E_NO_BACKEND', '无可用播放后端');
  }

  Future<void> play() async {
    if (_player == null) return;
    await _player!.play();
  }

  Future<void> pause() async {
    if (_player == null) return;
    await _player!.pause();
  }

  /// 播放 / 暂停切换（文档 T.7 `PlayPauseIntent` 接线目标）。
  Future<void> togglePlay() async {
    final PlayerState? s = _state;
    if (s == PlayerState.playing) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> seekTo(int positionMs) async {
    if (_player == null) return;
    await _player!.seekTo(positionMs);
  }

  Future<void> setVolume(double volume) async {
    if (_player == null) return;
    await _player!.setVolume(volume);
  }

  Future<void> setSpeed(double speed) async {
    if (_player == null) return;
    await _player!.setSpeed(speed);
  }

  /// 释放播放器 + 桥资源（路由一并清空）。
  Future<void> dispose() async {
    await _disposePlayer();
    _route = null;
    _activeChain = null;
    await _bridge.dispose();
  }

  // ─────────────── 内部 ───────────────

  List<PlayerBackend> _orderedChain(
    PlayerSource source,
    PlaybackRoute route,
  ) {
    final PlayerBackend initial = _selectInitialBackend(source, route);
    return <PlayerBackend>[
      initial,
      ..._backendChain.where((PlayerBackend b) => b != initial),
    ];
  }

  /// 按后端创建播放内核实例。
  ///
  /// 当前收敛为 media_kit 单内核（[MediaKitPlayer]）；自研桥（[ChannelPlayer]）
  /// 已退役：逻辑保留为「可扩展骨架」，当前收敛链中不会命中，仅在未被支持的
  /// 后端被显式 switch 时兜底创建（物理不删 channel_player / player_plugin）。
  Player _createPlayer(PlayerBackend backend) {
    if (backend == PlayerBackend.mediaKit) {
      return MediaKitPlayer(backend: backend);
    }
    return ChannelPlayer(backend: backend, bridge: _bridge);
  }

  void _attach(Player p) {
    p.onStateChanged = (PlayerState s) {
      _state = s;
      onStateChanged?.call(s);
    };
    p.onProgress = onProgress;
    p.onVideoSize = (int width, int height) {
      if (width <= 0 || height <= 0) return;
      onVideoSize?.call(width, height);
    };
    // R-渲1 补发：原生纹理懒注册，open 返回时多为 null；就绪后经此事件挂载。
    p.onTextureReady = (int textureId) {
      onSurfaceChanged?.call(textureId);
    };
    p.onError = _handleRuntimeError;
  }

  /// 运行期错误统一入口（C-06 + 内核降级）。
  ///
  /// 契约：Media3 **open 成功但解码失败**（如 4K HEVC HDR10 超硬解能力、
  /// `ERROR_CODE_DECODING_FAILED`）时，必须触发内核降级（Media3 → libVLC）；
  /// 此类错误在 open 阶段不可见，只能在运行期 error 事件里拦截。
  ///
  /// 命中且链上仍有后续后端时**暂缓上报**（由降级链接管，避免 UI 先弹错误态；
  /// 降级耗尽再补报）；否则按原语义直接转发 [_onError]。
  void _handleRuntimeError(String message, {bool fatal = false}) {
    if (fatal && _isRuntimeFallbackError(message) && _hasNextBackend()) {
      debugPrint('[PlayerController] 运行期解码错误 → 尝试内核降级：$message');
      unawaited(_retryNextBackend(message));
      return;
    }
    _onError?.call(message, fatal: fatal);
  }

  /// 当前后端之后是否仍有可降级后端。
  bool _hasNextBackend() {
    final List<PlayerBackend>? chain = _activeChain;
    final PlayerBackend? from = _player?.backend;
    if (chain == null || from == null) return false;
    final int idx = chain.indexOf(from);
    return idx >= 0 && idx < chain.length - 1;
  }

  /// 运行期错误降级：以当前源在当前链的**剩余后端**上重开。
  Future<void> _retryNextBackend(String reason) async {
    if (_fallbackInProgress) return;
    final List<PlayerBackend>? chain = _activeChain;
    final PlayerBackend? from = _player?.backend;
    final PlayerSource? source = _lastSource;
    if (chain == null || from == null || source == null) {
      _onError?.call(reason, fatal: true);
      return;
    }
    final int idx = chain.indexOf(from);
    if (idx < 0 || idx >= chain.length - 1) {
      _onError?.call(reason, fatal: true);
      return;
    }
    final List<PlayerBackend> rest = chain.sublist(idx + 1);
    final PlayerBackend to = rest.first;
    _fallbackInProgress = true;
    try {
      debugPrint(
        '[PlayerController] 内核降级（运行期）：${from.name} → ${to.name}'
        '（route=${_route?.name}，$reason）',
      );
      onBackendFallback?.call(from, to, reason);
      await _openWithChain(
        source,
        _route ?? PlaybackRouteResolver.resolve(source),
        rest,
      );
    } catch (e) {
      debugPrint('[PlayerController] 内核降级失败：$e');
      _onError?.call(reason, fatal: true);
    } finally {
      _fallbackInProgress = false;
    }
  }

  /// 判定错误是否为「解码 / 格式」类（应触发内核降级）。
  ///
  /// 覆盖 Media3 原生错误码名（`errorCodeName` 会随事件消息下发，如
  /// `ERROR_CODE_DECODING_FAILED` / `NO_EXCEEDS_CAPABILITIES`）与中文兜底文案。
  static bool _isRuntimeFallbackError(String message) {
    final String m = message.toLowerCase();
    const List<String> tokens = <String>[
      'decoding_failed',
      'decoder',
      'decode',
      'no_exceeds_capabilities',
      'exceeds_capabilities',
      'format_supported',
      'unsupported',
      '解码',
      '格式不支持',
      '不支持的格式',
    ];
    for (final String t in tokens) {
      if (m.contains(t)) return true;
    }
    return false;
  }

  Future<void> _disposePlayer() async {
    final Player? p = _player;
    _player = null;
    _state = null;
    if (p != null) {
      final bool hadSurface = p.textureId != null;
      await p.dispose();
      if (hadSurface) onSurfaceChanged?.call(null);
    }
  }
}
