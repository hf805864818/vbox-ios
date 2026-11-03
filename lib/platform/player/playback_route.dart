/// 平台层：播放路由（批次 C · C-01 路由 → 后端选择）。
///
/// 三端差异化后端选择的判定依据：按播放源特征解析出路由类型，
/// 再由 [PlaybackRouteResolver] 决定各平台的初始后端与降级链。
library;

import '../../domain/entities/player/player.dart';

/// 播放路由类型。
enum PlaybackRoute {
  /// 影视剧集（点播直链 / HLS）。
  detail,

  /// 直播（HLS / FLV 直播流）。
  live,

  /// 网盘播放（直链 / 转存分发）。
  pan,

  /// 音频（音乐 / 播客）。
  music,

  /// 本地文件（file:// 或绝对路径）。
  local,
}

/// 播放路由判定（C-01）。
///
/// 规则（对齐 iOS `PlayerCore/PlaybackRoute.swift` 的 `PlaybackRouteType`
/// + `PlaybackRoute{type,url,headers,title,priority}` 语义）：
/// - [PlayerSource.isLive] → 直播；
/// - `file://` / 绝对路径 / Windows 盘符路径 → 本地；
/// - 音频扩展名 → 音乐；
/// - 其余（含网盘直链，网盘模式由调用方经 `mimeType` 或显式 route 标记）→ 影视。
class PlaybackRouteResolver {
  PlaybackRouteResolver._();

  /// 音频扩展名清单。
  static const List<String> audioExtensions = <String>[
    '.mp3', '.m4a', '.aac', '.flac', '.wav', '.ogg', '.oga', '.opus', '.wma',
  ];

  /// 由播放源解析路由。
  static PlaybackRoute resolve(PlayerSource source) {
    if (source.isLive) return PlaybackRoute.live;
    final String u = source.url.trim().toLowerCase();
    if (_looksLocal(u)) return PlaybackRoute.local;
    if (u.endsWith('.flv')) return PlaybackRoute.live;
    for (final String ext in audioExtensions) {
      if (u.endsWith(ext)) return PlaybackRoute.music;
    }
    return PlaybackRoute.detail;
  }

  /// 是否本地路径（file:// 前缀 / 绝对路径 / Windows 盘符）。
  static bool _looksLocal(String url) {
    if (url.startsWith('file://')) return true;
    if (url.startsWith('/')) return true;
    return RegExp(r'^[a-z]:[\\/]').hasMatch(url);
  }

  /// 由 [PlayerSource] 构造候选（优先级 0）。
  static PlaybackRouteCandidate fromSource(
    PlayerSource source, {
    int priority = 0,
    PlaybackRoute? route,
  }) =>
      PlaybackRouteCandidate(
        route: route ?? resolve(source),
        url: source.url,
        headers: source.headers,
        title: source.title,
        priority: priority,
      );

  /// 按优先级降序排列候选（同优先级保持原顺序，稳定排序）。
  ///
  /// P-芯1：同一资源多条候选线路（原画 / 流畅 / localProxy 转封装等）时，
  /// 调用方取首项播放，失败再回退下一项（对齐 iOS `PlaybackRoute.priority`）。
  static List<PlaybackRouteCandidate> rank(
    List<PlaybackRouteCandidate> candidates,
  ) {
    final List<PlaybackRouteCandidate> sorted =
        List<PlaybackRouteCandidate>.of(candidates);
    // 稳定排序：index 记录原序，priority 降序为主键。
    final List<int> index = List<int>.generate(sorted.length, (int i) => i);
    index.sort((int a, int b) {
      final int c = sorted[b].priority.compareTo(sorted[a].priority);
      return c != 0 ? c : a.compareTo(b);
    });
    return <PlaybackRouteCandidate>[for (final int i in index) sorted[i]];
  }
}

/// 播放路由候选（P-芯1，对齐 iOS `PlaybackRoute{type,url,headers,title,priority}`）。
///
/// 表达「同一资源的多条候选线路 + 优先级 + 每线路鉴权头」，供调用方按
/// [priority] 从高到低尝试；`headers` 随选中线路下发播放后端。
class PlaybackRouteCandidate {
  /// 构造。
  const PlaybackRouteCandidate({
    required this.route,
    required this.url,
    this.headers = const <String, String>{},
    this.title,
    this.priority = 0,
  });

  /// 路由类型（影视 / 直播 / 网盘 / 音乐 / 本地）。
  final PlaybackRoute route;

  /// 该候选的媒体地址。
  final String url;

  /// 该候选的请求头（鉴权 / Referer 等，随线路下发）。
  final Map<String, String> headers;

  /// 显示标题。
  final String? title;

  /// 优先级（越大越优先）。
  final int priority;

  /// 转为播放源。
  PlayerSource toSource({bool isLive = false}) => PlayerSource(
        url: url,
        headers: headers,
        title: title,
        isLive: isLive || route == PlaybackRoute.live,
      );

  @override
  String toString() =>
      'PlaybackRouteCandidate(${route.name}, p=$priority, $url)';
}
