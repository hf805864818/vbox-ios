/// 表现层：播放器控制层主视图（批次 C · C-02 / C-04）。
///
/// 组装 [PlayerTopBar] ＋ [PlayerProgressBar] ＋ [PlayerBottomBar] ＋ 各类面板
/// （选集 / 清晰度 / 倍速 / 内核 / 弹幕设置），另含左缘方向锁定覆盖层。
/// 面板摆放随形态：竖屏底部抽屉、横屏右侧滑出。
///
/// 纯受控：全部状态与动作来自 [PlayerControlsController]；视频画面由调用方
/// 经 [videoBuilder] 注入（控制层不关心具体渲染后端）。
///
/// 对齐 iOS `PlayerControlsView`（[PlayerViewsV2.swift](../../../../vbox/Views/PlayerViewsV2.swift#L8313)）：
///  - 方向锁定按钮固定在**左缘垂直居中**（横屏），不在顶栏内；
///  - 锁定态隐藏顶栏 / 进度条 / 底栏 / 面板，仅保留锁按钮（防误触）；
///  - 锁定态点击屏幕仅短暂唤出锁按钮（由 [lockButtonVisible] 驱动，3s 自动隐藏）。
library;

import 'package:flutter/material.dart';

import '../../../domain/entities/player/player.dart';
import '../../../platform/player/danmaku/danmaku_service.dart';
import '../../../platform/player/danmaku/danmaku_settings.dart';
import '../../theme/tokens/colors.dart';
import '../../theme/tokens/radii.dart';
import '../../theme/tokens/spacing.dart';
import '../../ui_mode/ui_mode.dart';
import 'danmaku/danmaku_settings_panel.dart';
import 'panels/player_panels.dart';
import 'player_bottom_bar.dart';
import 'player_controls_controller.dart';
import 'player_loading_overlay.dart';
import 'player_progress_bar.dart';
import 'player_top_bar.dart';

/// 播放器控制层主视图。
class PlayerControlsView extends StatelessWidget {
  /// 构造。
  const PlayerControlsView({
    super.key,
    required this.controller,
    this.videoBuilder,
    this.danmakuBuilder,
    this.danmakuSettings,
    this.onDanmakuSettingsChanged,
    this.danmakuSearch,
    this.danmakuLoadEpisodes,
    this.onSelectDanmakuEpisode,
    this.onLoadSubtitleFile,
    this.lockButtonVisible = true,
    this.controlsVisible = true,
    this.videoGravity = VideoGravityMode.aspectFill,
    this.onCycleVideoGravity,
  });

  /// 控制层视图状态。
  final PlayerControlsController controller;

  /// 视频画面构建器（调用方注入实际渲染视图；null 显示深色占位）。
  final WidgetBuilder? videoBuilder;

  /// 弹幕层构建器（叠于画面之上、控制层之下；null 则不渲染弹幕）。
  final WidgetBuilder? danmakuBuilder;

  /// 当前弹幕设置（弹幕设置面板用；null 时隐藏该面板内容）。
  final DanmakuSettings? danmakuSettings;

  /// 弹幕设置变更回调。
  final ValueChanged<DanmakuSettings>? onDanmakuSettingsChanged;

  /// 弹幕搜索（关键字 → 候选番剧；UI-F3 搜索面板数据源；null 隐藏搜索入口）。
  final Future<List<DanmakuAnimeMatch>> Function(String keyword)? danmakuSearch;

  /// 拉取番剧分集（UI-F3）。
  final Future<List<DanmakuEpisodeInfo>> Function(int animeId)? danmakuLoadEpisodes;

  /// 选定弹幕分集回调（UI-F3）。
  final ValueChanged<DanmakuEpisodeInfo>? onSelectDanmakuEpisode;

  /// 上传本地字幕文件回调（UI-F5 字幕设置面板）。
  final VoidCallback? onLoadSubtitleFile;

  /// 锁定态下锁按钮是否可见（对齐 iOS `showLockButton`：点击屏幕后短暂显示）。
  final bool lockButtonVisible;

  /// 控制层是否可见（自动隐藏用；`false` 时仅保留画面与弹幕层）。
  ///
  /// 任一面板打开时强制可见（面板不得被自动隐藏吞掉）。
  final bool controlsVisible;

  /// 画面拉伸模式（UI-E2，传给顶栏按钮切图标）。
  final VideoGravityMode videoGravity;

  /// 循环切换画面拉伸模式回调（UI-E2；null 隐藏顶栏按钮）。
  final VoidCallback? onCycleVideoGravity;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final UiForm form = controller.form;
        final bool landscape = form.isLandscape;
        final bool locked = controller.orientationLocked;
        // 锁定态：主控制层整体隐藏（对齐 iOS），仅锁按钮独立显隐。
        final bool overlays =
            !locked && (controlsVisible || controller.hasAnyPanelOpen);
        // 锁按钮仅横屏出现；解锁态随控制层可见，锁定态由 lockButtonVisible 控制。
        final bool showLock = landscape && (!locked || lockButtonVisible);
        return ColoredBox(
          color: VboxColors.playerBackground,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // 视频画面（或占位）—— 常驻，不随控制层自动隐藏
              videoBuilder?.call(context) ??
                  const ColoredBox(color: VboxColors.playerBackground),
              // 弹幕层 —— 叠于画面之上、控制层之下（常驻，随开关由调用方决定）
              if (danmakuBuilder != null) danmakuBuilder!.call(context),
              // UI-F18 加载层 —— 叠于画面之上、控制层之下，不拦截手势。
              if (controller.isLoading)
                PlayerLoadingOverlay(message: controller.loadingMessage),
              if (overlays) ...<Widget>[
                // 顶栏
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: PlayerTopBar(
                    form: form,
                    title: controller.title,
                    subtitle: controller.subtitle,
                    onBack: controller.onBack,
                    onCast: controller.onCast,
                    showCast: controller.castAvailable,
                    onRotate: controller.onToggleFullscreen,
                    // UI-D3：画中画入口（能力可用才显示，不支持置灰）。
                    onTogglePip: controller.onTogglePip,
                    showPip: controller.pipAvailable,
                    pipActive: controller.inPip,
                    // UI-E2：屏幕拉伸（对齐 iOS 顶栏右上集群）。
                    videoGravity: videoGravity,
                    onCycleVideoGravity: onCycleVideoGravity,
                    onToolsMenu: controller.onToggleToolsMenu,
                  ),
                ),
                // 底部控制区（进度条 + 底栏）
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _BottomControls(controller: controller),
                ),
                // 面板层
                _PanelHost(
                  controller: controller,
                  landscape: landscape,
                  danmakuSettings: danmakuSettings,
                  onDanmakuSettingsChanged: onDanmakuSettingsChanged,
                  danmakuSearch: danmakuSearch,
                  danmakuLoadEpisodes: danmakuLoadEpisodes,
                  onSelectDanmakuEpisode: onSelectDanmakuEpisode,
                  onLoadSubtitleFile: onLoadSubtitleFile,
                ),
              ],
              // 方向锁定按钮（左缘垂直居中，对齐 iOS 覆盖层定位）
              if (showLock)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: _LockButton(
                    locked: locked,
                    onTap: controller.onToggleOrientationLock,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 方向锁定按钮（左缘垂直居中覆盖层；对齐 iOS `lock.open` / `lock.fill`）。
class _LockButton extends StatelessWidget {
  const _LockButton({required this.locked, this.onTap});

  final bool locked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // UI-D4 辅助功能：锁定 / 解除锁定。
      label: locked ? '解除锁定' : '锁定屏幕',
      button: true,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.only(left: VboxSpacing.xs),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: const BorderRadius.all(
                Radius.circular(VboxRadii.capsule),
              ),
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  locked ? Icons.lock_rounded : Icons.lock_open_rounded,
                  size: 20,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部控制区（进度条 + 底栏；对齐 iOS：无渐变遮罩，直接叠于画面）。
class _BottomControls extends StatelessWidget {
  const _BottomControls({required this.controller});

  final PlayerControlsController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        PlayerProgressBar(
          positionMs: controller.positionMs,
          durationMs: controller.durationMs,
          bufferedMs: controller.bufferedMs,
          isLive: controller.isLive,
          form: controller.form,
          onSeek: controller.onSeek,
        ),
        PlayerBottomBar(controller: controller),
      ],
    );
  }
}

/// 面板宿主：按形态摆放当前打开的面板（竖屏底部抽屉 / 横屏右侧滑出）。
class _PanelHost extends StatelessWidget {
  const _PanelHost({
    required this.controller,
    required this.landscape,
    this.danmakuSettings,
    this.onDanmakuSettingsChanged,
    this.danmakuSearch,
    this.danmakuLoadEpisodes,
    this.onSelectDanmakuEpisode,
    this.onLoadSubtitleFile,
  });

  final PlayerControlsController controller;
  final bool landscape;
  final DanmakuSettings? danmakuSettings;
  final ValueChanged<DanmakuSettings>? onDanmakuSettingsChanged;
  final Future<List<DanmakuAnimeMatch>> Function(String keyword)? danmakuSearch;
  final Future<List<DanmakuEpisodeInfo>> Function(int animeId)?
      danmakuLoadEpisodes;
  final ValueChanged<DanmakuEpisodeInfo>? onSelectDanmakuEpisode;
  final VoidCallback? onLoadSubtitleFile;

  @override
  Widget build(BuildContext context) {
    final Widget? panel = _currentPanel();
    if (panel == null) return const SizedBox.shrink();
    final double? width = landscape ? 380.0 : null;
    return Positioned(
      left: landscape ? null : 0,
      right: 0,
      bottom: 0,
      top: landscape ? 0 : null,
      width: width,
      child: SafeArea(
        top: landscape,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: panel,
        ),
      ),
    );
  }

  Widget? _currentPanel() {
    final void Function() close = controller.closeAllPanels;
    if (controller.showEpisodePicker) {
      return EpisodePickerPanelShell(
        key: const ValueKey<String>('episode'),
        episodes: controller.episodes,
        currentIndex: controller.currentEpisodeIndex,
        onSelect: controller.onSelectEpisode == null
            ? null
            : (int i) => controller.selectEpisode(i),
        onClose: close,
      );
    }
    if (controller.showQualityPicker) {
      return QualityPickerPanel(
        key: const ValueKey<String>('quality'),
        qualities: controller.qualities,
        selectedIndex: controller.selectedQuality,
        onSelect: controller.onSelectQuality == null
            ? null
            : (int i) => controller.selectQuality(i),
        onClose: close,
      );
    }
    if (controller.showSpeedPicker) {
      return SpeedPickerPanel(
        key: const ValueKey<String>('speed'),
        current: controller.speed,
        onSelect: controller.onSelectSpeed == null
            ? null
            : (double s) => controller.selectSpeed(s),
        onClose: close,
      );
    }
    if (controller.showEnginePicker) {
      return EnginePickerPanel(
        key: const ValueKey<String>('engine'),
        backends: controller.backends,
        current: controller.currentBackend,
        onSelect: controller.onSelectBackend == null
            ? null
            : (b) => controller.selectBackend(b),
        onClose: close,
      );
    }
    if (controller.showDanmakuSettings) {
      final DanmakuSettings? s = danmakuSettings;
      if (s == null) return null;
      return PlayerPanelContainer(
        key: const ValueKey<String>('danmaku'),
        title: '弹幕设置',
        onClose: close,
        child: DanmakuSettingsPanelBody(
          settings: s,
          onChanged: onDanmakuSettingsChanged ?? (_) {},
        ),
      );
    }
    if (controller.showToolsMenu) {
      return ToolsQuickMenuPanel(
        key: const ValueKey<String>('tools'),
        controller: controller,
        danmakuSearchAvailable:
            danmakuSearch != null && danmakuLoadEpisodes != null,
        onClose: close,
      );
    }
    // ── UI-F6 跳转目标面板 ─────────────────────────────
    if (controller.showLongPressSpeedSettings) {
      return LongPressSpeedSettingsPanel(
        key: const ValueKey<String>('longPressSpeed'),
        current: controller.longPressSpeed,
        onSelect: controller.onSelectLongPressSpeed == null
            ? null
            : controller.selectLongPressSpeed,
        onClose: close,
      );
    }
    if (controller.showSkipSettings) {
      return SkipSettingsPanel(
        key: const ValueKey<String>('skip'),
        settings: controller.skipSettings,
        onChanged: controller.onSkipSettingsChanged == null
            ? null
            : controller.updateSkipSettings,
        onClose: close,
      );
    }
    if (controller.showDanmakuSearch) {
      final Future<List<DanmakuAnimeMatch>> Function(String)? search =
          danmakuSearch;
      final Future<List<DanmakuEpisodeInfo>> Function(int)? loadEpisodes =
          danmakuLoadEpisodes;
      if (search == null || loadEpisodes == null) return null;
      return DanmakuSearchPanel(
        key: const ValueKey<String>('danmakuSearch'),
        search: search,
        loadEpisodes: loadEpisodes,
        onSelectEpisode: onSelectDanmakuEpisode == null
            ? null
            : (DanmakuEpisodeInfo e) {
                close();
                onSelectDanmakuEpisode!(e);
              },
        onClose: close,
      );
    }
    if (controller.showSubtitleSettings) {
      return SubtitleSettingsPanel(
        key: const ValueKey<String>('subtitle'),
        style: controller.subtitleStyle,
        fileName: controller.subtitleFileName,
        onLoadFile: controller.onLoadSubtitle == null
            ? null
            : (onLoadSubtitleFile ?? controller.onLoadSubtitle),
        onStyleChanged: controller.onSubtitleStyleChanged == null
            ? null
            : controller.updateSubtitleStyle,
        onClear: controller.onClearSubtitle,
        onClose: close,
      );
    }
    return null;
  }
}

/// 弹幕设置面板主体（复用 [DanmakuSettingsPanel] 结构但去壳，供面板宿主嵌入）。
class DanmakuSettingsPanelBody extends StatelessWidget {
  /// 构造。
  const DanmakuSettingsPanelBody({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  /// 当前设置。
  final DanmakuSettings settings;

  /// 变更回调。
  final ValueChanged<DanmakuSettings> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SwitchListTile(
          dense: true,
          title: const Text(
            '弹幕开关',
            style: TextStyle(fontSize: 14, color: Colors.white),
          ),
          value: settings.enabled,
          activeThumbColor: Colors.white,
          onChanged: (bool v) => onChanged(settings.copyWith(enabled: v)),
        ),
        if (settings.enabled) ..._sliders(),
      ],
    );
  }

  List<Widget> _sliders() => <Widget>[
        _slider(
          label: '不透明度 ${(settings.opacity * 100).round()}%',
          value: settings.opacity,
          min: 0.1,
          max: 1.0,
          divisions: 9,
          onChanged: (double v) => onChanged(settings.copyWith(opacity: v)),
        ),
        _slider(
          label: '字号 ${settings.fontSize.round()}px',
          value: settings.fontSize,
          min: 10,
          max: 32,
          divisions: 22,
          onChanged: (double v) => onChanged(settings.copyWith(fontSize: v)),
        ),
        _slider(
          label: '显示区域 ${(settings.area * 100).round()}%',
          value: settings.area,
          min: 0.25,
          max: 1.0,
          divisions: 7,
          onChanged: (double v) => onChanged(settings.copyWith(area: v)),
        ),
        // 弹幕显示速度（对齐 iOS「显示速度」Section：segmented 5 档）。
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text(
            '弹幕显示速度',
            style: TextStyle(fontSize: 13, color: Colors.white70),
          ),
          subtitle: SegmentedButton<int>(
            segments: <ButtonSegment<int>>[
              for (final (int idx, String label)
                  in DanmakuSettings.speedLabels.indexed)
                ButtonSegment<int>(
                  value: idx,
                  label: Text(
                    label,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
            ],
            selected: <int>{
              DanmakuSettings.speedValues.indexOf(
                DanmakuSettings.speedValues.reduce(
                  (double a, double b) =>
                      (a - settings.speed).abs() <= (b - settings.speed).abs()
                          ? a
                          : b,
                ),
              ),
            },
            showSelectedIcon: false,
            onSelectionChanged: (Set<int> selection) => onChanged(
              settings.copyWith(
                speed: DanmakuSettings.speedValues[selection.first],
              ),
            ),
          ),
        ),
        // 弹幕颜色（对齐 iOS「弹幕颜色」Section：segmented 8 档）。
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text(
            '弹幕颜色',
            style: TextStyle(fontSize: 13, color: Colors.white70),
          ),
          subtitle: SegmentedButton<int>(
            segments: <ButtonSegment<int>>[
              for (final (int idx, String label)
                  in DanmakuSettingsPanel.colorLabels.indexed)
                ButtonSegment<int>(
                  value: idx,
                  label: Text(
                    label,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
            selected: <int>{settings.colorMode},
            showSelectedIcon: false,
            onSelectionChanged: (Set<int> selection) =>
                onChanged(settings.copyWith(colorMode: selection.first)),
          ),
        ),
      ];

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) =>
      ListTile(
        dense: true,
        title: Text(
          label,
          style: const TextStyle(fontSize: 13, color: Colors.white70),
        ),
        subtitle: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      );
}
