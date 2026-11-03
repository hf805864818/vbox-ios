/// 领域层单测：收藏 / 历史 / 订阅 / 远程源用例。
///
/// 全部使用 `test/support/fakes.dart` 的内存仓储，无 IO、无插件依赖。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/core/errors/failures.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/domain/entities/library/library.dart';
import 'package:vbox/domain/usecases/usecases.dart';
import 'package:vbox/domain/entities/remote_source/remote_source.dart';

import '../../support/fakes.dart';

void main() {
  group('FavoriteUseCases', () {
    late InMemoryFavoriteRepository repo;
    late FavoriteUseCases usecases;

    setUp(() {
      repo = InMemoryFavoriteRepository();
      usecases = FavoriteUseCases(repo);
    });

    test('isFavorite：空地址 → ValidationFailure', () async {
      final Result<bool> r = await usecases.isFavorite('  ');
      expect(r.isSuccess, isFalse);
      expect(r.failureOrNull, isA<ValidationFailure>());
    });

    test('toggle：首次收藏 → true，再次切换 → false', () async {
      const FavoriteItem item = FavoriteItem(
        name: '示例片',
        detailurl: 'https://a.com/v/1',
        addedAt: 100,
      );

      final Result<bool> first = await usecases.toggle(item);
      expect(first.valueOrNull, isTrue);
      expect(repo.length, 1);
      expect((await usecases.count()).valueOrNull, 1);

      final Result<bool> second = await usecases.toggle(item);
      expect(second.valueOrNull, isFalse);
      expect(repo.length, 0);
    });

    test('toggle：缺名称/详情地址 → ValidationFailure', () async {
      expect(
        (await usecases.toggle(const FavoriteItem(name: '', detailurl: 'x', addedAt: 1)))
            .failureOrNull,
        isA<ValidationFailure>(),
      );
      expect(
        (await usecases.toggle(const FavoriteItem(name: 'n', detailurl: '', addedAt: 1)))
            .failureOrNull,
        isA<ValidationFailure>(),
      );
      expect(repo.length, 0);
    });

    test('remove：非法主键 → ValidationFailure', () async {
      final Result<bool> r = await usecases.remove(0);
      expect(r.failureOrNull, isA<ValidationFailure>());
    });

    test('list：按收藏时间倒序，支持 limit/offset', () async {
      for (int i = 1; i <= 3; i++) {
        await usecases.toggle(FavoriteItem(
          name: 'n$i',
          detailurl: 'https://a.com/$i',
          addedAt: i * 10,
        ));
      }
      final List<FavoriteItem> all =
          (await usecases.list()).valueOrNull ?? <FavoriteItem>[];
      expect(all.map((FavoriteItem e) => e.name).toList(), <String>['n3', 'n2', 'n1']);

      final List<FavoriteItem> page =
          (await usecases.list(limit: 2, offset: 1)).valueOrNull ?? <FavoriteItem>[];
      expect(page.map((FavoriteItem e) => e.name).toList(), <String>['n2', 'n1']);
    });

    test('仓储失败透传为 Failure', () async {
      repo.failWith = const DatabaseFailure('锁表');
      final Result<List<FavoriteItem>> r = await usecases.list();
      expect(r.failureOrNull, isA<DatabaseFailure>());
    });

    test('clear 返回删除条数', () async {
      await usecases.toggle(const FavoriteItem(name: 'n', detailurl: 'u1', addedAt: 1));
      await usecases.toggle(const FavoriteItem(name: 'm', detailurl: 'u2', addedAt: 2));
      expect((await usecases.clear()).valueOrNull, 2);
    });
  });

  group('HistoryUseCases', () {
    late InMemoryHistoryRepository repo;
    late HistoryUseCases usecases;

    setUp(() {
      repo = InMemoryHistoryRepository();
      usecases = HistoryUseCases(repo);
    });

    test('record：进度越界被钳制、时间缺省补当前', () async {
      await usecases.record(const HistoryItem(
        name: '片',
        detailurl: 'https://a.com/1',
        progress: 1.7,
        lastPlayedAt: 0,
      ));
      final HistoryItem? sent = repo.lastUpsert;
      expect(sent, isNotNull);
      expect(sent!.progress, 1.0);
      expect(sent.lastPlayedAt, greaterThan(0));
    });

    test('record：缺失字段 → ValidationFailure', () async {
      final Result<int> r = await usecases.record(
        const HistoryItem(name: '', detailurl: 'x', lastPlayedAt: 1),
      );
      expect(r.failureOrNull, isA<ValidationFailure>());
      expect(
        (await usecases.record(
          const HistoryItem(name: 'n', detailurl: '', lastPlayedAt: 1),
        ))
            .failureOrNull,
        isA<ValidationFailure>(),
      );
    });

    test('upsert 去重：同一详情地址只留一条并更新进度', () async {
      await usecases.record(const HistoryItem(
        name: '片',
        detailurl: 'https://a.com/1',
        progress: 0.2,
        lastPlayedAt: 100,
      ));
      await usecases.record(const HistoryItem(
        name: '片',
        detailurl: 'https://a.com/1',
        progress: 0.6,
        lastPlayedAt: 200,
      ));
      expect(repo.length, 1);
      final List<HistoryItem> items = (await usecases.recent()).valueOrNull!;
      expect(items.single.progress, 0.6);
      expect(items.single.lastPlayedAt, 200);
    });

    test('recent：按时间倒序、limit 校验', () async {
      await usecases.record(const HistoryItem(
        name: 'a', detailurl: 'u1', lastPlayedAt: 100,
      ));
      await usecases.record(const HistoryItem(
        name: 'b', detailurl: 'u2', lastPlayedAt: 300,
      ));
      final List<HistoryItem> items = (await usecases.recent()).valueOrNull!;
      expect(items.map((HistoryItem e) => e.name).toList(), <String>['b', 'a']);
      expect(
        (await usecases.recent(limit: 0)).failureOrNull,
        isA<ValidationFailure>(),
      );
    });

    test('resumable：过滤已看完/未开始，仅留可续播', () async {
      await usecases.record(const HistoryItem(
        name: '已完成', detailurl: 'u1', progress: 1.0, lastPlayedAt: 10,
      ));
      await usecases.record(const HistoryItem(
        name: '刚打开', detailurl: 'u2', progress: 0.0, lastPlayedAt: 20,
      ));
      await usecases.record(const HistoryItem(
        name: '看到一半', detailurl: 'u3', progress: 0.5, lastPlayedAt: 30,
      ));
      final List<HistoryItem> items = (await usecases.resumable()).valueOrNull!;
      expect(items.length, 1);
      expect(items.single.name, '看到一半');
    });

    test('trimTo：保留最新 N 条，非法值拒绝', () async {
      for (int i = 1; i <= 4; i++) {
        await usecases.record(HistoryItem(
          name: 'n$i',
          detailurl: 'u$i',
          lastPlayedAt: i * 100,
        ));
      }
      expect((await usecases.trimTo(2)).valueOrNull, 2);
      expect(repo.length, 2);
      expect(
        (await usecases.trimTo(0)).failureOrNull,
        isA<ValidationFailure>(),
      );
    });
  });

  group('SubscriptionUseCases', () {
    late InMemorySubscriptionRepository repo;
    late SubscriptionUseCases usecases;

    setUp(() {
      repo = InMemorySubscriptionRepository();
      usecases = SubscriptionUseCases(repo);
    });

    test('add：缺字段拒绝、重复（同址）拒绝', () async {
      expect(
        (await usecases.add(const SubscriptionItem(
          dyname: '', dyurl: 'u', lastSyncAt: 0,
        )))
            .failureOrNull,
        isA<ValidationFailure>(),
      );
      expect(
        (await usecases.add(const SubscriptionItem(
          dyname: 'n', dyurl: '', lastSyncAt: 0,
        )))
            .failureOrNull,
        isA<ValidationFailure>(),
      );

      final Result<int> ok = await usecases.add(const SubscriptionItem(
        dyname: '源A', dyurl: 'https://a.com/sub', lastSyncAt: 0,
      ));
      expect(ok.isSuccess, isTrue);

      final Result<int> dup = await usecases.add(const SubscriptionItem(
        dyname: '源A', dyurl: 'https://a.com/sub', lastSyncAt: 0,
      ));
      expect(dup.failureOrNull, isA<ValidationFailure>());
      expect((dup.failureOrNull?.message ?? '').contains('已存在'), isTrue);
    });

    test('同名不同址允许、同址不同名拒绝（唯一键为 dyurl）', () async {
      await usecases.add(const SubscriptionItem(
        dyname: '源A', dyurl: 'https://a.com/1', lastSyncAt: 0,
      ));
      final Result<int> r = await usecases.add(const SubscriptionItem(
        dyname: '源A', dyurl: 'https://a.com/2', lastSyncAt: 0,
      ));
      expect(r.isSuccess, isTrue);

      // 同址不同名：DDL 唯一约束为 dyurl，必须前置拒绝（而非直撞 DB 约束）
      final Result<int> sameUrl = await usecases.add(const SubscriptionItem(
        dyname: '源B', dyurl: 'https://a.com/1', lastSyncAt: 0,
      ));
      expect(sameUrl.failureOrNull, isA<ValidationFailure>());
    });

    test('list 按名称排序', () async {
      await repo.add(const SubscriptionItem(dyname: 'B', dyurl: 'u1', lastSyncAt: 0));
      await repo.add(const SubscriptionItem(dyname: 'A', dyurl: 'u2', lastSyncAt: 0));
      final List<SubscriptionItem> items = (await usecases.list()).valueOrNull!;
      expect(items.map((SubscriptionItem e) => e.dyname).toList(), <String>['A', 'B']);
    });

    test('dueForSync：从未同步视为到期；间隔内跳过；按最后同步升序', () async {
      const int now = 100000;
      final SubscriptionUseCases uc = SubscriptionUseCases(
        repo,
        syncIntervalSeconds: 3600,
      );
      await repo.add(const SubscriptionItem(
        dyname: '从没同步', dyurl: 'u1', lastSyncAt: 0,
      ));
      await repo.add(const SubscriptionItem(
        dyname: '刚同步过', dyurl: 'u2', lastSyncAt: now - 100,
      ));
      await repo.add(const SubscriptionItem(
        dyname: '早就该同步', dyurl: 'u3', lastSyncAt: now - 7200,
      ));

      final List<SubscriptionItem> due =
          (await uc.dueForSync(now)).valueOrNull!;
      expect(due.map((SubscriptionItem e) => e.dyname).toList(),
          <String>['从没同步', '早就该同步']);
    });

    test('markSynced：非法入参拒绝，正常更新', () async {
      final int id = (await repo.add(const SubscriptionItem(
        dyname: 'A', dyurl: 'u', lastSyncAt: 0,
      )))
          .valueOrNull!;
      expect(
        (await usecases.markSynced(0, 100)).failureOrNull,
        isA<ValidationFailure>(),
      );
      expect(
        (await usecases.markSynced(id, 0)).failureOrNull,
        isA<ValidationFailure>(),
      );
      expect((await usecases.markSynced(id, 555)).valueOrNull, isTrue);
      final SubscriptionItem? after = (await repo.findById(id)).valueOrNull;
      expect(after?.lastSyncAt, 555);
    });

    test('remove：非法主键拒绝', () async {
      expect(
        (await usecases.remove(-1)).failureOrNull,
        isA<ValidationFailure>(),
      );
    });
  });

  group('RemoteSourceUseCases', () {
    late InMemoryRemoteSourceRepository repo;
    late RemoteSourceUseCases usecases;

    setUp(() {
      repo = InMemoryRemoteSourceRepository();
      usecases = RemoteSourceUseCases(repo);
    });

    test('无缓存 → 直接拉取并落盘', () async {
      repo.fetchResult = buildManifest(configVersion: '2026.09.29.2');
      final Result<RemoteManifest> r =
          await usecases.refresh(nowSeconds: 1000);
      expect(r.isSuccess, isTrue);
      expect(r.valueOrNull?.configVersion, '2026.09.29.2');
      expect(repo.fetchCount, 1);
      expect(repo.saveCount, 1);
    });

    test('缓存未过期 → 命中缓存，不再拉取', () async {
      repo.cached = buildManifest(configVersion: '2026.09.29.3', ttlSeconds: 3600);
      repo.cachedAt = 1000;
      final Result<RemoteManifest> r =
          await usecases.refresh(nowSeconds: 1500);
      expect(r.valueOrNull?.configVersion, '2026.09.29.3');
      expect(repo.fetchCount, 0);
    });

    test('缓存过期 → 重新拉取', () async {
      repo.cached = buildManifest(configVersion: 'old', ttlSeconds: 3600);
      repo.cachedAt = 1000;
      repo.fetchResult = buildManifest(configVersion: 'new');
      final Result<RemoteManifest> r =
          await usecases.refresh(nowSeconds: 99999);
      expect(r.valueOrNull?.configVersion, 'new');
      expect(repo.fetchCount, 1);
    });

    test('forceRefresh → 跳过 TTL 直接拉取', () async {
      repo.cached = buildManifest(configVersion: 'cached', ttlSeconds: 99999);
      repo.cachedAt = 99999;
      repo.fetchResult = buildManifest(configVersion: 'forced');
      final Result<RemoteManifest> r =
          await usecases.refresh(forceRefresh: true, nowSeconds: 100000);
      expect(r.valueOrNull?.configVersion, 'forced');
      expect(repo.fetchCount, 1);
    });

    test('拉取失败 → 透传 Failure，不落盘', () async {
      repo.fetchFailure = const NetworkFailure('断网');
      final Result<RemoteManifest> r =
          await usecases.refresh(nowSeconds: 1);
      expect(r.failureOrNull, isA<NetworkFailure>());
      expect(repo.saveCount, 0);
    });

    test('status：无缓存 idle / 有缓存 loadedCache / 缺必需条目 failed', () async {
      expect((await usecases.status()).state, RemoteLoadState.idle);

      repo.cached = buildManifest(configVersion: '2026.09.29.4');
      final RemoteLoadStatus ok = await usecases.status();
      expect(ok.state, RemoteLoadState.loadedCache);
      expect(ok.version, '2026.09.29.4');

      repo.cached = buildManifest(withRequiredFiles: false);
      expect((await usecases.status()).state, RemoteLoadState.failed);
    });

    test('cachedAt 透传仓储', () async {
      repo.cachedAt = 4242;
      expect((await usecases.cachedAt()).valueOrNull, 4242);
    });
  });
}
