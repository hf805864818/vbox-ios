/// 视觉回归 Golden 基线（批次 A · A-12）。
///
/// 唯一真相源：`docs/第2轮开发计划_功能补全_v2.6.md` §3.7（视觉回归与守卫）。
/// 机制：真实页面渲染 → `matchesGoldenFile` 像素锁定（防布局/令牌漂移）；
/// 与 iOS 参考图的 SSIM 相似度由 `scripts/visual_regression.py` 产出（§3.6）。
///
/// 生成基线：`flutter test test/golden --update-goldens`
/// CI 校验：`flutter test test/golden`（像素不一致即失败）
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vbox/domain/entities/library/library.dart';
import 'package:vbox/domain/usecases/usecases.dart';
import 'package:vbox/platform/download/download.dart';
import 'package:vbox/presentation/shell/home_shell_page.dart';
import 'package:vbox/presentation/theme/vbox_skin_controller.dart';
import 'package:vbox/presentation/ui_mode/ui_mode_resolver.dart';
import 'package:vbox/presentation/welfare/welfare_controller.dart';
import 'package:vbox/presentation/widgets/adaptive/adaptive.dart';
import 'package:vbox/presentation/widgets/vbox/vbox.dart';

import '../support/fakes.dart';

Widget _app({
  UiFormOverride override = UiFormOverride.portrait,
  bool welfareUnlocked = false,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<UiFormController>.value(
        value: UiFormController(
          env: UiFormEnv(
            override: override,
            hasTouch: true,
          ),
        ),
      ),
      // A8：壳层消费皮肤（底栏四皮肤配色）与福利门控（「福利」Tab 显隐）。
      ChangeNotifierProvider<VboxSkinController>.value(
        value: VboxSkinController(),
      ),
      // 门控两态各出一张 Golden：默认 4 Tab；`welfareUnlocked` → 5 Tab（index 3 插入福利）。
      ChangeNotifierProvider<WelfareController>.value(
        value: WelfareController(unlocked: welfareUnlocked),
      ),
      // G-02：首页外壳消费下载胶囊/悬浮按键（内存 store，不触库不触网）。
      ChangeNotifierProvider<DownloadManager>.value(
        value: DownloadManager(
          store: InMemoryDownloadStore(),
          downloadsDirectory: '/tmp/vbox_test/dl',
        ),
      ),
      // A9：首页默认内容 = 豆瓣（[DoubanHomeView] 消费 [DoubanUseCases]）。
      Provider<DoubanUseCases>.value(value: buildDoubanUseCases()),
      Provider<FavoriteUseCases>.value(
        value: FavoriteUseCases(InMemoryFavoriteRepository(const <FavoriteItem>[])),
      ),
      Provider<HistoryUseCases>.value(
        value: HistoryUseCases(InMemoryHistoryRepository(const <HistoryItem>[])),
      ),
      Provider<SubscriptionUseCases>.value(
        value: SubscriptionUseCases(InMemorySubscriptionRepository()),
      ),
      Provider<RemoteSourceUseCases>.value(
        value: RemoteSourceUseCases(InMemoryRemoteSourceRepository()),
      ),
      Provider<ContentBrowseUseCases>.value(
        value: buildContentBrowseUseCases(),
      ),
      Provider<SearchHistoryUseCases>.value(
        value: SearchHistoryUseCases(InMemorySearchHistoryRepository()),
      ),
    ],
    child: const MaterialApp(debugShowCheckedModeBanner: false, home: HomeShellPage()),
  );
}

Future<void> _shot(
  WidgetTester tester,
  String name,
  Size size,
  Widget app,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final GlobalKey key = GlobalKey();
  await tester.pumpWidget(RepaintBoundary(key: key, child: app));
  await tester.pumpAndSettle();
  await expectLater(find.byKey(key), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  testWidgets('home_portrait（竖屏：底部胶囊 TabBar）', (WidgetTester tester) async {
    await _shot(
      tester,
      'home_portrait',
      const Size(390, 844),
      _app(override: UiFormOverride.portrait),
    );
  });

  testWidgets('home_landscape（横屏：仍为悬浮胶囊底栏，无 Rail）', (WidgetTester tester) async {
    await _shot(
      tester,
      'home_landscape',
      const Size(1280, 800),
      _app(override: UiFormOverride.landscape),
    );
  });

  testWidgets('home_welfare_portrait（5 Tab：福利已解锁，index 3 插入）', (WidgetTester tester) async {
    await _shot(
      tester,
      'home_welfare_portrait',
      const Size(390, 844),
      _app(override: UiFormOverride.portrait, welfareUnlocked: true),
    );
  });

  testWidgets('grid_landscape（响应式网格横屏排布）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: ResponsiveGrid(
              form: UiForm.landscape,
              childAspectRatio: 0.7,
              children: List<Widget>.generate(
                12,
                (int i) => ColoredBox(
                  color: HSLColor.fromAHSL(1.0, (i * 30.0) % 360, 0.5, 0.6).toColor(),
                  child: Center(child: Text('$i')),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(find.byKey(key), matchesGoldenFile('goldens/grid_landscape.png'));
  });

  testWidgets('story_page（A-04 组件画廊全量像素锁）', (WidgetTester tester) async {
    // 大视口一次性构建全部组件区块（懒加载 ListView）。
    tester.view.physicalSize = const Size(800, 6400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: VboxStoryPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(find.byKey(key), matchesGoldenFile('goldens/story_page.png'));
  });
}