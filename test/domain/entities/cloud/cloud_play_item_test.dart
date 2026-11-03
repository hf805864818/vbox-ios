/// 网盘播放统一缓存领域单测（批次 F · F-08）。
///
/// 对齐基准（唯一真相源）：iOS `CloudDriveManager` 的
/// `CloudPlayItem` / `CloudPlayItemSummary` / `cloudPlayItemCacheKey` /
/// `storeUnifiedCloudPlayItem` / `invalidateUnifiedCloudPlayItem` /
/// `clearExpiredUnifiedCloudPlayItems` / `clearUnifiedCloudPlayItems` /
/// `cloudPlayItemSummary`（`vbox/Services/CloudDriveManager.swift:221-766`）。
library;

import 'package:flutter_test/flutter_test.dart';
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
      shareURL: 'https://pan/quark/s/abc',
      resourceId: 'rid',
      fileName: 'a.mp4',
      playURL: playURL,
      expiresAt: expiresAt,
      updatedAt: updatedAt,
      source: source,
    );

void main() {
  final DateTime t0 = DateTime.utc(2026, 10, 3, 12);
  final DateTime t1 = t0.add(const Duration(minutes: 1));

  group('缓存键 / 条目判定', () {
    test('cacheKey = "provider|sourceKey"', () {
      expect(CloudPlayItemCache.keyOf('quark', 's1'), 'quark|s1');
      expect(_item(updatedAt: t0).cacheKey, 'quark|s1');
    });

    test('hasPlayURL / isExpiredAt', () {
      final CloudPlayItem a = _item(updatedAt: t0);
      expect(a.hasPlayURL, isTrue);
      expect(a.isExpiredAt(t0), isFalse); // 无过期时间视为未过期
      final CloudPlayItem b = _item(
        updatedAt: t0,
        playURL: '',
        expiresAt: t0,
      );
      expect(b.hasPlayURL, isFalse);
      expect(b.isExpiredAt(t0), isTrue);
    });
  });

  group('store', () {
    test('upsert：同键覆盖', () {
      final Map<String, CloudPlayItem> c1 =
          CloudPlayItemCache.store(<String, CloudPlayItem>{}, _item(updatedAt: t0));
      expect(c1.length, 1);
      final Map<String, CloudPlayItem> c2 = CloudPlayItemCache.store(
        c1,
        _item(updatedAt: t1, playURL: 'https://x/b.mp4'),
      );
      expect(c2.length, 1);
      expect(c2['quark|s1']!.playURL, 'https://x/b.mp4');
    });

    test('超过上限 260 按 updatedAt 倒序保留最新', () {
      Map<String, CloudPlayItem> cache = <String, CloudPlayItem>{};
      for (int i = 0; i < 261; i++) {
        cache = CloudPlayItemCache.store(
          cache,
          _item(
            sourceKey: 's$i',
            updatedAt: t0.add(Duration(seconds: i)),
          ),
        );
      }
      expect(cache.length, CloudPlayItemCache.maxItems);
      expect(cache.containsKey('quark|s0'), isFalse); // 最旧被裁
      expect(cache.containsKey('quark|s260'), isTrue);
    });
  });

  group('invalidate', () {
    test('清空 playURL / expiresAt，来源追加原因，更新时间刷新', () {
      final CloudPlayItem original = _item(
        updatedAt: t0,
        expiresAt: t1,
        source: 'node-pan',
      );
      final Map<String, CloudPlayItem> before = <String, CloudPlayItem>{
        original.cacheKey: original,
      };
      final Map<String, CloudPlayItem> after = CloudPlayItemCache.invalidate(
        before,
        provider: 'quark',
        sourceKey: 's1',
        reason: 'invalidated',
        now: t1,
      );
      final CloudPlayItem item = after['quark|s1']!;
      expect(item.playURL, isNull);
      expect(item.expiresAt, isNull);
      expect(item.source, 'node-pan-invalidated');
      expect(item.updatedAt, t1);
    });

    test('键不存在时原引用返回', () {
      final Map<String, CloudPlayItem> before = <String, CloudPlayItem>{};
      final Map<String, CloudPlayItem> after = CloudPlayItemCache.invalidate(
        before,
        provider: 'quark',
        sourceKey: 'missing',
        reason: 'invalidated',
        now: t1,
      );
      expect(identical(after, before), isTrue);
    });
  });

  group('clearExpired', () {
    test('仅目标 provider + 已过期 + 有 playURL 时清理', () {
      final Map<String, CloudPlayItem> before = <String, CloudPlayItem>{
        'quark|expired': _item(
          sourceKey: 'expired',
          expiresAt: t0,
          updatedAt: t0,
        ),
        'quark|fresh': _item(
          sourceKey: 'fresh',
          expiresAt: t1,
          updatedAt: t0,
        ),
        'baidu|expired': _item(
          provider: 'baidu',
          sourceKey: 'expired',
          expiresAt: t0,
          updatedAt: t0,
        ),
      };
      final Map<String, CloudPlayItem> after = CloudPlayItemCache.clearExpired(
        before,
        provider: 'quark',
        now: t0.add(const Duration(seconds: 1)),
      );
      expect(after['quark|expired']!.playURL, isNull);
      expect(after['quark|expired']!.source, 'node-pan-expired-cleaned');
      expect(after['quark|fresh']!.playURL, isNotNull);
      expect(after['baidu|expired']!.playURL, isNotNull); // 非目标 provider
    });

    test('无变化时原引用返回（避免无谓落盘）', () {
      final Map<String, CloudPlayItem> before = <String, CloudPlayItem>{
        'quark|fresh': _item(sourceKey: 'fresh', updatedAt: t0),
      };
      final Map<String, CloudPlayItem> after = CloudPlayItemCache.clearExpired(
        before,
        provider: 'quark',
        now: t0,
      );
      expect(identical(after, before), isTrue);
    });
  });

  group('clear / summary', () {
    test('clear 按 provider 移除', () {
      final Map<String, CloudPlayItem> after = CloudPlayItemCache.clear(
        <String, CloudPlayItem>{
          'quark|a': _item(sourceKey: 'a', updatedAt: t0),
          'baidu|b': _item(provider: 'baidu', sourceKey: 'b', updatedAt: t0),
        },
        provider: 'quark',
      );
      expect(after.keys, <String>['baidu|b']);
    });

    test('summary：总数 / 有效 / 过期 / 存储字节 / 最近更新', () {
      final CloudPlayItemSummary s = CloudPlayItemCache.summary(
        <CloudPlayItem>[
          _item(sourceKey: 'a', updatedAt: t1),
          _item(sourceKey: 'b', expiresAt: t0, updatedAt: t0),
          _item(sourceKey: 'c', playURL: '', updatedAt: t0),
          _item(provider: 'baidu', sourceKey: 'd', updatedAt: t0),
        ],
        provider: 'quark',
        now: t0.add(const Duration(seconds: 1)),
        storageBytes: 1234,
      );
      expect(s.totalCount, 3);
      expect(s.validPlayURLCount, 1); // a（无过期）
      expect(s.expiredPlayURLCount, 1); // b（已过期）
      expect(s.storageBytes, 1234);
      expect(s.lastUpdatedAt, t1);
    });
  });

  group('JSON 往返', () {
    test('字段完整往返（日期 ISO-8601）', () {
      final CloudPlayItem item = CloudPlayItem(
        provider: 'quark',
        sourceKey: 's1',
        shareURL: 'https://pan/quark/s/abc',
        resourceId: 'rid',
        fileName: 'a.mp4',
        ownPath: '/vbox/a.mp4',
        playURL: 'https://x/a.mp4',
        headers: <String, String>{'Referer': 'https://pan.quark.cn'},
        expiresAt: t1,
        compatibilityHint: 'node-proxy',
        preferredEngine: 'mpv',
        preparedAt: t0,
        updatedAt: t1,
        source: 'node-pan',
      );
      final CloudPlayItem back = CloudPlayItem.fromJson(item.toJson());
      expect(back.provider, 'quark');
      expect(back.sourceKey, 's1');
      expect(back.ownPath, '/vbox/a.mp4');
      expect(back.playURL, 'https://x/a.mp4');
      expect(back.headers['Referer'], 'https://pan.quark.cn');
      expect(back.expiresAt, t1);
      expect(back.compatibilityHint, 'node-proxy');
      expect(back.preferredEngine, 'mpv');
      expect(back.preparedAt, t0);
      expect(back.updatedAt, t1);
      expect(back.source, 'node-pan');
      expect(back.cacheKey, 'quark|s1');
    });

    test('字段缺失回退缺省值', () {
      final CloudPlayItem back = CloudPlayItem.fromJson(<String, dynamic>{});
      expect(back.provider, '');
      expect(back.headers, isEmpty);
      expect(back.playURL, isNull);
      expect(back.updatedAt.millisecondsSinceEpoch, 0);
    });
  });
}
