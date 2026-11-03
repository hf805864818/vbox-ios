/// 数据层单测：福利平台自定义域名存储（批次 H · H-07）。
///
/// 对齐 iOS `WelfareDomainStore.swift`：
///   · 添加（trim + 去重 + 追加）/ 整体覆写 / 删除（删空移除键）/ 清空；
///   · 契约键持久化（`welfare_custom_domains_v2`，JSON 字典字符串）；
///   · 脏数据 / 跨端数据降级为空态。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/local/welfare_domain_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PrefsManager prefs;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await PrefsManager.instance.init();
  });

  setUp(() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.clear();
    prefs = PrefsManager.instance;
  });

  group('增删改', () {
    test('addDomain：trim + 去重 + 追加，并通知监听者', () {
      final WelfareDomainStore store = WelfareDomainStore();
      int notified = 0;
      store.addListener(() => notified++);

      store.addDomain('平台甲', '  https://a.example.com  ');
      store.addDomain('平台甲', 'https://a.example.com'); // 去重
      store.addDomain('平台甲', 'https://b.example.com');
      store.addDomain('平台甲', '   '); // 空白忽略

      expect(store.domains('平台甲'), <String>[
        'https://a.example.com',
        'https://b.example.com',
      ]);
      expect(notified, 2);
    });

    test('removeDomain：删除单项，删空后移除键', () {
      final WelfareDomainStore store = WelfareDomainStore();
      store.setDomains(<String>['https://a.example.com', 'https://b.example.com'], '平台甲');

      store.removeDomain('平台甲', 'https://a.example.com');
      expect(store.domains('平台甲'), <String>['https://b.example.com']);

      store.removeDomain('平台甲', 'https://b.example.com');
      expect(store.domains('平台甲'), isEmpty);
      expect(store.customDomains.containsKey('平台甲'), isFalse);
    });

    test('clearDomains：清空指定平台，无键时无副作用', () {
      final WelfareDomainStore store = WelfareDomainStore();
      store.setDomains(<String>['https://a.example.com'], '平台甲');
      store.clearDomains('平台甲');
      expect(store.domains('平台甲'), isEmpty);

      // 已清空再清空 → 不通知。
      int notified = 0;
      store.addListener(() => notified++);
      store.clearDomains('平台甲');
      expect(notified, 0);
    });

    test('setDomains：整体覆写并过滤空串', () {
      final WelfareDomainStore store = WelfareDomainStore();
      store.setDomains(<String>['https://a.example.com'], '平台甲');
      store.setDomains(<String>['  ', 'https://c.example.com'], '平台甲');

      expect(store.domains('平台甲'), <String>['https://c.example.com']);
    });

    test('customDomains 为只读快照', () {
      final WelfareDomainStore store = WelfareDomainStore();
      store.setDomains(<String>['https://a.example.com'], '平台甲');

      expect(() => store.customDomains['平台甲']!.add('https://x.example.com'),
          throwsUnsupportedError);
    });
  });

  group('契约键持久化', () {
    test('写入后可跨实例 load 恢复', () async {
      final WelfareDomainStore writer = WelfareDomainStore(prefs: prefs);
      writer.setDomains(<String>['https://a.example.com', 'https://b.example.com'], '平台甲');
      writer.addDomain('平台乙', 'https://c.example.com');
      await Future<void>.delayed(Duration.zero);

      final WelfareDomainStore reader = WelfareDomainStore(prefs: prefs);
      await reader.load();

      expect(reader.domains('平台甲'), <String>['https://a.example.com', 'https://b.example.com']);
      expect(reader.domains('平台乙'), <String>['https://c.example.com']);
      expect(reader.domains('平台丙'), isEmpty);
    });

    test('脏数据 / 跨端异常数据 → load 降级为空态', () async {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(WelfareDomainStore.key, 'definitely-not-json');

      final WelfareDomainStore store = WelfareDomainStore(prefs: prefs);
      await store.load();

      expect(store.customDomains, isEmpty);
    });

    test('跨端 JSON 字典（string→数组）兼容读取', () async {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(
        WelfareDomainStore.key,
        '{"平台甲":["https://a.example.com"],"平台乙":[]}',
      );

      final WelfareDomainStore store = WelfareDomainStore(prefs: prefs);
      await store.load();

      expect(store.domains('平台甲'), <String>['https://a.example.com']);
      // 空数组平台不落键。
      expect(store.customDomains.containsKey('平台乙'), isFalse);
    });
  });
}
