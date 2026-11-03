/// 平台层：播放行为设置（批次 C · C-05 PiP / 后台 / 连播 / 长按倍速）。
///
/// 读取契约 `prefs_keys_v1.json` 的播放行为键（[PrefsManager.get] 未设置时
/// 自动回退契约默认值）：
///  - `player_pip_enabled`          画中画开关（契约默认 true）
///  - `player_background_play`      后台播放（契约默认 false）
///  - `player_auto_play_next`       自动连播下一集（契约默认 true）
///  - `player_long_press_speed`     长按倍速（契约默认 2.0）
///  - 自定义弹幕源（C-03 使用）：`custom_danmaku_source_enabled` / `custom_danmaku_source_url`
///
/// 弹幕开关/透明度/字号/显示区域为**会话级**设置（契约 99 键已冻结，未持久化），
/// 由弹幕设置面板在播放会话内调整，默认 开 / 0.8 / 16px / 1.0。
library;

import '../../data/datasources/local/prefs_manager.dart';

/// 播放行为设置快照（一次读取的不可变结果）。
class PlaybackSettings {
  /// 构造。
  const PlaybackSettings({
    required this.pipEnabled,
    required this.backgroundPlay,
    required this.autoPlayNext,
    required this.longPressSpeed,
    this.danmakuEnabled = true,
    this.danmakuOpacity = 0.8,
    this.danmakuFontSize = 16,
    this.danmakuArea = 1.0,
    this.customDanmakuSourceEnabled = false,
    this.customDanmakuSourceUrl = '',
  });

  /// 画中画开关（契约默认 true）。
  final bool pipEnabled;

  /// 后台播放开关（契约默认 false）。
  final bool backgroundPlay;

  /// 自动连播下一集（契约默认 true）。
  final bool autoPlayNext;

  /// 长按倍速（契约默认 2.0）。
  final double longPressSpeed;

  /// 弹幕开关（会话级，默认开）。
  final bool danmakuEnabled;

  /// 弹幕不透明度（0.0 ~ 1.0，默认 0.8）。
  final double danmakuOpacity;

  /// 弹幕字号（px，默认 16）。
  final double danmakuFontSize;

  /// 弹幕显示区域（0.25 ~ 1.0，默认 1.0）。
  final double danmakuArea;

  /// 自定义弹幕源开关（契约默认 false）。
  final bool customDanmakuSourceEnabled;

  /// 自定义弹幕源地址（契约默认空）。
  final String customDanmakuSourceUrl;

  /// 从 [PrefsManager] 加载播放行为设置（未设置键回退契约默认）。
  static Future<PlaybackSettings> load() async {
    final PrefsManager prefs = PrefsManager.instance;
    final bool autoPlayNext = await prefs.getBool('player_auto_play_next');
    final bool backgroundPlay = await prefs.getBool('player_background_play');
    final bool pipEnabled = await prefs.getBool('player_pip_enabled');
    final double longPressSpeed =
        await prefs.getDouble('player_long_press_speed');
    return PlaybackSettings(
      pipEnabled: pipEnabled,
      backgroundPlay: backgroundPlay,
      autoPlayNext: autoPlayNext,
      longPressSpeed: longPressSpeed <= 0 ? 1.0 : longPressSpeed,
    );
  }

  /// 加载播放行为 + 自定义弹幕源偏好（C-03）。
  ///
  /// 弹幕开关/透明度/字号/区域保持会话默认（契约冻结未持久化）；
  /// 自定义弹幕源走契约键 `custom_danmaku_source_enabled` / `custom_danmaku_source_url`。
  static Future<PlaybackSettings> loadWithDanmaku() async {
    final PrefsManager prefs = PrefsManager.instance;
    final PlaybackSettings base = await load();
    final bool customEnabled =
        await prefs.getBool('custom_danmaku_source_enabled');
    final String customUrl = await prefs.getString('custom_danmaku_source_url');
    return PlaybackSettings(
      pipEnabled: base.pipEnabled,
      backgroundPlay: base.backgroundPlay,
      autoPlayNext: base.autoPlayNext,
      longPressSpeed: base.longPressSpeed,
      customDanmakuSourceEnabled: customEnabled,
      customDanmakuSourceUrl: customUrl,
    );
  }
}
