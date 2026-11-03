/// 网盘播放统一缓存存储单测（批次 F · F-08）。
///
/// 对齐基准（唯一真相源）：iOS `CloudDriveManager` 的
/// `loadUnifiedCloudPlayItemCache` / `saveUnifiedCloudPlayItemCache` /
/// `storeUnifiedCloudPlayItem` / `invalidateUnifiedCloudPlayItem` /
/// `clearExpiredUnifiedCloudPlayItems` / `clearUnifiedCloudPlayItems` /
/// `cloudPlayItemSummary`（`vbox/Services/CloudDriveManager.swift:646-766`）。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/cloud_play_item_cache_store.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/cloud/cloud_play_item.dart';

CloudPlayItem _item({
  String provider = 'quark',
  String sourceKey = 's1',
  String? playURL = 'https://x/a.mp4',
  DateTime? expiresAt,
  required DateTime updatedAt,
  String source = 'node-pan',
}) =>
    CloudPlayItem(
      provider: provider,
      sourceKey: sourceKey,
      fileName: 'a.mp4',
      playURL: playURL,
      expiresAt: expiresAt,
      updatedAt: updatedAt,
      source: source,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final PrefsManager pm = PrefsManager.instance;
  late CloudPlayItemCacheStore store;
  final DateTime t0 = DateTime.utc(2026, 10, 3, 12);
  final DateTime t1 = t0.add(const Duration(minutes: 1));

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
    store = CloudPlayItemCacheStore(pm);
  });

  test('空存储 load() = {}', () async {
    expect(await store.load(), isEmpty);
  });

  test('store 写入并可跨实例读回（持久化 + 缓存键）', () async {
    await store.store(_item(updatedAt: t0));
    final CloudPlayItemCacheStore next = CloudPlayItemCacheStore(pm);
    final Map<String, CloudPlayItem> cache = await next.load();
    expect(cache.keys, <String>['quark|s1']);
    expect(cache['quark|s1']!.playURL, 'https://x/a.mp4');
    expect(cache['quark|s1']!.updatedAt, t0);
  });

  test('store 去重：同键覆盖不新增', () async {
    await store.store(_item(updatedAt: t0));
    await store.store(_item(updatedAt: t1, playURL: 'https://x/b.mp4'));
    final Map<String, CloudPlayItem> cache = await store.load();
    expect(cache.length, 1);
    expect(cache['quark|s1']!.playURL, 'https://x/b.mp4');
  });

  test('invalidate 清空播放地址并追加原因', () async {
    await store.store(_item(updatedAt: t0, expiresAt: t1));
    await store.invalidate(
      provider: 'quark',
      sourceKey: 's1',
      reason: 'invalidated',
      now: t1,
    );
    final CloudPlayItem item = (await store.load())['quark|s1']!;
    expect(item.playURL, isNull);
    expect(item.expiresAt, isNull);
    expect(item.source, 'node-pan-invalidated');
  });

  test('invalidate 键不存在时不落盘（保持空）', () async {
    await store.invalidate(
      provider: 'quark',
      sourceKey: 'missing',
      reason: 'invalidated',
      now: t1,
    );
    expect(await store.load(), isEmpty);
  });

  test('clearExpired 清理过期项，保留未过期项', () async {
    await store.store(_item(sourceKey: 'old', expiresAt: t0, updatedAt: t0));
    await store.store(_item(sourceKey: 'new', expiresAt: t1, updatedAt: t0));
    await store.clearExpired('quark', now: t0.add(const Duration(seconds: 1)));
    final Map<String, CloudPlayItem> cache = await store.load();
    expect(cache['quark|old']!.playURL, isNull);
    expect(cache['quark|new']!.playURL, isNotNull);
  });

  test('clear 按 provider 清空', () async {
    await store.store(_item(updatedAt: t0));
    await store.store(_item(provider: 'baidu', sourceKey: 'b', updatedAt: t0));
    await store.clear('quark');
    final Map<String, CloudPlayItem> cache = await store.load();
    expect(cache.keys, <String>['baidu|b']);
  });

  test('summary 计数 + 存储字节 > 0', () async {
    await store.store(_item(sourceKey: 'a', updatedAt: t1));
    await store.store(_item(sourceKey: 'b', expiresAt: t0, updatedAt: t0));
    final CloudPlayItemSummary s =
        await store.summary('quark', now: t0.add(const Duration(seconds: 1)));
    expect(s.totalCount, 2);
    expect(s.validPlayURLCount, 1);
    expect(s.expiredPlayURLCount, 1);
    expect(s.storageBytes, greaterThan(0));
    expect(s.lastUpdatedAt, t1);
  });

  test('非法 JSON / 非对象 / 缺键容忍为空', () async {
    await pm.set(CloudPlayItemCacheStore.storageKey, '{not-json');
    expect(await store.load(), isEmpty);
    await pm.set(CloudPlayItemCacheStore.storageKey, '[1,2,3]');
    expect(await store.load(), isEmpty);
    await pm.set(CloudPlayItemCacheStore.storageKey, '{"k":"not-map"}');
    expect(await store.load(), isEmpty);
    await pm.set(CloudPlayItemCacheStore.storageKey, '{"k":{}}');
    expect(await store.load(), isEmpty);
  });

  test('落 userdefaults 契约键（明文 SharedPreferences 可见）', () async {
    await store.store(_item(updatedAt: t0));
    final SharedPreferences raw = await SharedPreferences.getInstance();
    expect(
      raw.getString(CloudPlayItemCacheStore.storageKey),
      contains('quark|s1'),
    );
  });
}
