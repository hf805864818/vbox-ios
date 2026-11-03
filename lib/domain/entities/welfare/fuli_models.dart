/// 领域层：福利专区通用数据模型（批次 H · H-03）。
///
/// 唯一真相源：iOS `vbox/Models/FuliPlatformKit.swift`
///   · `FuliCategory`（分类，支持一级 + 可选二级）；
///   · `FuliVideo`（视频条目，`vodId` 为唯一标识）；
///   · `FuliEpisode`（剧集，漫画场景携带图片列表）；
///   · `FuliDetail` / `FuliHomeResult` / `FuliCategoryResult` / `FuliSearchResult`
///     / `FuliPlayerResult`（抓取契约各结果）；
///   · `FuliHomeResult.empty`（首页空结果兜底）。
///
/// 供 `fuli_base` / JS / Python 福利 Spider 服务与「福利原生平台」批次共用；
/// 内容类型枚举（video / comic）在 `domain/services/fuli_base_service.dart`。
library;

/// 分类（支持一级 + 可选二级）。
class FuliCategory {
  /// 构造。
  const FuliCategory({
    required this.typeId,
    required this.typeName,
    this.subCategories,
  });

  /// 分类 ID（二级分类沿用）。
  final String typeId;

  /// 分类名。
  final String typeName;

  /// 二级分类（可选）。
  final List<FuliCategory>? subCategories;
}

/// 视频条目。
class FuliVideo {
  /// 构造。
  const FuliVideo({
    required this.vodId,
    required this.vodName,
    required this.vodPic,
    this.vodRemarks,
    this.duration,
    this.score,
    this.areaName,
  });

  /// 唯一 ID（历史记录定位主键）。
  final String vodId;

  /// 名称。
  final String vodName;

  /// 封面图。
  final String vodPic;

  /// 备注（角标，如「更新至 12 集」）。
  final String? vodRemarks;

  /// 时长（可选扩展）。
  final String? duration;

  /// 评分（可选扩展）。
  final String? score;

  /// 地区（可选扩展）。
  final String? areaName;
}

/// 剧集。
class FuliEpisode {
  /// 构造。
  const FuliEpisode({required this.name, required this.url, this.images});

  /// 剧集名（多线路时形如「[线路名] 第X集」）。
  final String name;

  /// 播放地址（或待解析地址）。
  final String url;

  /// 漫画 / 套图专用：图片地址列表。
  final List<String>? images;
}

/// 视频详情。
class FuliDetail {
  /// 构造。
  const FuliDetail({
    required this.vodId,
    required this.vodName,
    required this.vodPic,
    required this.vodContent,
    required this.playFrom,
    required this.episodes,
  });

  /// 视频 ID。
  final String vodId;

  /// 名称。
  final String vodName;

  /// 封面图。
  final String vodPic;

  /// 简介（可空）。
  final String? vodContent;

  /// 线路名（`$$$` 分隔的多线路名）。
  final String playFrom;

  /// 剧集列表。
  final List<FuliEpisode> episodes;
}

/// 首页结果（分类 + 推荐视频）。
class FuliHomeResult {
  /// 构造。
  const FuliHomeResult({required this.categories, required this.videos});

  /// 分类列表。
  final List<FuliCategory> categories;

  /// 推荐视频列表。
  final List<FuliVideo> videos;

  /// 空结果（分类为空时的默认首页）。
  static const FuliHomeResult empty =
      FuliHomeResult(categories: <FuliCategory>[], videos: <FuliVideo>[]);
}

/// 分类结果。
class FuliCategoryResult {
  /// 构造。
  const FuliCategoryResult({
    required this.videos,
    required this.page,
    required this.hasMore,
  });

  /// 视频列表。
  final List<FuliVideo> videos;

  /// 当前页。
  final int page;

  /// 是否有下一页。
  final bool hasMore;
}

/// 搜索结果。
class FuliSearchResult {
  /// 构造。
  const FuliSearchResult({
    required this.videos,
    required this.page,
    required this.hasMore,
  });

  /// 视频列表。
  final List<FuliVideo> videos;

  /// 当前页。
  final int page;

  /// 是否有下一页。
  final bool hasMore;
}

/// 播放器结果。
class FuliPlayerResult {
  /// 构造。
  const FuliPlayerResult({
    required this.url,
    required this.headers,
    required this.parse,
  });

  /// 播放地址。
  final String url;

  /// 自定义请求头。
  final Map<String, String> headers;

  /// 0=直接播放，1=需要 Web 解析。
  final int parse;
}
