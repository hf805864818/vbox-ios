/// 视觉回归 Golden 基线：批次 I 页面族（I-01 / I-02 / I-03）。
///
/// 依据：`docs/UI对齐_H_I开工前置_v1.8.md` §11.1 **C2**（补 H/I 页面族 Golden）：
///   · I-01 个人中心 → 对齐图10 `个人中心主页面.PNG`；
///   · I-02 登录弹窗 → 对齐图11 `个人中心账号登陆页面.PNG`；
///   · I-03 设置页   → 对齐图12 `整个设置页面可以上下滑动查看更多.PNG`。
///
/// 机制同 `app_pages_golden_test.dart`：真实页面渲染 → `matchesGoldenFile` 像素锁；
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
import 'package:vbox/data/datasources/local/subscribe_config_store.dart';
import 'package:vbox/data/datasources/local/tg_search_config_store.dart';
import 'package:vbox/data/datasources/local/tmdb_config_store.dart';
import 'package:vbox/domain/entities/library/library.dart';
import 'package:vbox/domain/usecases/usecases.dart';
import 'package:vbox/platform/download/download.dart';
import 'package:vbox/presentation/pages/settings/settings_page.dart';
import 'package:vbox/presentation/profile/session_controller.dart';
import 'package:vbox/presentation/shell/home_shell_page.dart';
import 'package:vbox/presentation/theme/vbox_skin_controller.dart';
import 'package:vbox/presentation/ui_mode/ui_mode_resolver.dart';
import 'package:vbox/presentation/welfare/welfare_controller.dart';
import 'package:vbox/presentation/widgets/vbox/vbox.dart';

import '../support/fakes.dart';

/// 个人中心外壳（含全端统一底栏，贴近图10 的整体版式）。
Widget _shell() {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<UiFormController>.value(
        value: UiFormController(
          env: const UiFormEnv(override: UiFormOverride.portrait, hasTouch: true),
        ),
      ),
      ChangeNotifierProvider<VboxSkinController>.value(
        value: VboxSkinController(),
      ),
      ChangeNotifierProvider<WelfareController>.value(
        value: WelfareController(),
      ),
      // G-02：首页外壳消费下载胶囊/悬浮按键（内存 store，不触库不触网）。
      ChangeNotifierProvider<DownloadManager>.value(
        value: DownloadManager(
          store: InMemoryDownloadStore(),
          downloadsDirectory: '/tmp/vbox_test/dl',
        ),
      ),
      ChangeNotifierProvider<SessionController>.value(
        value: SessionController(store: InMemorySettingsStore()),
      ),
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
      Provider<DoubanUseCases>.value(value: buildDoubanUseCases()),
    ],
    child: const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: HomeShellPage(),
    ),
  );
}

/// 设置页外壳（I-03；消费皮肤与显示模式控制器）。
Widget _settings() {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<UiFormController>.value(value: UiFormController()),
      ChangeNotifierProvider<VboxSkinController>.value(
        value: VboxSkinController(),
      ),
      // G-04：TG 搜索分区消费配置存储。
      ChangeNotifierProvider<TGSearchConfigStore>.value(
        value: TGSearchConfigStore(),
      ),
      // G-07：订阅配置分区消费订阅存储。
      ChangeNotifierProvider<SubscribeConfigStore>.value(
        value: SubscribeConfigStore(prefs: PrefsManager.instance),
      ),
      // G-06：TMDB 分区消费 TMDB 配置存储。
      ChangeNotifierProvider<TmdbConfigStore>.value(
        value: TmdbConfigStore(),
      ),
      // G-08：设置页站点诊断入口读 `ContentBrowseUseCases.listSites()` 取接口总数。
      Provider<ContentBrowseUseCases>.value(
        value: buildContentBrowseUseCases(),
      ),
      // 订阅配置内联「远程默认源」编辑区消费 RemoteSourceUseCases。
      Provider<RemoteSourceUseCases>.value(
        value: RemoteSourceUseCases(InMemoryRemoteSourceRepository()),
      ),
    ],
    child: const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SettingsPage(),
    ),
  );
}

/// 登录弹窗内容（I-02；空态：账号为空 → 主按钮禁用）。
Widget _loginSheet() {
  final TextEditingController username = TextEditingController();
  final TextEditingController password = TextEditingController();
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: VboxLoginSheet(
        usernameController: username,
        passwordController: password,
      ),
    ),
  );
}

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

  // 设置页经 `PrefsManager.instance` 读契约键，需先注入内存偏好。
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await PrefsManager.instance.init();
  });

  testWidgets('profile_portrait（I-01：个人中心 · 未登录头部 + 底栏）',
      (WidgetTester tester) async {
    await _shot(
      tester,
      'profile_portrait',
      const Size(390, 844),
      _shell(),
      before: (WidgetTester tester) async => tester.tap(find.text('我的')),
    );
  });

  testWidgets('login_sheet（I-02：登录弹窗 · 空态禁用）', (WidgetTester tester) async {
    await _shot(
      tester,
      'login_sheet',
      const Size(390, 844),
      _loginSheet(),
    );
  });

  testWidgets('settings_portrait（I-03：设置页 · 全分区）', (WidgetTester tester) async {
    await _shot(
      tester,
      'settings_portrait',
      const Size(390, 2400),
      _settings(),
    );
  });
}