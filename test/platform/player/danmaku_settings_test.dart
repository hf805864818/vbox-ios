/// 批次 C · C-03：弹幕设置快照（默认 / copyWith / fromPlayback / normalized）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/player/danmaku/danmaku_settings.dart';
import 'package:vbox/platform/player/playback_settings.dart';

void main() {
  group('DanmakuSettings', () {
    test('会话默认值（开 / 0.8 / 16px / 1.0 / 随机色，自定义源关）', () {
      expect(DanmakuSettings.defaults.enabled, isTrue);
      expect(DanmakuSettings.defaults.opacity, 0.8);
      expect(DanmakuSettings.defaults.fontSize, 16);
      expect(DanmakuSettings.defaults.area, 1.0);
      // 颜色模式默认 7（随机）、速度默认 1.0x，对齐 iOS
      // `PlayerState.danmakuColorMode = 7 / danmakuSpeed = 1.0`。
      expect(DanmakuSettings.defaults.colorMode, 7);
      expect(DanmakuSettings.defaults.speed, 1.0);
      // 速度档位表对齐 iOS speedValues / speedLabels。
      expect(DanmakuSettings.speedValues, <double>[0.5, 0.75, 1.0, 1.5, 2.0]);
      expect(DanmakuSettings.speedLabels, <String>[
        '0.5x 慢', '0.75x', '1.0x 正常', '1.5x', '2.0x 快',
      ]);
      expect(DanmakuSettings.defaults.customSourceEnabled, isFalse);
      expect(DanmakuSettings.defaults.customSourceUrl, isEmpty);
    });

    test('颜色预设表 / 随机池数值对齐 iOS PlayerState', () {
      // 对齐 iOS presetColors（RGB）。
      expect(DanmakuSettings.presetColors[1], 0xFFFFFF); // 白色
      expect(DanmakuSettings.presetColors[2], 0xFFFF00); // 黄色
      expect(DanmakuSettings.presetColors[3], 0x00FF00); // 绿色
      expect(DanmakuSettings.presetColors[4], 0x0000FF); // 蓝色
      expect(DanmakuSettings.presetColors[5], 0xFF0000); // 红色
      expect(DanmakuSettings.presetColors[6], 0xFF69B4); // 粉色
      // 随机池 8 色（黄绿蓝红粉橙青紫），排除白色。
      expect(DanmakuSettings.randomColorPool.length, 8);
      expect(DanmakuSettings.randomColorPool.contains(0xFFFFFF), isFalse);
      expect(DanmakuSettings.randomColorPool, <int>[
        0xFFFF00, 0x00FF00, 0x0000FF, 0xFF0000,
        0xFF69B4, 0xFF8C00, 0x00FFFF, 0x9932CC,
      ]);
    });

    test('copyWith 只改指定字段，其余保留', () {
      final DanmakuSettings s = DanmakuSettings.defaults
          .copyWith(opacity: 0.5, enabled: false, speed: 2.0);
      expect(s.opacity, 0.5);
      expect(s.enabled, isFalse);
      expect(s.fontSize, 16); // 未改
      expect(s.area, 1.0);
      expect(s.colorMode, 7); // 未改
      expect(s.speed, 2.0);
    });

    test('fromPlayback 取自定义弹幕源，会话参数保持默认', () {
      const PlaybackSettings p = PlaybackSettings(
        pipEnabled: true,
        backgroundPlay: false,
        autoPlayNext: true,
        longPressSpeed: 2.0,
        customDanmakuSourceEnabled: true,
        customDanmakuSourceUrl: 'http://x/dm.xml',
      );
      final DanmakuSettings s = DanmakuSettings.fromPlayback(p);
      expect(s.customSourceEnabled, isTrue);
      expect(s.customSourceUrl, 'http://x/dm.xml');
      expect(s.enabled, isTrue);
      expect(s.opacity, 0.8);
    });

    test('normalized 越界值 clamp 到合法区间', () {
      const DanmakuSettings s = DanmakuSettings(
        enabled: true,
        opacity: 3.0,
        fontSize: 100,
        area: 0.01,
        colorMode: 7,
        speed: 1.0,
        customSourceEnabled: false,
        customSourceUrl: '',
      );
      final DanmakuSettings n = s.normalized();
      expect(n.opacity, 1.0);
      expect(n.fontSize, 32);
      expect(n.area, 0.25);
    });

    test('normalized 未越界值保持不变', () {
      const DanmakuSettings s = DanmakuSettings(
        enabled: true,
        opacity: 0.5,
        fontSize: 18,
        area: 0.75,
        colorMode: 7,
        speed: 1.0,
        customSourceEnabled: false,
        customSourceUrl: '',
      );
      final DanmakuSettings n = s.normalized();
      expect(n.opacity, 0.5);
      expect(n.fontSize, 18);
      expect(n.area, 0.75);
    });

    test('toString 含关键字段', () {
      expect(
        DanmakuSettings.defaults.toString(),
        contains('DanmakuSettings'),
      );
      expect(DanmakuSettings.defaults.toString(), contains('en=true'));
    });
  });
}