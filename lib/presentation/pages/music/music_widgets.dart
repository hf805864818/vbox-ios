/// 表现层：网络音乐浏览组件（批次 G · G-音1）。
///
/// 唯一真相源：iOS [MusicView.swift](../../../../vbox/Views/MusicView.swift)
///   · [PlaylistCard]（L981-L1047）：歌单封面 142 + 名称 13 + 播放量 / 曲目数；
///   · [RankingRow]（L1051-L1117）：榜单封面 56 + 名称 15 + 更新频率；
///   · [PlaylistDetailPage]（L1121-L1385）：详情头 + 播放全部 + 歌曲行列表；
///   · [PlaylistSongRow]（L1389-L1485）：封面 44 + 歌名 / 歌手 + 平台 tag + 时长；
///   · [MusicRow]（L1489-L1594）：封面 50 + 歌名 / 歌手 + 时长 + 播放键。
///
/// 落地差异（如实登记）：
///   · iOS `PlaylistDetailView` 自带 `platform / playlistId / isRanking`，进页后自行
///     拉详情；Flutter 侧按任务约定改为**详情已加载**后传入（[PlaylistDetailPage] 只
///     接收 [PlaylistDetail]），故不再持有 `isRanking` 标志，标题回退为歌单名；
///   · iOS `PlaylistDetailView` 顶栏一次性解析整单会有 `isResolvingPlaylist` 全局
///     状态与「固定源跨平台」提示；Flutter 侧无 lx 聚合源判定，去掉该提示，解析进度
///     改为本页局部状态；
///   · iOS 平台强调色为独立 RGB 字面量，Flutter 按 UI 守卫 R-4（禁散落 hex）改用
///     [musicPlatformAccent] 的既有令牌近似。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../domain/entities/music/music_playlist.dart';
import '../../../domain/entities/music/music_queue.dart';
import '../../../platform/player/music_player.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../theme/tokens/typography.dart';
import '../../widgets/music/mini_player.dart';
import '../../widgets/platform_async_image.dart';
import '../../widgets/vbox/vbox.dart';
import 'music_player_page.dart';

/// 平台强调色（对齐 iOS `MusicPlatformType.accentColor`，L23-L31）。
///
/// 落地差异：iOS 用独立 RGB 字面量；Flutter 按 UI 守卫 R-4 复用 [VboxColors]
/// 语义色近似（取最接近的既有令牌，禁止在本层散落十六进制）。
Color musicPlatformAccent(MusicPlatformType platform) => switch (platform) {
      // iOS 网易红 (0.85, 0.20, 0.20)。
      MusicPlatformType.netease => VboxColors.danger,
      // iOS 腾讯蓝 (0.11, 0.56, 1.00)。
      MusicPlatformType.qq => VboxColors.selected,
      // iOS 酷狗绿 (0.05, 0.75, 0.40)。
      MusicPlatformType.kugou => VboxColors.downloadCompleted,
      // iOS 酷我橙 (1.00, 0.55, 0.10)。
      MusicPlatformType.kuwo => VboxColors.warning,
      // iOS 咪咕紫 (0.50, 0.25, 0.85)。
      MusicPlatformType.migu => VboxColors.tgChannelPurple,
    };

/// 秒 → `mm:ss`（超过 1 小时 → `h:mm:ss`，对齐 iOS `formatDuration`）。
String formatMusicDuration(int seconds) {
  final int s = seconds < 0 ? 0 : seconds;
  final int h = s ~/ 3600;
  final int m = (s % 3600) ~/ 60;
  final int sec = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  if (h > 0) return '$h:${two(m)}:${two(sec)}';
  return '${two(m)}:${two(sec)}';
}

// ════════════════════════════════════════════════════════════════════════
// 歌单卡片
// ════════════════════════════════════════════════════════════════════════

/// 歌单卡片（对齐 iOS `PlaylistCard`，L981）。
class PlaylistCard extends StatelessWidget {
  /// 构造。
  const PlaylistCard({super.key, required this.playlist});

  /// 歌单条目。
  final PlaylistItem playlist;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? play = playlist.playCount;
    final int? songCount = playlist.songCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(VboxRadii.r10),
          child: SizedBox(
            height: 142,
            width: double.infinity,
            child: PlatformAsyncImage(
              url: playlist.coverURL,
              fit: BoxFit.cover,
              placeholder: _musicPlaceholder(scheme),
            ),
          ),
        ),
        const SizedBox(height: VboxSpacing.compact),
        Text(
          playlist.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: VboxTypography.s13,
            fontWeight: FontWeight.w500,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: VboxSpacing.xs),
        Row(
          children: <Widget>[
            if (play != null && play.isNotEmpty) ...<Widget>[
              Icon(
                Icons.play_circle_outline,
                size: 10,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: VboxSpacing.xs),
              Text(
                play,
                style: TextStyle(
                  fontSize: VboxTypography.s10,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            if (songCount != null && songCount > 0)
              Padding(
                padding: const EdgeInsets.only(left: VboxSpacing.xs),
                child: Text(
                  '·$songCount首',
                  style: TextStyle(
                    fontSize: VboxTypography.s10,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

Widget _musicPlaceholder(ColorScheme scheme) {
  return ColoredBox(
    color: scheme.surfaceContainerHighest,
    child: Icon(Icons.music_note, color: scheme.onSurfaceVariant),
  );
}

// ════════════════════════════════════════════════════════════════════════
// 排行榜行
// ════════════════════════════════════════════════════════════════════════

/// 排行榜行（对齐 iOS `RankingRow`，L1051）。
class RankingRow extends StatelessWidget {
  /// 构造。
  const RankingRow({super.key, required this.ranking});

  /// 榜单条目。
  final RankingItem ranking;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? freq = ranking.updateFreq;
    final String? cover = ranking.coverURL;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: VboxSpacing.lg,
        vertical: VboxSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(VboxRadii.r8),
            child: SizedBox(
              width: 56,
              height: 56,
              child: PlatformAsyncImage(
                url: cover,
                fit: BoxFit.cover,
                placeholder: ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.bar_chart,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: VboxSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  ranking.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: VboxTypography.s15,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: VboxSpacing.xs),
                Text(
                  (freq != null && freq.isNotEmpty)
                      ? freq
                      : ranking.platform.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: VboxTypography.s11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right,
            size: 16,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// 歌单歌曲行
// ════════════════════════════════════════════════════════════════════════

/// 歌单内歌曲行（对齐 iOS `PlaylistSongRowView`，L1389）。
class PlaylistSongRow extends StatelessWidget {
  /// 构造。
  const PlaylistSongRow({
    super.key,
    required this.song,
    required this.onPlay,
    this.accentColor,
  });

  /// 歌曲。
  final PlaylistSong song;

  /// 点击播放。
  final VoidCallback onPlay;

  /// 强调色（缺省取主题主色）。
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color accent = accentColor ?? scheme.primary;
    final MusicPlatformType? platform = MusicPlatformType.fromId(song.platform);
    final String? album = song.album;
    final int? duration = song.duration;

    return InkWell(
      onTap: onPlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: VboxSpacing.lg,
          vertical: VboxSpacing.compact,
        ),
        child: Row(
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(VboxRadii.r6),
              child: SizedBox(
                width: 44,
                height: 44,
                child: PlatformAsyncImage(
                  url: song.coverURL,
                  fit: BoxFit.cover,
                  placeholder: ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: Icon(
                      Icons.music_note,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: VboxSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    song.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: VboxTypography.s14,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: <Widget>[
                      if (song.artist.isNotEmpty)
                        Flexible(
                          child: Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: VboxTypography.s11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      if (album != null && album.isNotEmpty)
                        Flexible(
                          child: Text(
                            ' - $album',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: VboxTypography.s11,
                              color: scheme.onSurfaceVariant
                                  .withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: VboxSpacing.sm),
            if (platform != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 5,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: musicPlatformAccent(platform)
                      .withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(VboxRadii.r4),
                ),
                child: Text(
                  platform.displayName,
                  style: const TextStyle(
                    fontSize: VboxTypography.s10,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            if (duration != null && duration > 0) ...<Widget>[
              const SizedBox(width: VboxSpacing.sm),
              Text(
                formatMusicDuration(duration),
                style: TextStyle(
                  fontSize: VboxTypography.s11,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(width: VboxSpacing.sm),
            Icon(
              Icons.play_circle_fill,
              size: 24,
              color: accent.withValues(alpha: 0.85),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// 歌曲行（通用）
// ════════════════════════════════════════════════════════════════════════

/// 歌曲行（对齐 iOS `MusicRowView`，L1489）。
///
/// 落地差异：iOS 的 `MusicRowView` 消费跨源搜索的 `VodItem`；Flutter 侧服务只暴露
/// 歌单搜索、无跨源歌曲搜索，本组件改以 [PlaylistSong] 呈现（字段一一对应）。
class MusicRow extends StatelessWidget {
  /// 构造。
  const MusicRow({
    super.key,
    required this.song,
    required this.onPlay,
    this.accentColor,
  });

  /// 歌曲。
  final PlaylistSong song;

  /// 点击播放。
  final VoidCallback onPlay;

  /// 强调色（缺省取主题主色）。
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color accent = accentColor ?? scheme.primary;
    final MusicPlatformType? platform = MusicPlatformType.fromId(song.platform);
    final int? duration = song.duration;

    return InkWell(
      onTap: onPlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: VboxSpacing.xs),
        child: Row(
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(VboxRadii.r8),
              child: SizedBox(
                width: 50,
                height: 50,
                child: PlatformAsyncImage(
                  url: song.coverURL,
                  fit: BoxFit.cover,
                  placeholder: ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: Icon(
                      Icons.music_note,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: VboxSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    song.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: VboxTypography.s14,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  if (song.artist.isNotEmpty) ...<Widget>[
                    const SizedBox(height: VboxSpacing.xs),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: VboxTypography.s11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (platform != null) ...<Widget>[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: musicPlatformAccent(platform)
                      .withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(VboxRadii.r4),
                ),
                child: Text(
                  platform.displayName,
                  style: const TextStyle(
                    fontSize: VboxTypography.s10,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: VboxSpacing.sm),
            ],
            if (duration != null && duration > 0)
              Padding(
                padding: const EdgeInsets.only(right: VboxSpacing.sm),
                child: Text(
                  formatMusicDuration(duration),
                  style: TextStyle(
                    fontSize: VboxTypography.s11,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            Icon(
              Icons.play_circle_fill,
              size: 28,
              color: accent.withValues(alpha: 0.8),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// 歌单 / 榜单详情页
// ════════════════════════════════════════════════════════════════════════

/// 歌单 / 榜单详情页（对齐 iOS `PlaylistDetailView`，L1121）。
///
/// 详情由调用方（歌单卡 / 榜单行）加载后传入；本页负责展示 + 播放。
class PlaylistDetailPage extends StatelessWidget {
  /// 构造。
  const PlaylistDetailPage({
    super.key,
    required this.detail,
    this.controller,
    this.onResolveSong,
  });

  /// 已加载的歌单 / 榜单详情。
  final PlaylistDetail detail;

  /// 播放控制器（缺省取全局单例）。
  final MusicPlayerController? controller;

  /// 歌曲 → 可播放队列条目（缺省 / 返回 null 时提示「该来源暂不支持播放」）。
  final Future<MusicQueueItem?> Function(PlaylistSong song)? onResolveSong;

  @override
  Widget build(BuildContext context) {
    return _PlaylistDetailBody(
      detail: detail,
      controller: controller,
      onResolveSong: onResolveSong,
    );
  }
}

class _PlaylistDetailBody extends StatefulWidget {
  const _PlaylistDetailBody({
    required this.detail,
    this.controller,
    this.onResolveSong,
  });

  final PlaylistDetail detail;
  final MusicPlayerController? controller;
  final Future<MusicQueueItem?> Function(PlaylistSong song)? onResolveSong;

  @override
  State<_PlaylistDetailBody> createState() => _PlaylistDetailBodyState();
}

class _PlaylistDetailBodyState extends State<_PlaylistDetailBody> {
  late final MusicPlayerController _player =
      widget.controller ?? MusicPlayerController.instance;

  bool _isResolvingAll = false;
  int _resolveProgress = 0;
  int _resolveTotal = 0;

  PlaylistDetail get _detail => widget.detail;

  Future<void> _playSong(PlaylistSong song) async {
    final Future<MusicQueueItem?> Function(PlaylistSong)?
        resolver = widget.onResolveSong;
    if (resolver == null) {
      VboxToast.show(context, '该来源暂不支持播放');
      return;
    }
    final MusicQueueItem? item = await resolver(song);
    if (!mounted) return;
    if (item == null) {
      VboxToast.show(context, '该来源暂不支持播放');
      return;
    }
    await _player.setQueue(<MusicQueueItem>[item], startIndex: 0);
  }

  /// 播放全部（对齐 iOS `playPlaylistDetail`：先并发解析前 4 首尽快开播，其余分批追加）。
  Future<void> _playAll() async {
    final Future<MusicQueueItem?> Function(PlaylistSong)?
        resolver = widget.onResolveSong;
    final List<PlaylistSong> songs = _detail.songs;
    if (songs.isEmpty) return;
    if (resolver == null) {
      VboxToast.show(context, '该来源暂不支持播放');
      return;
    }

    setState(() {
      _isResolvingAll = true;
      _resolveTotal = songs.length;
      _resolveProgress = 0;
    });

    final int headCount = math.min(4, songs.length);
    final List<MusicQueueItem?> head =
        await _resolveBatch(songs.take(headCount).toList(), resolver);
    if (!mounted) return;
    final List<MusicQueueItem> headResolved =
        head.whereType<MusicQueueItem>().toList();
    if (headResolved.isNotEmpty) {
      await _player.setQueue(<MusicQueueItem>[headResolved.first], startIndex: 0);
      for (final MusicQueueItem item in headResolved.skip(1)) {
        await _player.addToQueue(item);
      }
    } else {
      if (!mounted) return;
      VboxToast.show(context, '该来源暂不支持播放');
    }
    setState(() => _resolveProgress = headCount);

    if (headCount < songs.length) {
      final List<PlaylistSong> rest = songs.skip(headCount).toList();
      for (int i = 0; i < rest.length; i += 4) {
        final List<PlaylistSong> batch =
            rest.sublist(i, math.min(i + 4, rest.length));
        final List<MusicQueueItem?> items =
            await _resolveBatch(batch, resolver);
        if (!mounted) return;
        for (final MusicQueueItem item in items.whereType<MusicQueueItem>()) {
          await _player.addToQueue(item);
        }
        setState(
          () => _resolveProgress =
              math.min(songs.length, headCount + i + batch.length),
        );
      }
    }

    if (!mounted) return;
    setState(() {
      _isResolvingAll = false;
      _resolveProgress = 0;
    });
  }

  Future<List<MusicQueueItem?>> _resolveBatch(
    List<PlaylistSong> songs,
    Future<MusicQueueItem?> Function(PlaylistSong) resolver,
  ) {
    return Future.wait<MusicQueueItem?>(
      songs.map((PlaylistSong s) => resolver(s)),
    );
  }

  void _openPlayer() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            MusicPlayerPage(controller: widget.controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color accent = scheme.primary;
    final List<PlaylistSong> songs = _detail.songs;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        centerTitle: true,
        title: Text(
          _detail.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: VboxTypography.s16,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: <Widget>[
          if (songs.isNotEmpty)
            IconButton(
              tooltip: '播放全部',
              onPressed: _playAll,
              icon: Icon(Icons.play_arrow, color: accent),
            ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          Column(
            children: <Widget>[
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 96),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _header(scheme),
                      if (_isResolvingAll)
                        _progressBanner(scheme, accent),
                      _playAllBar(scheme, accent),
                      if (songs.isEmpty)
                        _emptySongs(scheme)
                      else
                        for (final PlaylistSong song in songs) ...<Widget>[
                          PlaylistSongRow(
                            song: song,
                            accentColor: accent,
                            onPlay: () => _playSong(song),
                          ),
                          Divider(
                            indent: 68,
                            height: 1,
                            color: scheme.outlineVariant
                                .withValues(alpha: 0.5),
                          ),
                        ],
                    ],
                  ),
                ),
              ),
            ],
          ),
          Positioned.fill(
            child: MiniPlayerBar(
              controller: widget.controller,
              onExpand: _openPlayer,
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(ColorScheme scheme) {
    final String? creator = _detail.creator;
    final String? desc = _detail.description;

    return Padding(
      padding: const EdgeInsets.only(
        left: VboxSpacing.lg,
        right: VboxSpacing.lg,
        top: VboxSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(VboxRadii.r10),
            child: SizedBox(
              width: 110,
              height: 110,
              child: PlatformAsyncImage(
                url: _detail.coverURL,
                fit: BoxFit.cover,
                placeholder: ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.music_note,
                    size: 30,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: VboxSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _detail.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: VboxTypography.s16,
                    fontWeight: FontWeight.bold,
                    color: scheme.onSurface,
                  ),
                ),
                if (creator != null && creator.isNotEmpty) ...<Widget>[
                  const SizedBox(height: VboxSpacing.compact),
                  Text(
                    creator,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: VboxTypography.s12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: VboxSpacing.compact),
                Text(
                  '${_detail.songCount} 首',
                  style: TextStyle(
                    fontSize: VboxTypography.s11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (desc != null && desc.isNotEmpty) ...<Widget>[
                  const SizedBox(height: VboxSpacing.compact),
                  Text(
                    desc,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: VboxTypography.s11,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _progressBanner(ColorScheme scheme, Color accent) {
    return Padding(
      padding: const EdgeInsets.only(
        left: VboxSpacing.lg,
        right: VboxSpacing.lg,
        top: VboxSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: accent),
          ),
          const SizedBox(width: VboxSpacing.sm),
          Text(
            _resolveProgress > 0
                ? '正在解析歌曲地址 $_resolveProgress/$_resolveTotal…'
                : '正在解析首播地址…',
            style: TextStyle(
              fontSize: VboxTypography.s11,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _playAllBar(ColorScheme scheme, Color accent) {
    final List<PlaylistSong> songs = _detail.songs;
    return InkWell(
      onTap: _playAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: VboxSpacing.lg,
          vertical: VboxSpacing.segmentVertical,
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.play_circle_fill, size: 22, color: accent),
            const SizedBox(width: VboxSpacing.sm),
            Text(
              '播放全部',
              style: TextStyle(
                fontSize: VboxTypography.s14,
                fontWeight: FontWeight.w500,
                color: accent,
              ),
            ),
            if (songs.isNotEmpty) ...<Widget>[
              const SizedBox(width: VboxSpacing.xs),
              Text(
                '(${songs.length})',
                style: TextStyle(
                  fontSize: VboxTypography.s12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const Spacer(),
          ],
        ),
      ),
    );
  }

  Widget _emptySongs(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Column(
          children: <Widget>[
            Icon(
              Icons.queue_music,
              size: 36,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: VboxSpacing.segmentVertical),
            Text(
              '暂无歌曲',
              style: TextStyle(
                fontSize: VboxTypography.s13,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}