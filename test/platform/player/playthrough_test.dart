/// 批次 C · C-05：AutoPlayNextController 连播行为（纯 Dart）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/platform/player/playthrough.dart';

void main() {
  group('AutoPlayNextController.handleState', () {
    test('ended + 开启 → 触发 onAdvance', () {
      int advanced = 0;
      final AutoPlayNextController c = AutoPlayNextController(
        enabled: true,
        onAdvance: () => advanced++,
      );
      c.handleState(PlayerState.ended);
      expect(advanced, 1);
    });

    test('ended + 关闭 → 不触发', () {
      int advanced = 0;
      final AutoPlayNextController c = AutoPlayNextController(
        enabled: false,
        onAdvance: () => advanced++,
      );
      c.handleState(PlayerState.ended);
      expect(advanced, 0);
    });

    test('非 ended 状态 → 不触发', () {
      int advanced = 0;
      final AutoPlayNextController c = AutoPlayNextController(
        enabled: true,
        onAdvance: () => advanced++,
      );
      c.handleState(PlayerState.playing);
      c.handleState(PlayerState.paused);
      c.handleState(PlayerState.buffering);
      c.handleState(PlayerState.error);
      expect(advanced, 0);
    });

    test('运行中可动态开关', () {
      int advanced = 0;
      final AutoPlayNextController c = AutoPlayNextController(
        enabled: false,
        onAdvance: () => advanced++,
      );
      c.handleState(PlayerState.ended);
      expect(advanced, 0);
      c.enabled = true;
      c.handleState(PlayerState.ended);
      expect(advanced, 1);
    });
  });
}
