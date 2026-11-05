/// 核心层：全局常量。
///
/// 唯一真相源：
/// - 数据库文件名 / 迁移终点 → `contract/schema/schema_v1.sql`
/// - 目录布局 → `docs/VBOX_PLAN_v6.35.md` 附录 B
/// - 网络默认值 → `contract/docs/abi_v1.md` §6
library;

/// 应用标识。
abstract final class AppInfo {
  /// 展示名。
  static const String displayName = 'VBox';

  /// 包名（与 `pubspec.yaml` 的 `name` 一致）。
  static const String packageName = 'vbox';

  /// 语义版本（与 `pubspec.yaml` 的 `version` 前缀一致，由守卫规则 8 强制）。
  static const String version = '3.1621.0';

  /// 构建号（与 `pubspec.yaml` 的 `version` 的 `+build` 段一致）。
  static const int buildNumber = 1621;
}

/// 数据库常量（与 iOS `vbox/Services/DatabaseManager.swift` 对齐）。
abstract final class DbConstants {
  /// 数据库文件名（**必须**与 iOS 端一致，否则迁移产物无法互通）。
  static const String fileName = 'vbox.sqlite3';

  /// 当前 schema 版本（v1→v4 迁移链终点）。
  static const int currentVersion = 4;

  /// 备份文件名前缀。
  static const String backupFilePrefix = 'vbox_backup_';

  /// 备份文件扩展名（对齐 `contract/docs/backup_v1.md` §11 建议值）。
  static const String backupFileExtension = '.vboxbak';
}

/// 网络默认值（契约 §6）。
abstract final class NetConstants {
  /// 连接超时。
  static const Duration connectTimeout = Duration(seconds: 15);

  /// 读超时（http 包无独立连接超时，统一按读超时控制）。
  static const Duration receiveTimeout = Duration(seconds: 30);

  /// 最大重试次数（不含首次请求）。
  static const int maxRetries = 2;

  /// 重试基础退避（第 n 次重试等待 `base * 2^n`）。
  static const Duration retryBaseDelay = Duration(milliseconds: 400);

  /// 默认 UA（对齐 iOS 常见移动端请求头）。
  static const String defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// 列表分页默认页大小。
  static const int defaultPageSize = 20;

  /// meta charset 探测窗口（契约 §4.2 ③：前 4096 字节）。
  static const int metaSniffLimit = 4096;
}

/// 存储目录名（相对于应用数据根目录）。
abstract final class StorageDirs {
  /// 数据库目录。
  static const String db = 'db';

  /// 备份目录。
  static const String backup = 'backup';

  /// 缓存目录。
  static const String cache = 'cache';

  /// 日志目录。
  static const String log = 'log';

  /// 蜘蛛脚本目录。
  static const String spider = 'spider';

  /// 下载目录。
  static const String download = 'download';
}

/// 日志常量。
abstract final class LogConstants {
  /// 内存环形缓冲容量。
  static const int ringBufferSize = 500;

  /// 时间戳格式。
  static const String timePattern = 'yyyy-MM-dd HH:mm:ss.SSS';
}
