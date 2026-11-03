/// 批次 C · C-05：PlaybackSettings 契约默认与自定义弹幕源（SharedPreferences mock）。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/platform/player/playback_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await PrefsManager.instance.init();
  });

  tearDown(() async {
    await PrefsManager.instance.clearAll();
  });

  group('PlaybackSettings.load', () {
    test('未设置 → 回退契约默认（连播 true / PiP true / 后台 false / 倍速 2.0）',
        () async {
      final PlaybackSettings s = await PlaybackSettings.load();
      expect(s.autoPlayNext, isTrue);
      expect(s.pipEnabled, isTrue);
      expect(s.backgroundPlay, isFalse);
      expect(s.longPressSpeed, 2.0);
    });

    test('已设置 → 读取实际值', () async {
      final PrefsManager pm = PrefsManager.instance;
      await pm.set('player_auto_play_next', false);
      await pm.set('player_background_play', true);
      await pm.set('player_pip_enabled', false);
      await pm.set('player_long_press_speed', 3.0);
      final PlaybackSettings s = await PlaybackSettings.load();
      expect(s.autoPlayNext, isFalse);
      expect(s.backgroundPlay, isTrue);
      expect(s.pipEnabled, isFalse);
      expect(s.longPressSpeed, 3.0);
    });

    test('非法倍速（≤0）→ 兜底 1.0', () async {
      await PrefsManager.instance.set('player_long_press_speed', 0.0);
      final PlaybackSettings s = await PlaybackSettings.load();
      expect(s.longPressSpeed, 1.0);
    });
  });

  group('PlaybackSettings.loadWithDanmaku', () {
    test('自定义弹幕源未开启 → 默认关闭 + 空地址', () async {
      final PlaybackSettings s = await PlaybackSettings.loadWithDanmaku();
      expect(s.customDanmakuSourceEnabled, isFalse);
      expect(s.customDanmakuSourceUrl, isEmpty);
      // 会话级弹幕参数默认值
      expect(s.danmakuEnabled, isTrue);
      expect(s.danmakuOpacity, 0.8);
      expect(s.danmakuFontSize, 16);
      expect(s.danmakuArea, 1.0);
    });

    test('开启自定义弹幕源 → 读取 URL', () async {
      final PrefsManager pm = PrefsManager.instance;
      await pm.set('custom_danmaku_source_enabled', true);
      await pm.set('custom_danmaku_source_url', 'https://dm.example.com/api');
      final PlaybackSettings s = await PlaybackSettings.loadWithDanmaku();
      expect(s.customDanmakuSourceEnabled, isTrue);
      expect(s.customDanmakuSourceUrl, 'https://dm.example.com/api');
    });
  });
}
