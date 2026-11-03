/// 领域层：福利 Spider 结果映射工具（批次 H · H-03）。
///
/// 唯一真相源：iOS `vbox/WelfareRemote/WelfareResultMapper.swift`
///   · `mapHome` / `mapCategory` / `mapDetail` / `mapSearch` / `mapPlayer`：
///     标准 Spider 结果模型 → 福利专区 `Fuli*` 模型（分类 / 视频 / 详情 / 剧集）；
///   · `parseEpisodes`（L121-L164）：`vod_play_from` + `vod_play_url` 智能解析，
///     兼容标准（`$$$` 分线路 / `#` 分集）与非标准（`$$$` 直接分集）两种格式；
///   · `parseMangaURL` / `isMangaProtocol`（L85-L99）：漫画 `manga://` / `pics://`
///     协议图片列表解析。
///
/// 纯工具类，无状态，便于单测（对齐 iOS「纯工具类，无状态」设计目标）。
/// 被 [WelfareJSSpiderService] / [WelfarePythonSpiderService] 共用。
library;

import '../entities/spider/spider_models.dart';
import '../entities/welfare/fuli_models.dart';

/// Python / JS 福利蜘蛛 → 福利专区模型映射工具。
class WelfareResultMapper {
  /// 构造。
  const WelfareResultMapper();

  // ─────────────── Home ───────────────

  /// 首页结果映射（分类 + 推荐视频）。
  FuliHomeResult mapHome(HomeContentResult result) {
    final List<FuliCategory> categories = (result.classes ?? const <VodCategory>[])
        .map((VodCategory c) => FuliCategory(
              typeId: c.typeId,
              typeName: c.typeName,
              // 二级分类透传（可选）：普通源 subCategories 恒 null，行为不变。
              subCategories: c.subCategories
                  ?.map((VodCategory s) =>
                      FuliCategory(typeId: s.typeId, typeName: s.typeName))
                  .toList(),
            ))
        .toList(growable: false);
    final List<FuliVideo> videos =
        (result.list ?? const <VodItem>[]).map(_mapVideo).whereType<FuliVideo>().toList();
    return FuliHomeResult(categories: categories, videos: videos);
  }

  // ─────────────── Category ───────────────

  /// 分类结果映射（对齐 iOS `mapCategory`：page 缺省 1、pagecount 缺省 1）。
  FuliCategoryResult mapCategory(CategoryContentResult result) {
    final List<FuliVideo> videos =
        (result.list ?? const <VodItem>[]).map(_mapVideo).whereType<FuliVideo>().toList();
    final int pageCount = result.pagecount ?? 1;
    final int page = result.page ?? 1;
    return FuliCategoryResult(videos: videos, page: page, hasMore: page < pageCount);
  }

  // ─────────────── Detail ───────────────

  /// 详情结果映射（首个条目 → 详情 + 剧集）。
  FuliDetail mapDetail(DetailContentResult result) {
    final VodItem? item = result.list?.isNotEmpty == true ? result.list!.first : null;
    if (item == null) {
      return const FuliDetail(
        vodId: '',
        vodName: '',
        vodPic: '',
        vodContent: null,
        playFrom: '',
        episodes: <FuliEpisode>[],
      );
    }
    final List<FuliEpisode> episodes = parseEpisodes(
      playFrom: item.vodPlayFrom ?? '',
      playUrl: item.vodPlayUrl ?? '',
    );
    return FuliDetail(
      vodId: item.vodId,
      vodName: item.vodName,
      vodPic: item.vodPic,
      vodContent: item.vodContent,
      playFrom: item.vodPlayFrom ?? '',
      episodes: episodes,
    );
  }

  // ─────────────── Search ───────────────

  /// 搜索结果映射（对齐 iOS `mapSearch`）。
  FuliSearchResult mapSearch(SearchContentResult result) {
    final List<FuliVideo> videos =
        (result.list ?? const <VodItem>[]).map(_mapVideo).whereType<FuliVideo>().toList();
    final int pageCount = result.pagecount ?? 1;
    final int page = result.page ?? 1;
    return FuliSearchResult(videos: videos, page: page, hasMore: page < pageCount);
  }

  // ─────────────── Player ───────────────

  /// 播放结果映射（`playUrl` 优先，其次 `url`；对齐 iOS `mapPlayer`）。
  FuliPlayerResult mapPlayer(PlayerContentResult result) {
    final String url = (result.playUrl != null && result.playUrl!.isNotEmpty)
        ? result.playUrl!
        : (result.url ?? '');
    return FuliPlayerResult(
      url: url,
      headers: result.header ?? const <String, String>{},
      parse: result.parse ?? 0,
    );
  }

  // ─────────────── 漫画图片解析 ───────────────

  /// 解析 `manga://` / `pics://` 协议 URL 为图片列表（`&&` 分隔，http 前缀过滤）。
  List<String> parseMangaURL(String url) {
    if (!isMangaProtocol(url)) return const <String>[];
    final String content = url.startsWith('manga://')
        ? url.substring(8)
        : url.substring(7);
    return content
        .split('&&')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty && s.startsWith('http'))
        .toList(growable: false);
  }

  /// 判断 URL 是否为漫画图片协议。
  bool isMangaProtocol(String url) =>
      url.startsWith('manga://') || url.startsWith('pics://');

  // ─────────────── 剧集解析 ───────────────

  /// 解析标准 spider 的 `vod_play_from` + `vod_play_url` 为 [FuliEpisode] 数组。
  ///
  /// 格式：
  ///   `vod_play_from`: "线路1$$$线路2"  （多线路用 `$$$` 分隔）
  ///   `vod_play_url`:  "第1集$url1#第2集$url2$$$第1集$url1#第2集$url2"
  ///
  /// 非标准格式（黄豆短剧等）：
  ///   `vod_play_url`:  "第1集$url1$$$第2集$url2$$$第3集$url3"
  ///   （`$$$` 直接分隔每一集，而非分隔线路）
  List<FuliEpisode> parseEpisodes({
    required String playFrom,
    required String playUrl,
  }) {
    if (playUrl.isEmpty) return const <FuliEpisode>[];

    // 1. 先按标准格式解析（$$$ 分隔线路，# 分隔集）。
    final List<FuliEpisode> standard = parseStandardFormat(
      playFrom: playFrom,
      playUrl: playUrl,
    );

    // 2. 没有 $$$ 分隔符 → 直接返回标准格式。
    if (!playUrl.contains(r'$$$')) return standard;

    // 3. 尝试非标准格式（$$$ 直接分集）。
    final List<FuliEpisode> nonStandard = parseNonStandardFormat(playUrl);

    // 4. 智能判断使用哪种格式。
    final List<String> urlGroups = playUrl.split(r'$$$');
    final bool allBlocksLikeEpisodes = urlGroups.every(
      (String g) => _isEpisodeName(g.split(r'$').first),
    );
    final bool allBlocksLikeLines = urlGroups.every(
      (String g) => _isLineName(g.split(r'$').first),
    );

    // 所有 $$$ 块都像集名 且 标准格式只能解析出很少的集 → 用非标准格式。
    if (allBlocksLikeEpisodes &&
        standard.length <= 1 &&
        nonStandard.length > 1) {
      return nonStandard;
    }

    // 所有 $$$ 块都像线路名 → 用标准格式。
    if (allBlocksLikeLines) return standard;

    // 标准格式结果像线路名（集数少且名字像线路） → 尝试非标准格式。
    if (standard.length <= 5 &&
        standard.isNotEmpty &&
        _isLineName(standard.first.name)) {
      if (nonStandard.length > standard.length) return nonStandard;
    }

    // 集数差距很大（>3 倍）且非标准格式集数多时，选集数多的。
    if (nonStandard.length > standard.length * 3 && nonStandard.length > 5) {
      return nonStandard;
    }

    // 默认使用标准格式。
    return standard;
  }

  /// 标准格式解析：`$$$` 分隔线路，`#` 分隔集，`$` 分隔集名和 URL。
  List<FuliEpisode> parseStandardFormat({
    required String playFrom,
    required String playUrl,
  }) {
    final List<String> lines = playFrom.split(r'$$$');
    final List<String> urlGroups = playUrl.split(r'$$$');

    final List<FuliEpisode> episodes = <FuliEpisode>[];
    final bool hasMultipleLines = lines.length > 1;

    for (int i = 0; i < urlGroups.length; i++) {
      final String lineName =
          i < lines.length ? lines[i] : '线路${i + 1}';
      final List<String> items = urlGroups[i].split('#');

      for (final String item in items) {
        final List<String> parts = item.split(r'$');
        if (parts.length < 2) continue;
        final String epName =
            parts[0].isEmpty ? '第${episodes.length + 1}集' : parts[0];
        final String epUrl = parts[1];
        final String displayName =
            hasMultipleLines ? '[$lineName] $epName' : epName;
        episodes.add(FuliEpisode(name: displayName, url: epUrl));
      }
    }

    return episodes;
  }

  /// 非标准格式解析：`$$$` 直接分隔集，每集用 `集名$URL` 格式。
  List<FuliEpisode> parseNonStandardFormat(String playUrl) {
    final List<String> items = playUrl.split(r'$$$');
    final List<FuliEpisode> episodes = <FuliEpisode>[];

    for (int i = 0; i < items.length; i++) {
      final List<String> parts = items[i].split(r'$');
      if (parts.length < 2) continue;
      final String epName = parts[0].isEmpty ? '第${i + 1}集' : parts[0];
      final String epUrl = parts[1];
      if (epName.isEmpty || !epUrl.startsWith('http')) continue;
      episodes.add(FuliEpisode(name: epName, url: epUrl));
    }

    return episodes;
  }

  // ─────────────── 名称判定 ───────────────

  /// 判断名称是否像线路名（而非集数名）。
  bool _isLineName(String name) {
    const List<String> lineKeywords = <String>[
      '线路', '高清', '超清', '蓝光', '标清', '备用', '极速', '流畅', '云播', '云视频',
      'm3u8', 'mp4', 'ckm3u8', 'kuyun', 'zuidazy', 'ok资源', '永久', '腾讯', '爱奇艺',
      '优酷', '乐视', 'pptv', 'bilibili', '1080P', '720P', '4K', '专线',
    ];
    final String lower = name.toLowerCase();
    for (final String keyword in lineKeywords) {
      if (lower.contains(keyword.toLowerCase())) return true;
    }
    return false;
  }

  /// 判断名称是否像集数名。
  bool _isEpisodeName(String name) {
    // 第X集 / 第X话 / 第X章 / 第X期 / 第X回 / 第X篇。
    if (RegExp(r'^第\d+[集话章期回篇]').hasMatch(name)) return true;
    // 纯数字。
    if (RegExp(r'^\d+$').hasMatch(name)) return true;
    // EP / E / S01E01 格式。
    if (RegExp(r'^[Ee][Pp]?\d+').hasMatch(name)) return true;
    // 集 / 话 / 章 结尾。
    if (name.endsWith('集') ||
        name.endsWith('话') ||
        name.endsWith('章')) {
      return true;
    }
    return false;
  }

  /// VodItem → FuliVideo（`vodId` 为空返回 `null`，对齐 iOS `mapVideo`）。
  FuliVideo? _mapVideo(VodItem item) {
    if (item.vodId.isEmpty) return null;
    return FuliVideo(
      vodId: item.vodId,
      vodName: item.vodName,
      vodPic: item.vodPic,
      vodRemarks: item.vodRemarks,
    );
  }
}
