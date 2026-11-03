/// 领域层：TVBox 订阅配置（批次 G · G-07）。
///
/// 唯一真相源：iOS `vbox/Services/SubscriptionManager.swift`
///   · `SubscribeConfig`（Codable）字段：sites / spider / wallpaper / lives /
///     flags / banned / parses；
///   · `loadConfig(from:)`（L61-L281）的站点合成规则：
///     ① 标准 `sites` 数组 → `SiteConfig`（type 原样）；
///     ② `apiyuan` 数组 → `SiteConfig(type: 1)`（key `api_N`，`api` 为 searchurl，
///        缺尾分隔符时补 `&`，对齐 L194-L196）；
///     ③ `zhanyuan` 数组 → `SiteConfig(type: 2)`（key `zhan_N`，`api` 为 searchUrl，
///        `ext` 为整条原始 JSON 字符串，对齐 L210-L217）；
///     ④ 三者按 `name` 去重（先到先得，对齐 `!sites.contains(where:)`）；
///     ⑤ `parses` 数组 → `ParseConfig`。
///
/// 差异登记：iOS `lives` / `flags` / `banned` 为强类型 Codable；Flutter 以原始
/// JSON 值透传（仅用于缓存往返，不参与业务判定）。
library;

import 'dart:convert';

import '../spider/site_config.dart';

/// 解析器配置（对齐 iOS `ParseConfig`）。
class ParseConfig {
  /// 构造。
  const ParseConfig({required this.name, required this.url, this.type});

  /// 名称。
  final String name;

  /// 解析接口地址。
  final String url;

  /// 类型（iOS 为可选 Int）。
  final int? type;

  /// 源 JSON → 实体（字段缺失返回 null，对齐 iOS `if let name/url`）。
  static ParseConfig? fromRaw(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, Object?> item = raw.cast<String, Object?>();
    final String name = (item['name'] ?? '').toString();
    final String url = (item['url'] ?? '').toString();
    if (name.isEmpty || url.isEmpty) return null;
    final Object? type = item['type'];
    return ParseConfig(
      name: name,
      url: url,
      type: type is int ? type : (type == null ? null : int.tryParse('$type')),
    );
  }

  /// 缓存 JSON → 实体。
  factory ParseConfig.fromJson(Map<String, Object?> j) => ParseConfig(
        name: (j['name'] ?? '').toString(),
        url: (j['url'] ?? '').toString(),
        type: j['type'] is int ? j['type'] as int : null,
      );

  /// 实体 → 缓存 JSON。
  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'url': url,
        if (type != null) 'type': type,
      };
}

/// 订阅配置（对齐 iOS `SubscribeConfig`）。
class SubscribeConfig {
  /// 构造。
  const SubscribeConfig({
    this.sites = const <SiteConfig>[],
    this.spider,
    this.wallpaper,
    this.lives,
    this.flags,
    this.banned,
    this.parses = const <ParseConfig>[],
  });

  /// 站点列表（标准 sites + apiyuan + zhanyuan 合成后，已去重）。
  final List<SiteConfig> sites;

  /// 全局 spider jar 地址。
  final String? spider;

  /// 壁纸地址。
  final String? wallpaper;

  /// 直播源（原始 JSON 透传）。
  final Object? lives;

  /// flags（原始 JSON 透传）。
  final Object? flags;

  /// 禁用规则（原始 JSON 透传）。
  final Object? banned;

  /// 解析器列表。
  final List<ParseConfig> parses;

  /// 由订阅源原始 JSON 合成配置（对齐 iOS `loadConfig` 的站点转换链）。
  ///
  /// 返回 null 语义：`sites` 为空由调用方判失败（对齐 iOS「未包含任何可用站点」）。
  factory SubscribeConfig.buildFromSource(Map<String, Object?> json) {
    final List<SiteConfig> sites = <SiteConfig>[];

    // ① 标准 sites 数组。
    final Object? rawSites = json['sites'];
    if (rawSites is List) {
      for (final Object? e in rawSites) {
        if (e is Map) {
          sites.add(SiteConfig.fromJson(e.cast<String, Object?>()));
        }
      }
    }

    // ② apiyuan → type=1（API 源）。
    final Object? apiyuan = json['apiyuan'];
    if (apiyuan is List) {
      for (final Object? e in apiyuan) {
        if (e is! Map) continue;
        final Map<String, Object?> item = e.cast<String, Object?>();
        final String name = (item['name'] ?? '').toString();
        final String searchUrl = (item['searchurl'] ?? '').toString();
        if (name.isEmpty || searchUrl.isEmpty) continue;
        if (_hasName(sites, name)) continue;
        sites.add(
          SiteConfig(
            key: 'api_${sites.length + 1}',
            name: name,
            type: 1,
            api: _normalizeApiSearchUrl(searchUrl),
          ),
        );
      }
    }

    // ③ zhanyuan → type=2（自建源，ext 存整条原始 JSON）。
    final Object? zhanyuan = json['zhanyuan'];
    if (zhanyuan is List) {
      for (final Object? e in zhanyuan) {
        if (e is! Map) continue;
        final Map<String, Object?> item = e.cast<String, Object?>();
        final String name = (item['name'] ?? '').toString();
        final String searchUrl = (item['searchUrl'] ?? '').toString();
        if (name.isEmpty || searchUrl.isEmpty) continue;
        if (_hasName(sites, name)) continue;
        sites.add(
          SiteConfig(
            key: 'zhan_${sites.length + 1}',
            name: name,
            type: 2,
            api: searchUrl,
            ext: jsonEncode(item),
          ),
        );
      }
    }

    // ⑤ parses 数组。
    final List<ParseConfig> parses = <ParseConfig>[];
    final Object? rawParses = json['parses'];
    if (rawParses is List) {
      for (final Object? e in rawParses) {
        final ParseConfig? p = ParseConfig.fromRaw(e);
        if (p != null) parses.add(p);
      }
    }

    return SubscribeConfig(
      sites: sites,
      spider: json['spider']?.toString(),
      wallpaper: json['wallpaper']?.toString(),
      lives: json['lives'],
      flags: json['flags'],
      banned: json['banned'],
      parses: parses,
    );
  }

  /// 缓存 JSON → 实体（对齐 iOS `loadCachedConfig` 的 `JSONDecoder`）。
  factory SubscribeConfig.fromJson(Map<String, Object?> j) {
    final List<SiteConfig> sites = <SiteConfig>[];
    final Object? rawSites = j['sites'];
    if (rawSites is List) {
      for (final Object? e in rawSites) {
        if (e is Map) sites.add(SiteConfig.fromJson(e.cast<String, Object?>()));
      }
    }
    final List<ParseConfig> parses = <ParseConfig>[];
    final Object? rawParses = j['parses'];
    if (rawParses is List) {
      for (final Object? e in rawParses) {
        if (e is Map) parses.add(ParseConfig.fromJson(e.cast<String, Object?>()));
      }
    }
    return SubscribeConfig(
      sites: sites,
      spider: j['spider']?.toString(),
      wallpaper: j['wallpaper']?.toString(),
      lives: j['lives'],
      flags: j['flags'],
      banned: j['banned'],
      parses: parses,
    );
  }

  /// 实体 → 缓存 JSON（对齐 iOS `JSONEncoder().encode(finalConfig)`）。
  Map<String, Object?> toJson() => <String, Object?>{
        'sites': sites.map((SiteConfig s) => s.toJson()).toList(),
        if (spider != null) 'spider': spider,
        if (wallpaper != null) 'wallpaper': wallpaper,
        if (lives != null) 'lives': lives,
        if (flags != null) 'flags': flags,
        if (banned != null) 'banned': banned,
        'parses': parses.map((ParseConfig p) => p.toJson()).toList(),
      };

  /// 是否包含任何站点（UI 成功判定，对齐 iOS `!allSites.isEmpty`）。
  bool get hasSites => sites.isNotEmpty;

  static bool _hasName(List<SiteConfig> sites, String name) =>
      sites.any((SiteConfig s) => s.name == name);

  /// apiyuan 的 searchurl 补尾分隔符（对齐 iOS L194-L196）。
  static String _normalizeApiSearchUrl(String raw) {
    if (raw.endsWith('=') || raw.endsWith('&') || raw.endsWith('?')) return raw;
    return '$raw&';
  }
}