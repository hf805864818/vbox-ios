/// 领域层：直播频道模型。
///
/// 对齐 iOS `LiveTVService.swift` 的 `SubscribeChannel` / `LiveChannel` /
/// `LiveCategory`。M3U/TXT 源解析产出 [SubscribeChannel]，按分组聚合为
/// [LiveCategory]，同组同名频道合并多线路得到 [LiveChannel]。
library;

/// 订阅源解析出的原始频道（含分组 / 台标原始信息）。
class SubscribeChannel {
  const SubscribeChannel({
    required this.name,
    required this.url,
    this.group,
    this.logo,
  });

  /// 频道名。
  final String name;

  /// 播放地址。
  final String url;

  /// 分组名（如「央视」「卫视」）。
  final String? group;

  /// 台标 URL。
  final String? logo;

  /// 稳定标识（name + url，列表渲染用）。
  String get id => '$name|$url';

  @override
  bool operator ==(Object other) => other is SubscribeChannel && other.id == id;

  @override
  int get hashCode => id.hashCode;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'url': url,
        'group': group,
        'logo': logo,
      };

  factory SubscribeChannel.fromJson(Map<String, Object?> j) => SubscribeChannel(
        name: (j['name'] ?? '').toString(),
        url: (j['url'] ?? '').toString(),
        group: j['group']?.toString(),
        logo: j['logo']?.toString(),
      );
}

/// 可播放直播频道（同组同名已合并多线路）。
class LiveChannel {
  const LiveChannel({
    required this.id,
    required this.name,
    required this.tid,
    required this.channelId,
    required this.token,
    this.logo,
    this.sources = const <String>[],
  });

  /// 稳定标识（`sub_<name>_<firstUrl>`）。
  final String id;

  /// 频道名。
  final String name;

  /// 所属分组（分类 tid）。
  final String tid;

  /// 频道标识（对齐 iOS 用首个 URL 充当）。
  final String channelId;

  /// 令牌（订阅源场景一般为空）。
  final String token;

  /// 台标 URL。
  final String? logo;

  /// 多线路播放地址（解析后填充）。
  final List<String> sources;

  /// 播放地址：优先返回首个线路。
  String get playURL => sources.isNotEmpty ? sources.first : '';

  /// 线路数量。
  int get routeCount => sources.isEmpty ? 1 : sources.length;

  /// 取指定线路播放地址（缺省回退首线路，无线路返回 null）。
  String? routeURL(int index) {
    if (sources.isEmpty) return null;
    final int idx = index.clamp(0, sources.length - 1);
    return sources[idx];
  }
}

/// 直播分类（从 group-title 动态生成）。
class LiveCategory {
  const LiveCategory({
    required this.id,
    required this.name,
    required this.tid,
    this.icon = 'tv',
    this.logo,
  });

  /// 分类 id（`cat_<index>`，供取色）。
  final String id;

  /// 分类名。
  final String name;

  /// 分类标识（= group-title）。
  final String tid;

  /// 图标名。
  final String icon;

  /// 分类台标（取组内首个有台标的频道）。
  final String? logo;

  /// 调色板索引（对齐 iOS `LiveCategory.tintColor` 按 `cat_N` 取模）。
  int get paletteIndex {
    final String tail = id.split('_').last;
    final int? idx = int.tryParse(tail);
    return (idx == null || idx < 0) ? 0 : idx;
  }
}