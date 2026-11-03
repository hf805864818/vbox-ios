/// 核心层：应用目录布局。
///
/// 分层约束：核心层不依赖 `path_provider` 插件，根目录由**平台层在启动时注入**
/// （`StoragePaths.configure(...)`），从而保证核心层纯 Dart、可单测。
///
/// 目录布局见 `docs/VBOX_PLAN_v6.35.md` 附录 B。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../constants/app_constants.dart';

/// 目录布局（全部为绝对路径）。
abstract final class StoragePaths {
  static String? _root;

  /// 注入应用数据根目录（启动时调用一次）。
  static void configure(String rootDir) {
    _root = rootDir;
  }

  /// 清除配置（单测用）。
  static void reset() {
    _root = null;
  }

  /// 是否已配置。
  static bool get isConfigured => _root != null;

  /// 应用数据根目录（未配置则抛 [StateError]）。
  static String get root {
    final String? r = _root;
    if (r == null) {
      throw StateError(
        'StoragePaths 未配置：请在启动时调用 StoragePaths.configure(<应用数据目录>)',
      );
    }
    return r;
  }

  /// 数据库目录。
  static String get dbDir => p.join(root, StorageDirs.db);

  /// 备份目录。
  static String get backupDir => p.join(root, StorageDirs.backup);

  /// 缓存目录。
  static String get cacheDir => p.join(root, StorageDirs.cache);

  /// 日志目录。
  static String get logDir => p.join(root, StorageDirs.log);

  /// 蜘蛛脚本目录。
  static String get spiderDir => p.join(root, StorageDirs.spider);

  /// 下载目录。
  static String get downloadDir => p.join(root, StorageDirs.download);

  /// 数据库文件绝对路径（文件名与 iOS 端一致）。
  static String get databaseFile => p.join(dbDir, DbConstants.fileName);

  /// 需要预先创建的全部目录。
  static List<String> get allDirs => <String>[
        dbDir,
        backupDir,
        cacheDir,
        logDir,
        spiderDir,
        downloadDir,
      ];

  /// 创建全部目录（幂等）。
  static Future<void> ensureLayout() async {
    for (final String dir in allDirs) {
      await Directory(dir).create(recursive: true);
    }
  }
}
