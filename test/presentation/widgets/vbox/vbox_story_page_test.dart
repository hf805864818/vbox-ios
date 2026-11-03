/// 组件 Story 页单测（批次 A · A-04 验收项）。
///
/// 验收：`docs/第2轮细分实施WBS_v1.6.md` A-04「组件 Story 页 + 单测；
/// 规格对齐 UI 基准」—— Story 页须一页陈列全部 A-04 组件代表形态。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/presentation/theme/theme.dart';
import 'package:vbox/presentation/widgets/vbox/vbox.dart';

Widget _host() => MaterialApp(
      theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
      home: const VboxStoryPage(),
    );

/// Story 页为懒加载 ListView：用大视口一次性构建全部区块。
Future<void> _pumpFull(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 6400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_host());
}

void main() {
  testWidgets('Story 页陈列全部 A-04 组件', (WidgetTester tester) async {
    await _pumpFull(tester);

    // 结构：标题 + 全部组件区块。
    expect(find.text('组件 Story · A-04'), findsOneWidget);
    expect(find.byType(VboxButton), findsWidgets);
    expect(find.byType(VboxCard), findsWidgets);
    expect(find.byType(VboxChip), findsWidgets);
    expect(find.byType(VboxEpisodeChip), findsWidgets);
    expect(find.byType(VboxSectionHeader), findsWidgets);
    expect(find.byType(VboxSourceBadge), findsNWidgets(8));
    expect(find.byType(VboxPosterCard), findsNWidgets(3));
    expect(find.byType(VboxBottomNav), findsOneWidget);
    expect(find.byType(VboxNavRail), findsOneWidget);
    // A4：开关两态 + 禁用对照（共 3 个）；B3：设置开关行另加 1 个 → 4。
    expect(find.byType(Switch), findsNWidgets(4));
    // B3：设置分组 + 三行型（开关 / 输入 / 箭头）。
    expect(find.byType(VboxSettingsSection), findsOneWidget);
    expect(find.byType(VboxSettingsRow), findsNWidgets(2));
    expect(find.byType(VboxSettingsInputRow), findsOneWidget);
    // B4：四皮肤卡。
    expect(find.byType(VboxSkinPicker), findsOneWidget);
    expect(find.byType(VboxSkinCard), findsNWidgets(4));
    // B5：登录弹窗（空态）。
    expect(find.byType(VboxLoginSheet), findsOneWidget);
    // B6：三段福利分段 + 4 列平台网格（12 项）。
    expect(find.byType(VboxWelfareTabs), findsOneWidget);
    expect(find.byType(VboxWelfarePlatformGrid), findsOneWidget);
    expect(find.text('哔哩直播'), findsOneWidget);
  });

  testWidgets('区块标题齐全（14 区）', (WidgetTester tester) async {
    await _pumpFull(tester);
    const List<String> sections = <String>[
      '品牌（A-13）',
      '按钮 Button',
      '卡片 Card',
      '胶囊 Chip / 剧集 EpisodeChip',
      '区块标题 SectionHeader',
      '源角标 SourceBadge',
      '海报卡 PosterCard',
      '导航 BottomNav（Rail 已弃用 · A8）',
      '开关 Switch（A4）',
      '设置分组 SettingsSection（B3）',
      '皮肤选择 SkinPicker（B4）',
      '登录弹窗 LoginSheet（B5）',
      '福利分段 + 平台网格（B6）',
      '浮层 Dialog / Toast',
    ];
    for (final String s in sections) {
      expect(find.text(s), findsOneWidget, reason: '缺少区块：$s');
    }
  });

  testWidgets('浮层演示：Dialog 可打开', (WidgetTester tester) async {
    await _pumpFull(tester);
    await tester.tap(find.text('打开 Dialog'));
    await tester.pumpAndSettle();

    expect(find.text('示例弹窗'), findsOneWidget);
    expect(find.text('VboxDialog · 居中卡片（圆角 14）'), findsOneWidget);
  });

  testWidgets('浮层演示：Toast 可弹出并自动消失', (WidgetTester tester) async {
    await _pumpFull(tester);
    await tester.tap(find.text('弹 Toast'));
    await tester.pump();
    expect(find.text('已加入收藏'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    expect(find.text('已加入收藏'), findsNothing);
  });
}