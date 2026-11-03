/// 数据层：网盘清理队列持久化（批次 F · F-07）。
///
/// 对齐 iOS `CloudDriveManager`（`vbox/Services/CloudDriveManager.swift`）：
/// - 存储键 **`cloud_drive_cleanup_queue_v1`**（契约 `storage: userdefaults`，
///   类型 string）
/// - `loadCleanupQueue` / `saveCleanupQueue` / `enqueueCleanup` /
///   `flushCleanupQueue` 语义由 [CloudDriveCleanupQueue] 纯逻辑承载
///
/// iOS 侧以 `JSONEncoder([CleanupQueueItem])` 落 UserDefaults；
/// Flutter 端按契约类型 `string` 存 JSON 数组字符串（[PrefsManager.setJsonList]）。
library;

import '../../../domain/entities/cloud/cloud_drive_files.dart';
import 'prefs_manager.dart';

/// 网盘清理队列存储。
class CloudDriveCleanupQueueStore {
  /// 构造（注入契约偏好管理器）。
  CloudDriveCleanupQueueStore(this._prefs);

  final PrefsManager _prefs;

  /// 契约存储键（`prefs_keys_v1.json` → `_group_cloud`）。
  static const String storageKey = 'cloud_drive_cleanup_queue_v1';

  /// 读取全部队列条目（非法 JSON / 非数组容忍为空）。
  Future<List<CloudDriveCleanupItem>> load() async {
    final List<dynamic> raw = await _prefs.getJsonList(storageKey);
    final List<CloudDriveCleanupItem> out = <CloudDriveCleanupItem>[];
    for (final dynamic item in raw) {
      if (item is! Map) continue;
      final CloudDriveCleanupItem parsed = CloudDriveCleanupItem.fromJson(
        <String, dynamic>{
          for (final MapEntry<Object?, Object?> e in item.entries)
            e.key.toString(): e.value,
        },
      );
      if (parsed.fileId.isEmpty) continue;
      out.add(parsed);
    }
    return out;
  }

  /// 全量写入（覆盖）。
  Future<void> save(List<CloudDriveCleanupItem> items) async {
    await _prefs.setJsonList(
      storageKey,
      items.map((CloudDriveCleanupItem e) => e.toJson()).toList(),
    );
  }

  /// 入队（去重 + 上限裁剪），返回写入后的队列。
  ///
  /// 构造与 iOS `enqueueCleanup` 一致：默认延迟 180s。
  Future<List<CloudDriveCleanupItem>> enqueue({
    required String drive,
    required String tokenName,
    required Iterable<String> fileIds,
    Duration delay = const Duration(seconds: 180),
    DateTime? now,
  }) async {
    final List<CloudDriveCleanupItem> current = await load();
    final List<CloudDriveCleanupItem> next = CloudDriveCleanupQueue.enqueue(
      current,
      drive: drive,
      tokenName: tokenName,
      fileIds: fileIds,
      delay: delay,
      now: now ?? DateTime.now(),
    );
    if (next.length != current.length) {
      await save(next);
    }
    return next;
  }

  /// 到期条目（不落盘）。
  Future<List<CloudDriveCleanupItem>> due({DateTime? now}) async =>
      CloudDriveCleanupQueue.due(await load(), now ?? DateTime.now());

  /// 提交删除后移除到期条目（对齐 iOS `flushCleanupQueue` 尾部队列收缩）。
  Future<List<CloudDriveCleanupItem>> removeDue({DateTime? now}) async {
    final DateTime stamp = now ?? DateTime.now();
    final List<CloudDriveCleanupItem> current = await load();
    final List<CloudDriveCleanupItem> expired =
        CloudDriveCleanupQueue.due(current, stamp);
    if (expired.isEmpty) return current;
    final List<CloudDriveCleanupItem> next =
        CloudDriveCleanupQueue.remove(current, expired);
    await save(next);
    return next;
  }

  /// 队列长度。
  Future<int> count() async => (await load()).length;

  /// 清空队列（设置页「清空清理队列」用）。
  Future<void> clear() async => _prefs.remove(storageKey);
}
