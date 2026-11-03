/// 核心层单测：Semaphore 有界并发信号量。
///
/// 覆盖 acquire/release 的计数语义与 FIFO 唤醒，保证搜索/短剧侧引擎类源
/// 「有界并发」限流（对齐 iOS searchStream / scanShortDramaSources 的
/// maxConcurrent）行为可预期、有回归守护。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/core/async/semaphore.dart';

void main() {
  group('Semaphore（有界并发信号量）', () {
    test('容量内 acquire 立即返回不阻塞', () async {
      final Semaphore s = Semaphore(2);
      await s.acquire();
      await s.acquire();
    });

    test('超出容量挂起，release 后恢复', () async {
      final Semaphore s = Semaphore(1);
      await s.acquire();

      var resumed = false;
      final Future<void> pending = s.acquire().then((_) => resumed = true);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(resumed, isFalse);

      s.release();
      await pending.timeout(const Duration(seconds: 2));
      expect(resumed, isTrue);
    });

    test('按 FIFO 顺序唤醒等待者', () async {
      final Semaphore s = Semaphore(0);
      final List<int> order = <int>[];

      final Future<void> f1 = s.acquire().then((_) => order.add(1));
      final Future<void> f2 = s.acquire().then((_) => order.add(2));
      final Future<void> f3 = s.acquire().then((_) => order.add(3));

      await Future<void>.delayed(Duration.zero);
      s.release();
      await Future<void>.delayed(Duration.zero);
      s.release();
      await Future<void>.delayed(Duration.zero);
      s.release();

      await Future.wait(<Future<void>>[f1, f2, f3])
          .timeout(const Duration(seconds: 2));
      expect(order, <int>[1, 2, 3]);
    });

    test('无等待者时 release 增加可用计数', () async {
      final Semaphore s = Semaphore(0);
      s.release();
      await s.acquire();
    });
  });
}