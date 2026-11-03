/// UI-F2：片头片尾跳过设置（按视频独立存储 + 触发判定）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/platform/player/skip_settings.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('SkipSettings 持久化（按视频独立）', () {
    test('未设置 → 全关', () async {
      final SkipSettings s = await SkipSettings.load('v1');
      expect(s.introEnabled, isFalse);
      expect(s.introSeconds, 0);
      expect(s.outroEnabled, isFalse);
      expect(s.outroSeconds, 0);
    });

    test('保存后可按视频读回', () async {
      const SkipSettings s = SkipSettings(
        introEnabled: true,
        introSeconds: 90,
        outroEnabled: true,
        outroSeconds: 30,
      );
      await s.save('v1');
      final SkipSettings back = await SkipSettings.load('v1');
      expect(back.introEnabled, isTrue);
      expect(back.introSeconds, 90);
      expect(back.outroEnabled, isTrue);
      expect(back.outroSeconds, 30);
    });

    test('不同视频互不影响', () async {
      await const SkipSettings(introEnabled: true, introSeconds: 60).save('v1');
      final SkipSettings other = await SkipSettings.load('v2');
      expect(other.introEnabled, isFalse);
      expect(other.introSeconds, 0);
    });

    test('空 vodId 不落库（保持全关）', () async {
      await const SkipSettings(introEnabled: true).save('');
      expect(await SkipSettings.load(''), isA<SkipSettings>());
      final SharedPreferences p = await SharedPreferences.getInstance();
      expect(p.getKeys().where((String k) => k.startsWith('skip_')), isEmpty);
    });

    test('键名前缀对齐 iOS skipSettingsPrefix', () {
      expect(SkipSettings.keyPrefix('123'), 'skip_123');
    });
  });

  group('SkipSettings 值对象', () {
    test('sameAs 判等', () {
      const SkipSettings a = SkipSettings(introEnabled: true, introSeconds: 5);
      expect(a.sameAs(const SkipSettings(introEnabled: true, introSeconds: 5)),
          isTrue);
      expect(a.sameAs(const SkipSettings(introEnabled: true, introSeconds: 6)),
          isFalse);
    });

    test('copyWith 覆盖单字段', () {
      const SkipSettings a = SkipSettings(introEnabled: true, introSeconds: 5);
      final SkipSettings b = a.copyWith(outroEnabled: true);
      expect(b.introEnabled, isTrue);
      expect(b.introSeconds, 5);
      expect(b.outroEnabled, isTrue);
    });
  });

  group('SkipTrigger 判定', () {
    test('片头：窗口内且未触发 → 跳', () {
      expect(
        SkipTrigger.shouldSkipIntro(
          positionMs: 3000,
          settings: const SkipSettings(introEnabled: true, introSeconds: 90),
          alreadyTriggered: false,
        ),
        isTrue,
      );
    });

    test('片头：已触发 / 未启用 / 时长 0 → 不跳', () {
      const SkipSettings on =
          SkipSettings(introEnabled: true, introSeconds: 90);
      expect(
        SkipTrigger.shouldSkipIntro(
            positionMs: 0, settings: on, alreadyTriggered: true),
        isFalse,
      );
      expect(
        SkipTrigger.shouldSkipIntro(
            positionMs: 0, settings: const SkipSettings(), alreadyTriggered: false),
        isFalse,
      );
      expect(
        SkipTrigger.shouldSkipIntro(
          positionMs: 0,
          settings: const SkipSettings(introEnabled: true),
          alreadyTriggered: false,
        ),
        isFalse,
      );
    });

    test('片头：超出窗口 → 不跳', () {
      expect(
        SkipTrigger.shouldSkipIntro(
          positionMs: 95000,
          settings: const SkipSettings(introEnabled: true, introSeconds: 90),
          alreadyTriggered: false,
        ),
        isFalse,
      );
    });

    test('片尾：进入片尾窗口 → 跳', () {
      expect(
        SkipTrigger.shouldSkipOutro(
          positionMs: 98000,
          durationMs: 100000,
          settings: const SkipSettings(outroEnabled: true, outroSeconds: 30),
          alreadyTriggered: false,
        ),
        isTrue,
      );
    });

    test('片尾：时长/进度未知 → 不跳', () {
      const SkipSettings on =
          SkipSettings(outroEnabled: true, outroSeconds: 30);
      expect(
        SkipTrigger.shouldSkipOutro(
          positionMs: 100,
          durationMs: 0,
          settings: on,
          alreadyTriggered: false,
        ),
        isFalse,
      );
      expect(
        SkipTrigger.shouldSkipOutro(
          positionMs: 0,
          durationMs: 100000,
          settings: on,
          alreadyTriggered: false,
        ),
        isFalse,
      );
    });
  });
}
