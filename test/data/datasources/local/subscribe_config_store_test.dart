/// 数据层单测：订阅配置存储（批次 G · G-07）。
///
/// 对齐基准（唯一真相源）：iOS `vbox/Services/SubscriptionManager.swift`
///   · 契约键三枚（`prefs_keys_v1.json` → `_group_subscription`）：
///     `subscribed_config_urls` / `active_subscription_index` / `cached_subscribe_config`；
///   · `init` 读三键 + 越界索引归 0；
///   · `switchToSubscription` 置索引 + 清 `config` / `isLoaded`；
///   · `removeURL` 删激活项 / 清空时清态并删缓存键。
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/local/subscribe_config_store.dart';
import 'package:vbox/domain/entities/spider/site_config.dart';
import 'package:vbox/domain/entities/subscribe/subscribe.dart';

/// 构造含单站点的配置。
SubscribeConfig _config(String name) => SubscribeConfig(
      sites: <SiteConfig>[
        SiteConfig(key: 'k_$name', name: name, type: 0, api: 'https://$name/api'),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final PrefsManager pm = PrefsManager.instance;
  late SubscribeConfigStore store;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
    store = SubscribeConfigStore(prefs: pm);
    await store.load();
  });

  group('契约键（prefs_keys_v1.json → _group_subscription）', () {
    test('键名与契约一致', () {
      expect(SubscribeConfigStore.urlsKey, 'subscribed_config_urls');
      expect(SubscribeConfigStore.activeIndexKey, 'active_subscription_index');
      expect(SubscribeConfigStore.cacheKey, 'cached_subscribe_config');
    });
  });

  group('初始态', () {
    test('空态：无源 / 索引 0 / 无激活源 / 未加载', () {
      expect(store.configUrls, isEmpty);
      expect(store.activeURLIndex, 0);
      expect(store.activeURL, isNull);
      expect(store.config, isNull);
      expect(store.isLoaded, isFalse);
      expect(store.hasConfigUrls, isFalse);
    });
  });

  group('applyLoaded（对齐 iOS loadConfig 尾部）', () {
    test('写入配置 + 追加 URL + 落三键', () async {
      await store.applyLoaded('https://src/a.json', _config('a'));

      expect(store.config, isNotNull);
      expect(store.isLoaded, isTrue);
      expect(store.isLoading, isFalse);
      expect(store.errorMessage, isNull);
      expect(store.configUrls, <String>['https://src/a.json']);
      expect(store.activeURL, 'https://src/a.json');

      final SharedPreferences raw = await SharedPreferences.getInstance();
      expect(raw.getStringList(SubscribeConfigStore.urlsKey),
          <String>['https://src/a.json']);
      expect(raw.getInt(SubscribeConfigStore.activeIndexKey), 0);
      expect(raw.getString(SubscribeConfigStore.cacheKey), contains('k_a'));
    });

    test('同一 URL 重复加载不重复追加', () async {
      await store.applyLoaded('https://src/a.json', _config('a'));
      await store.applyLoaded('https://src/a.json', _config('a'));
      expect(store.configUrls, hasLength(1));
    });
  });

  group('switchTo（对齐 iOS switchToSubscription）', () {
    setUp(() async {
      await store.applyLoaded('https://src/a.json', _config('a'));
      await store.applyLoaded('https://src/b.json', _config('b'));
    });

    test('切到有效索引：置索引 + 清配置触发重载 + 落盘', () async {
      await store.switchTo(1);
      expect(store.activeURLIndex, 1);
      expect(store.activeURL, 'https://src/b.json');
      expect(store.config, isNull);
      expect(store.isLoaded, isFalse);

      final SharedPreferences raw = await SharedPreferences.getInstance();
      expect(raw.getInt(SubscribeConfigStore.activeIndexKey), 1);
    });

    test('越界索引 / 同索引：忽略', () async {
      await store.switchTo(9);
      expect(store.activeURLIndex, 0);
      await store.switchTo(-1);
      expect(store.activeURLIndex, 0);
      // 同索引不清配置。
      final SubscribeConfig? before = store.config;
      await store.switchTo(0);
      expect(store.config, same(before));
    });
  });

  group('removeUrl（对齐 iOS removeURL）', () {
    test('删除非激活源：保留当前配置，仅重排 + 落盘', () async {
      await store.applyLoaded('https://src/a.json', _config('a'));
      await store.applyLoaded('https://src/b.json', _config('b'));
      await store.switchTo(1); // 激活 b
      await store.applyLoaded('https://src/b.json', _config('b'));

      await store.removeUrl('https://src/a.json');

      expect(store.configUrls, <String>['https://src/b.json']);
      expect(store.activeURLIndex, 0);
      expect(store.activeURL, 'https://src/b.json');
      expect(store.config, isNotNull);
      expect(store.isLoaded, isTrue);
    });

    test('删除激活源：清态 + 删除缓存键（防重启恢复）', () async {
      await store.applyLoaded('https://src/a.json', _config('a'));
      await store.removeUrl('https://src/a.json');

      expect(store.configUrls, isEmpty);
      expect(store.config, isNull);
      expect(store.isLoaded, isFalse);
      expect(store.activeURL, isNull);
      expect(await pm.getString(SubscribeConfigStore.cacheKey), isEmpty);
    });

    test('删除末位使索引越界 → 收敛（清空归 0）', () async {
      await store.applyLoaded('https://src/a.json', _config('a'));
      await store.applyLoaded('https://src/b.json', _config('b'));
      await store.switchTo(1);
      await store.removeUrl('https://src/b.json');
      expect(store.configUrls, <String>['https://src/a.json']);
      expect(store.activeURLIndex, 0);
    });
  });

  group('load（启动恢复三键）', () {
    test('三键齐备 → 还原 URL 列表 / 索引 / 缓存配置', () async {
      await pm.set(SubscribeConfigStore.urlsKey,
          <String>['https://src/a.json', 'https://src/b.json']);
      await pm.set(SubscribeConfigStore.activeIndexKey, 1);
      await pm.set(SubscribeConfigStore.cacheKey, jsonEncode(_config('b').toJson()));

      final SubscribeConfigStore s = SubscribeConfigStore(prefs: pm);
      await s.load();

      expect(s.configUrls, <String>['https://src/a.json', 'https://src/b.json']);
      expect(s.activeURLIndex, 1);
      expect(s.activeURL, 'https://src/b.json');
      expect(s.config?.sites.single.key, 'k_b');
      expect(s.isLoaded, isTrue);
    });

    test('索引越界 → 归 0', () async {
      await pm.set(SubscribeConfigStore.urlsKey, <String>['https://src/a.json']);
      await pm.set(SubscribeConfigStore.activeIndexKey, 5);

      final SubscribeConfigStore s = SubscribeConfigStore(prefs: pm);
      await s.load();

      expect(s.activeURLIndex, 0);
    });

    test('脏缓存（非法 JSON）→ 配置保持 null，不打断加载', () async {
      await pm.set(SubscribeConfigStore.urlsKey, <String>['https://src/a.json']);
      await pm.set(SubscribeConfigStore.cacheKey, 'not-json{{{');

      final SubscribeConfigStore s = SubscribeConfigStore(prefs: pm);
      await s.load();

      expect(s.configUrls, <String>['https://src/a.json']);
      expect(s.config, isNull);
      expect(s.isLoaded, isFalse);
    });

    test('load 只恢复一次（_loaded 守卫；此后以内存态为准）', () async {
      await store.applyLoaded('https://src/a.json', _config('a'));
      await pm.set(SubscribeConfigStore.urlsKey, <String>['https://src/x.json']);
      await store.load();
      expect(store.configUrls, <String>['https://src/a.json']);
    });
  });
}