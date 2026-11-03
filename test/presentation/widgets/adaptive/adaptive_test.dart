/// 自适应框架单测（批次 A · A-07）。
///
/// 验收：`docs/第2轮开发计划_功能补全_v2.6.md` §3.3 ——
///   [ResponsiveGrid] 列数（竖屏 3 / 横屏 5–8）·
///   [AdaptiveScaffold] 导航（全端统一底部胶囊 TabBar，A8 起横竖屏不再分叉）·
///   [ContentPanel] 分栏（竖屏全屏列表 / 横屏列表 + 详情）·
///   [AdaptiveDialog] 锚点（竖屏居中 / 横屏右侧抽屉）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/presentation/theme/theme.dart';
import 'package:vbox/presentation/ui_mode/ui_mode.dart';
import 'package:vbox/presentation/widgets/adaptive/adaptive.dart';
import 'package:vbox/presentation/widgets/vbox/vbox.dart';

/// 以固定视口承载被测组件（保证 Row / 网格有确定约束）。
Widget _host(
  Widget child, {
  Size size = const Size(1200, 800),
}) =>
    MaterialApp(
      theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
      home: Scaffold(body: SizedBox(width: size.width, height: size.height, child: child)),
    );

const List<VboxNavItem> _items = <VboxNavItem>[
  VboxNavItem(icon: Icons.home_outlined, label: '首页'),
  VboxNavItem(icon: Icons.search, label: '搜索'),
  VboxNavItem(icon: Icons.person_outline, label: '我的'),
];

void main() {
  group('ResponsiveGrid.columnsFor', () {
    test('竖屏：恒 3 列（对齐 iOS）', () {
      expect(ResponsiveGrid.columnsFor(form: UiForm.portrait, width: 360), 3);
      expect(ResponsiveGrid.columnsFor(form: UiForm.portrait, width: 479), 3);
      expect(ResponsiveGrid.columnsFor(form: UiForm.portrait, width: 480), 3);
      expect(ResponsiveGrid.columnsFor(form: UiForm.portrait, width: 1024), 3);
    });

    test('横屏：随宽度落在 5–8 列', () {
      expect(ResponsiveGrid.columnsFor(form: UiForm.landscape, width: 800), 5);
      expect(ResponsiveGrid.columnsFor(form: UiForm.landscape, width: 960), 6);
      expect(ResponsiveGrid.columnsFor(form: UiForm.landscape, width: 1200), 7);
      expect(ResponsiveGrid.columnsFor(form: UiForm.landscape, width: 1600), 8);
      expect(ResponsiveGrid.columnsFor(form: UiForm.landscape, width: 2560), 8);
    });

    test('横屏列数恒 ≥ 竖屏（同宽度）', () {
      for (final double w in <double>[360, 480, 960, 1600]) {
        expect(
          ResponsiveGrid.columnsFor(form: UiForm.landscape, width: w),
          greaterThanOrEqualTo(
            ResponsiveGrid.columnsFor(form: UiForm.portrait, width: w),
          ),
        );
      }
    });
  });

  group('ResponsiveGrid 渲染', () {
    testWidgets('按形态推导 crossAxisCount', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(
          const ResponsiveGrid(
            form: UiForm.landscape,
            children: <Widget>[Text('a'), Text('b'), Text('c')],
          ),
        ),
      );
      final GridView grid = tester.widget<GridView>(find.byType(GridView));
      final SliverGridDelegateWithFixedCrossAxisCount delegate =
          grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 7);
      expect(find.text('a'), findsOneWidget);
    });

    testWidgets('显式 columns 覆盖宽度推导', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const ResponsiveGrid(
            form: UiForm.portrait,
            columns: 4,
            children: <Widget>[Text('x')],
          ),
        ),
      );
      final GridView grid = tester.widget<GridView>(find.byType(GridView));
      final SliverGridDelegateWithFixedCrossAxisCount delegate =
          grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 4);
    });
  });

  group('AdaptiveScaffold 导航', () {
    // A8（决策 2026-10-03，R-9）：全端统一「底部悬浮胶囊 TabBar」，
    // 横竖屏**均**不渲染左侧 Rail（原 A-07「横屏 → Rail」分支已废弃，解 D18）。
    testWidgets('竖屏 → 底部胶囊 TabBar（无 Rail）', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          AdaptiveScaffold(
            form: UiForm.portrait,
            items: _items,
            onSelected: (_) {},
            body: const Text('内容'),
          ),
        ),
      );
      expect(find.byType(VboxBottomNav), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('内容'), findsOneWidget);
    });

    testWidgets('横屏 → 仍为底部胶囊 TabBar（全端统一，无 Rail）', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          AdaptiveScaffold(
            form: UiForm.landscape,
            items: _items,
            onSelected: (_) {},
            body: const Text('内容'),
          ),
        ),
      );
      expect(find.byType(VboxBottomNav), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('内容'), findsOneWidget);
    });

    testWidgets('无导航项时不渲染导航', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const AdaptiveScaffold(
            form: UiForm.portrait,
            body: Text('裸内容'),
          ),
        ),
      );
      expect(find.byType(VboxBottomNav), findsNothing);
      expect(find.text('裸内容'), findsOneWidget);
    });

    testWidgets('标题渲染 AppBar', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const AdaptiveScaffold(
            form: UiForm.landscape,
            title: '设置',
            body: Text('内容'),
          ),
        ),
      );
      expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);
    });
  });

  group('ContentPanel 分栏', () {
    testWidgets('竖屏 → 仅列表全屏（详情不内联）', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const ContentPanel(
            form: UiForm.portrait,
            list: Text('列表'),
            detail: Text('详情'),
          ),
        ),
      );
      expect(find.text('列表'), findsOneWidget);
      expect(find.text('详情'), findsNothing);
    });

    testWidgets('横屏 → 列表 + 右侧详情并排', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const ContentPanel(
            form: UiForm.landscape,
            list: Text('列表'),
            detail: Text('详情'),
          ),
        ),
      );
      expect(find.text('列表'), findsOneWidget);
      expect(find.text('详情'), findsOneWidget);
      expect(find.byType(Row), findsWidgets);
    });

    testWidgets('横屏但 showDetail=false → 仅列表', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const ContentPanel(
            form: UiForm.landscape,
            showDetail: false,
            list: Text('列表'),
            detail: Text('详情'),
          ),
        ),
      );
      expect(find.text('列表'), findsOneWidget);
      expect(find.text('详情'), findsNothing);
    });

    testWidgets('横屏无详情 → 仅列表', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const ContentPanel(form: UiForm.landscape, list: Text('列表')),
        ),
      );
      expect(find.text('列表'), findsOneWidget);
    });
  });

  group('AdaptiveDialog 锚点', () {
    testWidgets('竖屏 → 复用 VboxDialog', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const AdaptiveDialog(
            form: UiForm.portrait,
            title: '标题',
            child: Text('正文'),
          ),
        ),
      );
      expect(find.byType(VboxDialog), findsOneWidget);
      expect(find.text('正文'), findsOneWidget);
    });

    testWidgets('横屏 → 右侧抽屉（无 VboxDialog）', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const AdaptiveDialog(
            form: UiForm.landscape,
            title: '标题',
            child: Text('正文'),
          ),
        ),
      );
      expect(find.byType(VboxDialog), findsNothing);
      expect(find.text('标题'), findsOneWidget);
      expect(find.text('正文'), findsOneWidget);
      // 右侧锚点：内容靠右对齐。
      final Align align = tester.widget<Align>(
        find
            .descendant(
              of: find.byType(AdaptiveDialog),
              matching: find.byType(Align),
            )
            .first,
      );
      expect(align.alignment, Alignment.centerRight);
    });

    testWidgets('show：竖屏走居中弹窗路由', (WidgetTester tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (BuildContext c) {
              ctx = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final Future<void> pending = AdaptiveDialog.show<void>(
        ctx,
        form: UiForm.portrait,
        title: '提示',
        child: const Text('内容'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('内容'), findsOneWidget);
      Navigator.of(ctx).pop();
      await tester.pumpAndSettle();
      await pending;
    });

    testWidgets('show：横屏走右侧抽屉路由', (WidgetTester tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (BuildContext c) {
              ctx = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final Future<void> pending = AdaptiveDialog.show<void>(
        ctx,
        form: UiForm.landscape,
        title: '提示',
        child: const Text('内容'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('内容'), findsOneWidget);
      Navigator.of(ctx).pop();
      await tester.pumpAndSettle();
      await pending;
    });
  });
}