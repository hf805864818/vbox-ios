/// 平台层：片头片尾跳过设置（UI-F2）。
///
/// 对齐 iOS `PlayerViewsV2.loadSkipSettings` / `saveSkipSettings`：设置**按视频
/// 独立存储**，同一剧集所有集数共享，键名为 `skip_<vodId>_intro_enabled` /
/// `skip_<vodId>_intro_seconds` / `skip_<vodId>_outro_enabled` /
/// `skip_<vodId>_outro_seconds`。
///
/// 这四类是**动态键**（后缀随 vodId 变化），契约 `prefs_keys_v1.json` 的 99 键
/// 已冻结、未登记它们，[PrefsManager.set] 对契约外键直接抛错，故此处直接走
/// `SharedPreferences`（等价 iOS `UserDefaults.standard`）。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// 片头片尾跳过设置快照。
class SkipSettings {
  /// 构造。
  const SkipSettings({
    this.introEnabled = false,
    this.introSeconds = 0,
    this.outroEnabled = false,
    this.outroSeconds = 0,
  });

  /// 是否自动跳过片头。
  final bool introEnabled;

  /// 片头时长（秒）。
  final int introSeconds;

  /// 是否自动跳过片尾。
  final bool outroEnabled;

  /// 片尾时长（秒）。
  final int outroSeconds;

  /// 是否与另一快照等值（面板内联编辑时避免无谓刷新）。
  bool sameAs(SkipSettings other) =>
      introEnabled == other.introEnabled &&
      introSeconds == other.introSeconds &&
      outroEnabled == other.outroEnabled &&
      outroSeconds == other.outroSeconds;

  /// 复制并覆盖部分字段。
  SkipSettings copyWith({
    bool? introEnabled,
    int? introSeconds,
    bool? outroEnabled,
    int? outroSeconds,
  }) =>
      SkipSettings(
        introEnabled: introEnabled ?? this.introEnabled,
        introSeconds: introSeconds ?? this.introSeconds,
        outroEnabled: outroEnabled ?? this.outroEnabled,
        outroSeconds: outroSeconds ?? this.outroSeconds,
      );

  /// 读取指定视频的设置（未设置 → 全关；对齐 iOS 语义）。
  static Future<SkipSettings> load(String vodId) async {
    if (vodId.isEmpty) return const SkipSettings();
    final SharedPreferences p = await SharedPreferences.getInstance();
    final String prefix = keyPrefix(vodId);
    return SkipSettings(
      introEnabled: p.getBool('${prefix}_intro_enabled') ?? false,
      introSeconds: p.getInt('${prefix}_intro_seconds') ?? 0,
      outroEnabled: p.getBool('${prefix}_outro_enabled') ?? false,
      outroSeconds: p.getInt('${prefix}_outro_seconds') ?? 0,
    );
  }

  /// 保存指定视频的设置。
  Future<void> save(String vodId) async {
    if (vodId.isEmpty) return;
    final SharedPreferences p = await SharedPreferences.getInstance();
    final String prefix = keyPrefix(vodId);
    await p.setBool('${prefix}_intro_enabled', introEnabled);
    await p.setInt('${prefix}_intro_seconds', introSeconds);
    await p.setBool('${prefix}_outro_enabled', outroEnabled);
    await p.setInt('${prefix}_outro_seconds', outroSeconds);
  }

  /// 键名前缀（对齐 iOS `skipSettingsPrefix(for:)`）。
  static String keyPrefix(String vodId) => 'skip_$vodId';
}

/// 片头片尾跳过判定（纯逻辑，便于单测；对齐 iOS 播放中两处判定）。
class SkipTrigger {
  /// 构造。
  const SkipTrigger();

  /// 片头判定：首次进入且当前时刻仍在片头窗口内 → 应跳到片头结束。
  ///
  /// [positionMs] 当前进度 · [settings] 设置 · [alreadyTriggered] 本集是否已触发。
  static bool shouldSkipIntro({
    required int positionMs,
    required SkipSettings settings,
    required bool alreadyTriggered,
  }) {
    if (!settings.introEnabled || settings.introSeconds <= 0) return false;
    if (alreadyTriggered) return false;
    return positionMs < settings.introSeconds * 1000;
  }

  /// 片尾判定：进度进入片尾窗口 → 应自动下一集。
  ///
  /// 对齐 iOS：要求 `duration > 0 && position > 0` 且
  /// `position >= duration - outroSeconds*1000`。
  static bool shouldSkipOutro({
    required int positionMs,
    required int durationMs,
    required SkipSettings settings,
    required bool alreadyTriggered,
  }) {
    if (!settings.outroEnabled || settings.outroSeconds <= 0) return false;
    if (alreadyTriggered) return false;
    if (durationMs <= 0 || positionMs <= 0) return false;
    return positionMs >= durationMs - settings.outroSeconds * 1000;
  }
}
