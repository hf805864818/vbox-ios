/// 平台层：音乐媒体会话接缝（UI-F15 · 对齐 iOS `AudioPlayerManager` 媒体会话段）。
///
/// 唯一真相源：iOS `vbox/Services/AudioPlayerManager.swift`
///   - L517-529 `MPNowPlayingInfoCenter`：锁屏 / 控制中心信息
///     （标题 / 艺术家 / 专辑 / 时长 / 进度 / 播放速率）；
///   - L533-574 `MPRemoteCommandCenter`：线控命令
///     （play / pause / toggle / next / previous / seek）；
///   - L355-379：停止清空 Now Playing、seek 后刷新信息。
///
/// D28 口径（对齐 [UnavailableMusicAudioEngine] 先例）：本层为**编排接缝**——
/// 状态机接线与命令分派先行交付并有单测；原生 NowPlaying 后端
/// （Android MediaSession / 桌面 SMTC）随真机批次实现 [MusicMediaSession]
/// 后替换缺省 [NoopMusicMediaSession] 即可，编排层零改动。
library;

import '../../domain/entities/music/music_queue.dart';

/// 锁屏 / 控制中心展示的曲目元数据（对齐 iOS `nowPlayingInfo` 各键）。
class MusicMediaMetadata {
  /// 构造。
  const MusicMediaMetadata({
    required this.title,
    this.artist = '',
    this.album,
    this.coverURL,
    this.duration = Duration.zero,
  });

  /// 歌名（iOS `MPMediaItemPropertyTitle`）。
  final String title;

  /// 来源 / 歌手（iOS `MPMediaItemPropertyArtist`）。
  final String artist;

  /// 专辑名（iOS `MPMediaItemPropertyAlbumTitle`；可空）。
  final String? album;

  /// 封面地址（原生端经 Artwork 加载；可空）。
  final String? coverURL;

  /// 总时长（iOS `MPMediaItemPropertyPlaybackDuration`）。
  final Duration duration;

  /// 由队列条目构造（对齐 iOS `updateNowPlaying` 的取值来源）。
  static MusicMediaMetadata fromItem(
    MusicQueueItem item, {
    Duration duration = Duration.zero,
  }) =>
      MusicMediaMetadata(
        title: item.name,
        artist: item.artist,
        album: item.albumName,
        coverURL: item.coverURL,
        duration: duration,
      );
}

/// 播放态快照（对齐 iOS `MPNowPlayingInfoPropertyPlaybackRate` + 进度键）。
class MusicMediaPlaybackState {
  /// 构造。
  const MusicMediaPlaybackState({
    required this.playing,
    this.position = Duration.zero,
  });

  /// 是否播放中（速率 1.0 / 0.0）。
  final bool playing;

  /// 当前进度（iOS `MPNowPlayingInfoPropertyElapsedPlaybackTime`）。
  final Duration position;
}

/// 线控命令（对齐 iOS `MPRemoteCommandCenter` 注册的六命令）。
sealed class MusicMediaCommand {
  const MusicMediaCommand();

  /// 播放（iOS `playCommand`）。
  static const MusicMediaCommand play = MusicMediaPlayCommand();

  /// 暂停（iOS `pauseCommand`）。
  static const MusicMediaCommand pause = MusicMediaPauseCommand();

  /// 播放 / 暂停切换（iOS `togglePlayPauseCommand`）。
  static const MusicMediaCommand toggle = MusicMediaToggleCommand();

  /// 下一曲（iOS `nextTrackCommand`）。
  static const MusicMediaCommand next = MusicMediaNextCommand();

  /// 上一曲（iOS `previousTrackCommand`）。
  static const MusicMediaCommand previous = MusicMediaPreviousCommand();
}

/// 定位命令（iOS `changePlaybackPositionCommand`，带目标进度）。
class MusicMediaSeekCommand extends MusicMediaCommand {
  /// 构造。
  const MusicMediaSeekCommand(this.position);

  /// 目标进度。
  final Duration position;
}

/// 播放命令。
class MusicMediaPlayCommand extends MusicMediaCommand {
  /// 构造。
  const MusicMediaPlayCommand();
}

/// 暂停命令。
class MusicMediaPauseCommand extends MusicMediaCommand {
  /// 构造。
  const MusicMediaPauseCommand();
}

/// 播放 / 暂停切换命令。
class MusicMediaToggleCommand extends MusicMediaCommand {
  /// 构造。
  const MusicMediaToggleCommand();
}

/// 下一曲命令。
class MusicMediaNextCommand extends MusicMediaCommand {
  /// 构造。
  const MusicMediaNextCommand();
}

/// 上一曲命令。
class MusicMediaPreviousCommand extends MusicMediaCommand {
  /// 构造。
  const MusicMediaPreviousCommand();
}

/// 命令回调（原生端线控 → 编排层；由 `MusicPlayerController` 接线）。
typedef MusicMediaCommandHandler = void Function(MusicMediaCommand command);

/// 媒体会话后端接缝（原生实现：Android `MediaSession` / 桌面 SMTC）。
abstract class MusicMediaSession {
  /// 命令回调（编排层在构造时注入；原生端收到线控后回派）。
  MusicMediaCommandHandler? get onCommand;

  set onCommand(MusicMediaCommandHandler? handler);

  /// 更新锁屏信息（对齐 iOS `updateNowPlayingInfo`：元数据 + 播放态一次写入）。
  Future<void> updateNowPlaying(
    MusicMediaMetadata metadata,
    MusicMediaPlaybackState state,
  );

  /// 清空锁屏信息（对齐 iOS 停止清理 `nowPlayingInfo = nil`）。
  Future<void> clear();
}

/// 未接入的媒体会话后端（no-op；原生接入前保证编排链路可跑，D28 口径）。
class NoopMusicMediaSession implements MusicMediaSession {
  /// 构造。
  NoopMusicMediaSession();

  @override
  MusicMediaCommandHandler? get onCommand => _onCommand;
  MusicMediaCommandHandler? _onCommand;

  @override
  set onCommand(MusicMediaCommandHandler? handler) => _onCommand = handler;

  @override
  Future<void> updateNowPlaying(
    MusicMediaMetadata metadata,
    MusicMediaPlaybackState state,
  ) async {}

  @override
  Future<void> clear() async {}
}

/// 媒体会话测试记录器（供单测断言更新 / 清理序列）。
class RecordingMusicMediaSession implements MusicMediaSession {
  /// 更新调用序列。
  final List<(MusicMediaMetadata, MusicMediaPlaybackState)> updates =
      <(MusicMediaMetadata, MusicMediaPlaybackState)>[];

  /// 清空调用次数。
  int clearCount = 0;

  @override
  MusicMediaCommandHandler? get onCommand => _onCommand;
  MusicMediaCommandHandler? _onCommand;

  @override
  set onCommand(MusicMediaCommandHandler? handler) => _onCommand = handler;

  @override
  Future<void> updateNowPlaying(
    MusicMediaMetadata metadata,
    MusicMediaPlaybackState state,
  ) async {
    updates.add((metadata, state));
  }

  @override
  Future<void> clear() async {
    clearCount += 1;
  }
}
