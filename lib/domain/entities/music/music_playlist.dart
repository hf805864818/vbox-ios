/// 领域层：网络音乐歌单 / 榜单模型（批次 G · G-音1）。
///
/// 唯一真相源：iOS `MusicPlaylistService.swift` L4-L82 的五个模型
/// （`MusicPlatformType` / `PlaylistCategory` / `PlaylistItem` / `PlaylistSong`
/// / `PlaylistDetail` / `RankingItem`）。
///
/// 纯 Dart（不引 Flutter）：平台强调色属表现层，见 `MusicPlatformType` 的
/// 展示色映射在表现层 `music_platform_style.dart`。
library;

/// 音乐平台（对齐 iOS `MusicPlatformType`：`wy` / `tx` / `kg` / `kw` / `mg`）。
enum MusicPlatformType {
  /// 网易云音乐。
  netease('wy', '网易云'),

  /// QQ 音乐。
  qq('tx', 'QQ音乐'),

  /// 酷狗音乐。
  kugou('kg', '酷狗'),

  /// 酷我音乐。
  kuwo('kw', '酷我'),

  /// 咪咕音乐。
  migu('mg', '咪咕');

  const MusicPlatformType(this.id, this.displayName);

  /// 契约字符串值（与 iOS `rawValue` 一致）。
  final String id;

  /// 中文显示名。
  final String displayName;

  /// 解析契约字符串（未知值返回 null）。
  static MusicPlatformType? fromId(String? id) {
    for (final MusicPlatformType p in values) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// 歌单分类标签（对齐 iOS `PlaylistCategory`）。
class PlaylistCategory {
  /// 构造。
  const PlaylistCategory({
    required this.id,
    required this.name,
    required this.platform,
  });

  /// 分类 ID（下拉/请求用）。
  final String id;

  /// 分类名。
  final String name;

  /// 所属平台。
  final MusicPlatformType platform;
}

/// 歌单条目（对齐 iOS `PlaylistItem`）。
class PlaylistItem {
  /// 构造。
  const PlaylistItem({
    required this.id,
    required this.name,
    required this.coverURL,
    required this.platform,
    required this.rawId,
    this.playCount,
    this.songCount,
    this.creator,
  });

  /// 唯一定位 ID（跨平台去重用）。
  final String id;

  /// 歌单名。
  final String name;

  /// 封面。
  final String coverURL;

  /// 平台。
  final MusicPlatformType platform;

  /// 平台原始 ID（详情请求用）。
  final String rawId;

  /// 播放量文案（「12.3万」等，平台给定）。
  final String? playCount;

  /// 歌曲数。
  final int? songCount;

  /// 创建者。
  final String? creator;
}

/// 歌单内歌曲（对齐 iOS `PlaylistSong`）。
class PlaylistSong {
  /// 构造。
  const PlaylistSong({
    required this.id,
    required this.name,
    required this.artist,
    required this.platform,
    this.album,
    this.duration,
    this.coverURL,
    this.rawInfo,
  });

  /// 歌曲 ID（lx 解析用）。
  final String id;

  /// 歌名。
  final String name;

  /// 歌手。
  final String artist;

  /// 平台标识（lx 音源定向用）。
  final String platform;

  /// 专辑名。
  final String? album;

  /// 时长（秒）。
  final int? duration;

  /// 封面。
  final String? coverURL;

  /// lx 原始 musicInfo（音质切换/歌词透传）。
  final String? rawInfo;
}

/// 歌单 / 榜单详情（对齐 iOS `PlaylistDetail`）。
class PlaylistDetail {
  /// 构造。
  const PlaylistDetail({
    required this.id,
    required this.name,
    required this.coverURL,
    required this.songCount,
    required this.songs,
    required this.platform,
    this.creator,
    this.description,
  });

  /// 歌单 ID。
  final String id;

  /// 歌单名。
  final String name;

  /// 封面。
  final String coverURL;

  /// 歌曲数。
  final int songCount;

  /// 歌曲列表。
  final List<PlaylistSong> songs;

  /// 平台。
  final MusicPlatformType platform;

  /// 创建者。
  final String? creator;

  /// 简介。
  final String? description;
}

/// 榜单条目（对齐 iOS `RankingItem`）。
class RankingItem {
  /// 构造。
  const RankingItem({
    required this.id,
    required this.name,
    required this.platform,
    required this.rawId,
    this.coverURL,
    this.updateFreq,
  });

  /// 唯一定位 ID。
  final String id;

  /// 榜单名。
  final String name;

  /// 平台。
  final MusicPlatformType platform;

  /// 平台原始 ID（详情请求用）。
  final String rawId;

  /// 封面。
  final String? coverURL;

  /// 更新频率文案。
  final String? updateFreq;
}