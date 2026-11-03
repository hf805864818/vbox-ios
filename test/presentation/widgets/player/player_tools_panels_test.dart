/// UI-F2/F3/F5/F6：播放器工具菜单与面板（工具快捷菜单 / 长按倍速 / 片头片尾 /
/// 弹幕搜索 / 字幕设置）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/player/danmaku/danmaku_service.dart';
import 'package:vbox/platform/player/skip_settings.dart';
import 'package:vbox/platform/player/subtitle_style.dart';
import 'package:vbox/presentation/theme/theme.dart';
import 'package:vbox/presentation/widgets/player/panels/danmaku_search_panel.dart';
import 'package:vbox/presentation/widgets/player/panels/long_press_speed_panel.dart';
import 'package:vbox/presentation/widgets/player/panels/skip_settings_panel.dart';
import 'package:vbox/presentation/widgets/player/panels/subtitle_settings_panel.dart';
import 'package:vbox/presentation/widgets/player/panels/tools_quick_menu.dart';
import 'package:vbox/presentation/widgets/player/player_controls_controller.dart';
import 'package:vbox/presentation/widgets/player/player_error_view.dart';

Widget _host(Widget child) => MaterialApp(
      theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(child: child),
      ),
    );

void main() {
  group('ToolsQuickMenuPanel（UI-F6）', () {
    testWidgets('渲染 8 项：4 跳转 + 4 开关', (WidgetTester tester) async {
      final PlayerControlsController c = PlayerControlsController()
        ..onToggleAutoPlayNext = (_) {}
        ..onToggleBackgroundPlay = (_) {}
        ..onTogglePipEnabled = (_) {}
        ..onToggleDebugOverlay = (_) {}
        ..onSelectLongPressSpeed = (_) {};
      await tester.pumpWidget(_host(ToolsQuickMenuPanel(
        controller: c,
        danmakuSearchAvailable: true,
      )));
      // 跳转项
      expect(find.text('长按倍速'), findsOneWidget);
      expect(find.text('搜索弹幕'), findsOneWidget);
      expect(find.text('加载字幕'), findsOneWidget);
      expect(find.text('片头片尾'), findsOneWidget);
      // 开关项
      expect(find.text('自动播放'), findsOneWidget);
      expect(find.text('后台播放'), findsOneWidget);
      expect(find.text('画中画'), findsOneWidget);
      expect(find.text('调试浮层'), findsOneWidget);
      expect(find.byType(Switch), findsNWidgets(4));
    });

    testWidgets('跳转项点击打开对应面板', (WidgetTester tester) async {
      final PlayerControlsController c = PlayerControlsController()
        ..onSelectLongPressSpeed = (_) {};
      await tester.pumpWidget(_host(ToolsQuickMenuPanel(
        controller: c,
        danmakuSearchAvailable: false,
      )));
      await tester.tap(find.text('长按倍速'));
      expect(c.showLongPressSpeedSettings, isTrue);
      expect(c.showToolsMenu, isFalse);
    });

    testWidgets('弹幕搜索数据源缺失时该项置灰', (WidgetTester tester) async {
      final PlayerControlsController c = PlayerControlsController();
      await tester.pumpWidget(_host(ToolsQuickMenuPanel(
        controller: c,
        danmakuSearchAvailable: false,
      )));
      await tester.tap(find.text('搜索弹幕'));
      expect(c.showDanmakuSearch, isFalse);
    });

    testWidgets('开关项切换回调上抛当前值与状态回填', (WidgetTester tester) async {
      bool? captured;
      final PlayerControlsController c = PlayerControlsController(
        autoPlayNext: false,
      )..onToggleAutoPlayNext = (bool v) => captured = v;
      await tester.pumpWidget(_host(ToolsQuickMenuPanel(
        controller: c,
        danmakuSearchAvailable: false,
      )));
      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      expect(captured, isTrue);
      expect(c.autoPlayNext, isTrue);
    });
  });

  group('LongPressSpeedSettingsPanel（UI-F6 → S-07）', () {
    testWidgets('4 档可选 + 当前档高亮', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const LongPressSpeedSettingsPanel(
        current: 2.0,
      )));
      expect(find.text('长按倍速设置'), findsOneWidget);
      expect(find.text('1.5x'), findsOneWidget);
      expect(find.text('2x'), findsOneWidget);
      expect(find.text('2.5x'), findsOneWidget);
      expect(find.text('3x'), findsOneWidget);
    });

    testWidgets('点选档位回调并关闭面板', (WidgetTester tester) async {
      double? picked;
      final PlayerControlsController c = PlayerControlsController(longPressSpeed: 2.0)
        ..onSelectLongPressSpeed = (double v) => picked = v;
      c.openLongPressSpeedSettings();
      await tester.pumpWidget(_host(LongPressSpeedSettingsPanel(
        current: c.longPressSpeed,
        onSelect: c.selectLongPressSpeed,
      )));
      await tester.tap(find.text('3x'));
      await tester.pump();
      expect(picked, 3.0);
      expect(c.longPressSpeed, 3.0);
      expect(c.showLongPressSpeedSettings, isFalse);
    });

    test('档位文案：整数不带小数 / 半档带一位', () {
      expect(LongPressSpeedSettingsPanel.formatSpeed(2.0), '2x');
      expect(LongPressSpeedSettingsPanel.formatSpeed(1.5), '1.5x');
      expect(LongPressSpeedSettingsPanel.formatSpeed(2.5), '2.5x');
    });
  });

  group('SkipSettingsPanel（UI-F2）', () {
    testWidgets('两行开关；开启后展开时长选择', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const SkipSettingsPanel(
        settings: SkipSettings(introEnabled: true, introSeconds: 90),
      )));
      expect(find.text('跳过片头'), findsOneWidget);
      expect(find.text('跳过片尾'), findsOneWidget);
      expect(find.byType(Switch), findsNWidgets(2));
      // 片头开启 → 展开「分 / 秒」两档
      expect(find.byType(DropdownButton<int>), findsNWidgets(2));
      expect(find.text('1分'), findsOneWidget);
      expect(find.text('30秒'), findsOneWidget);
    });

    testWidgets('关闭态不展开时长选择', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const SkipSettingsPanel(
        settings: SkipSettings(),
      )));
      expect(find.byType(DropdownButton<int>), findsNothing);
    });

    testWidgets('切换开关上抛更新后的设置', (WidgetTester tester) async {
      SkipSettings? captured;
      await tester.pumpWidget(_host(SkipSettingsPanel(
        settings: const SkipSettings(),
        onChanged: (SkipSettings v) => captured = v,
      )));
      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      expect(captured, isNotNull);
      expect(captured!.introEnabled, isTrue);
    });
  });

  group('SubtitleSettingsPanel（UI-F5）', () {
    testWidgets('未加载：显示提示 + 上传按钮，无样式项', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const SubtitleSettingsPanel(
        style: SubtitleStyle(),
      )));
      expect(find.text('暂未加载字幕'), findsOneWidget);
      expect(find.text('上传本地字幕文件'), findsOneWidget);
      expect(find.text('显示字幕'), findsNothing);
      expect(find.text('清除字幕'), findsNothing);
    });

    testWidgets('已加载：显示文件名 + 开关 / 字号 / 颜色 / 清除', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const SubtitleSettingsPanel(
        style: SubtitleStyle(),
        fileName: 'movie.zh.srt',
      )));
      expect(find.text('movie.zh.srt'), findsOneWidget);
      expect(find.text('显示字幕'), findsOneWidget);
      expect(find.text('字幕字号'), findsOneWidget);
      expect(find.text('字幕颜色'), findsOneWidget);
      expect(find.text('清除字幕'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
    });

    testWidgets('字号滑杆上抛新样式', (WidgetTester tester) async {
      SubtitleStyle? captured;
      await tester.pumpWidget(_host(SubtitleSettingsPanel(
        style: const SubtitleStyle(),
        fileName: 'a.srt',
        onStyleChanged: (SubtitleStyle v) => captured = v,
      )));
      final Slider slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChanged!(24);
      expect(captured, isNotNull);
      expect(captured!.fontSize, 24);
    });

    testWidgets('清除按钮回调触发', (WidgetTester tester) async {
      bool cleared = false;
      await tester.pumpWidget(_host(SubtitleSettingsPanel(
        style: const SubtitleStyle(),
        fileName: 'a.srt',
        onClear: () => cleared = true,
      )));
      await tester.tap(find.text('清除字幕'));
      expect(cleared, isTrue);
    });

    test('字号钳制在 12 ~ 32', () {
      expect(const SubtitleStyle().copyWith(fontSize: 3).fontSize, 12);
      expect(const SubtitleStyle().copyWith(fontSize: 99).fontSize, 32);
    });
  });

  group('DanmakuSearchPanel（UI-F3）', () {
    Future<List<DanmakuAnimeMatch>> fakeSearch(String k) async =>
        <DanmakuAnimeMatch>[
          const DanmakuAnimeMatch(animeId: 1, title: '示例番剧', type: 'TV动画'),
        ];

    Future<List<DanmakuEpisodeInfo>> fakeEpisodes(int id) async =>
        <DanmakuEpisodeInfo>[
          const DanmakuEpisodeInfo(episodeId: 11, episodeNumber: 1),
          const DanmakuEpisodeInfo(episodeId: 12, episodeNumber: 2),
        ];

    testWidgets('初始：引导文案 + 搜索框', (WidgetTester tester) async {
      await tester.pumpWidget(_host(DanmakuSearchPanel(
        search: fakeSearch,
        loadEpisodes: fakeEpisodes,
      )));
      expect(find.text('搜索弹幕'), findsOneWidget);
      expect(find.text('输入资源名称搜索弹幕'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('搜索 → 候选 → 分集 → 选定回抛', (WidgetTester tester) async {
      DanmakuEpisodeInfo? picked;
      await tester.pumpWidget(_host(DanmakuSearchPanel(
        search: fakeSearch,
        loadEpisodes: fakeEpisodes,
        onSelectEpisode: (DanmakuEpisodeInfo e) => picked = e,
      )));
      await tester.enterText(find.byType(TextField), '示例');
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(find.text('示例番剧'), findsOneWidget);

      await tester.tap(find.text('示例番剧'));
      await tester.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);

      await tester.tap(find.text('2'));
      await tester.pump();
      expect(picked, isNotNull);
      expect(picked!.episodeId, 12);
    });

    testWidgets('无结果：提示未找到', (WidgetTester tester) async {
      await tester.pumpWidget(_host(DanmakuSearchPanel(
        search: (String k) async => const <DanmakuAnimeMatch>[],
        loadEpisodes: fakeEpisodes,
      )));
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(find.text('未找到匹配的弹幕源'), findsOneWidget);
    });
  });

  group('PlayerErrorView / PlayerErrorWithLogsView（UI-F10）', () {
    test('可重试判定：4 类失效文案不可重试', () {
      expect(isPlayerErrorRetryable('播放地址不可达（网络错误）'), isTrue);
      expect(isPlayerErrorRetryable('资源已失效'), isFalse);
      expect(isPlayerErrorRetryable('内容已被和谐'), isFalse);
      expect(isPlayerErrorRetryable('禁止播放'), isFalse);
      expect(isPlayerErrorRetryable('转存返回占位'), isFalse);
    });

    testWidgets('基础错误态：图标 + 标题 + 原因 + 重试/返回', (WidgetTester tester) async {
      bool retried = false;
      await tester.pumpWidget(_host(PlayerErrorView(
        message: '播放地址不可达（网络错误）',
        onRetry: () => retried = true,
        onBack: () {},
      )));
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.text('加载失败'), findsOneWidget);
      expect(find.text('播放地址不可达（网络错误）'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('返回'), findsOneWidget);
      await tester.tap(find.text('重试'));
      expect(retried, isTrue);
    });

    testWidgets('不可重试错误隐藏「重试」按钮', (WidgetTester tester) async {
      await tester.pumpWidget(_host(PlayerErrorView(
        message: '资源已失效',
        onRetry: () {},
        onBack: () {},
      )));
      expect(find.text('重试'), findsNothing);
      expect(find.text('返回'), findsOneWidget);
    });

    testWidgets('含日志错误态：渲染日志行', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const PlayerErrorWithLogsView(
        message: '打开失败',
        logs: <String>['line-1', 'line-2'],
      )));
      expect(find.text('line-1'), findsOneWidget);
      expect(find.text('line-2'), findsOneWidget);
    });

    testWidgets('兼容内核不可用视图：展示所需内核名', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const PlayerUnsupportedView(
        engineName: 'MPV',
        message: '该封装需要转封装后重试',
      )));
      expect(find.text('当前资源需要MPV兼容内核'), findsOneWidget);
      expect(find.text('该封装需要转封装后重试'), findsOneWidget);
    });
  });
}
