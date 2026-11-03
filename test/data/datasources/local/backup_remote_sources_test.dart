/// 数据层单测：A2 · P0-2 —— 备份 remoteSources 远程源全量采集 / 还原。
///
/// 对齐 iOS `BackupManager.collectRemoteSources`（L349-L403）与
/// `restoreRemoteSources`（L716-L790）的跨端口径：
///   - `allSources`：本地聚合缓存 `all_sources.json` 原始字节 → Base64；
///   - `spiderJS`：蜘蛛脚本缓存目录 `*.js`，键 = 文件名去扩展名；
///   - 还原：`allSources` 原子写回缓存文件；`spiderJS` 键补 `.js` 写回脚本目录；
///   - 兼容：旧版 Flutter 备份键已带 `.js` 后缀（直接按原文件名写回）。
///
/// 临时 `StoragePaths` 环境下验证 dump → 清空 → restore roundtrip 内容一致。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vbox/core/storage/storage_paths.dart';
import 'package:vbox/data/datasources/local/backup_manager.dart';
import 'package:vbox/data/datasources/local/backup_payload.dart';
import 'package:vbox/data/datasources/local/backup_service.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final PrefsManager pm = PrefsManager.instance;
  final BackupService svc = BackupService();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final Directory tmp =
        await Directory.systemTemp.createTemp('vbox_backup_rs_test');
    StoragePaths.configure(tmp.path);
    await StoragePaths.ensureLayout();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
    // 清空远程源相关缓存（cacheDir / spiderDir 均在临时根下）。
    final File allSources = File(
        '${StoragePaths.cacheDir}${Platform.pathSeparator}all_sources.json');
    if (allSources.existsSync()) allSources.deleteSync();
    final Directory spiderDir = Directory(StoragePaths.spiderDir);
    if (spiderDir.existsSync()) spiderDir.deleteSync(recursive: true);
  });

  group('allSources 采集', () {
    test('缓存文件存在 → 采集原始字节 Base64（对齐 iOS Data→Base64）', () async {
      const String raw =
          '{"apiSources":{"sites":[{"key":"a","name":"源A"}]},"spiderSources":{"sites":[]}}';
      File('${StoragePaths.cacheDir}${Platform.pathSeparator}all_sources.json')
          .writeAsStringSync(raw);

      final BackupPayload p = await svc.dump(
        categories: <BackupCategory>{BackupCategory.remoteSources},
      );
      final Map<dynamic, dynamic> snap =
          p.readCategory(BackupCategory.remoteSources)! as Map<dynamic, dynamic>;

      expect(snap['allSources'], isNotNull);
      // Base64 解码后与原始文件字节逐一一致（未经 JSON 重排，保真）。
      expect(utf8.decode(base64.decode(snap['allSources']! as String)), raw);
    });

    test('缓存文件不存在 → 如实 null（不阻断备份）', () async {
      final BackupPayload p = await svc.dump(
        categories: <BackupCategory>{BackupCategory.remoteSources},
      );
      final Map<dynamic, dynamic> snap =
          p.readCategory(BackupCategory.remoteSources)! as Map<dynamic, dynamic>;
      expect(snap['allSources'], isNull);
    });
  });

  group('spiderJS 采集', () {
    test('目录 *.js 采集，键 = 去扩展名；非 js 跳过（对齐 iOS js_cache）', () async {
      final Directory spiderDir = Directory(StoragePaths.spiderDir)
        ..createSync(recursive: true);
      File('${spiderDir.path}/drpy_a.js').writeAsStringSync('// spider a');
      File('${spiderDir.path}/y_site.js').writeAsStringSync('# spider b');
      File('${spiderDir.path}/notes.txt').writeAsStringSync('非 js 不采集');

      final BackupPayload p = await svc.dump(
        categories: <BackupCategory>{BackupCategory.remoteSources},
      );
      final Map<dynamic, dynamic> snap =
          p.readCategory(BackupCategory.remoteSources)! as Map<dynamic, dynamic>;
      final Map<dynamic, dynamic> js =
          snap['spiderJS']! as Map<dynamic, dynamic>;

      expect(js.keys.toSet(), <String>{'drpy_a', 'y_site'});
      expect(utf8.decode(base64.decode(js['drpy_a']! as String)),
          '// spider a');
      expect(utf8.decode(base64.decode(js['y_site']! as String)),
          '# spider b');
    });

    test('目录不存在 → 空快照', () async {
      final BackupPayload p = await svc.dump(
        categories: <BackupCategory>{BackupCategory.remoteSources},
      );
      final Map<dynamic, dynamic> snap =
          p.readCategory(BackupCategory.remoteSources)! as Map<dynamic, dynamic>;
      expect(snap['spiderJS'], <String, Object?>{});
    });
  });

  group('roundtrip（dump → 清空 → restore）', () {
    test('站点缓存 + 蜘蛛脚本逐一还原一致（version 仅随 manifest 还原）', () async {
      final Directory spiderDir = Directory(StoragePaths.spiderDir)
        ..createSync(recursive: true);
      File('${spiderDir.path}/site_x.js').writeAsStringSync('// site x body');
      const String raw = '{"apiSources":{"sites":[]}}';
      File('${StoragePaths.cacheDir}${Platform.pathSeparator}all_sources.json')
          .writeAsStringSync(raw);
      await pm.set('remote_default_last_config_version', '2026.10.12.1');

      // dump → 模拟换机：删除本机全部对应缓存。
      final BackupPayload p = await svc.dump(
        categories: <BackupCategory>{BackupCategory.remoteSources},
      );
      expect(
        (p.readCategory(BackupCategory.remoteSources)!
                as Map<dynamic, dynamic>)['version'],
        '2026.10.12.1',
      );
      File('${StoragePaths.cacheDir}${Platform.pathSeparator}all_sources.json')
          .deleteSync();
      spiderDir.deleteSync(recursive: true);
      await pm.remove('remote_default_last_config_version');

      // restore → 文件逐一写回（快照无 manifest → version 不写回，对齐 iOS：
      // version 仅用于还原时的远端版本比对，实际版本以下次同步为准）。
      final int n = (await svc.restore(
        payload: p,
        categories: <BackupCategory>{BackupCategory.remoteSources},
        strategy: ConflictStrategy.overwrite,
      ))
          .counts[BackupCategory.remoteSources]!;

      // 计数：manifest（快照无缓存 manifest → 0）+ allSources(1) + spiderJS(1)。
      expect(n, 2);
      expect(
        File('${StoragePaths.cacheDir}${Platform.pathSeparator}all_sources.json')
            .readAsStringSync(),
        raw,
      );
      expect(
        File('${StoragePaths.spiderDir}${Platform.pathSeparator}site_x.js')
            .readAsStringSync(),
        '// site x body',
      );
    });
  });

  group('iOS 备份包兼容', () {
    test('spiderJS 键去扩展名（iOS 口径）→ 还原补 .js 写回脚本目录', () async {
      final BackupPayload p = BackupPayload();
      p.putCategory(BackupCategory.remoteSources, <String, Object?>{
        'manifest': null,
        'allSources': null,
        // iOS BackupManager 导出口径：键 = 文件名去扩展名。
        'spiderJS': <String, Object?>{
          'drpy_ios': base64.encode(utf8.encode('// ios spider')),
        },
        'lxPlugins': <String, Object?>{},
      });

      final int n = (await svc.restore(
        payload: p,
        categories: <BackupCategory>{BackupCategory.remoteSources},
        strategy: ConflictStrategy.merge,
      ))
          .counts[BackupCategory.remoteSources]!;

      expect(n, 1);
      expect(
        File('${StoragePaths.spiderDir}${Platform.pathSeparator}drpy_ios.js')
            .readAsStringSync(),
        '// ios spider',
      );
    });
  });
}
