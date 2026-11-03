/// 领域层：直播源类型。
///
/// 对齐 iOS `LiveTVService.swift` 的 `LiveSourceType`（Codable 字典格式
/// `{type, name, url}`），四种：
/// - defaultM3U    默认源1（秒播 M3U，远程实时拉取）
/// - defaultIPTV2  默认源2（运营商 IPTV）
/// - subscribe     订阅配置中的源
/// - custom        用户自定义源（含本地导入 `local://`）
library;

/// 直播源种类（含遗留 `yangshipin` 兼容）。
enum LiveSourceKind {
  defaultM3U,
  yangshipin,
  defaultIPTV2,
  subscribe,
  custom;

  static LiveSourceKind fromId(String s) {
    switch (s) {
      case 'defaultM3U':
      case 'yangshipin':
        return LiveSourceKind.defaultM3U;
      case 'defaultIPTV2':
        return LiveSourceKind.defaultIPTV2;
      case 'subscribe':
        return LiveSourceKind.subscribe;
      case 'custom':
        return LiveSourceKind.custom;
      default:
        throw ArgumentError('未知直播源类型: $s');
    }
  }

  String get id {
    switch (this) {
      case LiveSourceKind.defaultM3U:
      case LiveSourceKind.yangshipin:
        return 'defaultM3U';
      case LiveSourceKind.defaultIPTV2:
        return 'defaultIPTV2';
      case LiveSourceKind.subscribe:
        return 'subscribe';
      case LiveSourceKind.custom:
        return 'custom';
    }
  }
}

/// 直播源（不可变值对象）。
class LiveSourceType {
  const LiveSourceType({
    required this.kind,
    this.name,
    this.url,
  });

  /// 默认源1（秒播）。
  static const LiveSourceType defaultM3U =
      LiveSourceType(kind: LiveSourceKind.defaultM3U);

  /// 默认源2（运营商 IPTV）。
  static const LiveSourceType defaultIptv2 =
      LiveSourceType(kind: LiveSourceKind.defaultIPTV2);

  /// 源种类。
  final LiveSourceKind kind;

  /// 源名称（subscribe / custom 才有）。
  final String? name;

  /// 源地址（subscribe / custom / local 才有）。
  final String? url;

  /// 稳定标识（对齐 iOS `LiveSourceType.id`）。
  String get id {
    switch (kind) {
      case LiveSourceKind.defaultM3U:
      case LiveSourceKind.yangshipin:
        return 'default_m3u';
      case LiveSourceKind.defaultIPTV2:
        return 'default_iptv_2';
      case LiveSourceKind.subscribe:
        return 'subscribe_${name ?? ''}_${url ?? ''}';
      case LiveSourceKind.custom:
        return 'custom_${name ?? ''}_${url ?? ''}';
    }
  }

  /// 展示名。
  String get displayName {
    switch (kind) {
      case LiveSourceKind.defaultM3U:
      case LiveSourceKind.yangshipin:
        return '默认源1 (秒播)';
      case LiveSourceKind.defaultIPTV2:
        return '默认源2 (运营商IPTV)';
      case LiveSourceKind.subscribe:
      case LiveSourceKind.custom:
        return name ?? '';
    }
  }

  /// 实际拉取地址（defaultM3U / defaultIPTV2 为内置，其余透传）。
  String? get sourceURL {
    switch (kind) {
      case LiveSourceKind.defaultM3U:
      case LiveSourceKind.yangshipin:
        return 'https://gh-proxy.com/raw.githubusercontent.com/vbskycn/iptv/refs/heads/master/tv/iptv4.m3u';
      case LiveSourceKind.defaultIPTV2:
        return 'http://mg.earxo.com/itv_ANGEHPV3YLVD/m3u';
      case LiveSourceKind.subscribe:
      case LiveSourceKind.custom:
        return url;
    }
  }

  /// 是否内置默认源。
  bool get isDefault =>
      kind == LiveSourceKind.defaultM3U ||
      kind == LiveSourceKind.yangshipin ||
      kind == LiveSourceKind.defaultIPTV2;

  /// 是否用户自定义源（含本地导入）。
  bool get isCustom => kind == LiveSourceKind.custom;

  /// 序列化为字典（对齐 iOS `toDictionary()`）。
  Map<String, String> toDictionary() {
    switch (kind) {
      case LiveSourceKind.defaultM3U:
      case LiveSourceKind.yangshipin:
        return const <String, String>{'type': 'defaultM3U'};
      case LiveSourceKind.defaultIPTV2:
        return const <String, String>{'type': 'defaultIPTV2'};
      case LiveSourceKind.subscribe:
        return <String, String>{
          'type': 'subscribe',
          'name': name ?? '',
          'url': url ?? '',
        };
      case LiveSourceKind.custom:
        return <String, String>{
          'type': 'custom',
          'name': name ?? '',
          'url': url ?? '',
        };
    }
  }

  /// 从字典反序列化（对齐 iOS `init?(dictionary:)`；未知/缺字段返回 null）。
  static LiveSourceType? fromDictionary(Map<String, String> d) {
    final String? type = d['type'];
    if (type == null) return null;
    switch (type) {
      case 'defaultM3U':
      case 'yangshipin':
        return LiveSourceType.defaultM3U;
      case 'defaultIPTV2':
        return LiveSourceType.defaultIptv2;
      case 'subscribe':
        final String? name = d['name'];
        final String? url = d['url'];
        if (name == null || url == null) return null;
        return LiveSourceType(
          kind: LiveSourceKind.subscribe,
          name: name,
          url: url,
        );
      case 'custom':
        final String? name = d['name'];
        final String? url = d['url'];
        if (name == null || url == null) return null;
        return LiveSourceType(
          kind: LiveSourceKind.custom,
          name: name,
          url: url,
        );
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LiveSourceType && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'LiveSourceType($id)';
}