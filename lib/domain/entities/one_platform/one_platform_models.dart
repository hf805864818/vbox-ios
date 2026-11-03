/// 领域层：One 平台（YBox）数据模型。
///
/// 对齐 iOS `OnePlatformService.swift` L20-L102 的 `OneCategory` /
/// `OneVideoItem` / `OneVideoDetail` / `OnePlaySource` / `OneAlbum` /
/// `OneChapter`。
///
/// 说明：iOS 侧字段解析由服务层 `parseVideoItem` / `parseVideoDetail` /
/// `parseAlbum` 完成（多别名键容错），故模型本身只承载已归一化的字段，
/// JSON 解析逻辑落在呈现层控制器（见 `one_platform_controller.dart`）。
library;

/// 分类（来自 `/v2.5/article/category`）。
class OneCategory {
  /// 构造。
  const OneCategory({
    required this.cateId,
    required this.name,
    this.icon,
    required this.sortOrder,
  });

  /// 分类 ID。
  final String cateId;

  /// 名称。
  final String name;

  /// 图标（可选）。
  final String? icon;

  /// 排序（升序）。
  final int sortOrder;

  /// 展示标识（对齐 iOS `Identifiable.id { cateId }`）。
  String get id => cateId;
}

/// 视频/文章条目（来自 `/v2.5/article/discovery` 或分类列表）。
class OneVideoItem {
  /// 构造。
  const OneVideoItem({
    required this.articleId,
    required this.title,
    required this.cover,
    required this.duration,
    required this.views,
    required this.likes,
    required this.categoryId,
    this.categoryName,
    this.tags = const <String>[],
    this.rating,
    this.uploadTime,
    this.description,
    this.actorName,
  });

  /// 文章 ID。
  final String articleId;

  /// 标题。
  final String title;

  /// 封面地址（已拼接 CDN 域名的完整 URL）。
  final String cover;

  /// 时长。
  final String duration;

  /// 播放量。
  final int views;

  /// 点赞数。
  final int likes;

  /// 分类 ID。
  final String categoryId;

  /// 分类名（可选）。
  final String? categoryName;

  /// 标签。
  final List<String> tags;

  /// 评分（可选）。
  final String? rating;

  /// 上传时间（可选）。
  final String? uploadTime;

  /// 简介（可选）。
  final String? description;

  /// 演员名（可选）。
  final String? actorName;

  /// 展示标识（对齐 iOS `Identifiable.id { articleId }`）。
  String get id => articleId;
}

/// 播放源（多线路中的一条）。
class OnePlaySource {
  /// 构造。
  const OnePlaySource({required this.name, required this.url});

  /// 线路名（如「高清」「备用」）。
  final String name;

  /// m3u8 或 mp4 地址。
  final String url;

  /// 展示标识（对齐 iOS `Identifiable.id { name }`）。
  String get id => name;
}

/// 视频详情（来自 `/v2.5/article/detail`）。
class OneVideoDetail {
  /// 构造。
  const OneVideoDetail({
    required this.articleId,
    required this.title,
    required this.cover,
    required this.duration,
    required this.views,
    required this.likes,
    this.description = '',
    this.tags = const <String>[],
    this.actorName,
    this.categoryName,
    this.uploadTime,
    this.rating,
    this.playUrl,
    this.playUrls = const <OnePlaySource>[],
  });

  /// 文章 ID。
  final String articleId;

  /// 标题。
  final String title;

  /// 封面（已拼接 CDN 域名的完整 URL）。
  final String cover;

  /// 时长。
  final String duration;

  /// 播放量。
  final int views;

  /// 点赞数。
  final int likes;

  /// 简介。
  final String description;

  /// 标签。
  final List<String> tags;

  /// 演员名（可选）。
  final String? actorName;

  /// 分类名（可选）。
  final String? categoryName;

  /// 上传时间（可选）。
  final String? uploadTime;

  /// 评分（可选）。
  final String? rating;

  /// 播放地址（单线路，取首线路）。
  final String? playUrl;

  /// 播放列表（多线路）。
  final List<OnePlaySource> playUrls;
}

/// 专辑/系列。
class OneAlbum {
  /// 构造。
  const OneAlbum({
    required this.albumId,
    required this.title,
    required this.cover,
    this.description = '',
    this.itemCount = 0,
    this.rating,
  });

  /// 专辑 ID。
  final String albumId;

  /// 标题。
  final String title;

  /// 封面（已拼接 CDN 域名的完整 URL）。
  final String cover;

  /// 简介。
  final String description;

  /// 章节数量。
  final int itemCount;

  /// 评分（可选）。
  final String? rating;

  /// 展示标识（对齐 iOS `Identifiable.id { albumId }`）。
  String get id => albumId;
}

/// 章节/漫画章节。
class OneChapter {
  /// 构造。
  const OneChapter({
    required this.chapterId,
    required this.title,
    required this.sortOrder,
    this.isPaid = false,
    this.hasRead = false,
  });

  /// 章节 ID。
  final String chapterId;

  /// 标题。
  final String title;

  /// 排序（升序）。
  final int sortOrder;

  /// 是否付费章节。
  final bool isPaid;

  /// 是否已读。
  final bool hasRead;

  /// 展示标识（对齐 iOS `Identifiable.id { chapterId }`）。
  String get id => chapterId;
}