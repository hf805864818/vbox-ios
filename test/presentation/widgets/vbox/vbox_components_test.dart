/// 表现层组件库单测（批次 A · A-04）。
///
/// 规格对齐 `docs/UI对齐基准_v1.0.md` §2.3 / §2.4 / §2.5：
///   ① Card 圆角 20 + 渐变描边 + 可选主色阴影
///   ② Chip 选中填充 `#34C759`，未选中取分组底
///   ③ SectionHeader 标题 + 右侧操作
///   ④ EpisodeChip 当前项 `#2196F3` 文字 + 20% 底 + 描边
///   ⑤ Button 三形态（primary / secondary / danger）
///   ⑥ Toast 黑 85% + 白字 + 自动消失
///   ⑦ Dialog 标题 + 操作
///   ⑧ PosterCard 占位态 + 标题
///   ⑨ SourceBadge 分类色固定映射
///   ⑩ BottomNav / NavRail 渲染
///   ⑪ SettingsSection + 三种行型（批次 B · B3）
///   ⑫ SkinPicker 四皮肤两态（批次 B · B4）
///   ⑬ LoginSheet 空态禁用 / 填写态 / 密码可见性 / 错误态（批次 B · B5）
///   ⑭ WelfareTabs 三栏目 + WelfarePlatformGrid 4 列（批次 B · B6）
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/presentation/theme/theme.dart';
import 'package:vbox/presentation/widgets/vbox/vbox.dart';

Widget _host(Widget child) => MaterialApp(
      theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
      home: Scaffold(body: Center(child: child)),
    );

Material _materialUnder(WidgetTester tester, Type owner) => tester.widget<Material>(
      find.descendant(of: find.byType(owner), matching: find.byType(Material)).first,
    );

/// 取首个带渐变的 [DecoratedBox] 装饰（皮肤卡渐变填充断言用）。
BoxDecoration _gradientDecoration(WidgetTester tester) {
  final Finder finder = find.byWidgetPredicate(
    (Widget w) =>
        w is DecoratedBox &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).gradient != null,
  );
  return tester.widget<DecoratedBox>(finder.first).decoration as BoxDecoration;
}

void main() {
  group('VboxCard', () {
    testWidgets('渲染子组件并应用渐变描边装饰', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const VboxCard(child: Text('内容'))));
      expect(find.text('内容'), findsOneWidget);

      final DecoratedBox box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(VboxCard),
          matching: find.byType(DecoratedBox),
        ).first,
      );
      final BoxDecoration deco = box.decoration as BoxDecoration;
      expect(deco.gradient, isA<LinearGradient>());
      expect(deco.borderRadius, VboxRadii.panel);
    });

    testWidgets('onTap 生效', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _host(VboxCard(onTap: () => taps++, child: const Text('点击'))),
      );
      await tester.tap(find.text('点击'));
      expect(taps, 1);
    });
  });

  group('VboxChip', () {
    testWidgets('选中填充固定胶囊色', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const VboxChip(label: '榜单', selected: true)));
      expect(_materialUnder(tester, VboxChip).color, VboxColors.chipSelected);
    });

    testWidgets('未选中取分组底色', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const VboxChip(label: '分类')));
      final BuildContext ctx = tester.element(find.byType(VboxChip));
      final ColorScheme scheme = Theme.of(ctx).colorScheme;
      expect(_materialUnder(tester, VboxChip).color, scheme.surfaceContainerHighest);
    });
  });

  group('VboxSectionHeader', () {
    testWidgets('渲染标题并可触发查看全部', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _host(VboxSectionHeader(title: '热播', onSeeAll: () => taps++)),
      );
      expect(find.text('热播'), findsOneWidget);
      await tester.tap(find.text('查看全部'));
      expect(taps, 1);
    });
  });

  group('VboxEpisodeChip', () {
    testWidgets('当前项用强调色文字与 20% 底色', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(const VboxEpisodeChip(label: '第 1 集', selected: true)),
      );
      final Text text = tester.widget<Text>(find.text('第 1 集'));
      expect(text.style?.color, VboxColors.selected);
      expect(
        _materialUnder(tester, VboxEpisodeChip).color,
        VboxColors.selected.withValues(alpha: 0.20),
      );
    });
  });

  group('VboxButton', () {
    testWidgets('primary 用主色实心', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const VboxButton(label: '播放')));
      final BuildContext ctx = tester.element(find.byType(VboxButton));
      expect(
        _materialUnder(tester, VboxButton).color,
        Theme.of(ctx).colorScheme.primary,
      );
    });

    testWidgets('danger 用红字 + 红底 10%', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(VboxButton(
          label: '删除',
          kind: VboxButtonKind.danger,
          onPressed: () {},
        )),
      );
      expect(
        _materialUnder(tester, VboxButton).color,
        VboxColors.danger.withValues(alpha: 0.10),
      );
      final Text text = tester.widget<Text>(find.text('删除'));
      expect(text.style?.color, VboxColors.danger);
    });

    testWidgets('禁用态透明 50%', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const VboxButton(label: '不可用')));
      final Opacity opacity = tester.widget<Opacity>(
        find
            .descendant(of: find.byType(VboxButton), matching: find.byType(Opacity))
            .first,
      );
      expect(opacity.opacity, 0.5);
    });
  });

  group('VboxToast', () {
    testWidgets('展示后自动消失', (WidgetTester tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
          home: Builder(
            builder: (BuildContext c) {
              ctx = c;
              return const Scaffold();
            },
          ),
        ),
      );
      VboxToast.show(ctx, '已收藏', duration: const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('已收藏'), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('已收藏'), findsNothing);
    });
  });

  group('VboxDialog', () {
    testWidgets('弹出并显示标题与内容', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
          home: Builder(
            builder: (BuildContext c) => Scaffold(
              body: Center(
                child: VboxButton(
                  label: '打开',
                  onPressed: () => VboxDialog.show<void>(
                    c,
                    title: '提示',
                    child: const Text('正文'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('提示'), findsOneWidget);
      expect(find.text('正文'), findsOneWidget);
    });
  });

  group('VboxPosterCard', () {
    testWidgets('无封面时展示占位并保留标题', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const VboxPosterCard(title: '片名')));
      expect(find.text('片名'), findsOneWidget);
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    });

    testWidgets('评分标签展示', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(const VboxPosterCard(title: '片名', rating: '9.1')),
      );
      expect(find.text('9.1'), findsOneWidget);
    });
  });

  group('VboxSourceBadge', () {
    testWidgets('按分类固定色板取色', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(const VboxSourceBadge.category(
          label: '蜘蛛',
          category: VboxCategory.spider,
        )),
      );
      final Text text = tester.widget<Text>(find.text('蜘蛛'));
      expect(text.style?.color, VboxColors.categoryColors[VboxCategory.spider]);
    });
  });

  group('导航组件', () {
    const List<VboxNavItem> items = <VboxNavItem>[
      VboxNavItem(icon: Icons.home_outlined, label: '首页'),
      VboxNavItem(icon: Icons.search, label: '搜索'),
    ];

    testWidgets('BottomNav 渲染项并可切换', (WidgetTester tester) async {
      int index = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
          home: Scaffold(
            bottomNavigationBar: VboxBottomNav(
              items: items,
              selectedIndex: index,
              onSelected: (int i) => index = i,
            ),
          ),
        ),
      );
      expect(find.text('首页'), findsOneWidget);
      await tester.tap(find.text('搜索'));
      expect(index, 1);
    });

    testWidgets('NavRail 渲染项', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: VboxTheme.build(skin: VboxSkin.light, brightness: Brightness.light),
          home: Scaffold(
            body: Row(
              children: <Widget>[
                VboxNavRail(
                  items: items,
                  selectedIndex: 0,
                  onSelected: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(VboxNavRail), findsOneWidget);
    });
  });

  group('VboxSettingsSection（B3）', () {
    testWidgets('渲染标题、三行与 n-1 条分隔线', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(const VboxSettingsSection(
          title: '播放设置',
          children: <Widget>[
            VboxSettingsRow(title: 'A'),
            VboxSettingsRow(title: 'B'),
            VboxSettingsRow(title: 'C'),
          ],
        )),
      );
      expect(find.text('播放设置'), findsOneWidget);
      expect(find.byType(VboxSettingsRow), findsNWidgets(3));
      expect(find.byType(Divider), findsNWidgets(2));
      expect(find.byType(ClipRRect), findsWidgets);
    });

    testWidgets('行底取二级分组底 70%（浅色）', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(const VboxSettingsSection(
          title: '播放设置',
          children: <Widget>[VboxSettingsRow(title: 'A')],
        )),
      );
      expect(
        _materialUnder(tester, VboxSettingsRow).color,
        VboxColors.secondarySystemGroupedBackgroundLight.withValues(alpha: 0.7),
      );
    });
  });

  group('VboxSettingsRow（B3）', () {
    testWidgets('开关行渲染标题 / 副标题 / Switch 并可切换', (WidgetTester tester) async {
      bool value = false;
      await tester.pumpWidget(
        _host(VboxSettingsRow.toggle(
          title: '自定义弹幕源',
          subtitle: '已关闭',
          icon: Icons.forum_rounded,
          value: value,
          onChanged: (bool v) => value = v,
        )),
      );
      expect(find.text('自定义弹幕源'), findsOneWidget);
      expect(find.text('已关闭'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
      await tester.tap(find.byType(Switch));
      expect(value, isTrue);
    });

    testWidgets('箭头行渲染 chevron 且整行可点', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _host(VboxSettingsRow.navigation(
          title: '缓存管理',
          subtitle: '256 MB',
          icon: Icons.folder_rounded,
          onTap: () => taps++,
        )),
      );
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
      await tester.tap(find.text('缓存管理'));
      expect(taps, 1);
    });

    testWidgets('无图标时不渲染图标占位', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(const VboxSettingsRow(title: '无图标行')),
      );
      expect(find.byType(Icon), findsNothing);
    });
  });

  group('VboxSettingsInputRow（B3）', () {
    testWidgets('渲染输入框并可回调输入值', (WidgetTester tester) async {
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      String? typed;
      await tester.pumpWidget(
        _host(VboxSettingsInputRow(
          controller: controller,
          hint: 'https://your-danmu-api.com',
          onChanged: (String v) => typed = v,
        )),
      );
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('https://your-danmu-api.com'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'https://api.test');
      expect(typed, 'https://api.test');
    });
  });

  group('VboxSkinPicker（B4）', () {
    testWidgets('渲染四张皮肤卡（标题齐全）', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(const VboxSkinPicker(selected: VboxSkin.light, onSelected: _noop)),
      );
      expect(find.byType(VboxSkinCard), findsNWidgets(4));
      for (final VboxSkin skin in VboxSkin.values) {
        expect(find.text(skin.title), findsOneWidget);
      }
    });

    testWidgets('点击卡片回调对应皮肤', (WidgetTester tester) async {
      VboxSkin? picked;
      await tester.pumpWidget(
        _host(VboxSkinPicker(
          selected: VboxSkin.light,
          onSelected: (VboxSkin s) => picked = s,
        )),
      );
      await tester.tap(find.text(VboxSkin.liquid.title));
      expect(picked, VboxSkin.liquid);
    });
  });

  group('VboxSkinCard（B4）', () {
    testWidgets('选中填皮肤渐变', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(const VboxSkinCard(skin: VboxSkin.liquid, isSelected: true)),
      );
      final LinearGradient g =
          _gradientDecoration(tester).gradient! as LinearGradient;
      expect(g.colors, VboxColors.skinCardGradient(VboxSkin.liquid));
    });

    testWidgets('选中文字色：浅色卡取深字', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(const VboxSkinCard(skin: VboxSkin.light, isSelected: true)),
      );
      expect(
        tester.widget<Text>(find.text(VboxSkin.light.title)).style?.color,
        VboxColors.skinCardOnLightText,
      );
    });

    testWidgets('未选中取分组底渐变（浅色）', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(const VboxSkinCard(skin: VboxSkin.light, isSelected: false)),
      );
      final LinearGradient g =
          _gradientDecoration(tester).gradient! as LinearGradient;
      expect(
        g.colors.first,
        VboxColors.secondarySystemGroupedBackgroundLight.withValues(alpha: 0.95),
      );
    });
  });

  group('VboxLoginSheet（B5）', () {
    /// 建两个输入控制器并登记释放。
    List<TextEditingController> controllers() {
      final TextEditingController user = TextEditingController();
      final TextEditingController pwd = TextEditingController();
      addTearDown(user.dispose);
      addTearDown(pwd.dispose);
      return <TextEditingController>[user, pwd];
    }

    testWidgets('空账号 → 主按钮禁用并透明 60%，含标题 / 胶囊', (WidgetTester tester) async {
      final List<TextEditingController> c = controllers();
      await tester.pumpWidget(
        _host(VboxLoginSheet(
          usernameController: c[0],
          passwordController: c[1],
          onSubmit: () {},
        )),
      );
      expect(find.text('欢迎回来'), findsOneWidget);
      expect(find.text('登录你的账号继续使用'), findsOneWidget);
      expect(find.text('登录 / 注册'), findsOneWidget);
      expect(find.text('上级用户：没有上级用户'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);

      final Opacity opacity = tester.widget<Opacity>(
        find
            .ancestor(
              of: find.text('登录 / 注册'),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(opacity.opacity, 0.6);
    });

    testWidgets('填写账号后主按钮可点并回调', (WidgetTester tester) async {
      final List<TextEditingController> c = controllers();
      int submits = 0;
      await tester.pumpWidget(
        _host(VboxLoginSheet(
          usernameController: c[0],
          passwordController: c[1],
          onSubmit: () => submits++,
        )),
      );
      await tester.enterText(find.byType(TextField).first, 'alice');
      await tester.pump();
      await tester.tap(find.text('登录 / 注册'));
      expect(submits, 1);
    });

    testWidgets('已注册 → 按钮文案为「登录」', (WidgetTester tester) async {
      final List<TextEditingController> c = controllers();
      await tester.pumpWidget(
        _host(VboxLoginSheet(
          usernameController: c[0],
          passwordController: c[1],
          registered: true,
          onSubmit: () {},
        )),
      );
      expect(find.text('登录'), findsOneWidget);
      expect(find.text('登录 / 注册'), findsNothing);
    });

    testWidgets('密码可见性可切换', (WidgetTester tester) async {
      final List<TextEditingController> c = controllers();
      await tester.pumpWidget(
        _host(VboxLoginSheet(
          usernameController: c[0],
          passwordController: c[1],
          onSubmit: () {},
        )),
      );
      expect(find.byIcon(Icons.visibility_off), findsOneWidget);
      await tester.tap(find.byIcon(Icons.visibility_off));
      await tester.pump();
      expect(find.byIcon(Icons.visibility), findsOneWidget);
    });

    testWidgets('错误提示渲染', (WidgetTester tester) async {
      final List<TextEditingController> c = controllers();
      await tester.pumpWidget(
        _host(VboxLoginSheet(
          usernameController: c[0],
          passwordController: c[1],
          error: '密码错误，请重试',
          onSubmit: () {},
        )),
      );
      expect(find.text('密码错误，请重试'), findsOneWidget);
    });

    testWidgets('取消回调触发', (WidgetTester tester) async {
      final List<TextEditingController> c = controllers();
      int cancels = 0;
      await tester.pumpWidget(
        _host(VboxLoginSheet(
          usernameController: c[0],
          passwordController: c[1],
          onCancel: () => cancels++,
          onSubmit: () {},
        )),
      );
      await tester.tap(find.text('取消'));
      expect(cancels, 1);
    });
  });

  group('VboxWelfareTabs（B6）', () {
    testWidgets('渲染三栏目，选中项白字 + 渐变', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(const VboxWelfareTabs(
          selected: VboxWelfareCategory.live,
          onSelected: _noopCategory,
        )),
      );
      expect(find.text('视频'), findsOneWidget);
      expect(find.text('直播'), findsOneWidget);
      expect(find.text('漫画'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('直播')).style?.color,
        Colors.white,
      );
      final LinearGradient g =
          _gradientDecoration(tester).gradient! as LinearGradient;
      expect(g.colors, VboxColors.welfareTabLiveGradient);
    });

    testWidgets('点击切换回调', (WidgetTester tester) async {
      VboxWelfareCategory? picked;
      await tester.pumpWidget(
        _host(VboxWelfareTabs(
          selected: VboxWelfareCategory.video,
          onSelected: (VboxWelfareCategory c) => picked = c,
        )),
      );
      await tester.tap(find.text('漫画'));
      expect(picked, VboxWelfareCategory.comic);
    });
  });

  group('VboxWelfarePlatformGrid（B6）', () {
    testWidgets('按名渲染平台并可回调', (WidgetTester tester) async {
      final List<VboxWelfarePlatform> items = List<VboxWelfarePlatform>.generate(
        5,
        (int i) => VboxWelfarePlatform(name: '平台$i', icon: Icons.tv_rounded),
      );
      VboxWelfarePlatform? tapped;
      await tester.pumpWidget(
        _host(VboxWelfarePlatformGrid(
          platforms: items,
          onTap: (VboxWelfarePlatform p) => tapped = p,
        )),
      );
      for (int i = 0; i < 5; i++) {
        expect(find.text('平台$i'), findsOneWidget);
      }
      await tester.tap(find.text('平台0'));
      expect(tapped?.name, '平台0');
    });

    testWidgets('渐变取自稳定哈希色板', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(const VboxWelfarePlatformGrid(
          platforms: <VboxWelfarePlatform>[
            VboxWelfarePlatform(name: '熊猫直播', icon: Icons.tv_rounded),
          ],
        )),
      );
      final LinearGradient g =
          _gradientDecoration(tester).gradient! as LinearGradient;
      expect(g.colors, VboxColors.welfarePlatformGradient('熊猫直播'));
    });
  });
}

void _noop(VboxSkin _) {}

void _noopCategory(VboxWelfareCategory _) {}