/// 数据层：福利平台配置磁盘缓存（批次 H · H-01）。
///
/// 唯一真相源：iOS `WelfarePlatformConfigStore` 的磁盘缓存段
/// （`cacheFileURL` / `loadFromDiskCache()` / `saveToDiskCache()` /
/// `clearAllCache()`，见 `WelfarePlatformConfigStore.swift` L315-L368）：
///   · 缓存位置 iOS 为 `Documents/remote_sources/welfare_platforms.json`；
///     Flutter 端对应 `StoragePaths.cacheDir/welfare_platforms.json`；
///   · 缓存为**尽力而为**：读失败（缺失 / 损坏）返回 `null` 由调用方走网络，
///     写失败只记录日志，不阻断主流程。
library;

import '../../../core/storage/file_store.dart';
import '../../../core/storage/storage_paths.dart';
import '../../../core/utils/logger.dart';
import '../../../domain/entities/welfare/welfare.dart';

/// 福利平台配置磁盘缓存。
class WelfarePlatformCache {
  /// 构造（[filePath] 便于单测注入；为 null 时按 [StoragePaths] 推导）。
  WelfarePlatformCache({String? filePath}) : _filePath = filePath;

  /// 缓存文件名（与 iOS 同名）。
  static const String fileName = 'welfare_platforms.json';

  /// 日志标签。
  static const String logTag = 'welfare';

  final String? _filePath;

  /// 解析后的缓存路径（未注入且 [StoragePaths] 未配置时返回 null → 禁用缓存）。
  String? get path {
    final String? injected = _filePath;
    if (injected != null) return injected;
    if (!StoragePaths.isConfigured) return null;
    return FileStore.join(StoragePaths.cacheDir, fileName);
  }

  /// 读取缓存（无缓存 / 损坏 / 未启用一律返回 `null`）。
  Future<WelfarePlatformConfig?> read() async {
    final String? p = path;
    if (p == null) return null;
    try {
      final Map<String, Object?>? json = await FileStore.readJsonMap(p);
      if (json == null) return null;
      return WelfarePlatformConfig.tryParse(json);
    } catch (e) {
      AppLog.warn(logTag, '福利平台缓存读取失败：$p', error: e);
      return null;
    }
  }

  /// 写入缓存（尽力而为，失败只记日志）。
  Future<void> write(WelfarePlatformConfig config) async {
    final String? p = path;
    if (p == null) return;
    try {
      await FileStore.writeJson(p, config.toJson());
    } catch (e) {
      AppLog.warn(logTag, '福利平台缓存写入失败：$p', error: e);
    }
  }

  /// 清空缓存（调试 / 「清缓存」入口）。
  Future<void> clear() async {
    final String? p = path;
    if (p == null) return;
    try {
      await FileStore.delete(p);
    } catch (e) {
      AppLog.warn(logTag, '福利平台缓存清除失败：$p', error: e);
    }
  }
}