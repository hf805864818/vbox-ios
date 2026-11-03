/// 平台层：下载存储接缝（G-02）。
///
/// 把下载表的读写抽象成可注入接缝（测试用内存假件），生产走
/// [DatabaseDownloadStore]（包装 [DatabaseManager]，镜像 iOS `DatabaseManager.swift`
/// 的 download CRUD 五方法）。
library;

import '../../data/datasources/local/database_manager.dart';
import '../../data/models/download.dart';

/// 下载存储接缝（对齐 iOS `DatabaseManager` 的 Download CRUD 子集）。
abstract class DownloadStore {
  /// 新增下载（返回数据库分配的 id；失败返回 -1）。
  Future<int> add(Download d);

  /// 全量下载（按 addedAt 倒序，对齐 iOS `queryDownloads`）。
  Future<List<Download>> all();

  /// 更新进度 + 状态。
  Future<void> updateProgress(int id, double progress, int downloadedSize, String status);

  /// 更新完成路径 + 文件大小 + 状态（进度收敛 1.0）。
  Future<void> updatePath(int id, String path, int fileSize, String status);

  /// 更新状态。
  Future<void> updateStatus(int id, String status);

  /// 删除记录。
  Future<void> delete(int id);

  /// 清空表。
  Future<void> clear();
}

/// 默认实现：包装 [DatabaseManager]（与 iOS `DatabaseManager.swift` 对齐）。
class DatabaseDownloadStore implements DownloadStore {
  /// 构造（[manager] 可注入测试实例）。
  DatabaseDownloadStore({DatabaseManager? manager})
      : _manager = manager ?? DatabaseManager.instance;

  final DatabaseManager _manager;

  @override
  Future<int> add(Download d) async {
    try {
      return await _manager.insertDownload(d);
    } catch (_) {
      return -1;
    }
  }

  @override
  Future<List<Download>> all() => _manager.allDownloads();

  @override
  Future<void> updateProgress(
    int id,
    double progress,
    int downloadedSize,
    String status,
  ) =>
      _manager.updateDownloadProgress(id, progress, downloadedSize, status);

  @override
  Future<void> updatePath(int id, String path, int fileSize, String status) =>
      _manager.updateDownloadPath(id, path, fileSize, status);

  @override
  Future<void> updateStatus(int id, String status) =>
      _manager.updateDownloadStatus(id, status);

  @override
  Future<void> delete(int id) => _manager.deleteDownload(id);

  @override
  Future<void> clear() => _manager.clearDownloads();
}
