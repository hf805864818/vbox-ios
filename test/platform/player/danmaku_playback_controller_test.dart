/// 批次 C · C-03：弹幕播放控制器（喂入到期弹幕 / reset / 排序）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/player/danmaku/danmaku_controller.dart';
import 'package:vbox/platform/player/danmaku/danmaku_item.dart';
import 'package:vbox/platform/player/danmaku/danmaku_lane_engine.dart';

void main() {
  group('DanmakuPlaybackController', () {
    test('构造对 items 按 timeMs 升序排序', () {
      final DanmakuPlaybackController c = DanmakuPlaybackController(
        items: const <DanmakuItem>[
          DanmakuItem(content: 'later', timeMs: 3000),
          DanmakuItem(content: 'early', timeMs: 1000),
          DanmakuItem(content: 'mid', timeMs: 2000),
        ],
      );
      expect(c.totalCount, 3);
      expect(c.hasMore, isTrue);
      // 排序正确：先喂入 1500ms，应只有 early
      final List<DanmakuRenderState> s = c.tick(1500);
      expect(s, hasLength(1));
      expect(s.single.item.content, 'early');
    });

    test('tick 推进喂入到期弹幕', () {
      final DanmakuPlaybackController c = DanmakuPlaybackController(
        items: const <DanmakuItem>[
          DanmakuItem(content: 'a', timeMs: 0),
          DanmakuItem(content: 'b', timeMs: 1000),
          DanmakuItem(content: 'c', timeMs: 2000),
        ],
      );
      expect(c.tick(0), hasLength(1)); // a
      expect(c.tick(1000), isNotEmpty); // b 到期喂入（a 仍滚动在屏）
      expect(c.hasMore, isTrue); // c（2000ms）仍未到期
      c.tick(2000); // c 到期
      expect(c.hasMore, isFalse);
    });

    test('hasMore 随 cursor 推进变 false', () {
      final DanmakuPlaybackController c = DanmakuPlaybackController(
        items: const <DanmakuItem>[DanmakuItem(content: 'a', timeMs: 0)],
      );
      expect(c.hasMore, isTrue);
      c.tick(0);
      expect(c.hasMore, isFalse);
    });

    test('reset 清空 cursor 与引擎', () {
      final DanmakuPlaybackController c = DanmakuPlaybackController(
        items: const <DanmakuItem>[DanmakuItem(content: 'a', timeMs: 0)],
      );
      c.tick(0);
      expect(c.hasMore, isFalse);
      c.reset();
      expect(c.hasMore, isTrue);
      final List<DanmakuRenderState> s = c.tick(0);
      expect(s, hasLength(1));
    });

    test('engine getter 暴露底层引擎', () {
      final DanmakuLaneEngine engine = DanmakuLaneEngine(viewportWidth: 500);
      final DanmakuPlaybackController c = DanmakuPlaybackController(
        items: const <DanmakuItem>[],
        engine: engine,
      );
      expect(c.engine, same(engine));
    });

    test('空 items', () {
      final DanmakuPlaybackController c =
          DanmakuPlaybackController(items: const <DanmakuItem>[]);
      expect(c.totalCount, 0);
      expect(c.hasMore, isFalse);
      expect(c.tick(0), isEmpty);
    });
  });
}