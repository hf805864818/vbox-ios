/// 百度播放缓存统一层单测（批次 E · E5-5）。
///
/// 对齐基准（唯一真相源）：iOS `CloudDriveManager.swift`
///   · `baiduStableHash`（L904-911）/ 键派生（L344-358）；
///   · 播放结果缓存（L518-538 / L618-624，TTL 6h、上限 80）；
///   · 文件列表缓存（L392-401 / L381-390，TTL 8h、上限 80）；
///   · iBox PlayItem 缓存（L606-616 / L587-604，上限 160）；
///   · 分享上下文缓存（L424-458 / L403-422，TTL 8h、上限 60、完整性校验）；
///   · 路由诊断（L309-342，上限 60）；
///   · 摘要与清理（L768 / L812 / L868）。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/baidu_playback_cache_store.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final PrefsManager pm = PrefsManager.instance;
  late BaiduPlaybackCacheStore store;
  final DateTime t0 = DateTime.utc(2026, 10, 12, 12);

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
    store = BaiduPlaybackCacheStore(pm);
  });

  BaiduIBoxPlayItem ibox({
    String path = '/vbox/a.mp4',
    String? dlink,
    DateTime? dlinkExpiresAt,
    DateTime? updatedAt,
    String source = 'test',
  }) =>
      BaiduIBoxPlayItem(
        shareUrl: 'https://pan.baidu.com/s/1abc',
        fsId: 'f1',
        fileName: 'a.mp4',
        path: path,
        dlinkUrl: dlink,
        dlinkExpiresAt: dlinkExpiresAt,
        preparedAt: t0,
        updatedAt: updatedAt ?? t0,
        source: source,
      );

  group('stableHash（对齐 iOS baiduStableHash，FNV-1a 64）', () {
    test('空串 = offset basis 的 hex', () {
      expect(BaiduPlaybackCacheStore.stableHash(''), '14650fb0739d0383');
    });

    test('确定性且随输入变化', () {
      final String a = BaiduPlaybackCacheStore.stableHash('BDUSS=abc123');
      expect(a, 'f55b3e8db42929e9');
      expect(BaiduPlaybackCacheStore.stableHash('BDUSS=abc123'), a);
      expect(BaiduPlaybackCacheStore.stableHash('BDUSS=abc124'), isNot(a));
    });
  });

  group('键派生（对齐 iOS）', () {
    test('mainRouteCacheKey 前缀 + 结构', () {
      final String key = BaiduPlaybackCacheStore.mainRouteCacheKey(
        shareUrl: 'u',
        fsId: 'f',
        bduss: 'b',
        pcsCookie: 'p',
      );
      final String base = BaiduPlaybackCacheStore.playCacheKey(
        shareUrl: 'u',
        fsId: 'f',
        bduss: 'b',
        pcsCookie: 'p',
      );
      expect(key, 'main-route-v2|$base');
      expect(
        base,
        'u|f|${BaiduPlaybackCacheStore.stableHash('b')}|'
        '${BaiduPlaybackCacheStore.stableHash('p')}',
      );
    });

    test('fileListCacheKey / shareContextCacheKey 结构', () {
      expect(
        BaiduPlaybackCacheStore.fileListCacheKey(shareUrl: 'u', bduss: 'b'),
        'u|${BaiduPlaybackCacheStore.stableHash('b')}',
      );
      expect(
        BaiduPlaybackCacheStore.shareContextCacheKey(
          shareUrl: 'u',
          cookie: 'c',
        ),
        'u|${BaiduPlaybackCacheStore.stableHash('c')}',
      );
    });
  });

  group('播放结果缓存（TTL 6h / 上限 80）', () {
    test('写后可读回；过期不命中', () async {
      await store.storePlayResult(
        'k1',
        url: 'https://cdn/a.mp4',
        headers: <String, String>{'Cookie': 'x'},
        now: t0,
      );
      final BaiduPersistedPlayCacheItem? hit =
          await store.cachedPlayResult('k1', now: t0.add(const Duration(hours: 1)));
      expect(hit?.url, 'https://cdn/a.mp4');
      expect(hit?.headers['Cookie'], 'x');

      final BaiduPersistedPlayCacheItem? expired = await store.cachedPlayResult(
        'k1',
        now: t0.add(const Duration(hours: 7)),
      );
      expect(expired, isNull);
    });

    test('上限 80：按过期时刻保留最新', () async {
      for (int i = 0; i < 90; i++) {
        await store.storePlayResult(
          'k$i',
          url: 'https://cdn/$i.mp4',
          headers: const <String, String>{},
          now: t0.add(Duration(seconds: i)),
        );
      }
      final BaiduPlaybackCacheSummary s = await store.summary(
        now: t0.add(const Duration(hours: 1)),
      );
      expect(s.playResultCount, 80);
      // 最早写入的 k0 应被淘汰。
      expect(
        await store.cachedPlayResult('k0', now: t0.add(const Duration(hours: 1))),
        isNull,
      );
      expect(
        await store.cachedPlayResult('k89', now: t0.add(const Duration(hours: 1))),
        isNotNull,
      );
    });
  });

  group('文件列表缓存（TTL 8h）', () {
    test('写非空可命中；空列表不写', () async {
      await store.storeFileList(
        'fk',
        const <BaiduCacheFile>[
          BaiduCacheFile(fsId: 'f1', name: 'a.mp4'),
          BaiduCacheFile(fsId: 'f2', name: 'b.mp4'),
        ],
        now: t0,
      );
      final List<BaiduCacheFile>? hit =
          await store.cachedFileList('fk', now: t0.add(const Duration(hours: 1)));
      expect(hit?.map((BaiduCacheFile f) => f.name), <String>['a.mp4', 'b.mp4']);

      await store.storeFileList('empty', const <BaiduCacheFile>[], now: t0);
      expect(await store.cachedFileList('empty', now: t0), isNull);
    });

    test('过期不命中且顺手剔除', () async {
      await store.storeFileList(
        'fk',
        const <BaiduCacheFile>[BaiduCacheFile(fsId: 'f1', name: 'a.mp4')],
        now: t0,
      );
      expect(
        await store.cachedFileList('fk', now: t0.add(const Duration(hours: 9))),
        isNull,
      );
    });
  });

  group('iBox PlayItem 缓存（上限 160）', () {
    test('写后可读回；copyWith 可清空 dlink 保留 path', () async {
      await store.storeIBoxPlayItem(
        'ik',
        ibox(dlink: 'https://cdn/a.mp4', dlinkExpiresAt: t0.add(const Duration(hours: 6))),
      );
      final BaiduIBoxPlayItem? hit = await store.cachedIBoxPlayItem('ik');
      expect(hit?.dlinkUrl, 'https://cdn/a.mp4');
      expect(hit?.path, '/vbox/a.mp4');

      await store.storeIBoxPlayItem(
        'ik',
        hit!.copyWith(
          dlinkUrl: () => null,
          dlinkExpiresAt: () => null,
          source: 'invalidated',
        ),
      );
      final BaiduIBoxPlayItem? invalidated = await store.cachedIBoxPlayItem('ik');
      expect(invalidated?.dlinkUrl, isNull);
      expect(invalidated?.path, '/vbox/a.mp4');
    });

    test('上限 160：按 updatedAt 保留最新', () async {
      for (int i = 0; i < 170; i++) {
        await store.storeIBoxPlayItem(
          'k$i',
          ibox(path: '/vbox/$i.mp4', updatedAt: t0.add(Duration(seconds: i))),
        );
      }
      final BaiduPlaybackCacheSummary s = await store.summary(now: t0);
      expect(s.iBoxPlayItemCount, 160);
      expect(await store.cachedIBoxPlayItem('k0'), isNull);
      expect(await store.cachedIBoxPlayItem('k169'), isNotNull);
    });
  });

  group('分享上下文缓存（TTL 8h / 完整性校验）', () {
    BaiduShareContextCacheItem ctx({
      String? bdstoken = 'tok',
      String? randsk = 'rnd',
      String shareid = '777',
      String shareUk = '888',
    }) =>
        BaiduShareContextCacheItem(
          shareUrl: 'https://pan.baidu.com/s/1abc',
          surl: '1abc',
          shareid: shareid,
          shareUk: shareUk,
          bdstoken: bdstoken,
          randsk: randsk,
          cookie: 'BDUSS=u',
          files: const <BaiduCacheFile>[BaiduCacheFile(fsId: 'f1', name: 'a.mp4')],
          source: 'test',
        );

    test('完整上下文命中；TTL 8h', () async {
      await store.storeShareContext('ck', ctx(), now: t0);
      expect(
        await store.cachedShareContext('ck', now: t0.add(const Duration(hours: 7))),
        isNotNull,
      );
      expect(
        await store.cachedShareContext('ck', now: t0.add(const Duration(hours: 9))),
        isNull,
      );
    });

    test('缺 bdstoken → 不命中（对齐 iOS 完整性校验）', () async {
      await store.storeShareContext('ck', ctx(bdstoken: null), now: t0);
      expect(await store.cachedShareContext('ck', now: t0), isNull);
    });

    test('needsRandsk：缺 randsk → 不命中', () async {
      await store.storeShareContext('ck', ctx(randsk: null), now: t0);
      expect(
        await store.cachedShareContext('ck', needsRandsk: false, now: t0),
        isNotNull,
      );
      expect(
        await store.cachedShareContext('ck', needsRandsk: true, now: t0),
        isNull,
      );
    });
  });

  group('路由诊断（上限 60）', () {
    test('头插 + 上限 60 + 清空', () async {
      for (int i = 0; i < 70; i++) {
        await store.recordRouteDiagnostic(
          stage: 'iBox主路链',
          status: 'step$i',
          detail: 'd$i',
          now: t0.add(Duration(seconds: i)),
        );
      }
      final List<BaiduRouteDiagnostic> items =
          await store.recentRouteDiagnostics();
      expect(items.length, 60);
      expect(items.first.status, 'step69'); // 最新在前
      expect(items.last.status, 'step10'); // 最早的 0..9 被截断
      await store.clearRouteDiagnostics();
      expect(await store.recentRouteDiagnostics(), isEmpty);
    });
  });

  group('摘要与清理', () {
    test('summary 统计条数 / 过期数 / 占用', () async {
      await store.storePlayResult(
        'p1',
        url: 'https://cdn/a.mp4',
        headers: const <String, String>{},
        now: t0,
      );
      await store.storeFileList(
        'f1',
        const <BaiduCacheFile>[BaiduCacheFile(fsId: 'x', name: 'a.mp4')],
        now: t0,
      );
      await store.storeIBoxPlayItem(
        'i1',
        ibox(
          dlink: 'https://cdn/a.mp4',
          dlinkExpiresAt: t0.add(const Duration(hours: 6)),
        ),
      );
      final BaiduPlaybackCacheSummary s =
          await store.summary(now: t0.add(const Duration(hours: 1)));
      expect(s.playResultCount, 1);
      expect(s.fileListCount, 1);
      expect(s.iBoxPlayItemCount, 1);
      expect(s.validIBoxDlinkCount, 1);
      expect(s.expiredIBoxDlinkCount, 0);
      expect(s.storageBytes, greaterThan(0));
      expect(s.lastUpdatedAt, isNotNull);
    });

    test('clearExpired 清过期播放/文件列表；iBox 保留 path 仅清 dlink', () async {
      await store.storePlayResult(
        'p1',
        url: 'https://cdn/a.mp4',
        headers: const <String, String>{},
        now: t0,
      );
      await store.storeIBoxPlayItem(
        'i1',
        ibox(
          dlink: 'https://cdn/a.mp4',
          dlinkExpiresAt: t0.add(const Duration(hours: 1)),
        ),
      );
      final DateTime later = t0.add(const Duration(hours: 7));
      await store.clearExpired(now: later);
      expect(await store.cachedPlayResult('p1', now: later), isNull);
      final BaiduIBoxPlayItem? item = await store.cachedIBoxPlayItem('i1');
      expect(item, isNotNull);
      expect(item!.dlinkUrl, isNull);
      expect(item.path, '/vbox/a.mp4');
    });

    test('clearAll 清空六键（诊断键不在清空范围，对齐 iOS）', () async {
      await store.storePlayResult(
        'p1',
        url: 'https://cdn/a.mp4',
        headers: const <String, String>{},
        now: t0,
      );
      await store.storeFileList(
        'f1',
        const <BaiduCacheFile>[BaiduCacheFile(fsId: 'x', name: 'a.mp4')],
        now: t0,
      );
      await store.recordRouteDiagnostic(stage: 's', status: 'x', detail: 'd');
      await store.clearAll();
      expect(
        await pm.getString(BaiduPlaybackCacheStore.playResultKey),
        isEmpty,
      );
      expect(await pm.getString(BaiduPlaybackCacheStore.fileListKey), isEmpty);
      // 对齐 iOS `clearAllBaiduPlaybackCaches`：不含 `baidu_route_diagnostics_v1`
      // （该键由 `clearBaiduRouteDiagnostics` 单独清理）。
      expect(await store.recentRouteDiagnostics(), isNotEmpty);
      await store.clearRouteDiagnostics();
      expect(await store.recentRouteDiagnostics(), isEmpty);
    });
  });
}
