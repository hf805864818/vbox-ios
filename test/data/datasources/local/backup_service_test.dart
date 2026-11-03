/// 数据层单测：#B4 —— `backup_service.dart`（9 类目 dump / restore）。
///
/// 真库（`sqflite_common_ffi`）+ Mock prefs（SharedPreferences / SecureStorage）
/// + 临时 `StoragePaths`，覆盖：
///   ① 表类目 dump/restore（含 merge / overwrite 两种冲突策略）
///   ② siteConfigs 三表快照
///   ③ personalSettings 白名单（11 / 14 键）+ 类型还原
///   ④ remoteSources 清单缓存写回
///   ⑤ cloudCredentials 安全键写回
///   ⑥ `.vboxbak` 文件读写与端到端（加密往返）
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
import 'package:vbox/data/datasources/local/database_manager.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';

Future<void> _deleteDbFiles(String path) async {
  for (final String suffix in <String>['', '-wal', '-shm', '-journal']) {
    final File f = File('$path$suffix');
    if (f.existsSync()) await f.delete();
  }
}

Future<void> _insertFavorite(int id, String name) async {
  await DatabaseManager.instance.insert('favorite', <String, Object?>{
    'id': id,
    'name': name,
    'laiyuan': 'demo',
    'imgurl': '',
    'detailurl': 'u/$id',
    'detailua': '',
    'xianlu': 0,
    'jishu': 0,
    'addedAt': 1700000000 + id,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final DatabaseManager dbm = DatabaseManager.instance;
  final PrefsManager pm = PrefsManager.instance;
  final BackupService svc = BackupService();
  late String dbPath;
  late Directory backupDir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final Directory tmp = await Directory.systemTemp.createTemp('vbox_backup_test');
    StoragePaths.configure(tmp.path);
    await StoragePaths.ensureLayout();
    dbPath = StoragePaths.databaseFile;
    backupDir = Directory(StoragePaths.backupDir);

    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await dbm.close();
    await _deleteDbFiles(dbPath);
    await pm.clearAll();
    if (await backupDir.exists()) {
      await backupDir.delete(recursive: true);
    }
    await backupDir.create(recursive: true);
  });

  tearDownAll(() async {
    await dbm.close();
    await _deleteDbFiles(dbPath);
  });

  group('表类目 dump', () {
    test('favorites：dump 出全部行，值为 Base64(JSON)', () async {
      await _insertFavorite(1, '片A');
      await _insertFavorite(2, '片B');

      final BackupPayload p = await svc.dump(
        categories: <BackupCategory>{BackupCategory.favorites},
      );
      expect(p.contains(BackupCategory.favorites), isTrue);
      final Object? decoded = p.readCategory(BackupCategory.favorites);
      expect(decoded, isA<List<dynamic>>());
      expect((decoded! as List<dynamic>).length, 2);
    });

    test('siteConfigs：三表快照键为 zhanyuan/apiyuan/jiexi', () async {
      await dbm.insert('jiexisetting', <String, Object?>{
        'bianma': 'j1',
        'zhuurl': 'https://z',
        'beiurl': '',
      });
      final BackupPayload p = await svc.dump(
        categories: <BackupCategory>{BackupCategory.siteConfigs},
      );
      final Map<dynamic, dynamic> snap =
          p.readCategory(BackupCategory.siteConfigs)! as Map<dynamic, dynamic>;
      expect(snap.keys.toSet(), <Object>{'zhanyuan', 'apiyuan', 'jiexi'});
      expect((snap['jiexi']! as List<dynamic>).length, 1);
    });

    test('searchHistory 类目从 search_history 表采集', () async {
      await dbm.insert('search_history', <String, Object?>{
        'keyword': 'kw',
        'searchedAt': 1,
      });
      final BackupPayload p = await svc.dump(
        categories: <BackupCategory>{BackupCategory.searchHistory},
      );
      expect((p.readCategory(BackupCategory.searchHistory)! as List<dynamic>).length, 1);
    });
  });

  group('restore 冲突策略', () {
    test('overwrite：清空本机后写入备份', () async {
      await _insertFavorite(1, '备份片');
      final BackupPayload p = await svc.dump(
        categories: <BackupCategory>{BackupCategory.favorites},
      );
      // 本机改成另一条
      await dbm.delete('favorite', where: '1 = 1', whereArgs: const <Object?>[]);
      await _insertFavorite(9, '本机片');

      final BackupRestoreReport r = await svc.restore(
        payload: p,
        categories: <BackupCategory>{BackupCategory.favorites},
        strategy: ConflictStrategy.overwrite,
      );
      expect(r.counts[BackupCategory.favorites], 1);
      final List<Map<String, Object?>> rows = await dbm.queryAll('favorite');
      expect(rows.single['name'], '备份片');
    });

    test('merge：保留本机独有，补齐备份独有', () async {
      await _insertFavorite(2, '备份片');
      final BackupPayload p = await svc.dump(
        categories: <BackupCategory>{BackupCategory.favorites},
      );
      await dbm.delete('favorite', where: '1 = 1', whereArgs: const <Object?>[]);
      await _insertFavorite(1, '本机片');

      await svc.restore(
        payload: p,
        categories: <BackupCategory>{BackupCategory.favorites},
        strategy: ConflictStrategy.merge,
      );
      final List<Map<String, Object?>> rows =
          await dbm.queryAll('favorite', orderBy: 'id ASC');
      expect(rows.map((Map<String, Object?> r) => r['name']),
          <String>['本机片', '备份片']);
    });

    test('备份中无该类目 → 记入 missing，不报错', () async {
      final BackupRestoreReport r = await svc.restore(
        payload: BackupPayload(),
        categories: <BackupCategory>{BackupCategory.downloads},
        strategy: ConflictStrategy.merge,
      );
      expect(r.missing, contains(BackupCategory.downloads));
      expect(r.total, 0);
    });
  });

  group('personalSettings', () {
    test('默认 11 键；includeWelfare=true 时 14 键', () async {
      final BackupPayload plain = await svc.dump(
        categories: <BackupCategory>{BackupCategory.personalSettings},
      );
      final Map<dynamic, dynamic> a =
          plain.readCategory(BackupCategory.personalSettings)! as Map<dynamic, dynamic>;
      expect((a['defaults']! as Map<dynamic, dynamic>).length, 11);

      final BackupPayload full = await svc.dump(
        categories: <BackupCategory>{BackupCategory.personalSettings},
        includeWelfare: true,
      );
      final Map<dynamic, dynamic> b =
          full.readCategory(BackupCategory.personalSettings)! as Map<dynamic, dynamic>;
      expect((b['defaults']! as Map<dynamic, dynamic>).length, 14);
    });

    test('restore overwrite：字符串值按契约 type 还原（bool/int）', () async {
      await pm.set('app_skin_mode', 'dark');
      await pm.set('app_enable_tmdb', true);
      await pm.set('app_dev_log_level', 3);
      final BackupPayload p = await svc.dump(
        categories: <BackupCategory>{BackupCategory.personalSettings},
      );
      await pm.clearAll();

      await svc.restore(
        payload: p,
        categories: <BackupCategory>{BackupCategory.personalSettings},
        strategy: ConflictStrategy.overwrite,
      );
      expect(await pm.getString('app_skin_mode'), 'dark');
      expect(await pm.getBool('app_enable_tmdb'), isTrue);
      expect(await pm.getInt('app_dev_log_level'), 3);
    });

    test('restore merge：不覆盖本机已有设置', () async {
      await pm.set('app_skin_mode', 'dark');
      final BackupPayload p = await svc.dump(
        categories: <BackupCategory>{BackupCategory.personalSettings},
      );
      await pm.set('app_skin_mode', 'light');

      await svc.restore(
        payload: p,
        categories: <BackupCategory>{BackupCategory.personalSettings},
        strategy: ConflictStrategy.merge,
      );
      expect(await pm.getString('app_skin_mode'), 'light');
    });
  });

  group('remoteSources / cloudCredentials', () {
    test('dump 空缓存 → 空快照结构', () async {
      final BackupPayload p = await svc.dump(
        categories: <BackupCategory>{BackupCategory.remoteSources},
      );
      final Map<dynamic, dynamic> snap =
          p.readCategory(BackupCategory.remoteSources)! as Map<dynamic, dynamic>;
      expect(snap['manifest'], isNull);
      expect(snap['spiderJS'], <String, Object?>{});
    });

    test('restore 写回 manifest 缓存文件', () async {
      final BackupPayload p = BackupPayload();
      final String manifestB64 =
          base64.encode(utf8.encode(jsonEncode(<String, Object?>{'version': '1'})));
      p.putCategory(BackupCategory.remoteSources, <String, Object?>{
        'version': '2026.10.01.1',
        'manifest': manifestB64,
        'allSources': null,
        'spiderJS': <String, Object?>{},
        'lxPlugins': <String, Object?>{},
      });

      final int n = (await svc.restore(
        payload: p,
        categories: <BackupCategory>{BackupCategory.remoteSources},
        strategy: ConflictStrategy.overwrite,
      ))
          .counts[BackupCategory.remoteSources]!;
      expect(n, 1);
      expect(
        File('${StoragePaths.cacheDir}/remote_manifest.json').existsSync(),
        isTrue,
      );
      expect(await pm.getString('remote_default_last_config_version'),
          '2026.10.01.1');
    });

    test('cloudCredentials 走安全存储，dump/restore 往返', () async {
      await pm.set('cloud_drive_credentials_v1', '{"quark":"token-abc"}');
      final BackupPayload p = await svc.dump(
        categories: <BackupCategory>{BackupCategory.cloudCredentials},
      );
      await pm.remove('cloud_drive_credentials_v1');

      await svc.restore(
        payload: p,
        categories: <BackupCategory>{BackupCategory.cloudCredentials},
        strategy: ConflictStrategy.overwrite,
      );
      expect(await pm.getString('cloud_drive_credentials_v1'),
          '{"quark":"token-abc"}');
    });

    test('lxPlugins 采集目录 .js 文件（键 = 去扩展名，对齐 iOS）', () async {
      final Directory lxDir =
          await Directory.systemTemp.createTemp('vbox_lx_test');
      File('${lxDir.path}/my_plugin.js')
          .writeAsStringSync('// lx plugin body');
      File('${lxDir.path}/readme.txt').writeAsStringSync('非 js 不采集');

      final BackupService withLx =
          BackupService(lxPluginsDirPath: () => lxDir.path);
      final BackupPayload p = await withLx.dump(
        categories: <BackupCategory>{BackupCategory.remoteSources},
      );
      final Map<dynamic, dynamic> snap =
          p.readCategory(BackupCategory.remoteSources)! as Map<dynamic, dynamic>;
      final Map<dynamic, dynamic> lx =
          snap['lxPlugins']! as Map<dynamic, dynamic>;
      // 键口径对齐 iOS BackupManager（文件名去扩展名）。
      expect(lx.keys, <String>['my_plugin']);
      expect(
        utf8.decode(base64.decode(lx['my_plugin']! as String)),
        '// lx plugin body',
      );
      await lxDir.delete(recursive: true);
    });

    test('lxPlugins 还原写回目录；iOS 键补 .js / 旧包键兼容 / 路径穿越拒绝',
        () async {
      final Directory lxDir =
          await Directory.systemTemp.createTemp('vbox_lx_restore');
      final BackupPayload p = BackupPayload();
      p.putCategory(BackupCategory.remoteSources, <String, Object?>{
        'manifest': null,
        // 混合两代备份口径：iOS 包键去扩展名（`key + ".js"` 写回）；
        // 旧版 Flutter 包键带 .js 后缀（直接按原文件名写回）。
        'lxPlugins': <String, Object?>{
          'ios_key': base64.encode(utf8.encode('body-ios')),
          'ok.js': base64.encode(utf8.encode('body-ok')),
          '../evil.js': base64.encode(utf8.encode('bad')),
          'sub/dir.js': base64.encode(utf8.encode('bad')),
        },
      });

      final BackupService withLx =
          BackupService(lxPluginsDirPath: () => lxDir.path);
      final int n = (await withLx.restore(
        payload: p,
        categories: <BackupCategory>{BackupCategory.remoteSources},
        strategy: ConflictStrategy.merge,
      ))
          .counts[BackupCategory.remoteSources]!;
      expect(n, 2);
      expect(File('${lxDir.path}/ios_key.js').readAsStringSync(), 'body-ios');
      expect(File('${lxDir.path}/ok.js').readAsStringSync(), 'body-ok');
      expect(File('${lxDir.path}/../evil.js').existsSync(), isFalse);
      expect(File('${lxDir.path}/sub').existsSync(), isFalse);
      await lxDir.delete(recursive: true);
    });
  });

  group('.vboxbak 文件 I/O 与端到端', () {
    test('buildFileName 使用 .vboxbak 扩展名', () {
      final String name = BackupService.buildFileName(DateTime(2026, 10, 1, 8, 9, 10));
      expect(name, 'vbox_backup_20261001_080910.vboxbak');
    });

    test('write / list / read / delete 往返', () async {
      final String path = await svc.writeBackupFile('{"hello":1}');
      expect(path.endsWith('.vboxbak'), isTrue);

      final List<BackupFileInfo> files = await svc.listBackupFiles();
      expect(files.length, 1);
      expect(files.single.name.endsWith('.vboxbak'), isTrue);

      expect(await svc.readBackupFile(path), '{"hello":1}');
      expect(await svc.deleteBackupFile(path), isTrue);
      expect(await svc.listBackupFiles(), isEmpty);
    });

    test('readBackupFile 不存在 → InvalidFormatException', () async {
      expect(() => svc.readBackupFile('${backupDir.path}/nope.vboxbak'),
          throwsA(isA<InvalidFormatException>()));
    });

    test('端到端：dump → 加密 → 落盘 → 读回 → 解密 → 还原', () async {
      await _insertFavorite(1, '端到端片');
      final BackupPayload payload = await svc.dump(
        categories: <BackupCategory>{BackupCategory.favorites},
      );
      final BackupEnvelope env = await BackupManager.instance.encrypt(
        plaintextJson: payload.encode(),
        meta: BackupService.buildMeta(),
        password: 'p@ss',
      );
      final String path =
          await svc.writeBackupFile(BackupManager.instance.encode(env));

      // 清空本机，再从文件还原
      await dbm.delete('favorite', where: '1 = 1', whereArgs: const <Object?>[]);
      final BackupEnvelope back =
          BackupManager.instance.decode(await svc.readBackupFile(path));
      final BackupPayload decoded = BackupPayload.decode(await BackupManager.instance
          .decrypt(envelope: back, password: 'p@ss'));
      final BackupRestoreReport r = await svc.restore(
        payload: decoded,
        categories: <BackupCategory>{BackupCategory.favorites},
        strategy: ConflictStrategy.overwrite,
      );
      expect(r.total, 1);
      expect((await dbm.queryAll('favorite')).single['name'], '端到端片');
    });

    test('错误口令 → WrongPasswordException', () async {
      final BackupEnvelope env = await BackupManager.instance.encrypt(
        plaintextJson: '{}',
        meta: BackupService.buildMeta(),
        password: 'right',
      );
      expect(
        () => BackupManager.instance.decrypt(envelope: env, password: 'wrong'),
        throwsA(isA<WrongPasswordException>()),
      );
    });
  });
}