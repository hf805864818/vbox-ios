import 'dart:async';

/// 有界并发信号量（计数型）。
///
/// 对齐 iOS `SpiderManager.searchStream` / `ShortDramaService.scanShortDramaSources`
/// 的 `running/maxConcurrent` 滑动窗口限流。Dart 侧此前用 `Future.wait` 一次性
/// 打满全部源，在低配云电脑上导致 Python 子进程 / Node 桥 / QuickJS FFI 同时
/// 海量并发，触发原生崩溃（日志 `Python 桥启动超时` / `node 127.0.0.1 拒绝连接`）。
class Semaphore {
  Semaphore(int capacity) : _available = capacity;

  int _available;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  /// 申请一个许可；无可用许可时挂起直到有人 [release]。
  Future<void> acquire() {
    if (_available > 0) {
      _available--;
      return Future<void>.value();
    }
    final Completer<void> c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  /// 归还一个许可；有等待者时按 FIFO 唤醒其中一个，否则增加可用计数。
  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _available++;
    }
  }
}