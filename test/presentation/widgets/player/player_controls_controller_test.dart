/// 批次 C · C-02/C-04：播放器控制层视图状态容器（派生值 / 面板互斥 / 回调上抛）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/domain/entities/playback/playback_detail.dart';
import 'package:vbox/platform/player/skip_settings.dart';
import 'package:vbox/platform/player/subtitle_style.dart';
import 'package:vbox/presentation/ui_mode/ui_mode.dart';
import 'package:vbox/presentation/widgets/player/player_controls_controller.dart';

void main() {
  group('派生值', () {
    test('progress 直播 / 未知时长恒 0', () {
      final PlayerControlsController c = PlayerControlsController(
        isLive: true,
        positionMs: 5000,
        durationMs: 10000,
      );
      expect(c.progress, 0);
      c.isLive = false;
      c.durationMs = 0;
      expect(c.progress, 0);
    });

    test('progress 正常比例', () {
      final PlayerControlsController c = PlayerControlsController(
        positionMs: 5000,
        durationMs: 10000,
      );
      expect(c.progress, 0.5);
    });

    test('buffered 直播恒 0', () {
      final PlayerControlsController c = PlayerControlsController(
        isLive: true,
        bufferedMs: 5000,
        durationMs: 10000,
      );
      expect(c.buffered, 0);
    });

    test('speedDisplayText 尾零裁剪', () {
      expect(PlayerControlsController(speed: 1.0).speedDisplayText, '1x');
      expect(PlayerControlsController(speed: 1.25).speedDisplayText, '1.25x');
      expect(PlayerControlsController(speed: 1.5).speedDisplayText, '1.5x');
      expect(PlayerControlsController(speed: 2.0).speedDisplayText, '2x');
      expect(PlayerControlsController(speed: 0.75).speedDisplayText, '0.75x');
    });

    test('qualityDisplayText 空回默认 / 越界钳制', () {
      expect(PlayerControlsController().qualityDisplayText, '默认');
      final PlayerControlsController c = PlayerControlsController(
        qualities: const <String>['标清', '高清', '蓝光'],
        selectedQuality: 1,
      );
      expect(c.qualityDisplayText, '高清');
      c.selectedQuality = 99;
      expect(c.qualityDisplayText, '蓝光'); // clamp 到末尾
    });

    test('backendDisplayText 四后端映射', () {
      expect(PlayerControlsController().backendDisplayText, '内核');
      expect(
        PlayerControlsController(currentBackend: PlayerBackend.media3)
            .backendDisplayText,
        'Media3',
      );
      expect(
        PlayerControlsController(currentBackend: PlayerBackend.libVLC)
            .backendDisplayText,
        'VLC',
      );
      expect(
        PlayerControlsController(currentBackend: PlayerBackend.libmpv)
            .backendDisplayText,
        'MPV',
      );
      expect(
        PlayerControlsController(currentBackend: PlayerBackend.nativeiOS)
            .backendDisplayText,
        '原生',
      );
    });

    test('positionText / durationText 时间格式', () {
      expect(PlayerControlsController(positionMs: 0).positionText, '00:00');
      expect(PlayerControlsController(positionMs: 61000).positionText, '01:01');
      expect(
        PlayerControlsController(positionMs: 3661000).positionText,
        '01:01:01',
      );
      expect(PlayerControlsController(durationMs: 0).durationText, '--:--');
      expect(PlayerControlsController(durationMs: 60000).durationText, '01:00');
    });

    test('hasPrevEpisode / hasNextEpisode 边界', () {
      const List<PlaybackEpisode> eps = <PlaybackEpisode>[
        PlaybackEpisode(name: '第1集', url: 'http://x/1'),
        PlaybackEpisode(name: '第2集', url: 'http://x/2'),
        PlaybackEpisode(name: '第3集', url: 'http://x/3'),
      ];
      final PlayerControlsController c =
          PlayerControlsController(episodes: eps, currentEpisodeIndex: 0);
      expect(c.hasPrevEpisode, isFalse);
      expect(c.hasNextEpisode, isTrue);

      c.currentEpisodeIndex = 1;
      expect(c.hasPrevEpisode, isTrue);
      expect(c.hasNextEpisode, isTrue);

      c.currentEpisodeIndex = 2;
      expect(c.hasPrevEpisode, isTrue);
      expect(c.hasNextEpisode, isFalse);
    });

    test('hasQuality / hasBackend', () {
      expect(PlayerControlsController().hasQuality, isFalse);
      expect(PlayerControlsController().hasBackend, isFalse);
      expect(
        PlayerControlsController(qualities: const <String>['x']).hasQuality,
        isTrue,
      );
      expect(
        PlayerControlsController(backends: const <PlayerBackend>[PlayerBackend.media3])
            .hasBackend,
        isTrue,
      );
    });
  });

  group('状态更新', () {
    test('updateProgress 更新并通知（保留可选未传字段）', () {
      final PlayerControlsController c = PlayerControlsController(bufferedMs: 100);
      int notified = 0;
      c.addListener(() => notified++);
      c.updateProgress(positionMs: 1000, durationMs: 2000, bufferedMs: 1500);
      expect(c.positionMs, 1000);
      expect(c.durationMs, 2000);
      expect(c.bufferedMs, 1500);
      expect(c.isLive, isFalse);
      c.updateProgress(positionMs: 2000, durationMs: 2000);
      expect(c.bufferedMs, 1500); // 未传 buffered 保留
      expect(notified, 2);
    });

    test('updatePlaying 无变化不通知', () {
      final PlayerControlsController c = PlayerControlsController();
      int notified = 0;
      c.addListener(() => notified++);
      c.updatePlaying(false); // 已是 false
      expect(notified, 0);
      c.updatePlaying(true);
      expect(notified, 1);
      expect(c.isPlaying, isTrue);
    });

    test('setForm 无变化不通知', () {
      final PlayerControlsController c = PlayerControlsController();
      int notified = 0;
      c.addListener(() => notified++);
      c.setForm(UiForm.portrait); // 已是 portrait
      expect(notified, 0);
      c.setForm(UiForm.landscape);
      expect(notified, 1);
      expect(c.form, UiForm.landscape);
    });

    test('setOrientationLocked 去重通知', () {
      final PlayerControlsController c = PlayerControlsController();
      int notified = 0;
      c.addListener(() => notified++);
      c.setOrientationLocked(false); // 已是 false
      expect(notified, 0);
      c.setOrientationLocked(true);
      expect(c.orientationLocked, isTrue);
      expect(notified, 1);
    });

    test('setDanmakuEnabled 去重通知', () {
      final PlayerControlsController c = PlayerControlsController();
      int notified = 0;
      c.addListener(() => notified++);
      c.setDanmakuEnabled(false); // 已是 false
      expect(notified, 0);
      c.setDanmakuEnabled(true);
      expect(c.showDanmaku, isTrue);
      expect(notified, 1);
    });

    test('applyEpisode 回填当前集与副标题（不触发 onSelectEpisode）', () {
      const List<PlaybackEpisode> eps = <PlaybackEpisode>[
        PlaybackEpisode(name: '1', url: 'u1'),
        PlaybackEpisode(name: '2', url: 'u2'),
      ];
      int? selected;
      final PlayerControlsController c = PlayerControlsController(episodes: eps);
      c.onSelectEpisode = (int i) => selected = i;
      c.applyEpisode(1, subtitle: '第 2 集');
      expect(c.currentEpisodeIndex, 1);
      expect(c.subtitle, '第 2 集');
      expect(selected, isNull); // 回填不重入回调
    });

    test('applyEpisode 越界索引不改当前集', () {
      const List<PlaybackEpisode> eps = <PlaybackEpisode>[
        PlaybackEpisode(name: '1', url: 'u1'),
      ];
      final PlayerControlsController c = PlayerControlsController(episodes: eps);
      c.applyEpisode(5);
      expect(c.currentEpisodeIndex, 0);
    });
  });

  group('选择动作', () {
    test('selectEpisode 合法索引回调 + 关闭面板', () {
      const List<PlaybackEpisode> eps = <PlaybackEpisode>[
        PlaybackEpisode(name: '1', url: 'u1'),
        PlaybackEpisode(name: '2', url: 'u2'),
      ];
      int? selected;
      final PlayerControlsController c = PlayerControlsController(episodes: eps);
      c.onSelectEpisode = (int i) => selected = i;
      c.openEpisodePicker();
      c.selectEpisode(1);
      expect(selected, 1);
      expect(c.currentEpisodeIndex, 1);
      expect(c.showEpisodePicker, isFalse);
    });

    test('selectEpisode 越界忽略', () {
      const List<PlaybackEpisode> eps = <PlaybackEpisode>[
        PlaybackEpisode(name: '1', url: 'u1'),
      ];
      int? selected;
      final PlayerControlsController c = PlayerControlsController(episodes: eps);
      c.onSelectEpisode = (int i) => selected = i;
      c.selectEpisode(5);
      expect(selected, isNull);
      c.selectEpisode(-1);
      expect(selected, isNull);
    });

    test('selectQuality / selectSpeed / selectBackend 回调 + 关闭面板', () {
      int? q;
      double? sp;
      PlayerBackend? b;
      final PlayerControlsController c = PlayerControlsController(
        qualities: const <String>['标清', '高清'],
        backends: const <PlayerBackend>[PlayerBackend.media3, PlayerBackend.libVLC],
      );
      c.onSelectQuality = (int i) => q = i;
      c.onSelectSpeed = (double s) => sp = s;
      c.onSelectBackend = (PlayerBackend x) => b = x;
      c.selectQuality(1);
      expect(q, 1);
      expect(c.selectedQuality, 1);
      c.selectSpeed(1.5);
      expect(sp, 1.5);
      expect(c.speed, 1.5);
      c.selectBackend(PlayerBackend.libVLC);
      expect(b, PlayerBackend.libVLC);
      expect(c.currentBackend, PlayerBackend.libVLC);
    });

    test('selectQuality 越界忽略', () {
      int? q;
      final PlayerControlsController c = PlayerControlsController(
        qualities: const <String>['标清'],
      );
      c.onSelectQuality = (int i) => q = i;
      c.selectQuality(3);
      expect(q, isNull);
    });

    test('selectBackend 列表外忽略', () {
      PlayerBackend? b;
      final PlayerControlsController c = PlayerControlsController(
        backends: const <PlayerBackend>[PlayerBackend.media3],
      );
      c.onSelectBackend = (PlayerBackend x) => b = x;
      c.selectBackend(PlayerBackend.libmpv); // 不在列表
      expect(b, isNull);
    });

    test('togglePlay / goPrev / goNext 经回调上抛', () {
      int play = 0, prev = 0, next = 0;
      final PlayerControlsController c = PlayerControlsController();
      c.onTogglePlay = () => play++;
      c.onPrevEpisode = () => prev++;
      c.onNextEpisode = () => next++;
      c.togglePlay();
      c.goPrevEpisode();
      c.goNextEpisode();
      expect(play, 1);
      expect(prev, 1);
      expect(next, 1);
    });
  });

  group('面板互斥', () {
    PlayerControlsController controller() => PlayerControlsController();

    test('openEpisodePicker 关闭其它面板', () {
      final PlayerControlsController c = controller();
      c.openQualityPicker();
      expect(c.showQualityPicker, isTrue);
      c.openEpisodePicker();
      expect(c.showEpisodePicker, isTrue);
      expect(c.showQualityPicker, isFalse);
    });

    test('hasAnyPanelOpen 聚合', () {
      final PlayerControlsController c = controller();
      expect(c.hasAnyPanelOpen, isFalse);
      c.openSpeedPicker();
      expect(c.hasAnyPanelOpen, isTrue);
    });

    test('closeAllPanels 关闭全部', () {
      final PlayerControlsController c = controller();
      c.openToolsMenu();
      expect(c.showToolsMenu, isTrue);
      c.closeAllPanels();
      expect(c.hasAnyPanelOpen, isFalse);
    });

    test('逐个打开六种面板', () {
      final PlayerControlsController c = controller();
      c.openEpisodePicker();
      expect(c.showEpisodePicker, isTrue);
      c.openQualityPicker();
      expect(c.showQualityPicker, isTrue);
      c.openSpeedPicker();
      expect(c.showSpeedPicker, isTrue);
      c.openEnginePicker();
      expect(c.showEnginePicker, isTrue);
      c.openDanmakuSettings();
      expect(c.showDanmakuSettings, isTrue);
      c.openToolsMenu();
      expect(c.showToolsMenu, isTrue);
    });

    // ── UI-F6 跳转目标面板（新增 4 个，同属互斥族）──
    test('逐个打开 UI-F 新增四面板', () {
      final PlayerControlsController c = controller();
      c.openLongPressSpeedSettings();
      expect(c.showLongPressSpeedSettings, isTrue);
      expect(c.hasAnyPanelOpen, isTrue);
      c.openSkipSettings();
      expect(c.showSkipSettings, isTrue);
      expect(c.showLongPressSpeedSettings, isFalse);
      c.openDanmakuSearch();
      expect(c.showDanmakuSearch, isTrue);
      c.openSubtitleSettings();
      expect(c.showSubtitleSettings, isTrue);
      expect(c.hasAnyPanelOpen, isTrue);
    });

    test('工具菜单开关面板与其它面板互斥', () {
      final PlayerControlsController c = controller();
      c.openToolsMenu();
      c.openSpeedPicker();
      expect(c.showToolsMenu, isFalse);
      expect(c.showSpeedPicker, isTrue);
    });
  });

  group('UI-F6 工具菜单开关', () {
    test('切换即回填并上抛', () {
      final List<bool> auto = <bool>[];
      final List<bool> bg = <bool>[];
      final List<bool> pip = <bool>[];
      final List<bool> dbg = <bool>[];
      final PlayerControlsController c = PlayerControlsController()
        ..onToggleAutoPlayNext = auto.add
        ..onToggleBackgroundPlay = bg.add
        ..onTogglePipEnabled = pip.add
        ..onToggleDebugOverlay = dbg.add;
      c.setAutoPlayNext(true);
      c.setBackgroundPlay(true);
      c.setPipEnabled(true);
      c.setDebugOverlay(true);
      expect(c.autoPlayNext, isTrue);
      expect(c.backgroundPlay, isTrue);
      expect(c.pipEnabled, isTrue);
      expect(c.debugOverlay, isTrue);
      expect(auto, <bool>[true]);
      expect(bg, <bool>[true]);
      expect(pip, <bool>[true]);
      expect(dbg, <bool>[true]);
    });

    test('同值重复设置不通知', () {
      int notified = 0;
      final PlayerControlsController c = PlayerControlsController()
        ..addListener(() => notified++);
      c.setAutoPlayNext(false);
      expect(notified, 0);
      c.setAutoPlayNext(true);
      expect(notified, 1);
    });
  });

  group('UI-F2 片头片尾 / UI-F5 字幕', () {
    test('selectLongPressSpeed 回填并关闭面板', () {
      double? picked;
      final PlayerControlsController c = PlayerControlsController()
        ..onSelectLongPressSpeed = (double v) => picked = v;
      c.openLongPressSpeedSettings();
      c.selectLongPressSpeed(3.0);
      expect(c.longPressSpeed, 3.0);
      expect(c.showLongPressSpeedSettings, isFalse);
      expect(picked, 3.0);
    });

    test('updateSkipSettings 回填快照并上抛', () {
      SkipSettings? captured;
      final PlayerControlsController c = PlayerControlsController()
        ..onSkipSettingsChanged = (SkipSettings v) => captured = v;
      c.updateSkipSettings(const SkipSettings(
        introEnabled: true,
        introSeconds: 90,
        outroEnabled: true,
        outroSeconds: 20,
      ));
      expect(c.skipSettings.introEnabled, isTrue);
      expect(c.skipSettings.introSeconds, 90);
      expect(c.skipSettings.outroSeconds, 20);
      expect(captured, isNotNull);
      expect(captured!.outroEnabled, isTrue);
    });

    test('updateSubtitleStyle 回填并暴露快照', () {
      SubtitleStyle? captured;
      final PlayerControlsController c = PlayerControlsController()
        ..onSubtitleStyleChanged = (SubtitleStyle v) => captured = v;
      c.updateSubtitleStyle(
        const SubtitleStyle().copyWith(visible: false, fontSize: 20, colorIndex: 2),
      );
      expect(c.showSubtitle, isFalse);
      expect(c.subtitleFontSize, 20);
      expect(c.subtitleColorIndex, 2);
      expect(c.subtitleStyle.fontSize, 20);
      expect(captured, isNotNull);
    });
  });

  group('构造默认值', () {
    test('未开播初始态', () {
      final PlayerControlsController c = PlayerControlsController();
      expect(c.title, isNull);
      expect(c.isPlaying, isFalse);
      expect(c.isFullscreen, isFalse);
      expect(c.positionMs, 0);
      expect(c.durationMs, 0);
      expect(c.isLive, isFalse);
      expect(c.speed, 1.0);
      expect(c.qualities, isEmpty);
      expect(c.episodes, isEmpty);
      expect(c.currentBackend, isNull);
      expect(c.showDanmaku, isFalse);
      expect(c.hasDanmaku, isFalse);
    });
  });

  group('清晰度（R-04）', () {
    test('默认三档标签（对齐 iOS 固定档位）', () {
      expect(PlayerControlsController.kDefaultQualities, <String>['标清', '高清', '蓝光']);
    });

    test('detectQualityIndex 按地址探测档位', () {
      expect(
        PlayerControlsController.detectQualityIndex('http://x/蓝光/1.m3u8'),
        2,
      );
      expect(
        PlayerControlsController.detectQualityIndex('http://x/2160p/a.mp4'),
        2,
      );
      expect(
        PlayerControlsController.detectQualityIndex('http://x/1080p/a.mp4'),
        1,
      );
      expect(
        PlayerControlsController.detectQualityIndex('http://x/720/标清.mp4'),
        0,
      );
    });

    test('detectQualityIndex 未命中返回 null（保持当前档）', () {
      expect(
        PlayerControlsController.detectQualityIndex('http://x/stream/index.m3u8'),
        isNull,
      );
    });

    test('qualityDisplayText 随档位变化', () {
      final PlayerControlsController c = PlayerControlsController()
        ..qualities = PlayerControlsController.kDefaultQualities;
      expect(c.hasQuality, isTrue);
      c.selectQuality(2);
      expect(c.qualityDisplayText, '蓝光');
      c.selectQuality(0);
      expect(c.qualityDisplayText, '标清');
    });
  });

  group('加载态（UI-F18）', () {
    test('showLoading 置起并回填文案；hideLoading 幂等', () {
      final PlayerControlsController c = PlayerControlsController();
      expect(c.isLoading, isFalse);
      c.showLoading();
      expect(c.isLoading, isTrue);
      expect(c.loadingMessage, PlayerControlsController.loadingResolving);
      c.showLoading(PlayerControlsController.loadingFirstFrame);
      expect(c.loadingMessage, PlayerControlsController.loadingFirstFrame);
      c.hideLoading();
      expect(c.isLoading, isFalse);
      // 幂等：重复收起不抛。
      c.hideLoading();
      expect(c.isLoading, isFalse);
    });

    test('文案常量与动态文案对齐 iOS', () {
      expect(PlayerControlsController.loadingResolving, '正在解析播放地址...');
      expect(PlayerControlsController.loadingFirstFrame, '正在缓冲首帧...');
      expect(PlayerControlsController.loadingCompatKernel, '正在使用兼容内核...');
      expect(PlayerControlsController.loadingFetchingUrl, '正在获取视频地址...');
      expect(PlayerControlsController.loadingFailed, '播放失败');
      expect(
        PlayerControlsController.loadingSwitchingEngine('VLC'),
        '正在切换 VLC...',
      );
      expect(PlayerControlsController.loadingSeeking('02:04'), '正在跳转到 02:04...');
    });

    test('formatTime 公开可用（供加载文案复用）', () {
      expect(PlayerControlsController.formatTime(124000), '02:04');
      expect(PlayerControlsController.formatTime(3725000), '01:02:05');
    });
  });
}