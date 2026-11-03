/// 表现层：播放器控制层视图状态（批次 C · C-02 / C-04）。
///
/// 纯 UI 状态容器：只承载「当前播放状态 + 面板开关 + 选择项」，动作经回调
/// 字段上抛（调用方接线到 [PlayerController] 与业务回调）。`ChangeNotifier`
/// 供 [AnimatedBuilder] / `ListenableBuilder` 刷新。
///
/// 对齐 iOS `PlayerState`（ObservableObject）在控制层的语义子集：
/// 播放/暂停 · 进度 · 倍速 · 清晰度 · 选集 · 内核 · 弹幕开关 · 面板互斥开关。
///
/// UI-F 家族扩充（面板互斥：同屏至多一个）：
///  - UI-F2 片头片尾设置 · UI-F3 弹幕搜索 · UI-F5 字幕设置 · UI-F6 工具快捷菜单
///    （4 跳转 + 4 开关）· S-07 长按倍速。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/player/player.dart';
import '../../../domain/entities/playback/playback_detail.dart';
import '../../../platform/player/skip_settings.dart';
import '../../../platform/player/subtitle_style.dart';
import '../../ui_mode/ui_mode.dart';

/// 播放器控制层视图状态。
class PlayerControlsController extends ChangeNotifier {
  /// 构造（缺省为「未开播」初始态）。
  PlayerControlsController({
    this.title,
    this.subtitle,
    this.form = UiForm.portrait,
    this.isPlaying = false,
    this.isFullscreen = false,
    this.positionMs = 0,
    this.durationMs = 0,
    this.bufferedMs = 0,
    this.isLive = false,
    this.speed = 1.0,
    this.qualities = const <String>[],
    this.selectedQuality = 0,
    this.episodes = const <PlaybackEpisode>[],
    this.currentEpisodeIndex = 0,
    this.backends = const <PlayerBackend>[],
    this.currentBackend,
    this.showDanmaku = false,
    this.hasDanmaku = false,
    this.autoPlayNext = false,
    this.backgroundPlay = false,
    this.pipEnabled = false,
    this.debugOverlay = false,
    this.longPressSpeed = 2.0,
  });

  // ── 标题区 ───────────────────────────────────────────

  /// 默认清晰度标签（对齐 iOS `QualityPickerPanelV2.qualities` 的固定三档）。
  static const List<String> kDefaultQualities = <String>['标清', '高清', '蓝光'];

  /// 按播放地址探测初始清晰度档位（对齐 iOS `PlayerState.detectVideoQuality`）。
  ///
  /// 判定顺序与 iOS 一致：蓝光/4K → 2，高清/1080 → 1，标清/720 及以下 → 0；
  /// **未命中返回 null**（调用方保持当前档，对齐 iOS 不改动语义）。
  static int? detectQualityIndex(String url) {
    final String lower = url.toLowerCase();
    const List<String> bluray = <String>[
      '蓝光',
      'bd',
      'bluray',
      '2160',
      '4k',
      'uhd',
    ];
    for (final String k in bluray) {
      if (lower.contains(k)) return 2;
    }
    const List<String> hd = <String>[
      '高清',
      '1080',
      '超清',
      'hd',
      'fhd',
      'full',
    ];
    for (final String k in hd) {
      if (lower.contains(k)) return 1;
    }
    const List<String> sd = <String>[
      '标清',
      '720',
      '480',
      '360',
      'sd',
      'low',
    ];
    for (final String k in sd) {
      if (lower.contains(k)) return 0;
    }
    return null;
  }

  /// 主标题（剧名）。
  String? title;

  /// 副标题（如「第 3 集 · 默认源」）。
  String? subtitle;

  // ── 形态与播放状态 ───────────────────────────────────

  /// 显示形态（横 / 竖；决定底栏与面板布局）。
  UiForm form;

  /// 是否播放中。
  bool isPlaying;

  /// 是否全屏（决定是否显示顶栏「退出全屏」等）。
  bool isFullscreen;

  /// 方向锁（对齐 iOS `isOrientationLocked`）：锁定后隐藏进度条 / 底栏，
  /// 仅保留解锁按钮，防误触。
  bool orientationLocked = false;

  /// 当前进度（毫秒）。
  int positionMs;

  /// 总时长（毫秒；直播或未知为 0）。
  int durationMs;

  /// 缓冲进度（毫秒）。
  int bufferedMs;

  /// 是否直播流（隐藏拖拽 / 显示直播态）。
  bool isLive;

  // ── 倍速 / 清晰度 / 选集 / 内核 ──────────────────────

  /// 当前倍速。
  double speed;

  /// 可选清晰度文案（如 `标清/高清/蓝光`；空表不可用）。
  List<String> qualities;

  /// 当前清晰度索引。
  int selectedQuality;

  /// 剧集列表。
  List<PlaybackEpisode> episodes;

  /// 当前剧集索引。
  int currentEpisodeIndex;

  /// 可用内核列表（当前端降级链）。
  List<PlayerBackend> backends;

  /// 当前内核（null 表示未开播）。
  PlayerBackend? currentBackend;

  // ── 加载态（UI-F18；对齐 iOS `PlayerState.isLoading` / `loadingMessage`）──

  /// 是否显示中央加载层（对齐 iOS `isLoading`）。
  ///
  /// 缺省 `false`（裸控制器不显示加载层）；播放页进入时经 [showLoading] 置起。
  bool isLoading = false;

  /// 加载提示文案（[isLoading] 为 true 时显示；对齐 iOS `loadingMessage`）。
  String loadingMessage = loadingResolving;

  /// 加载文案：解析播放地址（对齐 iOS `loadingMessage` 默认值）。
  static const String loadingResolving = '正在解析播放地址...';

  /// 加载文案：缓冲首帧（对齐 iOS `正在缓冲首帧...`）。
  static const String loadingFirstFrame = '正在缓冲首帧...';

  /// 加载文案：兼容内核（对齐 iOS `正在使用兼容内核...`）。
  static const String loadingCompatKernel = '正在使用兼容内核...';

  /// 加载文案：获取媒体 / 网盘地址（对齐 iOS `正在获取百度视频地址...`）。
  static const String loadingFetchingUrl = '正在获取视频地址...';

  /// 加载文案：播放失败（对齐 iOS `播放失败`）。
  static const String loadingFailed = '播放失败';

  /// 加载文案：切换内核（对齐 iOS `正在切换 \(engineName)...`）。
  static String loadingSwitchingEngine(String engineName) =>
      '正在切换 $engineName...';

  /// 加载文案：跳转中（对齐 iOS `正在跳转到 \(target)...`；target 为已格式化时长）。
  static String loadingSeeking(String target) => '正在跳转到 $target...';

  // ── 弹幕 ─────────────────────────────────────────────

  /// 弹幕显示开关（会话级）。
  bool showDanmaku;

  /// 该源是否具备弹幕（无弹幕源时隐藏弹幕按钮）。
  bool hasDanmaku;

  // ── 工具快捷菜单开关（UI-F6；对齐 iOS `ToolsQuickMenuV2`）──

  /// 自动连播下一集（契约键 `player_auto_play_next`）。
  bool autoPlayNext;

  /// 后台播放（契约键 `player_background_play`）。
  bool backgroundPlay;

  /// 画中画开关（契约键 `player_pip_enabled`；与「能力可用」[pipAvailable] 区分）。
  bool pipEnabled;

  /// 调试浮层（契约键 `show_debug_overlay`）。
  bool debugOverlay;

  /// 长按倍速档位（契约键 `player_long_press_speed`）。
  double longPressSpeed;

  // ── 片头片尾跳过（UI-F2；按视频独立存储，对齐 iOS `skip_<vodId>_*`）──

  /// 是否自动跳过片头。
  bool skipIntroEnabled = false;

  /// 片头时长（秒）。
  int skipIntroSeconds = 0;

  /// 是否自动跳过片尾。
  bool skipOutroEnabled = false;

  /// 片尾时长（秒）。
  int skipOutroSeconds = 0;

  // ── 字幕（UI-F5）──

  /// 当前外挂字幕名（空串表示未加载）。
  String subtitleFileName = '';

  /// 字幕是否显示。
  bool showSubtitle = true;

  /// 字幕字号（px）。
  double subtitleFontSize = 16;

  /// 字幕颜色档位索引（0 白 / 1 黄 / 2 青）。
  int subtitleColorIndex = 0;

  // ── 画中画 / 字幕（C-05 / C-08 接线，更多面板入口）──

  /// 是否提供画中画入口（[PipStrategy.showsVisualPip]；不可用则入口置灰）。
  bool pipAvailable = false;

  /// 是否处于画中画（[PipController.isInPip] 回填）。
  bool inPip = false;

  /// 是否提供投屏入口（[CastService.isAvailable]；不可用则隐藏顶栏投屏图标）。
  bool castAvailable = false;

  // ── 面板开关（互斥：同屏至多一个）────────────────────

  bool _showEpisodePicker = false;
  bool _showQualityPicker = false;
  bool _showSpeedPicker = false;
  bool _showEnginePicker = false;
  bool _showDanmakuSettings = false;
  bool _showToolsMenu = false;
  bool _showLongPressSpeedSettings = false;
  bool _showSkipSettings = false;
  bool _showDanmakuSearch = false;
  bool _showSubtitleSettings = false;

  // ── 动作回调（调用方接线；null 表示不可用/禁用）──────

  VoidCallback? onTogglePlay;
  VoidCallback? onPrevEpisode;
  VoidCallback? onNextEpisode;
  VoidCallback? onToggleFullscreen;
  VoidCallback? onBack;
  VoidCallback? onCast;
  VoidCallback? onToggleDanmaku;
  VoidCallback? onToggleDanmakuSettings;
  VoidCallback? onToggleToolsMenu;
  VoidCallback? onToggleOrientationLock;

  /// 画中画切换回调（进入 / 退出；null 表示不可用）。
  VoidCallback? onTogglePip;

  /// 发送弹幕回调（null 表示不可用）。
  VoidCallback? onSendDanmaku;

  /// 加载字幕回调（null 表示不可用）。
  VoidCallback? onLoadSubtitle;

  /// 清除已加载字幕（UI-F5）。
  VoidCallback? onClearSubtitle;

  /// 字幕设置变更回调（字号 / 颜色 / 显示开关）。
  ValueChanged<SubtitleStyle>? onSubtitleStyleChanged;

  /// 工具菜单开关回调（UI-F6；null 表示不可变）。
  ValueChanged<bool>? onToggleAutoPlayNext;

  /// 后台播放开关回调。
  ValueChanged<bool>? onToggleBackgroundPlay;

  /// 画中画开关回调（写契约键，与「临时进入 PiP」区分）。
  ValueChanged<bool>? onTogglePipEnabled;

  /// 调试浮层开关回调。
  ValueChanged<bool>? onToggleDebugOverlay;

  /// 长按倍速档位变更回调（UI-F20 / S-07）。
  ValueChanged<double>? onSelectLongPressSpeed;

  /// 片头片尾设置变更回调（UI-F2）。
  ValueChanged<SkipSettings>? onSkipSettingsChanged;

  /// 进度拖拽结束回调（毫秒）。
  void Function(int positionMs)? onSeek;

  /// 选集回调（索引）。
  void Function(int index)? onSelectEpisode;

  /// 清晰度回调（索引）。
  void Function(int index)? onSelectQuality;

  /// 倍速回调。
  void Function(double speed)? onSelectSpeed;

  /// 内核回调。
  void Function(PlayerBackend backend)? onSelectBackend;

  // ── 只读派生 ─────────────────────────────────────────

  /// 进度百分比（0.0 ~ 1.0；直播 / 未知时长恒 0）。
  double get progress {
    if (isLive || durationMs <= 0) return 0;
    return (positionMs / durationMs).clamp(0.0, 1.0);
  }

  /// 缓冲百分比（0.0 ~ 1.0）。
  double get buffered {
    if (isLive || durationMs <= 0) return 0;
    return (bufferedMs / durationMs).clamp(0.0, 1.0);
  }

  /// 倍速显示文案（如 `1.0x` / `1.25x`；尾零裁剪）。
  String get speedDisplayText {
    final String s = speed.toStringAsFixed(2);
    final String trimmed = s.endsWith('.00')
        ? s.substring(0, s.length - 3)
        : s.endsWith('0')
            ? s.substring(0, s.length - 1)
            : s;
    return '${trimmed}x';
  }

  /// 当前清晰度文案（无可用清晰度时回「默认」）。
  String get qualityDisplayText {
    if (qualities.isEmpty) return '默认';
    final int i = selectedQuality.clamp(0, qualities.length - 1);
    return qualities[i];
  }

  /// 当前内核按钮文案（未开播显示「内核」）。
  String get backendDisplayText {
    final PlayerBackend? b = currentBackend;
    if (b == null) return '内核';
    return b.shortName; // P-芯6：读后端元数据
  }

  /// 当前播放位置时间文案（`HH:MM:SS` / `MM:SS`）。
  String get positionText => formatTime(positionMs);

  /// 总时长时间文案（未知时长显示 `--:--`）。
  String get durationText => durationMs <= 0 ? '--:--' : formatTime(durationMs);

  /// 是否有上一集 / 下一集。
  bool get hasPrevEpisode => currentEpisodeIndex > 0;
  bool get hasNextEpisode =>
      currentEpisodeIndex >= 0 && currentEpisodeIndex < episodes.length - 1;

  /// 是否有可用清晰度。
  bool get hasQuality => qualities.isNotEmpty;

  /// 是否有可用内核。
  bool get hasBackend => backends.isNotEmpty;

  // ── 面板开关访问 ─────────────────────────────────────

  bool get showEpisodePicker => _showEpisodePicker;
  bool get showQualityPicker => _showQualityPicker;
  bool get showSpeedPicker => _showSpeedPicker;
  bool get showEnginePicker => _showEnginePicker;
  bool get showDanmakuSettings => _showDanmakuSettings;
  bool get showToolsMenu => _showToolsMenu;
  bool get showLongPressSpeedSettings => _showLongPressSpeedSettings;
  bool get showSkipSettings => _showSkipSettings;
  bool get showDanmakuSearch => _showDanmakuSearch;
  bool get showSubtitleSettings => _showSubtitleSettings;

  /// 是否任一面板打开（控制层据此隐藏自动消失逻辑）。
  bool get hasAnyPanelOpen =>
      _showEpisodePicker ||
      _showQualityPicker ||
      _showSpeedPicker ||
      _showEnginePicker ||
      _showDanmakuSettings ||
      _showToolsMenu ||
      _showLongPressSpeedSettings ||
      _showSkipSettings ||
      _showDanmakuSearch ||
      _showSubtitleSettings;

  // ── 状态更新（调用方 / 播放器事件接线）────────────────

  /// 批量更新播放进度（对齐 iOS `PlayerProgress` 回调）。
  void updateProgress({
    required int positionMs,
    required int durationMs,
    int? bufferedMs,
    bool? isLive,
  }) {
    this.positionMs = positionMs;
    this.durationMs = durationMs;
    this.bufferedMs = bufferedMs ?? this.bufferedMs;
    this.isLive = isLive ?? this.isLive;
    notifyListeners();
  }

  /// 更新播放状态（对齐 iOS `PlayerState` 回调）。
  void updatePlaying(bool playing) {
    if (isPlaying == playing) return;
    isPlaying = playing;
    notifyListeners();
  }

  /// 拖动预览：仅刷新进度显示，不触发实际 seek（对齐 iOS 拖动中实时回显）。
  ///
  /// 目标位置钳制在 `0 ~ durationMs`；值未变则不通知（避免拖动中无谓重建）。
  void previewSeek(int positionMs) {
    final int clamped =
        durationMs <= 0 ? positionMs : positionMs.clamp(0, durationMs);
    if (this.positionMs == clamped) return;
    this.positionMs = clamped;
    notifyListeners();
  }

  /// 进入加载态并设置文案（对齐 iOS `isLoading = true` + `loadingMessage = ...`）。
  ///
  /// 文案未变也会通知（加载层可能由隐藏转为显示）。
  void showLoading([String message = loadingResolving]) {
    isLoading = true;
    loadingMessage = message;
    notifyListeners();
  }

  /// 退出加载态（幂等；对齐 iOS `isLoading = false`）。
  void hideLoading() {
    if (!isLoading) return;
    isLoading = false;
    notifyListeners();
  }

  /// 设置形态（横竖切换时由调用方注入）。
  void setForm(UiForm form) {
    if (this.form == form) return;
    this.form = form;
    notifyListeners();
  }

  /// 设置方向锁（播放页顶栏锁定按钮 / 状态同步）。
  void setOrientationLocked(bool locked) {
    if (orientationLocked == locked) return;
    orientationLocked = locked;
    notifyListeners();
  }

  /// 设置弹幕开关（会话级；播放页底栏「弹」按钮切换）。
  void setDanmakuEnabled(bool enabled) {
    if (showDanmaku == enabled) return;
    showDanmaku = enabled;
    notifyListeners();
  }

  /// 回填当前倍速（长按倍速等外部改速后同步显示；不触发 [onSelectSpeed]）。
  void applySpeed(double value) {
    if (speed == value) return;
    speed = value;
    notifyListeners();
  }

  /// 回填画中画状态（进入 / 退出后同步入口图标）。
  void setInPip(bool value) {
    if (inPip == value) return;
    inPip = value;
    notifyListeners();
  }

  /// 选集重开成功后回填（当前集 + 副标题；不再触发 [onSelectEpisode]）。
  void applyEpisode(int index, {String? subtitle}) {
    if (index >= 0 && index < episodes.length) currentEpisodeIndex = index;
    if (subtitle != null) this.subtitle = subtitle;
    notifyListeners();
  }

  /// 选择剧集（先回调，失败由调用方回滚）。
  void selectEpisode(int index) {
    if (index < 0 || index >= episodes.length) return;
    currentEpisodeIndex = index;
    _showEpisodePicker = false;
    onSelectEpisode?.call(index);
    notifyListeners();
  }

  /// 选择清晰度。
  void selectQuality(int index) {
    if (index < 0 || index >= qualities.length) return;
    selectedQuality = index;
    _showQualityPicker = false;
    onSelectQuality?.call(index);
    notifyListeners();
  }

  /// 选择倍速。
  void selectSpeed(double value) {
    speed = value;
    _showSpeedPicker = false;
    onSelectSpeed?.call(value);
    notifyListeners();
  }

  /// 选择内核。
  void selectBackend(PlayerBackend backend) {
    if (!backends.contains(backend)) return;
    currentBackend = backend;
    _showEnginePicker = false;
    onSelectBackend?.call(backend);
    notifyListeners();
  }

  /// 切换播放 / 暂停（禁用态无回调时忽略）。
  void togglePlay() => onTogglePlay?.call();

  /// 上一集 / 下一集。
  void goPrevEpisode() => onPrevEpisode?.call();
  void goNextEpisode() => onNextEpisode?.call();

  // ── 面板互斥开关 ─────────────────────────────────────

  /// 打开选集面板（关闭其余面板）。
  void openEpisodePicker() => _openOnly(() => _showEpisodePicker = true);

  /// 打开清晰度面板。
  void openQualityPicker() => _openOnly(() => _showQualityPicker = true);

  /// 打开倍速面板。
  void openSpeedPicker() => _openOnly(() => _showSpeedPicker = true);

  /// 打开内核面板。
  void openEnginePicker() => _openOnly(() => _showEnginePicker = true);

  /// 打开弹幕设置面板。
  void openDanmakuSettings() => _openOnly(() => _showDanmakuSettings = true);

  /// 打开「更多」菜单。
  void openToolsMenu() => _openOnly(() => _showToolsMenu = true);

  /// 打开长按倍速设置面板（UI-F6 → S-07）。
  void openLongPressSpeedSettings() =>
      _openOnly(() => _showLongPressSpeedSettings = true);

  /// 打开片头片尾设置面板（UI-F2）。
  void openSkipSettings() => _openOnly(() => _showSkipSettings = true);

  /// 打开弹幕搜索面板（UI-F3）。
  void openDanmakuSearch() => _openOnly(() => _showDanmakuSearch = true);

  /// 打开字幕设置面板（UI-F5）。
  void openSubtitleSettings() => _openOnly(() => _showSubtitleSettings = true);

  /// 关闭全部面板。
  void closeAllPanels() {
    if (!hasAnyPanelOpen) return;
    _showEpisodePicker = false;
    _showQualityPicker = false;
    _showSpeedPicker = false;
    _showEnginePicker = false;
    _showDanmakuSettings = false;
    _showToolsMenu = false;
    _showLongPressSpeedSettings = false;
    _showSkipSettings = false;
    _showDanmakuSearch = false;
    _showSubtitleSettings = false;
    notifyListeners();
  }

  // ── 工具菜单开关（UI-F6；先回填本地再上抛，保证即时响应）──

  /// 切换自动连播（回填 + 上抛持久化）。
  void setAutoPlayNext(bool value) {
    if (autoPlayNext == value) return;
    autoPlayNext = value;
    onToggleAutoPlayNext?.call(value);
    notifyListeners();
  }

  /// 切换后台播放。
  void setBackgroundPlay(bool value) {
    if (backgroundPlay == value) return;
    backgroundPlay = value;
    onToggleBackgroundPlay?.call(value);
    notifyListeners();
  }

  /// 切换画中画开关。
  void setPipEnabled(bool value) {
    if (pipEnabled == value) return;
    pipEnabled = value;
    onTogglePipEnabled?.call(value);
    notifyListeners();
  }

  /// 切换调试浮层。
  void setDebugOverlay(bool value) {
    if (debugOverlay == value) return;
    debugOverlay = value;
    onToggleDebugOverlay?.call(value);
    notifyListeners();
  }

  /// 选择长按倍速档位（回填并关闭面板）。
  void selectLongPressSpeed(double value) {
    longPressSpeed = value;
    _showLongPressSpeedSettings = false;
    onSelectLongPressSpeed?.call(value);
    notifyListeners();
  }

  /// 更新片头片尾设置（回填 + 上抛持久化；面板内联编辑不关面板）。
  void updateSkipSettings(SkipSettings value) {
    skipIntroEnabled = value.introEnabled;
    skipIntroSeconds = value.introSeconds;
    skipOutroEnabled = value.outroEnabled;
    skipOutroSeconds = value.outroSeconds;
    onSkipSettingsChanged?.call(value);
    notifyListeners();
  }

  /// 更新字幕样式（回填 + 上抛；面板内联编辑不关面板）。
  void updateSubtitleStyle(SubtitleStyle value) {
    showSubtitle = value.visible;
    subtitleFontSize = value.fontSize;
    subtitleColorIndex = value.colorIndex;
    onSubtitleStyleChanged?.call(value);
    notifyListeners();
  }

  /// 当前字幕样式快照。
  SubtitleStyle get subtitleStyle => SubtitleStyle(
        visible: showSubtitle,
        fontSize: subtitleFontSize,
        colorIndex: subtitleColorIndex,
      );

  /// 当前片头片尾设置快照。
  SkipSettings get skipSettings => SkipSettings(
        introEnabled: skipIntroEnabled,
        introSeconds: skipIntroSeconds,
        outroEnabled: skipOutroEnabled,
        outroSeconds: skipOutroSeconds,
      );

  void _openOnly(VoidCallback open) {
    final bool wasOpen = hasAnyPanelOpen;
    closeAllPanels();
    open();
    if (!wasOpen) notifyListeners();
  }

  // ── 内部工具 ─────────────────────────────────────────

  static String formatTime(int ms) {
    final int totalSec = ms ~/ 1000;
    final int h = totalSec ~/ 3600;
    final int m = (totalSec % 3600) ~/ 60;
    final int s = totalSec % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }
}
