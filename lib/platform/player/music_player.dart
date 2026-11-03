/// 平台层：音乐播放编排（批次 G · G-01 首段）。
///
/// 职责（对齐 iOS `AudioPlayerManager` 的状态机与队列持久化，不含 AVPlayer 细节）：
///  - 持有 [MusicQueue]（队列 + 当前下标）+ 播放模式 + 播放态（[isPlaying] / 进度 / 时长）；
///  - 队列变更即落 [MusicQueueStore]（`music_queue_items` / `music_queue_index`）；
///  - 音频输出经 [MusicAudioEngine] 接缝下发（缺省 [UnavailableMusicAudioEngine] 为
///    空实现，真机原生接入后替换；对齐 D28 口径：编排先行、原生能力后接）。
///
/// 对齐说明：iOS `AudioPlayerManager` 的 `playNext` / `playPrevious` / `stop` /
/// `switchQuality` 语义逐条映射到本类同名方法；歌词 / NowPlaying 锁屏控制经
/// [MusicMediaSession] 接缝承接（UI-F15：更新 / 清理 / 命令分派编排已接线，
/// 对齐 iOS `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` 语义；原生后端
/// 随真机批次替换缺省 [NoopMusicMediaSession]）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/datasources/local/music_queue_store.dart';
import '../../data/datasources/local/prefs_manager.dart';
import '../../domain/entities/music/music.dart';
import 'media_session.dart';
import 'media_session/native_music_media_session.dart';

/// 音频输出引擎接缝（缺省空实现，原生接入后替换）。
abstract class MusicAudioEngine {
  /// 装载播放地址。
  Future<void> load(String url);

  /// 开始 / 继续播放。
  Future<void> play();

  /// 暂停。
  Future<void> pause();

  /// 定位。
  Future<void> seek(Duration position);

  /// 停止并释放当前条目。
  Future<void> stop();

  /// 释放引擎。
  Future<void> dispose();
}

/// 未接入的原生音频引擎（no-op；真机原生接入前保证编排链路可跑）。
///
/// 对齐 iOS `AudioPlayerManager` 的实际播放由 AVPlayer 承担——Flutter 端原生
/// 播放能力接入前，本实现不产生声音但保持状态机可用（D28 口径）。
class UnavailableMusicAudioEngine implements MusicAudioEngine {
  /// 构造。
  const UnavailableMusicAudioEngine();

  @override
  Future<void> load(String url) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

/// 音乐播放控制器（对齐 iOS `AudioPlayerManager` 的可观测状态 + 队列方法）。
class MusicPlayerController extends ChangeNotifier {
  /// 构造（[store] / [engine] / [mediaSession] 可注入；测试用替身）。
  ///
  /// [mediaSession] 缺省走 [NativeMusicMediaSession]（批次 D · D3：原生锁屏
  /// 会话接线；桌面未接线 / 单测环境静默降级，行为等价原 Noop）。
  MusicPlayerController({
    MusicQueueStore? store,
    MusicAudioEngine? engine,
    MusicMediaSession? mediaSession,
  })  : _store = store ?? MusicQueueStore(PrefsManager.instance),
        _engine = engine ?? const UnavailableMusicAudioEngine(),
        _mediaSession = mediaSession ?? NativeMusicMediaSession() {
    // 线控命令接线（对齐 iOS `MPRemoteCommandCenter` handler → 播放编排）。
    _mediaSession.onCommand = _handleMediaCommand;
  }

  final MusicQueueStore _store;
  final MusicAudioEngine _engine;
  final MusicMediaSession _mediaSession;

  static MusicPlayerController? _instance;

  /// 全局实例（app 启动接线；测试用 [overrideForTest] 注入假实现）。
  static MusicPlayerController get instance =>
      _instance ??= MusicPlayerController();

  /// 测试注入。
  @visibleForTesting
  static void overrideForTest(MusicPlayerController controller) {
    _instance = controller;
  }

  MusicQueue _queue = MusicQueue.empty;
  MusicRepeatMode _repeatMode = MusicRepeatMode.sequential;
  bool _isPlaying = false;
  bool _isLoading = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _notice;
  int _consecutiveFailures = 0;

  /// 当前队列。
  MusicQueue get queue => _queue;

  /// 当前曲目（空队列为 null）。
  MusicQueueItem? get currentSong => _queue.current;

  /// 当前下标（空队列 -1）。
  int get currentIndex => _queue.currentIndex;

  /// 是否正在播放。
  bool get isPlaying => _isPlaying;

  /// 是否加载中。
  bool get isLoading => _isLoading;

  /// 当前进度。
  Duration get position => _position;

  /// 总时长。
  Duration get duration => _duration;

  /// 播放即时提示（如「播放失败，正在切换下一首」）。
  String? get notice => _notice;

  /// 播放模式。
  MusicRepeatMode get repeatMode => _repeatMode;

  /// 是否有队列（MiniPlayer 显示依据）。
  bool get hasQueue => _queue.isNotEmpty;

  /// 是否可切歌（队列 > 1）。
  bool get canSkip => _queue.length > 1;

  // ─────────────────────────────────────────────────────────
  // 队列
  // ─────────────────────────────────────────────────────────

  /// 恢复存档（对齐 iOS `restoreQueue`；空存档直接返回）。
  Future<void> restore() async {
    final MusicQueue restored = await _store.load();
    if (restored.isEmpty) return;
    _queue = restored;
    _resetPlaybackState();
    notifyListeners();
  }

  /// 全量替换队列并从 [startIndex] 起播（对齐 iOS `setQueue` / `playQueue`）。
  Future<void> setQueue(
    List<MusicQueueItem> items, {
    int startIndex = 0,
  }) async {
    _consecutiveFailures = 0;
    _queue = MusicQueue.empty.setQueue(items, startIndex: startIndex);
    await _persist();
    await _startPlayback();
  }

  /// 播放某首（对齐 iOS `play(item:)`）。
  Future<void> playItem(MusicQueueItem item) async {
    _consecutiveFailures = 0;
    _queue = _queue.play(item);
    await _persist();
    await _startPlayback();
  }

  /// 追加到队列尾（对齐 iOS `addToQueue`，不改当前下标）。
  Future<void> addToQueue(MusicQueueItem item) async {
    _queue = _queue.addToQueue(item);
    await _persist();
    notifyListeners();
  }

  /// 移除某下标（对齐 iOS `removeFromQueue`：移除当前项 → stop 语义）。
  Future<void> removeFromQueue(int index) async {
    _queue = _queue.removeFromQueue(index);
    if (_queue.isEmpty) {
      await _engine.stop();
      _resetPlaybackState();
      unawaited(_mediaSession.clear());
    }
    await _persist();
    notifyListeners();
  }

  // ─────────────────────────────────────────────────────────
  // 播放控制
  // ─────────────────────────────────────────────────────────

  /// 播放 / 暂停切换（对齐 iOS `togglePlayPause`）。
  Future<void> togglePlayPause() async {
    if (_isPlaying) {
      await pause();
    } else {
      await resume();
    }
  }

  /// 继续播放（对齐 iOS `resume`；无播放器时重新起播当前曲目）。
  Future<void> resume() async {
    if (_queue.current == null) return;
    if (_isPlaying) return;
    await _engine.play();
    _isPlaying = true;
    notifyListeners();
    unawaited(_syncMediaSession());
  }

  /// 暂停（对齐 iOS `pause`）。
  Future<void> pause() async {
    if (!_isPlaying) return;
    await _engine.pause();
    _isPlaying = false;
    notifyListeners();
    unawaited(_syncMediaSession());
  }

  /// 下一首（对齐 iOS `playNext`：单曲循环重播，其余按模式换下标）。
  Future<void> playNext() async {
    if (_queue.isEmpty) return;
    if (_repeatMode == MusicRepeatMode.single) {
      await _engine.seek(Duration.zero);
      _position = Duration.zero;
      await _engine.play();
      _isPlaying = true;
      notifyListeners();
      unawaited(_syncMediaSession());
      return;
    }
    final int? next = _queue.nextIndex(_repeatMode);
    if (next == null) return;
    _queue = _queue.withCurrentIndex(next);
    await _persist();
    await _startPlayback();
  }

  /// 上一首（对齐 iOS `playPrevious`：> 3s 先回本曲开头）。
  Future<void> playPrevious() async {
    if (_queue.isEmpty) return;
    if (_position.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }
    final int? previous = _queue.previousIndex(_repeatMode);
    if (previous == null) return;
    _queue = _queue.withCurrentIndex(previous);
    await _persist();
    await _startPlayback();
  }

  /// 定位（对齐 iOS `seek(to:)`；seek 后刷新锁屏信息）。
  Future<void> seek(Duration position) async {
    _position = position;
    await _engine.seek(position);
    notifyListeners();
    unawaited(_syncMediaSession());
  }

  /// 停止并清空队列（对齐 iOS `stop`：队列清空后 MiniPlayer 自动隐藏；
  /// 同时清空锁屏信息，对齐 iOS `nowPlayingInfo = nil`）。
  Future<void> stop() async {
    await _engine.stop();
    _queue = MusicQueue.empty;
    _notice = null;
    _resetPlaybackState();
    await _persist();
    notifyListeners();
    unawaited(_mediaSession.clear());
  }

  /// 设置播放模式。
  void setRepeatMode(MusicRepeatMode mode) {
    if (_repeatMode == mode) return;
    _repeatMode = mode;
    notifyListeners();
  }

  /// 循环切换播放模式（对齐 iOS 全屏页顶栏按钮）。
  void cycleRepeatMode() => setRepeatMode(_repeatMode.next);

  /// 替换当前曲目（音质切换用：保留下标与进度，对齐 iOS `switchQuality` 的下标不变语义）。
  Future<void> replaceCurrent(MusicQueueItem item) async {
    if (_queue.currentIndex < 0) return;
    final Duration keep = _position;
    _queue = _queue.replaceAt(_queue.currentIndex, item);
    await _persist();
    await _startPlayback();
    if (keep > Duration.zero) {
      await seek(keep);
    }
  }

  /// 音质直链重拉回调（批次 E · E4-1；由音乐域注入 lx `musicUrl` 重拉链路，
  /// 对齐 iOS `AudioPlayerManager` 走插件 `musicUrl`）。
  ///
  /// 返回 null / 空 → 该来源或档位不可用（切换放弃并提示）；
  /// 缺省 null → 提示「该来源暂不支持音质切换」（登记：音乐域 resolver
  /// 接线属后续拆分，见方案 E4-1 核验结论）。
  Future<String?> Function(MusicQueueItem item, String quality)?
      qualityResolver;

  /// 切换音质（对齐 iOS `switchQuality(q)`：重拉直链 → `replaceCurrent`
  /// 保留进度；±3s 精度由引擎 seek 决定）。
  Future<void> switchQuality(String quality) async {
    final MusicQueueItem? current = _queue.current;
    if (current == null) return;
    if (!current.availQualities.contains(quality)) return;
    if (quality == current.quality) return;
    final Future<String?> Function(MusicQueueItem, String)? resolver =
        qualityResolver;
    if (resolver == null) {
      _notice = '该来源暂不支持音质切换';
      notifyListeners();
      return;
    }
    _isLoading = true;
    notifyListeners();
    try {
      final String? url = await resolver(current, quality);
      if (url == null || url.isEmpty) {
        _notice = '音质切换失败';
        notifyListeners();
        return;
      }
      await replaceCurrent(
        current
            .copying(playURL: url, quality: quality)
            .copyWith(qualityIndex: current.availQualities.indexOf(quality)),
      );
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 清除即时提示。
  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  // ─────────────────────────────────────────────────────────
  // 引擎回传（原生时间观察者 / 播放结束回调）
  // ─────────────────────────────────────────────────────────

  /// 进度回传（对齐 iOS 周期性时间观察者）。
  void reportPosition(Duration position) {
    _position = position;
    notifyListeners();
  }

  /// 时长回传（对齐 iOS `playerItem.status == .readyToPlay`）。
  void reportDuration(Duration duration) {
    _duration = duration;
    if (_isLoading) _isLoading = false;
    notifyListeners();
  }

  /// 播放结束（对齐 iOS `playerDidFinish` → `playNext`）。
  Future<void> reportCompleted() => playNext();

  // ─────────────────────────────────────────────────────────
  // 内部
  // ─────────────────────────────────────────────────────────

  /// 同步锁屏媒体会话（UI-F15，对齐 iOS `updateNowPlayingInfo`：
  /// 当前曲目元数据 + 播放态一次写入；无当前曲目时不更新）。
  Future<void> _syncMediaSession() async {
    final MusicQueueItem? item = _queue.current;
    if (item == null) return;
    await _mediaSession.updateNowPlaying(
      MusicMediaMetadata.fromItem(
        item,
        duration: _duration > Duration.zero
            ? _duration
            : Duration(seconds: item.duration ?? 0),
      ),
      MusicMediaPlaybackState(playing: _isPlaying, position: _position),
    );
  }

  /// 线控命令分派（对齐 iOS `MPRemoteCommandCenter` 六命令 → 播放编排）。
  void _handleMediaCommand(MusicMediaCommand command) {
    switch (command) {
      case MusicMediaPlayCommand():
        unawaited(resume());
      case MusicMediaPauseCommand():
        unawaited(pause());
      case MusicMediaToggleCommand():
        unawaited(togglePlayPause());
      case MusicMediaNextCommand():
        unawaited(playNext());
      case MusicMediaPreviousCommand():
        unawaited(playPrevious());
      case MusicMediaSeekCommand(:final Duration position):
        unawaited(seek(position));
    }
  }

  /// 起播当前曲目（对齐 iOS `startPlayback`）。
  Future<void> _startPlayback() async {
    final MusicQueueItem? item = _queue.current;
    if (item == null) return;

    _isLoading = true;
    _position = Duration.zero;
    _duration = item.duration == null
        ? Duration.zero
        : Duration(seconds: item.duration!);
    notifyListeners();

    if (item.playURL.trim().isEmpty) {
      _isLoading = false;
      _isPlaying = false;
      _notice = '播放地址为空';
      notifyListeners();
      unawaited(_syncMediaSession());
      return;
    }

    try {
      await _engine.load(item.playURL);
      await _engine.play();
      _isPlaying = true;
      _isLoading = false;
      _consecutiveFailures = 0;
      notifyListeners();
      unawaited(_syncMediaSession());
    } catch (_) {
      _isLoading = false;
      _isPlaying = false;
      _notice = '播放失败，正在切换下一首';
      // 连续失败保护：失败数 < 队列长度才自动跳，避免整单全坏死循环（对齐 iOS #1）。
      _consecutiveFailures += 1;
      if (_consecutiveFailures < _queue.length && _queue.length > 1) {
        await playNext();
      } else {
        _consecutiveFailures = 0;
        notifyListeners();
        unawaited(_syncMediaSession());
      }
    }
  }

  void _resetPlaybackState() {
    _isPlaying = false;
    _isLoading = false;
    _position = Duration.zero;
    _duration = Duration.zero;
  }

  Future<void> _persist() => _store.save(_queue);
}
