/// 批次 C · C-02/C-04：播放器控制层 UI（顶栏 / 底栏 / 进度条 / 主视图 / 各面板）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/domain/entities/playback/playback_detail.dart';
import 'package:vbox/platform/player/danmaku/danmaku_item.dart';
import 'package:vbox/platform/player/danmaku/danmaku_lane_engine.dart';
import 'package:vbox/platform/player/danmaku/danmaku_settings.dart';
import 'package:vbox/presentation/theme/theme.dart';
import 'package:vbox/presentation/ui_mode/ui_mode.dart';
import 'package:vbox/presentation/widgets/player/danmaku/danmaku_overlay.dart';
import 'package:vbox/presentation/widgets/player/danmaku/danmaku_settings_panel.dart';
import 'package:vbox/presentation/widgets/player/panels/engine_picker_panel.dart';
import 'package:vbox/presentation/widgets/player/panels/episode_picker_panel.dart';
import 'package:vbox/presentation/widgets/player/panels/player_panel_container.dart';
import 'package:vbox/presentation/widgets/player/panels/quality_picker_panel.dart';
import 'package:vbox/presentation/widgets/player/panels/speed_picker_panel.dart';
import 'package:vbox/presentation/widgets/player/player_bottom_bar.dart';
import 'package:vbox/presentation/widgets/player/player_controls_controller.dart';
import 'package:vbox/presentation/widgets/player/player_controls_view.dart';
import 'package:vbox/presentation/widgets/player/player_progress_bar.dart';
import 'package:vbox/presentation/widgets/player/player_top_bar.dart';

Widget _host(Widget child, {Size size = const Size(1200, 800)}) => MaterialApp(
      theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
      home: Scaffold(
        body: SizedBox(width: size.width, height: size.height, child: child),
      ),
    );

void main() {
  group('PlayerTopBar', () {
    testWidgets('竖屏：标题 + 副标题 + 旋转/投屏/更多按钮', (WidgetTester tester) async {
      await tester.pumpWidget(_host(PlayerTopBar(
        form: UiForm.portrait,
        title: '测试剧',
        subtitle: '第 3 集 · 默认源',
        // 移动端语义：旋转按钮随回调注入显示（桌面端为 null 隐藏）。
        onRotate: () {},
      )));
      expect(find.text('测试剧'), findsOneWidget);
      expect(find.text('第 3 集 · 默认源'), findsOneWidget);
      expect(find.byIcon(Icons.rotate_right_rounded), findsOneWidget);
      expect(find.byIcon(Icons.cast_rounded), findsOneWidget);
      expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);
      // 顶栏不含方向锁按钮（锁定按钮为左缘覆盖层）。
      expect(find.byIcon(Icons.lock_rounded), findsNothing);
      expect(find.byIcon(Icons.lock_open_rounded), findsNothing);
    });

    testWidgets('横屏：旋转图标为「转竖屏」，回调触发', (WidgetTester tester) async {
      bool back = false, cast = false, rotate = false, tools = false;
      await tester.pumpWidget(_host(PlayerTopBar(
        form: UiForm.landscape,
        title: '剧',
        onBack: () => back = true,
        onCast: () => cast = true,
        onRotate: () => rotate = true,
        onToolsMenu: () => tools = true,
      )));
      expect(find.byIcon(Icons.rotate_left_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.rotate_left_rounded));
      expect(rotate, isTrue);
      await tester.tap(find.byIcon(Icons.cast_rounded));
      expect(cast, isTrue);
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      expect(tools, isTrue);
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
      expect(back, isTrue);
    });

    testWidgets('无标题副标题时不渲染文本', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const PlayerTopBar(form: UiForm.portrait)));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('桌面端语义：onRotate 为 null → 隐藏旋转按钮', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const PlayerTopBar(form: UiForm.portrait)));
      expect(find.byIcon(Icons.rotate_right_rounded), findsNothing);
      expect(find.byIcon(Icons.rotate_left_rounded), findsNothing);
    });

    testWidgets('UI-D3 画中画入口：pipEnabled 才显示 / 不支持置灰 / 激活换图标',
        (WidgetTester tester) async {
      // 默认不显示（pipEnabled 未开）。
      await tester.pumpWidget(_host(const PlayerTopBar(form: UiForm.landscape)));
      expect(find.byIcon(Icons.picture_in_picture_alt_outlined), findsNothing);

      // 显示但无回调（能力不支持）→ 置灰。
      await tester.pumpWidget(_host(const PlayerTopBar(
        form: UiForm.landscape,
        showPip: true,
      )));
      final Icon disabled =
          tester.widget<Icon>(find.byIcon(Icons.picture_in_picture_alt_outlined));
      expect(disabled.color, Colors.white.withValues(alpha: 0.3));

      // 有回调 → 可点且触发。
      bool pip = false;
      await tester.pumpWidget(_host(PlayerTopBar(
        form: UiForm.landscape,
        showPip: true,
        onTogglePip: () => pip = true,
      )));
      final Icon enabled =
          tester.widget<Icon>(find.byIcon(Icons.picture_in_picture_alt_outlined));
      expect(enabled.color, Colors.white);
      await tester.tap(find.byIcon(Icons.picture_in_picture_alt_outlined));
      expect(pip, isTrue);

      // 处于画中画 → 换「退出」图标。
      await tester.pumpWidget(_host(PlayerTopBar(
        form: UiForm.landscape,
        showPip: true,
        pipActive: true,
        onTogglePip: () {},
      )));
      expect(find.byIcon(Icons.picture_in_picture_alt_rounded), findsOneWidget);
      expect(find.byIcon(Icons.picture_in_picture_alt_outlined), findsNothing);
    });

    testWidgets('UI-E2 屏幕拉伸入口：回调非空才显示 / 图标随模式切换 / 点击循环',
        (WidgetTester tester) async {
      // 默认不显示（无回调）。
      await tester.pumpWidget(_host(const PlayerTopBar(form: UiForm.landscape)));
      expect(find.byIcon(Icons.open_in_full_rounded), findsNothing);

      // 有回调 → 显示，缺省 aspectFill 图标。
      int taps = 0;
      await tester.pumpWidget(_host(PlayerTopBar(
        form: UiForm.landscape,
        onCycleVideoGravity: () => taps++,
      )));
      expect(find.byIcon(Icons.open_in_full_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.open_in_full_rounded));
      expect(taps, 1);

      // 切到 aspectFit → 宽高比框图标。
      await tester.pumpWidget(_host(PlayerTopBar(
        form: UiForm.landscape,
        videoGravity: VideoGravityMode.aspectFit,
        onCycleVideoGravity: () {},
      )));
      expect(find.byIcon(Icons.aspect_ratio_rounded), findsOneWidget);

      // 切到 resize → 横向拉伸图标。
      await tester.pumpWidget(_host(PlayerTopBar(
        form: UiForm.landscape,
        videoGravity: VideoGravityMode.resize,
        onCycleVideoGravity: () {},
      )));
      expect(find.byIcon(Icons.swap_horiz_rounded), findsOneWidget);
    });
  });

  group('PlayerProgressBar', () {
    testWidgets('可拖拽：时间标签 + Slider', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const PlayerProgressBar(
        positionMs: 5000,
        durationMs: 60000,
        bufferedMs: 30000,
      )));
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('00:05'), findsOneWidget);
      expect(find.text('01:00'), findsOneWidget);
    });

    testWidgets('直播：禁用拖拽 + 直播标签', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const PlayerProgressBar(
        positionMs: 0,
        durationMs: 0,
        isLive: true,
      )));
      expect(find.text('直播'), findsOneWidget);
      final Slider slider =
          tester.widget<Slider>(find.byType(Slider));
      expect(slider.onChanged, isNull);
    });

    testWidgets('拖拽结束回调上抛', (WidgetTester tester) async {
      int? seeked;
      await tester.pumpWidget(_host(PlayerProgressBar(
        positionMs: 0,
        durationMs: 60000,
        onSeek: (int v) => seeked = v,
      )));
      final Slider slider =
          tester.widget<Slider>(find.byType(Slider));
      slider.onChangeEnd!(30000);
      expect(seeked, 30000);
    });
  });

  group('PlayerBottomBar', () {
    testWidgets('竖屏：播放/下一集图标，无引擎按钮', (WidgetTester tester) async {
      final PlayerControlsController c = PlayerControlsController(
        isPlaying: false,
        form: UiForm.portrait,
      );
      await tester.pumpWidget(_host(PlayerBottomBar(controller: c)));
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
      expect(find.text('内核'), findsNothing);
      expect(find.text('请文明发送弹幕'), findsNothing);
    });

    testWidgets('横屏：含引擎按钮 + 弹幕输入', (WidgetTester tester) async {
      final PlayerControlsController c = PlayerControlsController(
        form: UiForm.landscape,
        backends: const <PlayerBackend>[PlayerBackend.media3],
      );
      c.onSelectBackend = (_) {};
      await tester.pumpWidget(_host(PlayerBottomBar(controller: c)));
      expect(find.text('内核'), findsOneWidget);
      expect(find.text('请文明发送弹幕'), findsOneWidget);
    });

    testWidgets('hasDanmaku 显示弹幕按钮', (WidgetTester tester) async {
      final PlayerControlsController c = PlayerControlsController(
        hasDanmaku: true,
        showDanmaku: true,
      );
      await tester.pumpWidget(_host(PlayerBottomBar(controller: c)));
      expect(find.text('弹'), findsNWidgets(2));
    });

    testWidgets('播放按钮点击触发 togglePlay', (WidgetTester tester) async {
      int taps = 0;
      final PlayerControlsController c = PlayerControlsController();
      c.onTogglePlay = () => taps++;
      await tester.pumpWidget(_host(PlayerBottomBar(controller: c)));
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      expect(taps, 1);
    });
  });

  group('PlayerPanelContainer', () {
    testWidgets('标题 + trailing + 关闭按钮', (WidgetTester tester) async {
      bool closed = false;
      await tester.pumpWidget(_host(PlayerPanelContainer(
        title: '选集',
        trailing: const Text('共 3 集'),
        onClose: () => closed = true,
        child: const Text('内容'),
      )));
      expect(find.text('选集'), findsOneWidget);
      expect(find.text('共 3 集'), findsOneWidget);
      expect(find.text('内容'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close_rounded));
      expect(closed, isTrue);
    });

    testWidgets('无 trailing / onClose', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const PlayerPanelContainer(
        title: '更多',
        child: Text('x'),
      )));
      expect(find.byIcon(Icons.close_rounded), findsNothing);
    });
  });

  group('EpisodePickerPanel', () {
    testWidgets('空列表显示暂无剧集', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const EpisodePickerPanelShell(
        episodes: <PlaybackEpisode>[],
        currentIndex: 0,
      )));
      expect(find.text('暂无剧集'), findsOneWidget);
      expect(find.text('共 0 集'), findsOneWidget);
    });

    testWidgets('有剧集显示选集网格，点击回调', (WidgetTester tester) async {
      int? selected;
      await tester.pumpWidget(_host(EpisodePickerPanelShell(
        episodes: const <PlaybackEpisode>[
          PlaybackEpisode(name: '第1集', url: 'u1'),
          PlaybackEpisode(name: '第2集', url: 'u2'),
        ],
        currentIndex: 0,
        onSelect: (int i) => selected = i,
      )));
      expect(find.text('共 2 集'), findsOneWidget);
      expect(find.text('第1集'), findsOneWidget);
      expect(find.text('第2集'), findsOneWidget);
      await tester.tap(find.text('第2集'));
      expect(selected, 1);
    });
  });

  group('QualityPickerPanel', () {
    testWidgets('选项列表 + 点击回调', (WidgetTester tester) async {
      int? selected;
      await tester.pumpWidget(_host(QualityPickerPanel(
        qualities: const <String>['标清', '高清'],
        selectedIndex: 0,
        onSelect: (int i) => selected = i,
      )));
      expect(find.text('标清'), findsOneWidget);
      expect(find.text('高清'), findsOneWidget);
      await tester.tap(find.text('高清'));
      expect(selected, 1);
    });
  });

  group('SpeedPickerPanel', () {
    testWidgets('默认档位排序 + 点击回调', (WidgetTester tester) async {
      double? selected;
      await tester.pumpWidget(_host(SpeedPickerPanel(
        current: 1.0,
        onSelect: (double s) => selected = s,
      )));
      expect(find.text('0.5x'), findsOneWidget);
      expect(find.text('1x'), findsOneWidget);
      expect(find.text('2x'), findsOneWidget);
      await tester.tap(find.text('2x'));
      expect(selected, 2.0);
    });
  });

  group('EnginePickerPanel', () {
    testWidgets('后端列表 + 当前高亮', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const EnginePickerPanel(
        backends: <PlayerBackend>[PlayerBackend.media3, PlayerBackend.libVLC],
        current: PlayerBackend.media3,
      )));
      expect(find.text('Media3（系统播放器）'), findsOneWidget);
      expect(find.text('libVLC（全格式）'), findsOneWidget);
    });

    testWidgets('降级后端显示提示行', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const EnginePickerPanel(
        backends: <PlayerBackend>[PlayerBackend.media3, PlayerBackend.libVLC],
        current: PlayerBackend.libVLC,
      )));
      expect(find.textContaining('当前为降级后端'), findsOneWidget);
    });
  });

  group('DanmakuOverlay', () {
    testWidgets('无弹幕 → 空', (WidgetTester tester) async {
      await tester.pumpWidget(
          _host(const DanmakuOverlay(states: <DanmakuRenderState>[])));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('有弹幕渲染文本', (WidgetTester tester) async {
      const DanmakuItem item = DanmakuItem(
        content: '弹幕内容',
        timeMs: 0,
        color: 0xFF42A5F5,
      );
      const DanmakuRenderState state = DanmakuRenderState(
        item: item,
        lane: 0,
        x: 100,
        y: 50,
        width: 60,
      );
      await tester.pumpWidget(
          _host(const DanmakuOverlay(states: <DanmakuRenderState>[state])));
      expect(find.text('弹幕内容'), findsOneWidget);
    });
  });

  group('DanmakuSettingsPanel', () {
    testWidgets('开启态：显示三个滑块', (WidgetTester tester) async {
      await tester.pumpWidget(_host(DanmakuSettingsPanel(
        settings: DanmakuSettings.defaults,
        onChanged: (_) {},
      )));
      expect(find.byType(Slider), findsNWidgets(3));
      expect(find.text('弹幕开关'), findsOneWidget);
    });

    testWidgets('关闭态：不显示滑块', (WidgetTester tester) async {
      await tester.pumpWidget(_host(DanmakuSettingsPanel(
        settings: DanmakuSettings.defaults.copyWith(enabled: false),
        onChanged: (_) {},
      )));
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('自定义弹幕源开关 + 地址显示', (WidgetTester tester) async {
      await tester.pumpWidget(_host(DanmakuSettingsPanel(
        settings: DanmakuSettings.defaults.copyWith(
          enabled: false,
          customSourceEnabled: true,
          customSourceUrl: 'http://x/dm.xml',
        ),
        onChanged: (_) {},
      )));
      expect(find.text('自定义弹幕源'), findsOneWidget);
      expect(find.text('http://x/dm.xml'), findsOneWidget);
    });
  });

  group('PlayerControlsView', () {
    testWidgets('竖屏：顶栏 + 中央播放 + 进度条 + 底栏', (WidgetTester tester) async {
      final PlayerControlsController c = PlayerControlsController(
        title: '剧名',
        isPlaying: false,
        form: UiForm.portrait,
        durationMs: 60000,
        positionMs: 5000,
      );
      await tester.pumpWidget(_host(PlayerControlsView(controller: c)));
      expect(find.text('剧名'), findsOneWidget);
      expect(find.byType(PlayerProgressBar), findsOneWidget);
      expect(find.byType(PlayerBottomBar), findsOneWidget);
    });

    testWidgets('横屏：视频 builder 注入渲染', (WidgetTester tester) async {
      final PlayerControlsController c = PlayerControlsController(
        form: UiForm.landscape,
        isPlaying: true,
      );
      await tester.pumpWidget(_host(PlayerControlsView(
        controller: c,
        videoBuilder: (BuildContext _) => const ColoredBox(color: Colors.red),
      )));
      expect(find.byType(ColoredBox), findsWidgets);
    });

    testWidgets('打开选集面板', (WidgetTester tester) async {
      final PlayerControlsController c = PlayerControlsController(
        form: UiForm.portrait,
        episodes: const <PlaybackEpisode>[
          PlaybackEpisode(name: '1', url: 'u1'),
        ],
      );
      c.onSelectEpisode = (_) {};
      await tester.pumpWidget(_host(PlayerControlsView(controller: c)));
      c.openEpisodePicker();
      await tester.pump();
      // 底栏「选集」按钮 + 面板标题「选集」各一
      expect(find.text('选集'), findsNWidgets(2));
    });

    testWidgets('打开弹幕设置面板', (WidgetTester tester) async {
      final PlayerControlsController c = PlayerControlsController(
        form: UiForm.portrait,
      );
      await tester.pumpWidget(_host(PlayerControlsView(
        controller: c,
        danmakuSettings: DanmakuSettings.defaults,
      )));
      c.openDanmakuSettings();
      await tester.pump();
      expect(find.text('弹幕设置'), findsOneWidget);
    });

    testWidgets('打开更多菜单', (WidgetTester tester) async {
      final PlayerControlsController c = PlayerControlsController(
        form: UiForm.portrait,
      );
      await tester.pumpWidget(_host(PlayerControlsView(controller: c)));
      c.openToolsMenu();
      await tester.pump();
      expect(find.text('更多'), findsOneWidget);
    });

    testWidgets('横屏解锁态：左缘锁按钮可见且回调触发', (WidgetTester tester) async {
      int toggles = 0;
      final PlayerControlsController c = PlayerControlsController(
        form: UiForm.landscape,
      );
      c.onToggleOrientationLock = () => toggles++;
      await tester.pumpWidget(_host(PlayerControlsView(controller: c)));
      expect(find.byIcon(Icons.lock_open_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.lock_open_rounded));
      expect(toggles, 1);
    });

    testWidgets('锁定态：隐藏控制层，仅剩锁按钮', (WidgetTester tester) async {
      final PlayerControlsController c = PlayerControlsController(
        form: UiForm.landscape,
        title: '剧名',
        durationMs: 60000,
      );
      await tester.pumpWidget(_host(PlayerControlsView(controller: c)));
      expect(find.byType(PlayerProgressBar), findsOneWidget);

      c.setOrientationLocked(true);
      await tester.pump();
      // 控制层整体隐藏（顶栏标题 / 进度条 / 底栏均不渲染）。
      expect(find.byType(PlayerProgressBar), findsNothing);
      expect(find.byType(PlayerBottomBar), findsNothing);
      expect(find.text('剧名'), findsNothing);
      expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
    });

    testWidgets('锁定态且锁按钮已自动隐藏：画面外无任何覆盖层', (WidgetTester tester) async {
      final PlayerControlsController c = PlayerControlsController(
        form: UiForm.landscape,
      )..setOrientationLocked(true);
      await tester.pumpWidget(_host(PlayerControlsView(
        controller: c,
        lockButtonVisible: false,
      )));
      expect(find.byIcon(Icons.lock_rounded), findsNothing);
      expect(find.byIcon(Icons.lock_open_rounded), findsNothing);
      expect(find.byType(PlayerProgressBar), findsNothing);
    });
  });

  test('playerPanelAccent 强调色常量已导出', () {
    expect(playerPanelAccent, VboxColors.selected);
  });
}