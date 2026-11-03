/// 数据层单测：TMDB 配置存储（批次 G · G-06）。
///
/// 对齐真相源：iOS `vbox/App/AppSettings.swift` L53-L101：
///   · 四契约键：`app_enable_tmdb` / `app_tmdb_proxy_url` / `app_tmdb_use_token`
///     / `app_tmdb_proxy_token`（**sensitive**）；
///   · `enableTMDB` / `tmdbProxyURL` / `tmdbUseToken` / `tmdbProxyToken`
///     的 `@Published didSet` 即时落盘语义。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/local/tmdb_config_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final PrefsManager pm = PrefsManager.instance;
  late TmdbConfigStore store;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
    store = TmdbConfigStore(prefs: pm);
    await store.load();
  });

  group('契约键（prefs_keys_v1.json → _group_tmdb）', () {
    test('键名与契约一致', () {
      expect(TmdbConfigStore.enableKey, 'app_enable_tmdb');
      expect(TmdbConfigStore.proxyUrlKey, 'app_tmdb_proxy_url');
      expect(TmdbConfigStore.useTokenKey, 'app_tmdb_use_token');
      expect(TmdbConfigStore.proxyTokenKey, 'app_tmdb_proxy_token');
    });

    test('默认态：未启用 / 空代理 / 无 token', () {
      expect(store.enabled, isFalse);
      expect(store.proxyUrl, '');
      expect(store.useToken, isFalse);
      expect(store.proxyToken, '');
      expect(store.hasProxy, isFalse);
      expect(store.isReady, isFalse);
    });
  });

  group('setter 即时落盘（对齐 iOS didSet）', () {
    test('setEnabled / setProxyUrl / setUseToken 落盘', () async {
      store.setEnabled(true);
      store.setProxyUrl('https://proxy.example.com/');
      store.setUseToken(true);
      await Future<void>.delayed(Duration.zero);

      final SharedPreferences raw = await SharedPreferences.getInstance();
      expect(raw.getBool(TmdbConfigStore.enableKey), isTrue);
      expect(
        raw.getString(TmdbConfigStore.proxyUrlKey),
        'https://proxy.example.com/',
      );
      expect(raw.getBool(TmdbConfigStore.useTokenKey), isTrue);
    });

    test('hasProxy（trim 非空）与 isReady（启用 + 代理非空）', () {
      store.setEnabled(true);
      expect(store.isReady, isFalse); // 有开关但无代理
      store.setProxyUrl('   ');
      expect(store.hasProxy, isFalse);
      store.setProxyUrl('https://proxy.example.com/');
      expect(store.hasProxy, isTrue);
      expect(store.isReady, isTrue);
      store.setEnabled(false);
      expect(store.isReady, isFalse);
    });

    test('同值 set 不触发通知', () {
      int notified = 0;
      store.addListener(() => notified++);
      store.setEnabled(false); // 默认已是 false
      expect(notified, 0);
      store.setEnabled(true);
      expect(notified, 1);
    });
  });

  group('敏感键路由（app_tmdb_proxy_token → 安全存储）', () {
    test('setProxyToken 落安全存储，不写 SharedPreferences', () async {
      store.setProxyToken('secret-token');
      await Future<void>.delayed(Duration.zero);

      final SharedPreferences raw = await SharedPreferences.getInstance();
      expect(raw.getString(TmdbConfigStore.proxyTokenKey), isNull);
      // 经 PrefsManager 读回（自动路由安全存储）。
      expect(await pm.getString(TmdbConfigStore.proxyTokenKey), 'secret-token');
    });
  });

  group('持久化（对齐 iOS save/load）', () {
    test('四键落盘且新实例可读回', () async {
      store.setEnabled(true);
      store.setProxyUrl('https://proxy.example.com/');
      store.setUseToken(true);
      store.setProxyToken('tok');
      await Future<void>.delayed(Duration.zero);

      final TmdbConfigStore back = TmdbConfigStore(prefs: pm);
      await back.load();
      expect(back.enabled, isTrue);
      expect(back.proxyUrl, 'https://proxy.example.com/');
      expect(back.useToken, isTrue);
      expect(back.proxyToken, 'tok');
      expect(back.isReady, isTrue);
    });

    test('load 只恢复一次（_loaded 守卫；此后以内存态为准）', () async {
      store.setProxyUrl('https://a.example.com/');
      await pm.set(TmdbConfigStore.proxyUrlKey, 'https://b.example.com/');
      await store.load();
      expect(store.proxyUrl, 'https://a.example.com/');
    });

    test('无注入 prefs 时降级为内存态（不崩）', () async {
      final TmdbConfigStore mem = TmdbConfigStore();
      await mem.load();
      mem.setEnabled(true);
      mem.setProxyUrl('https://x/');
      expect(mem.isReady, isTrue);
    });
  });
}