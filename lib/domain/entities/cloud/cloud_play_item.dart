/// 网盘播放统一缓存领域模型（批次 F · F-08）。
///
/// 对齐 iOS（唯一契约来源）：
/// - `CloudDriveManager.CloudPlayItem`（`vbox/Services/CloudDriveManager.swift:221`）
/// - `CloudDriveManager.CloudPlayItemSummary`（同上 `:237`）
/// - 统一缓存键 `cloud_play_item_cache_v1`（同上 `:131`）与
///   `storeUnifiedCloudPlayItem` / `invalidateUnifiedCloudPlayItem` /
///   `clearExpiredUnifiedCloudPlayItems` / `clearUnifiedCloudPlayItems` /
///   `cloudPlayItemSummary`（同上 `:660` ~ `:766`）的纯逻辑。
///
/// 缓存语义（逐档对齐 iOS）：
/// - 键 = `"provider|sourceKey"`；
/// - 上限 **260** 条，超出按 `updatedAt` 倒序保留最新；
/// - 失效 / 过期清理**不删条目**，只清空 `playURL` / `expiresAt` 并在
///   `source` 追加原因后缀（`-invalidated` / `-expired-cleaned`）。
library;

/// 网盘播放缓存条目（对齐 iOS `CloudPlayItem`）。
class CloudPlayItem {
  /// 构造。
  const CloudPlayItem({
    required this.provider,
    required this.sourceKey,
    this.shareURL = '',
    this.resourceId = '',
    this.fileName = '',
    this.ownPath,
    this.playURL,
    this.headers = const <String, String>{},
    this.expiresAt,
    this.compatibilityHint = '',
    this.preferredEngine = '',
    this.preparedAt,
    required this.updatedAt,
    this.source = '',
    this.fallbackURL,
    this.fallbackHeaders = const <String, String>{},
    this.fallbackSource = '',
  });

  /// 网盘类型契约值（[CloudDriveType.id]）。
  final String provider;

  /// 播放源标识（分享 ID / 文件 ID 等，配合 [provider] 构成缓存键）。
  final String sourceKey;

  /// 分享链接。
  final String shareURL;

  /// 资源 ID。
  final String resourceId;

  /// 文件名。
  final String fileName;

  /// 自建目录路径（转存分发场景）。
  final String? ownPath;

  /// 解析出的可播放地址（未就绪 / 已失效为 null）。
  final String? playURL;

  /// 播放请求头。
  final Map<String, String> headers;

  /// 播放地址过期时间（未知为 null）。
  final DateTime? expiresAt;

  /// 兼容性提示（内核选择参考）。
  final String compatibilityHint;

  /// 首选播放内核（对齐 iOS `preferredEngine`）。
  final String preferredEngine;

  /// 准备时间。
  final DateTime? preparedAt;

  /// 最近更新时间。
  final DateTime updatedAt;

  /// 来源标记（清理时追加原因后缀）。
  final String source;

  /// 兜底线路地址（对齐 iOS `PlayResult.fallbackURL`；null 表示无兜底链）。
  final String? fallbackURL;

  /// 兜底线路请求头（对齐 iOS `PlayResult.fallbackHeaders`）。
  final Map<String, String> fallbackHeaders;

  /// 兜底线路来源标记（对齐 iOS `PlayResult.fallbackSource`）。
  final String fallbackSource;

  /// 缓存键（对齐 iOS `cloudPlayItemCacheKey`）。
  String get cacheKey => CloudPlayItemCache.keyOf(provider, sourceKey);

  /// 是否持有可用播放地址。
  bool get hasPlayURL => playURL != null && playURL!.isNotEmpty;

  /// 是否具备可切换的兜底线路。
  bool get hasFallback =>
      fallbackURL != null && fallbackURL!.isNotEmpty;

  /// 在 [now] 时点是否已过期（无过期时间视为未过期）。
  bool isExpiredAt(DateTime now) =>
      expiresAt != null && !expiresAt!.isAfter(now);

  /// 复制并覆盖部分字段。
  CloudPlayItem copyWith({
    String? shareURL,
    String? resourceId,
    String? fileName,
    String? ownPath,
    String? playURL,
    bool clearPlayURL = false,
    Map<String, String>? headers,
    DateTime? expiresAt,
    bool clearExpiresAt = false,
    String? compatibilityHint,
    String? preferredEngine,
    DateTime? preparedAt,
    DateTime? updatedAt,
    String? source,
    String? fallbackURL,
    Map<String, String>? fallbackHeaders,
    String? fallbackSource,
  }) {
    return CloudPlayItem(
      provider: provider,
      sourceKey: sourceKey,
      shareURL: shareURL ?? this.shareURL,
      resourceId: resourceId ?? this.resourceId,
      fileName: fileName ?? this.fileName,
      ownPath: ownPath ?? this.ownPath,
      playURL: clearPlayURL ? null : (playURL ?? this.playURL),
      headers: headers ?? this.headers,
      expiresAt: clearExpiresAt ? null : (expiresAt ?? this.expiresAt),
      compatibilityHint: compatibilityHint ?? this.compatibilityHint,
      preferredEngine: preferredEngine ?? this.preferredEngine,
      preparedAt: preparedAt ?? this.preparedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      source: source ?? this.source,
      // 播放地址被清空（失效 / 过期）→ 兜底线路一并作废。
      fallbackURL: clearPlayURL ? null : (fallbackURL ?? this.fallbackURL),
      fallbackHeaders: clearPlayURL
          ? const <String, String>{}
          : (fallbackHeaders ?? this.fallbackHeaders),
      fallbackSource:
          clearPlayURL ? '' : (fallbackSource ?? this.fallbackSource),
    );
  }

  /// 反序列化（字段缺失回退缺省值，对齐 iOS `Codable` 语义）。
  factory CloudPlayItem.fromJson(Map<String, dynamic> json) {
    return CloudPlayItem(
      provider: (json['provider'] as String?) ?? '',
      sourceKey: (json['sourceKey'] as String?) ?? '',
      shareURL: (json['shareURL'] as String?) ?? '',
      resourceId: (json['resourceId'] as String?) ?? '',
      fileName: (json['fileName'] as String?) ?? '',
      ownPath: json['ownPath'] as String?,
      playURL: json['playURL'] as String?,
      headers: _parseStringMap(json['headers']),
      expiresAt: _parseDate(json['expiresAt']),
      compatibilityHint: (json['compatibilityHint'] as String?) ?? '',
      preferredEngine: (json['preferredEngine'] as String?) ?? '',
      preparedAt: _parseDate(json['preparedAt']),
      updatedAt: _parseDate(json['updatedAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      source: (json['source'] as String?) ?? '',
      fallbackURL: json['fallbackURL'] as String?,
      fallbackHeaders: _parseStringMap(json['fallbackHeaders']),
      fallbackSource: (json['fallbackSource'] as String?) ?? '',
    );
  }

  /// 序列化（日期按 ISO-8601 字符串，与凭据模型一致）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'provider': provider,
        'sourceKey': sourceKey,
        'shareURL': shareURL,
        'resourceId': resourceId,
        'fileName': fileName,
        'ownPath': ownPath,
        'playURL': playURL,
        'headers': headers,
        'expiresAt': expiresAt?.toIso8601String(),
        'compatibilityHint': compatibilityHint,
        'preferredEngine': preferredEngine,
        'preparedAt': preparedAt?.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'source': source,
        'fallbackURL': fallbackURL,
        'fallbackHeaders': fallbackHeaders,
        'fallbackSource': fallbackSource,
      };

  static DateTime? _parseDate(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }

  static Map<String, String> _parseStringMap(Object? value) {
    if (value is! Map) return const <String, String>{};
    return <String, String>{
      for (final MapEntry<Object?, Object?> e in value.entries)
        if (e.key != null && e.value != null)
          e.key.toString(): e.value.toString(),
    };
  }
}

/// 网盘播放缓存汇总（对齐 iOS `CloudPlayItemSummary`）。
class CloudPlayItemSummary {
  /// 构造。
  const CloudPlayItemSummary({
    this.totalCount = 0,
    this.validPlayURLCount = 0,
    this.expiredPlayURLCount = 0,
    this.storageBytes = 0,
    this.lastUpdatedAt,
  });

  /// 条目总数。
  final int totalCount;

  /// 有效播放地址数（未过期且非空）。
  final int validPlayURLCount;

  /// 已过期播放地址数。
  final int expiredPlayURLCount;

  /// 占用字节数。
  final int storageBytes;

  /// 最近更新时间。
  final DateTime? lastUpdatedAt;
}

/// 统一缓存纯逻辑（对齐 iOS `CloudDriveManager` 同名方法）。
abstract final class CloudPlayItemCache {
  /// 缓存条目上限（对齐 iOS「保留最新 260 条」）。
  static const int maxItems = 260;

  /// 缓存键（对齐 iOS `cloudPlayItemCacheKey`）：`"provider|sourceKey"`。
  static String keyOf(String provider, String sourceKey) =>
      '$provider|$sourceKey';

  /// 写入（upsert + 上限裁剪），返回新缓存。
  static Map<String, CloudPlayItem> store(
    Map<String, CloudPlayItem> cache,
    CloudPlayItem item,
  ) {
    final Map<String, CloudPlayItem> next = Map<String, CloudPlayItem>.of(cache);
    next[item.cacheKey] = item;
    if (next.length <= maxItems) return next;
    final List<String> keys = next.keys.toList();
    keys.sort((String a, String b) {
      final int byTime = next[b]!.updatedAt.compareTo(next[a]!.updatedAt);
      if (byTime != 0) return byTime;
      // 同刻并发：保留较晚写入者（对齐 iOS Dictionary 重建的「取最新」语义）。
      return keys.indexOf(b).compareTo(keys.indexOf(a));
    });
    final Set<String> kept = keys.take(maxItems).toSet();
    return <String, CloudPlayItem>{
      for (final MapEntry<String, CloudPlayItem> e in next.entries)
        if (kept.contains(e.key)) e.key: e.value,
    };
  }

  /// 失效标记：清空 `playURL` / `expiresAt`，`source` 追加 `-reason`。
  ///
  /// 键不存在时原样返回（对齐 iOS `guard let item = cache[key] else { return }`）。
  static Map<String, CloudPlayItem> invalidate(
    Map<String, CloudPlayItem> cache, {
    required String provider,
    required String sourceKey,
    required String reason,
    required DateTime now,
  }) {
    final String key = keyOf(provider, sourceKey);
    final CloudPlayItem? item = cache[key];
    if (item == null) return cache;
    final Map<String, CloudPlayItem> next = Map<String, CloudPlayItem>.of(cache);
    next[key] = item.copyWith(
      clearPlayURL: true,
      clearExpiresAt: true,
      updatedAt: now,
      source: '${item.source}-$reason',
    );
    return next;
  }

  /// 过期清理（仅目标 provider；清空 `playURL` / `expiresAt`，后缀 `-expired-cleaned`）。
  ///
  /// 无变化时原引用返回（对齐 iOS `changed` 短路，避免无谓落盘）。
  static Map<String, CloudPlayItem> clearExpired(
    Map<String, CloudPlayItem> cache, {
    required String provider,
    required DateTime now,
  }) {
    Map<String, CloudPlayItem>? next;
    for (final MapEntry<String, CloudPlayItem> e in cache.entries) {
      final CloudPlayItem item = e.value;
      if (item.provider != provider) continue;
      if (item.expiresAt == null || item.expiresAt!.isAfter(now)) continue;
      if (!item.hasPlayURL) continue;
      next ??= Map<String, CloudPlayItem>.of(cache);
      next[e.key] = item.copyWith(
        clearPlayURL: true,
        clearExpiresAt: true,
        updatedAt: now,
        source: '${item.source}-expired-cleaned',
      );
    }
    return next ?? cache;
  }

  /// 按 provider 清空（对齐 iOS `clearUnifiedCloudPlayItems`）。
  static Map<String, CloudPlayItem> clear(
    Map<String, CloudPlayItem> cache, {
    required String provider,
  }) =>
      <String, CloudPlayItem>{
        for (final MapEntry<String, CloudPlayItem> e in cache.entries)
          if (e.value.provider != provider) e.key: e.value,
      };

  /// 汇总（对齐 iOS `cloudPlayItemSummary`）。
  static CloudPlayItemSummary summary(
    Iterable<CloudPlayItem> items, {
    required String provider,
    required DateTime now,
    int storageBytes = 0,
  }) {
    final List<CloudPlayItem> own = items
        .where((CloudPlayItem e) => e.provider == provider)
        .toList(growable: false);
    int valid = 0;
    int expired = 0;
    DateTime? last;
    for (final CloudPlayItem item in own) {
      if (item.hasPlayURL) {
        if (item.expiresAt == null || item.expiresAt!.isAfter(now)) {
          valid++;
        } else {
          expired++;
        }
      }
      final DateTime u = item.updatedAt;
      if (last == null || u.isAfter(last)) last = u;
    }
    return CloudPlayItemSummary(
      totalCount: own.length,
      validPlayURLCount: valid,
      expiredPlayURLCount: expired,
      storageBytes: storageBytes,
      lastUpdatedAt: last,
    );
  }
}
