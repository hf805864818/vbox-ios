/// 视觉回归 Golden 基线：批次 H 页面族（H-06 福利专区三栏目 + 平台网格 +
/// H-07 福利平台设置页）。
///
/// 依据：`docs/UI对齐_H_I开工前置_v1.9.md` §3.4（H-06 → 图17「福利页面直播栏目」；
/// H-07 → 图19「福利专区设置」）
///   + §9.4「每页一步」接入 [visual_pairs.json]。
///
/// 机制同 `i_pages_golden_test.dart`：真实页面渲染 → `matchesGoldenFile` 像素锁；
/// 与 iOS 基准图的 SSIM 由 `scripts/visual_regression.py`（清单模式）产出。
///
/// 生成基线：`flutter test test/golden --update-goldens`
/// CI 校验：`flutter test test/golden`（像素不一致即失败）
library;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/local/welfare_domain_store.dart';
import 'package:vbox/data/datasources/local/welfare_proxy_store.dart';
import 'package:vbox/domain/entities/welfare/welfare.dart';
import 'package:vbox/presentation/pages/welfare/welfare_home_page.dart';
import 'package:vbox/presentation/pages/welfare/welfare_settings_page.dart';
import 'package:vbox/presentation/welfare/welfare_platform_controller.dart';

import '../support/fakes.dart';

/// 直播栏目基准配置（图17 版式：分段三栏 + 4 列彩色平台图标网格）。
WelfarePlatformConfig _liveConfig() => const WelfarePlatformConfig(
      meta: <String, Object?>{'version': '2026.10.03.1'},
      categories: <WelfarePlatformCategoryMeta>[
        WelfarePlatformCategoryMeta(
          key: 'video',
          name: '视频',
          icon: 'play.rectangle.fill',
        ),
        WelfarePlatformCategoryMeta(
          key: 'live',
          name: '直播',
          icon: 'antenna.radiowaves.left.and.right',
        ),
        WelfarePlatformCategoryMeta(
          key: 'comic',
          name: '漫画',
          icon: 'books.vertical.fill',
        ),
      ],
      platforms: <WelfarePlatform>[
        WelfarePlatform(
          platformKey: 'live-1',
          name: '咪咕直播',
          category: WelfarePlatformCategory.live,
          icon: 'antenna.radiowaves.left.and.right',
          sortOrder: 0,
        ),
        WelfarePlatform(
          platformKey: 'live-2',
          name: '央视直播',
          category: WelfarePlatformCategory.live,
          icon: 'tv.fill',
          sortOrder: 1,
        ),
        WelfarePlatform(
          platformKey: 'live-3',
          name: '体育直播',
          category: WelfarePlatformCategory.live,
          icon: 'flame.fill',
          sortOrder: 2,
        ),
        WelfarePlatform(
          platformKey: 'live-4',
          name: '卫视直播',
          category: WelfarePlatformCategory.live,
          icon: 'star.fill',
          sortOrder: 3,
        ),
        WelfarePlatform(
          platformKey: 'live-5',
          name: '音乐现场',
          category: WelfarePlatformCategory.live,
          icon: 'music.note',
          sortOrder: 4,
        ),
        WelfarePlatform(
          platformKey: 'live-6',
          name: '游戏直播',
          category: WelfarePlatformCategory.live,
          icon: 'video.fill',
          sortOrder: 5,
        ),
        WelfarePlatform(
          platformKey: 'live-7',
          name: '纪录片',
          category: WelfarePlatformCategory.live,
          icon: 'film.fill',
          sortOrder: 6,
        ),
        WelfarePlatform(
          platformKey: 'live-8',
          name: '新闻直播',
          category: WelfarePlatformCategory.live,
          icon: 'photo.fill',
          sortOrder: 7,
        ),
        // 其余两栏各留一项，验证三栏可切换（Golden 仅锁直播栏）。
        WelfarePlatform(
          platformKey: 'video-1',
          name: '视频一',
          category: WelfarePlatformCategory.video,
          icon: 'play.rectangle.fill',
          sortOrder: 0,
        ),
        WelfarePlatform(
          platformKey: 'comic-1',
          name: '漫画一',
          category: WelfarePlatformCategory.comic,
          icon: 'books.vertical.fill',
          sortOrder: 0,
        ),
      ],
    );

/// 福利专区外壳（H-06；注入内存数据源，Golden 不触网）。
Widget _welfare() => ChangeNotifierProvider<WelfarePlatformController>.value(
      value: WelfarePlatformController(
        datasource: InMemoryWelfarePlatformDatasource(config: _liveConfig()),
        cache: InMemoryWelfarePlatformCache(),
        prefs: PrefsManager.instance,
      ),
      child: const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: WelfareHomePage(),
      ),
    );

/// 福利平台设置页外壳（H-07；注入内存数据源 + 内存 Store，Golden 不触网不落盘）。
Widget _welfareSettings(WelfarePlatformController controller) =>
    ChangeNotifierProvider<WelfarePlatformController>.value(
      value: controller,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: WelfareSettingsPage(
          proxyStore: WelfareProxyStore(),
          domainStore: WelfareDomainStore(),
        ),
      ),
    );

/// 通用截图（构建 → 稳定 → 逐像素锁）。
Future<void> _shot(
  WidgetTester tester,
  String name,
  Size size,
  Widget app, {
  Future<void> Function(WidgetTester tester)? before,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final GlobalKey key = GlobalKey();
  await tester.pumpWidget(RepaintBoundary(key: key, child: app));
  await tester.pumpAndSettle();
  if (before != null) {
    await before(tester);
    await tester.pumpAndSettle();
  }
  await expectLater(find.byKey(key), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 控制器经 `PrefsManager.instance` 读契约键，需先注入内存偏好。
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await PrefsManager.instance.init();
  });

  testWidgets('welfare_live_portrait（H-06：福利专区 · 直播栏目 + 4 列平台网格）',
      (WidgetTester tester) async {
    await _shot(
      tester,
      'welfare_live_portrait',
      const Size(390, 844),
      _welfare(),
      before: (WidgetTester tester) async => tester.tap(find.text('直播')),
    );
  });

  testWidgets('welfare_settings_portrait（H-07：福利平台设置 · 远程源版）',
      (WidgetTester tester) async {
    final WelfarePlatformController controller = WelfarePlatformController(
      datasource: InMemoryWelfarePlatformDatasource(config: _liveConfig()),
      cache: InMemoryWelfarePlatformCache(),
      prefs: PrefsManager.instance,
    );
    await controller.refresh();
    await _shot(
      tester,
      'welfare_settings_portrait',
      const Size(390, 844),
      _welfareSettings(controller),
    );
  });
}