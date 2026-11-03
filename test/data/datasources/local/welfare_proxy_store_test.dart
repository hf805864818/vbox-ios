/// 数据层单测：福利平台代理配置存储（批次 H · H-07）。
///
/// 对齐 iOS `WelfareProxyStore.swift`：
///   · 代理 URL 管理（设置 / 清除 / 有效判定）；
///   · 平台代理开关（代理有效前置守卫、启用计数、清除连带清空）；
///   · 代理 URL 构建（URL 转发格式：`?url=` / `&url=` / 末尾直接拼接）；
///   · 契约键持久化（`welfare_proxy_url_v1` / `welfare_proxy_enabled_platforms_v1`）；
///   · 脏数据 / 跨端数据降级为空态。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/local/welfare_proxy_store.dart';

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

  group('代理 URL 管理', () {
    test('初始为空且代理无效', () {
      final WelfareProxyStore store = WelfareProxyStore();
      expect(store.proxyURL, '');
      expect(store.hasValidProxy, isFalse);
    });

    test('setProxyURL 记录并通知监听者', () {
      final WelfareProxyStore store = WelfareProxyStore();
      int notified = 0;
      store.addListener(() => notified++);

      store.setProxyURL('  https://proxy.example.com/?token=abc&url=  ');

      expect(store.proxyURL, 'https://proxy.example.com/?token=abc&url=');
      expect(store.hasValidProxy, isTrue);
      expect(notified, 1);
    });

    test('clearProxyURL 清空代理并连带清空平台开关', () {
      final WelfareProxyStore store = WelfareProxyStore();
      store.setProxyURL('https://proxy.example.com/');
      store.setProxyEnabled(true, '平台甲');
      expect(store.enabledPlatforms, isNotEmpty);

      store.clearProxyURL();

      expect(store.hasValidProxy, isFalse);
      expect(store.proxyURL, '');
      expect(store.enabledPlatforms, isEmpty);
    });
  });

  group('平台代理开关', () {
    test('代理无效时 isProxyEnabled 一律 false', () {
      final WelfareProxyStore store = WelfareProxyStore();
      store.setProxyEnabled(true, '平台甲');
      expect(store.isProxyEnabled('平台甲'), isFalse);
    });

    test('代理有效后开关生效，可切换', () {
      final WelfareProxyStore store = WelfareProxyStore();
      store.setProxyURL('https://proxy.example.com/');
      store.setProxyEnabled(true, '平台甲');

      expect(store.isProxyEnabled('平台甲'), isTrue);
      expect(store.isProxyEnabled('平台乙'), isFalse);

      store.toggleProxy('平台甲');
      expect(store.isProxyEnabled('平台甲'), isFalse);
    });

    test('enabledProxyCount 统计指定平台集中启用数', () {
      final WelfareProxyStore store = WelfareProxyStore();
      store.setProxyURL('https://proxy.example.com/');
      store.setProxyEnabled(true, '平台甲');
      store.setProxyEnabled(false, '平台乙');
      store.setProxyEnabled(true, '平台丙');

      expect(
        store.enabledProxyCount(const <String>['平台甲', '平台乙', '平台丙']),
        2,
      );
    });
  });

  group('代理 URL 构建', () {
    test('代理含 ? 且不是以 & / ? 结尾 → 追加 &url=', () {
      final WelfareProxyStore store = WelfareProxyStore()
        ..setProxyURL('https://proxy.example.com/?token=abc');

      final String built = store.buildProxiedURL('http://s.example.com/a?b=1&c=2');

      expect(
        built,
        'https://proxy.example.com/?token=abc&url=http%3A%2F%2Fs.example.com%2Fa%3Fb%3D1%26c%3D2',
      );
    });

    test('代理含 ? 且末尾是 & / ? → 直接拼接原始 URL', () {
      final WelfareProxyStore store = WelfareProxyStore()
        ..setProxyURL('https://proxy.example.com/?token=abc&');
      expect(
        store.buildProxiedURL('http://s.example.com/'),
        'https://proxy.example.com/?token=abc&http://s.example.com/',
      );

      final WelfareProxyStore store2 = WelfareProxyStore()
        ..setProxyURL('https://proxy.example.com/?');
      expect(
        store2.buildProxiedURL('http://s.example.com/'),
        'https://proxy.example.com/?http://s.example.com/',
      );
    });

    test('代理不含 ? → 追加 ?url=', () {
      final WelfareProxyStore store = WelfareProxyStore()
        ..setProxyURL('https://proxy.example.com');
      expect(
        store.buildProxiedURL('http://s.example.com/'),
        'https://proxy.example.com?url=http%3A%2F%2Fs.example.com%2F',
      );
    });

    test('proxiedURL 仅在平台开关开启且代理有效时生效', () {
      final WelfareProxyStore store = WelfareProxyStore();
      store.setProxyURL('https://proxy.example.com/');

      // 开关未开 → 原样。
      expect(store.proxiedURL('http://s.example.com/', '平台甲'), 'http://s.example.com/');

      store.setProxyEnabled(true, '平台甲');
      expect(
        store.proxiedURL('http://s.example.com/', '平台甲'),
        startsWith('https://proxy.example.com/?url='),
      );
    });
  });

  group('契约键持久化', () {
    test('写入后可跨实例 load 恢复', () async {
      final WelfareProxyStore writer = WelfareProxyStore(prefs: prefs);
      writer.setProxyURL('https://proxy.example.com/');
      writer.setProxyEnabled(true, '平台甲');
      writer.setProxyEnabled(false, '平台乙');
      // 等待异步落盘。
      await Future<void>.delayed(Duration.zero);

      final WelfareProxyStore reader = WelfareProxyStore(prefs: prefs);
      await reader.load();

      expect(reader.proxyURL, 'https://proxy.example.com/');
      expect(reader.hasValidProxy, isTrue);
      expect(reader.isProxyEnabled('平台甲'), isTrue);
      expect(reader.isProxyEnabled('平台乙'), isFalse);
    });

    test('脏数据 / 跨端异常数据 → load 降级为空态', () async {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(
        WelfareProxyStore.enabledPlatformsKey,
        'not-json{{{',
      );
      await p.setString(WelfareProxyStore.proxyUrlKey, '');

      final WelfareProxyStore store = WelfareProxyStore(prefs: prefs);
      await store.load();

      expect(store.hasValidProxy, isFalse);
      expect(store.enabledPlatforms, isEmpty);
    });

    test('代理有效但键缺失 → hasValidProxy 为 false', () async {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(WelfareProxyStore.proxyUrlKey, 'ftp://old.example.com');

      final WelfareProxyStore store = WelfareProxyStore(prefs: prefs);
      await store.load();

      expect(store.hasValidProxy, isFalse);
    });
  });
}
