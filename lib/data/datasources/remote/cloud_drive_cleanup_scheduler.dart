/// 数据层：网盘转存文件延迟清理调度（NC-清 · 对齐 iOS
/// `CloudDriveManager.scheduleCleanup` / `enqueueCleanup` / `flushCleanupQueue`）。
///
/// 唯一真相源：`vbox/Services/CloudDriveManager.swift`
///   · `scheduleCleanup(drive:fileIds:token:delay:)`（L1173）——登记延迟清理 +
///     启动清理工作线程；
///   · `enqueueCleanup`（L1239）——去重入队（键 `drive|tokenName|fileId`）+ 上限 300；
///   · `flushCleanupQueue`（L1278）——取到期条目 → 按 `drive|tokenName` 分组 →
///     每 100 条一批调用 `cleanupFiles` → 移除全部到期条目。
///
/// Flutter 端复用既有契约清理队列（[CloudDriveCleanupQueueStore]，键
/// `cloud_drive_cleanup_queue_v1`）承载持久化；`tokenName` 固定空串表示
/// 「未命中具名 Token，取兜底」，落库时由 [CloudDriveCredentialStore] 按盘取 Cookie。
///
/// 删除执行器以 [CloudDriveCleanupDeleter] 注入：夸克 / UC / 百度各自实现在
/// 原生客户端内（`deleteFiles`），避免本层反向依赖具体客户端。
library;

import '../../../domain/entities/cloud/cloud_drive.dart';
import '../../../domain/entities/cloud/cloud_drive_files.dart';
import '../local/cloud_drive_cleanup_queue_store.dart';
import '../local/cloud_drive_credential_store.dart';

/// 单盘删除执行器：删除 [fileIds]（[token] 为该盘 Cookie）。
typedef CloudDriveCleanupDeleter = Future<void> Function(
  String drive,
  List<String> fileIds,
  String token,
);

/// 清理调度接缝（可注入；缺省 [PersistentCloudDriveCleanupScheduler]）。
abstract interface class CloudDriveCleanupScheduler {
  /// 登记延迟清理（对齐 iOS `scheduleCleanup`）。
  Future<void> schedule({
    required CloudDriveType drive,
    required Iterable<String> fileIds,
    Duration delay = const Duration(hours: 1),
  });
}

/// 基于契约清理队列的调度实现。
class PersistentCloudDriveCleanupScheduler
    implements CloudDriveCleanupScheduler {
  /// 构造（[store] 契约队列；[credentials] 取 Cookie；[deleters] 各盘删除器）。
  PersistentCloudDriveCleanupScheduler({
    required CloudDriveCleanupQueueStore store,
    required CloudDriveCredentialStore credentials,
    required Map<String, CloudDriveCleanupDeleter> deleters,
    this.batchSize = 100,
  })  : _store = store,
        _credentials = credentials,
        _deleters = deleters;

  final CloudDriveCleanupQueueStore _store;
  final CloudDriveCredentialStore _credentials;
  final Map<String, CloudDriveCleanupDeleter> _deleters;

  /// 单批删除上限（对齐 iOS `stride(... by: 100)`）。
  final int batchSize;

  @override
  Future<void> schedule({
    required CloudDriveType drive,
    required Iterable<String> fileIds,
    Duration delay = const Duration(hours: 1),
  }) async {
    await _store.enqueue(
      drive: drive.id,
      tokenName: '',
      fileIds: fileIds,
      delay: delay,
    );
  }

  /// 执行到期清理（对齐 iOS `flushCleanupQueue`），返回成功提交的文件数。
  ///
  /// 与 iOS 一致：到期条目在提交后即移出队列（失败由下一次播放/兜底清理覆盖）。
  Future<int> flush({DateTime? now}) async {
    final DateTime stamp = now ?? DateTime.now();
    final List<CloudDriveCleanupItem> due = await _store.due(now: stamp);
    if (due.isEmpty) return 0;

    final Map<String, List<String>> groups =
        CloudDriveCleanupQueue.groupByDrive(due);
    int deleted = 0;
    for (final MapEntry<String, List<String>> group in groups.entries) {
      final String driveId = group.key.split('|').first;
      final CloudDriveCleanupDeleter? deleter = _deleters[driveId];
      if (deleter == null) continue;
      final String token = await _cookieFor(driveId);
      if (token.isEmpty) continue;
      final List<String> unique = group.value.toSet().toList();
      for (int i = 0; i < unique.length; i += batchSize) {
        final List<String> batch =
            unique.sublist(i, (i + batchSize).clamp(0, unique.length));
        if (batch.isEmpty) continue;
        try {
          await deleter(driveId, batch, token);
          deleted += batch.length;
        } catch (_) {
          // 单盘失败不阻断其余（对齐 iOS：错误仅记录，不影响队列收缩）。
        }
      }
    }
    await _store.removeDue(now: stamp);
    return deleted;
  }

  Future<String> _cookieFor(String driveId) async {
    for (final CloudDriveType type in CloudDriveType.values) {
      if (type.id == driveId) {
        return (await _credentials.credential(type))?.cookie ?? '';
      }
    }
    return '';
  }
}
