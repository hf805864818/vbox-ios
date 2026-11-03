/// 领域实体 ↔ 数据模型：列一致性守护。
///
/// 目的：实体与数据模型是两套代码但**共用同一张表的列名**，
/// 任一方的列增删而另一方未同步时，此处立即失败（防契约漂移）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/models/favorite.dart';
import 'package:vbox/data/models/history.dart';
import 'package:vbox/data/models/subscription.dart';
import 'package:vbox/domain/entities/library/library.dart';

void main() {
  group('列名集合一致（实体 toRow ↔ 数据模型 toMap）', () {
    test('favorite', () {
      const FavoriteItem entity = FavoriteItem(name: 'n', addedAt: 1);
      const Favorite model = Favorite(name: 'n', addedAt: 1);
      expect(
        entity.toRow().keys.toSet(),
        model.toMap().keys.toSet(),
        reason: 'favorite 表列名漂移',
      );
    });

    test('history', () {
      const HistoryItem entity = HistoryItem(name: 'n', lastPlayedAt: 1);
      const History model = History(name: 'n', lastPlayedAt: 1);
      expect(
        entity.toRow().keys.toSet(),
        model.toMap().keys.toSet(),
        reason: 'history 表列名漂移',
      );
    });

    test('subscription', () {
      const SubscriptionItem entity =
          SubscriptionItem(dyname: 'n', dyurl: 'u', lastSyncAt: 1);
      const Subscription model =
          Subscription(dyname: 'n', dyurl: 'u', lastSyncAt: 1);
      expect(
        entity.toRow().keys.toSet(),
        model.toMap().keys.toSet(),
        reason: 'subscription 表列名漂移',
      );
    });

    test('主键存在时不引入额外列', () {
      const FavoriteItem entity = FavoriteItem(id: 7, name: 'n', addedAt: 1);
      const Favorite model = Favorite(id: 7, name: 'n', addedAt: 1);
      expect(entity.toRow().keys.toSet(), model.toMap().keys.toSet());
    });

    test('表名与契约一致', () {
      expect(FavoriteItem.table, Favorite.table);
      expect(HistoryItem.table, History.table);
      expect(SubscriptionItem.table, Subscription.table);
    });
  });

  group('fromRow 容错（列缺失/类型异常不抛异常）', () {
    test('history 仅给 name', () {
      final HistoryItem h = HistoryItem.fromRow(<String, Object?>{'name': 'x'});
      expect(h.name, 'x');
      expect(h.id, isNull);
      expect(h.detailurl, '');
      expect(h.progress, 0.0);
      expect(h.lastPlayedAt, 0);
    });

    test('数值列写成字符串也能解析', () {
      final HistoryItem h = HistoryItem.fromRow(<String, Object?>{
        'name': 'x',
        'xianlu': '2',
        'jishu': '3',
        'progress': '0.5',
        'lastPlayedAt': '1700000000',
      });
      expect(h.xianlu, 2);
      expect(h.jishu, 3);
      expect(h.progress, 0.5);
      expect(h.lastPlayedAt, 1700000000);
    });

    test('subscription 缺列 → 空串/0', () {
      final SubscriptionItem s = SubscriptionItem.fromRow(<String, Object?>{});
      expect(s.dyname, '');
      expect(s.dyurl, '');
      expect(s.dyzz, '');
      expect(s.lastSyncAt, 0);
      expect(s.neverSynced, isTrue);
    });
  });

  group('进度语义', () {
    test('越界钳制（NaN / 负数 / 超过 1）', () {
      expect(
        const HistoryItem(name: 'n', detailurl: 'u', progress: 1.5, lastPlayedAt: 1)
            .clampedProgress,
        1.0,
      );
      expect(
        const HistoryItem(name: 'n', detailurl: 'u', progress: -0.5, lastPlayedAt: 1)
            .clampedProgress,
        0.0,
      );
      expect(
        const HistoryItem(name: 'n', detailurl: 'u', progress: double.nan, lastPlayedAt: 1)
            .clampedProgress,
        0.0,
      );
      expect(
        const HistoryItem(name: 'n', detailurl: 'u', progress: 0.42, lastPlayedAt: 1)
            .clampedProgress,
        0.42,
      );
    });

    test('可续播判定边界（1%–95%）', () {
      bool resumable(double p) => HistoryItem(
            name: 'n',
            detailurl: 'u',
            progress: p,
            lastPlayedAt: 1,
          ).isResumable;
      expect(resumable(0.0), isFalse);
      expect(resumable(0.009), isFalse);
      expect(resumable(0.01), isTrue);
      expect(resumable(0.95), isTrue);
      expect(resumable(0.951), isFalse);
      expect(resumable(1.0), isFalse);
    });
  });

  group('订阅到期判定', () {
    test('从未同步视为到期；间隔边界', () {
      const SubscriptionItem never =
          SubscriptionItem(dyname: 'a', dyurl: 'u', lastSyncAt: 0);
      expect(never.neverSynced, isTrue);
      expect(never.isDue(1, 3600), isTrue);

      const SubscriptionItem recent =
          SubscriptionItem(dyname: 'a', dyurl: 'u', lastSyncAt: 100000);
      expect(recent.ageSeconds(100100), 100);
      expect(recent.isDue(100100, 3600), isFalse);
      expect(recent.isDue(103600, 3600), isTrue);
    });
  });
}
