/// 领域层：源治理实体（切片源 / 自定义解析器）。
///
/// 唯一真相源：iOS `SpiderManager` 的 `customFallbackSites: [(name, api)]`
/// 与 `customParsers: [ParseConfig]`（`vbox/Services/SpiderManager.swift` L45-L49、
/// L150 `ParseConfig`）。
///
/// 持久化口径（复用既有契约键，不新增契约）：
/// - 自定义切片源 → `custom_fallback_sites`（JSON 数组字符串）；
/// - 自定义解析器 → `user_parsers`（JSON 数组字符串）。
library;

/// 自定义切片源（兜底采集 API 站）。
///
/// 对齐 iOS `SpiderManager.customFallbackSites` 的 `(name, api)` 元组。
class FallbackSite {
  /// 构造。
  const FallbackSite({required this.name, required this.api});

  /// 源名称（展示用）。
  final String name;

  /// API 地址（CMS V10 `?ac=videolist` 接口基址）。
  final String api;

  /// 是否有效（名称与地址均非空）。
  bool get isValid => name.trim().isNotEmpty && api.trim().isNotEmpty;

  /// 反序列化（容忍缺字段的脏数据）。
  factory FallbackSite.fromJson(Map<String, Object?> j) => FallbackSite(
        name: (j['name'] ?? '').toString(),
        api: (j['api'] ?? '').toString(),
      );

  /// 序列化（与 iOS `saveCustomFallbackSites` 的 `["name":…, "api":…]` 对齐）。
  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'api': api,
      };

  @override
  bool operator ==(Object other) =>
      other is FallbackSite && other.name == name && other.api == api;

  @override
  int get hashCode => Object.hash(name, api);
}

/// 自定义解析器（对齐 iOS `ParseConfig`，本端只用 name/url 两字段）。
class ParserEntry {
  /// 构造。
  const ParserEntry({required this.name, required this.url});

  /// 解析器名称（展示用）。
  final String name;

  /// 解析器地址（形如 `https://jx.xxx.com/player/?url=`，后接待解析地址）。
  final String url;

  /// 是否有效（名称与地址均非空）。
  bool get isValid => name.trim().isNotEmpty && url.trim().isNotEmpty;

  /// 反序列化（兼容 iOS `ParseConfig` 的 `name` / `url` 键）。
  factory ParserEntry.fromJson(Map<String, Object?> j) => ParserEntry(
        name: (j['name'] ?? '').toString(),
        url: (j['url'] ?? '').toString(),
      );

  /// 序列化。
  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'url': url,
      };

  @override
  bool operator ==(Object other) =>
      other is ParserEntry && other.name == name && other.url == url;

  @override
  int get hashCode => Object.hash(name, url);
}
