/// 数据层单测：源治理存储（Wave D · O-源1/O-源2/O-源3）。
///
/// 唯一真相源：iOS `vbox/Services/SpiderManager.swift`
///   · 契约键 `fallback_enabled` / `custom_fallback_sites` / `user_parsers`；
///   · SQLite `zhanyuan.isActive`（`DatabaseManager.queryAllZhanyuanSites`
///     / `updateZhanyuanActive`）。
///
/// 用 `sqflite_common_ffi`（桌面端真实 SQLite）+ 内存 UserDefaults mock 跑：
/// 配置持久化往返、去重语义、站源启停落库与批量通知合并。
library;

import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vbox/core/storage/storage_paths.dart';
import 'package:vbox/data/datasources/local/database_manager.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/local/source_governance_store.dart';
import 'package:vbox/data/models/zhanyuan.dart';
import 'package:vbox/domain/entities/source/source_governance.dart';

Future<void> _deleteDbFiles(String path) async {
  for (final String suffix in <String>['', '-wal', '-shm', '-journal']) {
    final File f = File('$path$suffix');
    if (f.existsSync()) await f.delete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final PrefsManager prefs = PrefsManager.instance;
  final SourceGovernanceStore store = SourceGovernanceStore.instance;
  final DatabaseManager dbm = DatabaseManager.instance;
  late String dbPath;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final Directory tmp = await Directory.systemTemp.createTemp('vbox_gov_test');
    StoragePaths.configure(tmp.path);
    await StoragePaths.ensureLayout();
    dbPath = StoragePaths.databaseFile;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await prefs.init();
  });

  setUp(() async {
    store.resetForTest();
    await prefs.clearAll();
    await dbm.close();
    await _deleteDbFiles(dbPath);
  });

  tearDownAll(() async {
    await dbm.close();
    await _deleteDbFiles(dbPath);
  });

  group('O-源1 · 兜底开关', () {
    test('缺省 true（契约默认），写入后重启恢复', () async {
      await store.load();
      expect(store.fallbackEnabled, isTrue);

      await store.setFallbackEnabled(false);
      expect(store.fallbackEnabled, isFalse);
      expect(await prefs.getBool('fallback_enabled'), isFalse);

      // 模拟重启：复位内存后重新 load。
      store.resetForTest();
      await store.load();
      expect(store.fallbackEnabled, isFalse);
    });

    test('同值写入不触发通知', () async {
      await store.load();
      int notifications = 0;
      store.addListener(() => notifications++);

      await store.setFallbackEnabled(true); // 与当前值相同
      expect(notifications, 0);

      await store.setFallbackEnabled(false);
      expect(notifications, 1);
    });
  });

  group('O-源3 · 自定义切片源', () {
    test('添加 → 持久化 → 重启恢复；重复地址拒绝', () async {
      await store.load();
      expect(
        await store.addCustomFallbackSite(
          const FallbackSite(name: '甲源', api: 'https://a.example.com/api.php'),
        ),
        isTrue,
      );
      // 同地址重复 → false（对齐 iOS 去重语义）。
      expect(
        await store.addCustomFallbackSite(
          const FallbackSite(name: '甲源副本', api: 'https://a.example.com/api.php'),
        ),
        isFalse,
      );
      // 字段非法 → false。
      expect(
        await store.addCustomFallbackSite(const FallbackSite(name: '', api: '')),
        isFalse,
      );

      store.resetForTest();
      await store.load();
      expect(store.customFallbackSites, hasLength(1));
      expect(store.customFallbackSites.single.name, '甲源');
      expect(store.customFallbackSites.single.api, 'https://a.example.com/api.php');
    });

    test('删除按地址移除', () async {
      await store.load();
      await store.addCustomFallbackSite(
        const FallbackSite(name: '甲源', api: 'https://a.example.com/api.php'),
      );
      await store.removeCustomFallbackSite('https://a.example.com/api.php');
      expect(store.customFallbackSites, isEmpty);
      // 再次删除（不存在）不报错。
      await store.removeCustomFallbackSite('https://a.example.com/api.php');
      expect(store.customFallbackSites, isEmpty);
    });

    test('脏数据（非对象 / 缺字段）被过滤', () async {
      await prefs.setJsonList('custom_fallback_sites', <Object?>[
        <String, Object?>{'name': '合法源', 'api': 'https://ok.example.com/api.php'},
        <String, Object?>{'name': '', 'api': 'https://bad.example.com/api.php'},
        'not-an-object',
      ]);
      await store.load();
      expect(store.customFallbackSites, hasLength(1));
      expect(store.customFallbackSites.single.name, '合法源');
    });
  });

  group('O-源2 · 自定义解析器', () {
    test('添加 → 持久化 → 重启恢复；重复地址拒绝', () async {
      await store.load();
      expect(
        await store.addUserParser(
          const ParserEntry(name: '777', url: 'https://jx.example.com/?url='),
        ),
        isTrue,
      );
      expect(
        await store.addUserParser(
          const ParserEntry(name: '重复', url: 'https://jx.example.com/?url='),
        ),
        isFalse,
      );

      store.resetForTest();
      await store.load();
      expect(store.userParsers, hasLength(1));
      expect(store.userParsers.single.name, '777');
    });

    test('删除按地址移除', () async {
      await store.load();
      await store.addUserParser(
        const ParserEntry(name: '777', url: 'https://jx.example.com/?url='),
      );
      await store.removeUserParser('https://jx.example.com/?url=');
      expect(store.userParsers, isEmpty);
    });
  });

  group('O-源3 · 站源启停（SQLite isActive 权威）', () {
    test('禁用不存在的站源 → 插入行；再启用 → 更新行', () async {
      await store.load();

      await store.setZhanyuanActive(
        name: '站源甲',
        searchUrl: 'https://a.example.com',
        active: false,
      );
      expect(store.disabledZhanyuanNames, contains('站源甲'));

      final List<Zhanyuan> all = await store.allZhanyuanSites();
      expect(all, hasLength(1));
      expect(all.single.name, '站源甲');
      expect(all.single.isActive, isFalse);
      expect(all.single.searchUrl, 'https://a.example.com');

      await store.setZhanyuanActive(
        name: '站源甲',
        searchUrl: 'https://a.example.com',
        active: true,
      );
      expect(store.disabledZhanyuanNames, isNot(contains('站源甲')));
      expect(await store.activeZhanyuanSites(), hasLength(1));
    });

    test('空站名直接忽略（不落库）', () async {
      await store.load();
      await store.setZhanyuanActive(name: '  ', searchUrl: '', active: false);
      expect(await store.allZhanyuanSites(), isEmpty);
    });

    test('批量启用仅触发一次通知（合并重建）', () async {
      await store.load();
      await store.setZhanyuanActive(
        name: '站源甲',
        searchUrl: 'https://a.example.com',
        active: false,
      );
      await store.setZhanyuanActive(
        name: '站源乙',
        searchUrl: 'https://b.example.com',
        active: false,
      );

      int notifications = 0;
      store.addListener(() => notifications++);
      await store.setZhanyuanActiveAll(
        <(String, String)>[
          ('站源甲', 'https://a.example.com'),
          ('站源乙', 'https://b.example.com'),
        ],
        true,
      );

      expect(notifications, 1);
      expect(store.disabledZhanyuanNames, isEmpty);
      expect(await store.activeZhanyuanSites(), hasLength(2));
    });

    test('load 恢复禁用集合（对齐 iOS 重启后过滤）', () async {
      await store.load();
      await store.setZhanyuanActive(
        name: '站源甲',
        searchUrl: 'https://a.example.com',
        active: false,
      );

      store.resetForTest();
      expect(store.disabledZhanyuanNames, isEmpty);
      await store.load();
      expect(store.disabledZhanyuanNames, <String>{'站源甲'});
    });
  });
}
