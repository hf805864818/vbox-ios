/// 数据层：网盘播放统一缓存持久化（批次 F · F-08）。
///
/// 对齐 iOS `CloudDriveManager`：
/// - 存储键 **`cloud_play_item_cache_v1`**（契约 `storage: userdefaults`，
///   类型 string）；
/// - `loadUnifiedCloudPlayItemCache` / `saveUnifiedCloudPlayItemCache` /
///   `storeUnifiedCloudPlayItem` / `invalidateUnifiedCloudPlayItem` /
///   `clearExpiredUnifiedCloudPlayItems` / `clearUnifiedCloudPlayItems` /
///   `cloudPlayItemSummary` 语义由 [CloudPlayItemCache] 纯逻辑承载。
///
/// iOS 侧以 `JSONEncoder([String: CloudPlayItem])` 落 UserDefaults（Data）；
/// Flutter 端按契约类型 `string` 存 JSON 对象字符串。
library;

import 'dart:convert';

import '../../../domain/entities/cloud/cloud_play_item.dart';
import 'prefs_manager.dart';

/// 网盘播放统一缓存存储。
class CloudPlayItemCacheStore {
  /// 构造（注入契约偏好管理器）。
  CloudPlayItemCacheStore(this._prefs);

  final PrefsManager _prefs;

  /// 契约存储键（`prefs_keys_v1.json` → `_group_cloud`）。
  static const String storageKey = 'cloud_play_item_cache_v1';

  /// 读取全部缓存（非法 JSON / 非对象 / 缺键容忍为空）。
  Future<Map<String, CloudPlayItem>> load() async {
    final String raw = await _prefs.getString(storageKey);
    if (raw.isEmpty) return <String, CloudPlayItem>{};
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return <String, CloudPlayItem>{};
    }
    if (decoded is! Map) return <String, CloudPlayItem>{};
    final Map<String, CloudPlayItem> out = <String, CloudPlayItem>{};
    for (final MapEntry<Object?, Object?> e in decoded.entries) {
      if (e.value is! Map) continue;
      final CloudPlayItem item = CloudPlayItem.fromJson(<String, dynamic>{
        for (final MapEntry<Object?, Object?> f
            in (e.value as Map).entries)
          f.key.toString(): f.value,
      });
      if (item.provider.isEmpty && item.sourceKey.isEmpty) continue;
      out[e.key.toString()] = item;
    }
    return out;
  }

  /// 全量写入（覆盖）。
  Future<void> save(Map<String, CloudPlayItem> cache) async {
    await _prefs.set(
      storageKey,
      jsonEncode(<String, dynamic>{
        for (final MapEntry<String, CloudPlayItem> e in cache.entries)
          e.key: e.value.toJson(),
      }),
    );
  }

  /// 当前原始字符串字节数（对齐 iOS `storageBytes`）。
  Future<int> storageBytes() async {
    final String raw = await _prefs.getString(storageKey);
    return utf8.encode(raw).length;
  }

  /// 写入一条（upsert + 上限裁剪），返回写入后的缓存。
  Future<Map<String, CloudPlayItem>> store(CloudPlayItem item) async {
    final Map<String, CloudPlayItem> next =
        CloudPlayItemCache.store(await load(), item);
    await save(next);
    return next;
  }

  /// 失效标记（键不存在时为空操作，不落盘）。
  Future<Map<String, CloudPlayItem>> invalidate({
    required String provider,
    required String sourceKey,
    required String reason,
    DateTime? now,
  }) async {
    final Map<String, CloudPlayItem> current = await load();
    final Map<String, CloudPlayItem> next = CloudPlayItemCache.invalidate(
      current,
      provider: provider,
      sourceKey: sourceKey,
      reason: reason,
      now: now ?? DateTime.now(),
    );
    if (!identical(next, current)) await save(next);
    return next;
  }

  /// 过期清理（仅目标 provider；无变化不落盘）。
  Future<Map<String, CloudPlayItem>> clearExpired(
    String provider, {
    DateTime? now,
  }) async {
    final Map<String, CloudPlayItem> current = await load();
    final Map<String, CloudPlayItem> next = CloudPlayItemCache.clearExpired(
      current,
      provider: provider,
      now: now ?? DateTime.now(),
    );
    if (!identical(next, current)) await save(next);
    return next;
  }

  /// 按 provider 清空。
  Future<Map<String, CloudPlayItem>> clear(String provider) async {
    final Map<String, CloudPlayItem> next =
        CloudPlayItemCache.clear(await load(), provider: provider);
    await save(next);
    return next;
  }

  /// 汇总（对齐 iOS `cloudPlayItemSummary`）。
  Future<CloudPlayItemSummary> summary(
    String provider, {
    DateTime? now,
  }) async {
    final Map<String, CloudPlayItem> cache = await load();
    return CloudPlayItemCache.summary(
      cache.values,
      provider: provider,
      now: now ?? DateTime.now(),
      storageBytes: await storageBytes(),
    );
  }
}
