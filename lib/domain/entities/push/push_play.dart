/// 推送播放领域模型（批次 G · G-03）。
///
/// 唯一真相源：iOS `vbox/Services/PushPlayStore.swift`
///   · [PushPlayLinkType]：三类链接（网盘 / 直链 / 网页解析）；
///   · [PushPlayEpisode]：解析后的剧集条目；
///   · [PushPlayItem]：推送链接条目（去重置顶 / 按 url 去重 / 可携带剧集）。
///
/// 持久化：契约键 `push_play_items_v1`（string）存 JSON 数组字符串；
/// 字段键名与 iOS `CodingKeys` 一致（title / url / type / createdAt / episodes）。
library;

import 'dart:convert';

/// 推送播放链接类型（对齐 iOS `PushPlayLinkType`）。
enum PushPlayLinkType {
  /// 网盘链接（阿里云盘 / 夸克 / 百度网盘 / 115 等分享链接）。
  cloud('cloud', '网盘资源'),

  /// 直链播放（m3u8 / mp4 / flv 等视频地址）。
  direct('direct', '直链播放'),

  /// 网页解析链接（视频详情页 URL，将自动解析）。
  web('web', '网页解析');

  /// 构造。
  const PushPlayLinkType(this.rawValue, this.displayName);

  /// 存储原始值（对齐 iOS `rawValue`：cloud / direct / web）。
  final String rawValue;

  /// 展示名。
  final String displayName;

  /// 反序列化（未知值 → [PushPlayLinkType.web] 兜底，避免脏数据崩溃）。
  static PushPlayLinkType fromRaw(String? raw) {
    for (final PushPlayLinkType t in PushPlayLinkType.values) {
      if (t.rawValue == raw) return t;
    }
    return PushPlayLinkType.web;
  }
}

/// 推送播放剧集条目（对齐 iOS `PushPlayEpisode`）。
class PushPlayEpisode {
  /// 构造。
  const PushPlayEpisode({required this.name, required this.url});

  /// 唯一标识（iOS `id: name + url`）。
  String get id => '$name$url';

  /// 集名。
  final String name;

  /// 播放地址。
  final String url;

  /// 序列化（键名对齐 iOS `CodingKeys`）。
  Map<String, Object?> toJson() => <String, Object?>{'name': name, 'url': url};

  /// 反序列化（缺失 / 类型不符 → null；url 必须非空）。
  static PushPlayEpisode? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? url = raw['url'];
    if (url is! String || url.isEmpty) return null;
    final Object? name = raw['name'];
    return PushPlayEpisode(name: name is String ? name : '', url: url);
  }

  @override
  bool operator ==(Object other) =>
      other is PushPlayEpisode && other.name == name && other.url == url;

  @override
  int get hashCode => Object.hash(name, url);

  @override
  String toString() => 'PushPlayEpisode($name)';
}

/// 推送播放条目（对齐 iOS `PushPlayItem`）。
class PushPlayItem {
  /// 构造。
  const PushPlayItem({
    required this.title,
    required this.url,
    required this.type,
    required this.createdAt,
    this.episodes,
  });

  /// 唯一标识（iOS `id: url`）。
  String get id => url;

  /// 标题（空时由存储层按类型生成默认名）。
  final String title;

  /// 链接地址。
  final String url;

  /// 链接类型。
  final PushPlayLinkType type;

  /// 创建时间（毫秒时间戳，落盘 ISO8601 字符串）。
  final DateTime createdAt;

  /// 解析后的剧集列表（可空）。
  final List<PushPlayEpisode>? episodes;

  /// 序列化（键名对齐 iOS `CodingKeys`；createdAt 落 ISO8601 字符串）。
  Map<String, Object?> toJson() => <String, Object?>{
        'title': title,
        'url': url,
        'type': type.rawValue,
        'createdAt': createdAt.toIso8601String(),
        if (episodes != null)
          'episodes': episodes!.map((PushPlayEpisode e) => e.toJson()).toList(),
      };

  /// 反序列化（缺失 / 类型不符字段回退缺省值；url 缺失 → null）。
  static PushPlayItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? url = raw['url'];
    if (url is! String || url.isEmpty) return null;
    return PushPlayItem(
      title: _asString(raw['title']),
      url: url,
      type: PushPlayLinkType.fromRaw(raw['type'] is String ? raw['type'] as String : null),
      createdAt: _parseDate(raw['createdAt']),
      episodes: _parseEpisodes(raw['episodes']),
    );
  }

  /// 编码整表：条目列表 → JSON 数组字符串。
  static String encodeItems(List<PushPlayItem> items) =>
      jsonEncode(items.map((PushPlayItem e) => e.toJson()).toList());

  /// 解码整表：JSON 数组字符串 → 条目列表（非法输入 / 缺 url 项容忍跳过）。
  static List<PushPlayItem> decodeItems(String? raw) {
    final String text = (raw ?? '').trim();
    if (text.isEmpty) return const <PushPlayItem>[];
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return const <PushPlayItem>[];
    }
    if (decoded is! List) return const <PushPlayItem>[];
    final List<PushPlayItem> out = <PushPlayItem>[];
    for (final Object? entry in decoded) {
      final PushPlayItem? item = PushPlayItem.fromJson(entry);
      if (item != null) out.add(item);
    }
    return out;
  }

  static String _asString(Object? value) => value is String ? value : '';

  /// 剧集解码：容忍 `{"name":..,"url":..}` 与 `"name$url"` 两种形态。
  static List<PushPlayEpisode>? _parseEpisodes(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    final List<PushPlayEpisode> out = <PushPlayEpisode>[];
    for (final Object? entry in raw) {
      final PushPlayEpisode? ep = PushPlayEpisode.fromJson(entry);
      if (ep != null) out.add(ep);
    }
    return out.isEmpty ? null : out;
  }

  /// 创建时间解码：优先 ISO8601 字符串，兼容数字（iOS `JSONEncoder` 默认
  /// `timeIntervalSinceReferenceDate` 秒）与缺失（→ 纪元起点）。
  static DateTime _parseDate(Object? raw) {
    if (raw is num) {
      return DateTime.fromMillisecondsSinceEpoch((raw * 1000).round());
    }
    if (raw is String && raw.isNotEmpty) {
      final DateTime? parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed;
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  @override
  bool operator ==(Object other) =>
      other is PushPlayItem &&
      other.url == url &&
      other.title == title &&
      other.type == type &&
      other.createdAt == createdAt &&
      _episodesEqual(other.episodes, episodes);

  @override
  int get hashCode => Object.hash(url, title, type, createdAt);

  static bool _episodesEqual(
    List<PushPlayEpisode>? a,
    List<PushPlayEpisode>? b,
  ) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() => 'PushPlayItem($title, ${type.rawValue})';
}
