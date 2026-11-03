/// 核心层单测：全局常量（G-05 零触达收尾）。
///
/// 覆盖 `app_constants.dart` 各组常量，与契约 / 文档唯一真相源对照
/// （版本号与 `pubspec.yaml` 由守卫规则 8 强制一致，此处只断格式不断值）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/core/constants/app_constants.dart';

void main() {
  group('AppInfo（应用标识，对齐 pubspec）', () {
    test('展示名 / 包名', () {
      expect(AppInfo.displayName, 'VBox');
      expect(AppInfo.packageName, 'vbox');
    });

    test('语义版本为 semver 格式，构建号为正整数', () {
      expect(AppInfo.version, matches(RegExp(r'^\d+\.\d+\.\d+$')));
      expect(AppInfo.buildNumber, greaterThan(0));
    });
  });

  group('DbConstants（对齐 schema_v1.sql）', () {
    test('数据库文件名 / schema 版本 / 备份命名', () {
      expect(DbConstants.fileName, 'vbox.sqlite3');
      expect(DbConstants.currentVersion, 4);
      expect(DbConstants.backupFilePrefix, 'vbox_backup_');
      expect(DbConstants.backupFileExtension, '.vboxbak');
    });
  });

  group('NetConstants（契约 §6 网络默认值）', () {
    test('超时 / 重试 / 分页 / UA', () {
      expect(NetConstants.connectTimeout, const Duration(seconds: 15));
      expect(NetConstants.receiveTimeout, const Duration(seconds: 30));
      expect(NetConstants.maxRetries, 2);
      expect(NetConstants.retryBaseDelay, const Duration(milliseconds: 400));
      expect(NetConstants.defaultUserAgent, contains('Android'));
      expect(NetConstants.defaultPageSize, 20);
      expect(NetConstants.metaSniffLimit, 4096);
    });
  });

  group('StorageDirs / LogConstants', () {
    test('存储目录名齐备', () {
      expect(StorageDirs.db, 'db');
      expect(StorageDirs.backup, 'backup');
      expect(StorageDirs.cache, 'cache');
      expect(StorageDirs.log, 'log');
      expect(StorageDirs.spider, 'spider');
      expect(StorageDirs.download, 'download');
    });

    test('日志常量', () {
      expect(LogConstants.ringBufferSize, 500);
      expect(LogConstants.timePattern, isNotEmpty);
    });
  });
}
