/// 领域层：麻豆平台（MDTV）数据模型 + 加密模式枚举。
///
/// 对齐 iOS `MDTVService.swift` 的 `MDTVCategory` / `MDTVVideoItem` /
/// `MDTVVideoDetail` / `MDTVPlaySource` / `MDTVTag` / `MDTVEncryptMode`。
/// iOS 侧未声明 `CodingKeys`，故 JSON 键即属性名（camelCase）。
library;

/// 分类/频道模型。
class MdtvCategory {
  /// 构造。
  const MdtvCategory({
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

  /// 从 JSON 反序列化。
  factory MdtvCategory.fromJson(Map<String, dynamic> json) => MdtvCategory(
        cateId: json['cateId']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        icon: json['icon']?.toString(),
        sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
      );
}

/// 视频条目。
class MdtvVideoItem {
  /// 构造。
  const MdtvVideoItem({
    required this.videoId,
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
  });

  /// 视频 ID。
  final String videoId;

  /// 标题。
  final String title;

  /// 封面图 URL 路径（需拼接 CDN 域名）。
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

  /// 展示标识（对齐 iOS `Identifiable.id { videoId }`）。
  String get id => videoId;

  /// 从 JSON 反序列化。
  factory MdtvVideoItem.fromJson(Map<String, dynamic> json) => MdtvVideoItem(
        videoId: json['videoId']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        cover: json['cover']?.toString() ?? '',
        duration: json['duration']?.toString() ?? '00:00',
        views: (json['views'] as num?)?.toInt() ?? 0,
        likes: (json['likes'] as num?)?.toInt() ?? 0,
        categoryId: json['categoryId']?.toString() ?? '',
        categoryName: json['categoryName']?.toString(),
        tags: (json['tags'] as List<dynamic>?)
                ?.map((dynamic e) => e.toString())
                .toList() ??
            const <String>[],
        rating: json['rating']?.toString(),
        uploadTime: json['uploadTime']?.toString(),
      );
}

/// 播放源（多线路中的一条）。
class MdtvPlaySource {
  /// 构造。
  const MdtvPlaySource({required this.name, required this.url});

  /// 线路名。
  final String name;

  /// m3u8 或 mp4 地址。
  final String url;

  /// 展示标识（对齐 iOS `Identifiable.id { name }`）。
  String get id => name;

  /// 从 JSON 反序列化。
  factory MdtvPlaySource.fromJson(Map<String, dynamic> json) => MdtvPlaySource(
        name: json['name']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
      );
}

/// 视频详情。
class MdtvVideoDetail {
  /// 构造。
  const MdtvVideoDetail({
    required this.videoId,
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
    this.playUrls = const <MdtvPlaySource>[],
  });

  /// 视频 ID。
  final String videoId;

  /// 标题。
  final String title;

  /// 封面。
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

  /// 播放地址（单线路）。
  final String? playUrl;

  /// 播放列表（多线路）。
  final List<MdtvPlaySource> playUrls;

  /// 从 JSON 反序列化。
  factory MdtvVideoDetail.fromJson(Map<String, dynamic> json) =>
      MdtvVideoDetail(
        videoId: json['videoId']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        cover: json['cover']?.toString() ?? '',
        duration: json['duration']?.toString() ?? '00:00',
        views: (json['views'] as num?)?.toInt() ?? 0,
        likes: (json['likes'] as num?)?.toInt() ?? 0,
        description: json['description']?.toString() ?? '',
        tags: (json['tags'] as List<dynamic>?)
                ?.map((dynamic e) => e.toString())
                .toList() ??
            const <String>[],
        actorName: json['actorName']?.toString(),
        categoryName: json['categoryName']?.toString(),
        uploadTime: json['uploadTime']?.toString(),
        rating: json['rating']?.toString(),
        playUrl: json['playUrl']?.toString(),
        playUrls: (json['playUrls'] as List<dynamic>?)
                ?.whereType<Map>()
                .map((dynamic e) => MdtvPlaySource.fromJson(
                    (e as Map).cast<String, dynamic>()))
                .toList() ??
            const <MdtvPlaySource>[],
      );
}

/// 标签。
class MdtvTag {
  /// 构造。
  const MdtvTag({required this.tagId, required this.name, required this.count});

  /// 标签 ID。
  final String tagId;

  /// 名称。
  final String name;

  /// 数量。
  final int count;

  /// 展示标识（对齐 iOS `Identifiable.id { tagId }`）。
  String get id => tagId;

  /// 从 JSON 反序列化。
  factory MdtvTag.fromJson(Map<String, dynamic> json) => MdtvTag(
        tagId: json['tagId']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        count: (json['count'] as num?)?.toInt() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is MdtvTag && other.tagId == tagId && other.name == name;

  @override
  int get hashCode => Object.hash(tagId, name);
}

/// 加密模式枚举（对齐 iOS `MDTVEncryptMode`）。
enum MdtvEncryptMode {
  /// AES-CBC。
  cbc('AES-CBC'),

  /// AES-CFB。
  cfb('AES-CFB'),

  /// AES-CTR。
  ctr('AES-CTR'),

  /// AES-OFB。
  ofb('AES-OFB'),

  /// AES-ECB。
  ecb('AES-ECB');

  /// 构造。
  const MdtvEncryptMode(this.label);

  /// 展示名。
  final String label;
}