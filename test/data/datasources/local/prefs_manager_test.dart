/// 数据层单测：#10 —— `prefs_manager.dart`（契约分派 + 安全存储路由）。
///
/// 安全重点：**敏感键（7）、`storage=keychain` 与 `storage=credential_extra` 键
/// 绝不能落明文 SharedPreferences**。
/// 该防线由契约 `sensitive` 标志与 `storage` 字段驱动，本文件逐键实测。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/contract/prefs_keys.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';

/// 应走安全存储的键：敏感键 ∪ storage=keychain ∪ storage=credential_extra。
final Set<String> _secureKeys = <String>{
  ...kSensitiveKeys,
  for (final PrefsKey k in kAllPrefsKeys)
    if (k.storage == PrefsStorage.keychain ||
        k.storage == PrefsStorage.credentialExtra)
      k.name,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final PrefsManager pm = PrefsManager.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  tearDown(() async {
    await pm.clearAll();
  });

  group('契约守卫', () {
    test('契约外键名：get/set 抛 ArgumentError，remove 静默', () async {
      await expectLater(pm.get('不存在的键'), throwsArgumentError);
      await expectLater(pm.set('不存在的键', 1), throwsArgumentError);
      await expectLater(pm.remove('不存在的键'), completes);
    });

    test('安全键集合 = 敏感键 ∪ keychain ∪ credential_extra（共 11 键）', () {
      expect(kSensitiveKeys.length, 7);
      expect(_secureKeys.length, 11, reason: '7 敏感 + 2 keychain + 2 credential_extra');
      expect(_secureKeys.contains('cloud_drive_credentials_v1'), isTrue);
      expect(_secureKeys.contains('saved_drive_tokens_v1'), isTrue);
      // B2：PG 凭据 extra 字段也须走安全存储，不得明文落 SharedPreferences
      expect(_secureKeys.contains('pg_source'), isTrue);
      expect(_secureKeys.contains('qr_scan'), isTrue);
      // B3：新增敏感键裁定
      expect(_secureKeys.contains('baidu_local_pcs_device_id'), isTrue);
      expect(_secureKeys.contains('saved_drive_tokens'), isTrue);
    });
  });

  group('存储路由：敏感/keychain → secure，其余 → SharedPreferences', () {
    test('每个安全键都不落明文 SharedPreferences', () async {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      for (final String name in _secureKeys) {
        await pm.set(name, 'SECRET_$name');
        expect(sp.containsKey(name), isFalse,
            reason: '$name 被写入明文 SharedPreferences！');
      }
      // 全部可经 secure 读回
      const FlutterSecureStorage s = FlutterSecureStorage();
      for (final String name in _secureKeys) {
        expect(await s.read(key: name), 'SECRET_$name', reason: name);
        expect(await pm.get(name), 'SECRET_$name', reason: name);
      }
    });

    test('普通键走 SharedPreferences，不落 secure', () async {
      const String name = 'remote_default_manifest_url';
      await pm.set(name, 'https://cdn/x.json');
      final SharedPreferences sp = await SharedPreferences.getInstance();
      expect(sp.getString(name), 'https://cdn/x.json');
      const FlutterSecureStorage s = FlutterSecureStorage();
      expect(await s.read(key: name), isNull);
    });

    test('安全键 set(null) 删除而非写入空串', () async {
      const String name = 'quark_device_id';
      await pm.set(name, 'dev-1');
      expect(await pm.get(name), 'dev-1');
      await pm.set(name, null);
      const FlutterSecureStorage s = FlutterSecureStorage();
      expect(await s.read(key: name), isNull);
    });

    test('remove 同时清除两处（按路由）', () async {
      await pm.set('cloud_drive_credentials_v1', 'v');
      await pm.set('remote_default_manifest_url', 'u');
      await pm.remove('cloud_drive_credentials_v1');
      await pm.remove('remote_default_manifest_url');
      final SharedPreferences sp = await SharedPreferences.getInstance();
      expect(sp.containsKey('remote_default_manifest_url'), isFalse);
      expect(await const FlutterSecureStorage().read(key: 'cloud_drive_credentials_v1'),
          isNull);
    });
  });

  group('A1：安全键回退读 UserDefaults（iOS 迁移兼容）', () {
    test('安全存储为空时回退读明文，并迁移进安全存储 + 清除明文', () async {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      // 模拟 iOS 遗留：敏感键写在 UserDefaults（Flutter 端 = SharedPreferences）
      await sp.setString('one_platform_token', 'legacy-tok');
      expect(await const FlutterSecureStorage().read(key: 'one_platform_token'),
          isNull);

      expect(await pm.get('one_platform_token'), 'legacy-tok');

      // 迁移完成：明文已清除、安全存储已写入
      expect(sp.containsKey('one_platform_token'), isFalse);
      expect(await const FlutterSecureStorage().read(key: 'one_platform_token'),
          'legacy-tok');
    });

    test('安全存储已有值时以安全存储为准（不触发回退）', () async {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setString('quark_device_id', 'legacy-dev');
      await pm.set('quark_device_id', 'secure-dev');
      expect(await pm.get('quark_device_id'), 'secure-dev');
      await sp.remove('quark_device_id');
    });

    test('两处皆空 → 回退契约默认值', () async {
      // 契约 default：one_platform_uuid = ""（string 默认空串）
      expect(await pm.get('one_platform_uuid'), '');
    });
  });

  group('类型分派与默认值', () {
    test('未写入时回退契约默认值', () async {
      expect(await pm.getBool('vbox_sqlite_migration_done'), isFalse);
      expect(await pm.getInt('active_subscription_index'), 0);
      expect(await pm.getString('remote_default_manifest_url'), isA<String>());
      expect(await pm.getStringList('subscribed_config_urls'), isEmpty);
    });

    test('bool / int / double / string / stringArray 往返', () async {
      await pm.set('vbox_sqlite_migration_done', true);
      expect(await pm.getBool('vbox_sqlite_migration_done'), isTrue);

      await pm.set('active_subscription_index', 3);
      expect(await pm.getInt('active_subscription_index'), 3);

      await pm.set('subscribed_config_urls', <String>['a', 'b']);
      expect(await pm.getStringList('subscribed_config_urls'), <String>['a', 'b']);
    });

    test('set 严格校验写入类型：int 键写 String → TypeError', () async {
      await expectLater(
        pm.set('active_subscription_index', 'oops'),
        throwsA(isA<TypeError>()),
      );
    });

    test('B1：读取时类型不符 → 静默回退契约默认值，不崩溃', () async {
      // 模拟历史数据以错误类型落库（绕过 set 的类型校验）
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setString('active_subscription_index', 'legacy-string');
      // B1 闭环（P.16 #2）：契约 type 与历史存储类型不一致时，读取不再抛
      // TypeError，而是静默回退契约默认值，避免首读崩溃。
      expect(await pm.getInt('active_subscription_index'), 0);
      await pm.remove('active_subscription_index');
    });
  });

  group('JSON 列表便捷读写', () {
    test('setJsonList / getJsonList 往返', () async {
      await pm.setJsonList('custom_fallback_sites', <String>['x', 'y']);
      expect(await pm.getJsonList('custom_fallback_sites'), <String>['x', 'y']);
    });

    test('空串 → 空列表；非法 JSON → 空列表', () async {
      expect(await pm.getJsonList('custom_fallback_sites'), isEmpty);
      await pm.set('custom_fallback_sites', 'not-json');
      expect(await pm.getJsonList('custom_fallback_sites'), isEmpty);
      await pm.set('custom_fallback_sites', '{"a":1}');
      expect(await pm.getJsonList('custom_fallback_sites'), isEmpty,
          reason: '非数组 JSON 应回退空列表');
    });
  });

  group('契约语义专用方法', () {
    test('迁移标记：needSqliteMigration ↔ markSqliteMigrationDone', () async {
      expect(await pm.needSqliteMigration(), isTrue);
      await pm.markSqliteMigrationDone();
      expect(await pm.needSqliteMigration(), isFalse);
    });

    test('订阅 / manifest 便捷读', () async {
      await pm.set('active_subscription_index', 2);
      expect(await pm.activeSubscriptionIndex(), 2);
      await pm.set('subscribed_config_urls', <String>['u1']);
      expect(await pm.subscribedConfigUrls(), <String>['u1']);
      await pm.set('remote_default_manifest_url', 'https://m');
      expect(await pm.remoteManifestUrl(), 'https://m');
    });
  });

  group('dumpAll 脱敏', () {
    test('maskSensitive=true 时敏感键为 *** / null，普通键原值', () async {
      await pm.set('one_platform_token', 'tok');
      await pm.set('remote_default_manifest_url', 'https://m');
      final Map<String, Object?> d = await pm.dumpAll();
      expect(d['one_platform_token'], '***');
      expect(d['remote_default_manifest_url'], 'https://m');
      expect(d.keys.length, kAllPrefsKeys.length);
    });

    test('敏感键未设置时导出 null；maskSensitive=false 出真值', () async {
      expect((await pm.dumpAll())['one_platform_userkey'], isNull);
      await pm.set('one_platform_userkey', 'uk');
      expect((await pm.dumpAll())['one_platform_userkey'], '***');
      expect((await pm.dumpAll(maskSensitive: false))['one_platform_userkey'], 'uk');
    });
  });

  group('未初始化守卫', () {
    test('clearAll 后仍可继续读写（单例状态稳定）', () async {
      await pm.set('active_subscription_index', 5);
      await pm.clearAll();
      expect(await pm.getInt('active_subscription_index'), 0);
    });
  });
}