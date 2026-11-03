/// 领域层：远程源 manifest 模型。
///
/// 唯一真相源：`contract/schema/manifest_v1.json`
/// 逆向来源：iOS `vbox/Services/RemoteSourceConfigManager.swift`
library;

import 'cloud_site.dart';

/// 远程源 manifest（对齐契约 manifest_v1.json）。
class RemoteManifest {
  const RemoteManifest({
    this.schemaVersion = 1,
    required this.configVersion,
    this.minAppVersion,
    this.updatedAt,
    this.ttlSeconds = defaultTtlSeconds,
    this.forceRefresh = true,
    this.disabledKeys = const <String>[],
    required this.files,
    this.meta,
  });

  /// 缓存有效期默认值（契约实测 21600 = 6 小时）。
  static const int defaultTtlSeconds = 21600;

  /// manifest 结构版本，契约固定为 1。
  final int schemaVersion;

  /// 配置版本号，格式 `YYYY.MM.DD.N`。
  final String configVersion;

  /// 客户端最低版本要求（兼容门控）。
  final String? minAppVersion;

  /// 更新时间（ISO 8601 UTC）。
  final String? updatedAt;

  /// 缓存有效期（秒）。
  final int ttlSeconds;

  /// 是否强制全量刷新。
  final bool forceRefresh;

  /// 全局禁用的源 key 列表。
  final List<String> disabledKeys;

  /// 各配置文件地址（10 个键，实测）。
  final Map<String, String> files;

  /// 自描述元信息（`_meta`）。
  final Map<String, Object?>? meta;

  /// 契约要求的 `configVersion` 格式：`YYYY.MM.DD.N`。
  static final RegExp configVersionPattern =
      RegExp(r'^\d{4}\.\d{2}\.\d{2}\.\d+$');

  /// configVersion 是否符合契约格式。
  bool get hasValidConfigVersion =>
      configVersionPattern.hasMatch(configVersion);

  /// 必需文件键（契约 `files.required`）。
  static const String keyAllSources = 'allSources';

  /// Node bundle 远端地址键（契约 `files.nodeRuntimeBundle`；ND-02）。
  static const String keyNodeRuntimeBundle = 'nodeRuntimeBundle';

  /// Node bundle 版本键（契约 `files.nodeRuntimeBundleVer`；版本探针用，ND-02）。
  static const String keyNodeRuntimeBundleVer = 'nodeRuntimeBundleVer';

  /// 已知文件键（契约，10 个）。
  static const List<String> knownFileKeys = <String>[
    'allSources',
    'apiSources',
    'cloudSources',
    'spiderSources',
    'domainOverrides',
    'parsers',
    'disabledSources',
    'welfarePlatforms',
    'nodeRuntimeBundle',
    'nodeRuntimeBundleVer',
  ];

  /// 是否包含必需键 allSources。
  bool get hasRequiredFiles => files.containsKey(keyAllSources);

  factory RemoteManifest.fromJson(Map<String, Object?> j) => RemoteManifest(
        schemaVersion: (j['schemaVersion'] as num?)?.toInt() ?? 1,
        configVersion: (j['configVersion'] ?? '').toString(),
        minAppVersion: j['minAppVersion']?.toString(),
        updatedAt: j['updatedAt']?.toString(),
        ttlSeconds:
            (j['ttlSeconds'] as num?)?.toInt() ?? defaultTtlSeconds,
        forceRefresh: j['forceRefresh'] as bool? ?? true,
        disabledKeys: (j['disabledKeys'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[],
        files: (j['files'] as Map?)?.map(
                (k, v) => MapEntry(k.toString(), v.toString())) ??
            const <String, String>{},
        meta: (j['_meta'] as Map?)?.cast<String, Object?>(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        if (meta != null) '_meta': meta,
        'schemaVersion': schemaVersion,
        'configVersion': configVersion,
        if (minAppVersion != null) 'minAppVersion': minAppVersion,
        if (updatedAt != null) 'updatedAt': updatedAt,
        'ttlSeconds': ttlSeconds,
        'forceRefresh': forceRefresh,
        'disabledKeys': disabledKeys,
        'files': files,
      };
}

/// all_sources.json 聚合容器（契约 `$defs.allSources`，实测 7 键）。
class AllSourcesContainer {
  const AllSourcesContainer({
    this.apiSources,
    this.cloudSources,
    this.spiderSources,
    this.domainOverrides,
    this.parsers,
    this.disabledSources,
    this.welfarePlatforms,
  });

  final Map<String, Object?>? apiSources;
  final Map<String, Object?>? cloudSources;
  final Map<String, Object?>? spiderSources;
  final Map<String, Object?>? domainOverrides;

  /// 解析器段：契约 `$defs.allSources.parsers` 为**对象** `{ "parses": [...] }`
  /// （非数组；对齐 iOS `cachedParsers()` 的 `ParserWrapper`）。
  final Map<String, Object?>? parsers;

  /// 全局禁用段：契约 `$defs.allSources.disabledSources` 为**对象**
  /// `{ "disabledKeys": [...], "disabledHosts": [...] }`（非数组；对齐 iOS
  /// `cachedDisabledKeys()` / `cachedDisabledHosts()` 的 `DisabledSourcesWrapper`）。
  final Map<String, Object?>? disabledSources;

  final Map<String, Object?>? welfarePlatforms;

  factory AllSourcesContainer.fromJson(Map<String, Object?> j) =>
      AllSourcesContainer(
        apiSources: _asSection(j['apiSources']),
        cloudSources: _asSection(j['cloudSources']),
        spiderSources: _asSection(j['spiderSources']),
        domainOverrides: _asSection(j['domainOverrides']),
        parsers: _asSection(j['parsers']),
        disabledSources: _asSection(j['disabledSources']),
        welfarePlatforms: _asSection(j['welfarePlatforms']),
      );

  /// 远程默认解析器条目（`parsers.parses`，对齐 iOS `cachedParsers()`）。
  List<Object?> get parses => _asList(parsers?['parses']);

  /// 全局禁用 key（`disabledSources.disabledKeys`）。
  List<String> get disabledSourceKeys =>
      _asStringList(disabledSources?['disabledKeys']);

  /// 全局禁用 host（`disabledSources.disabledHosts`）。
  List<String> get disabledSourceHosts =>
      _asStringList(disabledSources?['disabledHosts']);

  /// 宽容取「对象段」：非对象（含误传数组 / null）一律返回 null，绝不抛异常。
  static Map<String, Object?>? _asSection(Object? v) =>
      v is Map ? v.map((Object? k, Object? val) => MapEntry('$k', val)) : null;

  static List<Object?> _asList(Object? v) =>
      v is List ? List<Object?>.from(v) : const <Object?>[];

  static List<String> _asStringList(Object? v) => v is List
      ? v.map((Object? e) => e.toString()).toList(growable: false)
      : const <String>[];

  /// 聚合出的站点列表（apiSources.sites + spiderSources.sites）。
  List<Map<String, Object?>> get sites {
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    void collect(Map<String, Object?>? src) {
      final Object? arr = src?['sites'];
      if (arr is List) {
        for (final Object? e in arr) {
          if (e is Map) out.add(e.cast<String, Object?>());
        }
      }
    }

    collect(apiSources);
    collect(spiderSources);
    return out;
  }

  /// 蜘蛛源站点原始 JSON（`spiderSources.sites`）。
  ///
  /// 对齐 iOS `cachedSpiderSites()` 的取值口径（`allSources.spiderSources?.sites`）：
  /// 只含 spider 段站点，供远程同步批量下载 JS/Python 脚本到本地缓存
  /// （iOS `downloadAndCacheSpiderJS`）——api 段站点的 `api` 是 CMS 端点，
  /// 不能被当作脚本下载。
  List<Map<String, Object?>> get spiderSites {
    final Object? arr = spiderSources?['sites'];
    if (arr is! List) return const <Map<String, Object?>>[];
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    for (final Object? e in arr) {
      if (e is Map) out.add(e.cast<String, Object?>());
    }
    return out;
  }

  /// 网盘站点列表（`cloudSources.cloudSites`）。
  ///
  /// 对齐 iOS `SpiderManager.loadCloudSitesFromJSONConfig()`：网盘源是与
  /// api/spider **同级**的独立源类别，参与「切换源」列表与搜索，但不并入
  /// [sites]（[sites] 语义对齐 iOS `allSites`，只含视频站点键）。
  List<CloudSiteConfig> get cloudSites {
    final Object? arr = cloudSources?['cloudSites'];
    if (arr is! List) return const <CloudSiteConfig>[];
    final List<CloudSiteConfig> out = <CloudSiteConfig>[];
    for (final Object? e in arr) {
      if (e is Map) {
        final CloudSiteConfig site =
            CloudSiteConfig.fromJson(e.cast<String, Object?>());
        if (site.name.isNotEmpty && site.searchurl.isNotEmpty) {
          out.add(site);
        }
      }
    }
    return List<CloudSiteConfig>.unmodifiable(out);
  }
}
