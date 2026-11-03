/// 呈现层单测：福利专区首页（批次 H · H-06）。
///
/// 覆盖：三栏目 Tab + 平台网格（默认视频栏目）、栏目切换、空分类提示、失败态 + 重试、
/// 平台点击路由（未支持页 / 目标页面族提示 / JS·Python Spider 引擎执行页 / 脚本状态页）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/welfare/welfare.dart';
import 'package:vbox/domain/services/welfare_js_spider_service.dart';
import 'package:vbox/domain/services/welfare_python_spider_service.dart';
import 'package:vbox/presentation/pages/welfare/kanliao_home_page.dart';
import 'package:vbox/presentation/pages/welfare/welfare_home_page.dart';
import 'package:vbox/presentation/pages/welfare/welfare_spider_home_page.dart';
import 'package:vbox/presentation/pages/welfare/welfare_spider_main_page.dart';
import 'package:vbox/presentation/welfare/welfare_platform_controller.dart';

import '../../../support/fakes.dart';

Widget _page(WelfarePlatformController controller) =>
    ChangeNotifierProvider<WelfarePlatformController>.value(
      value: controller,
      child: const MaterialApp(home: WelfareHomePage()),
    );

WelfarePlatformController controllerWith({
  WelfarePlatformConfig? config,
}) =>
    WelfarePlatformController(
      datasource: InMemoryWelfarePlatformDatasource(config: config),
      cache: InMemoryWelfarePlatformCache(),
      prefs: PrefsManager.instance,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await PrefsManager.instance.init();
  });

  setUp(() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.clear();
    // 引擎服务按 platformKey 静态缓存，避免用例间互相污染。
    WelfareJSSpiderService.clearCache();
    WelfarePythonSpiderService.clearCache();
  });

  testWidgets('三栏目 Tab 齐备，默认视频栏目显示其平台', (WidgetTester tester) async {
    await tester.pumpWidget(
      _page(controllerWith(config: buildWelfarePlatformConfig())),
    );
    await tester.pumpAndSettle();

    // 分段三栏。
    expect(find.text('视频'), findsOneWidget);
    expect(find.text('直播'), findsOneWidget);
    expect(find.text('漫画'), findsOneWidget);

    // 默认视频栏目的平台可见，他栏不可见。
    expect(find.text('平台甲'), findsOneWidget);
    expect(find.text('平台乙'), findsOneWidget);
    expect(find.text('直播甲'), findsNothing);
    expect(find.text('漫画甲'), findsNothing);
  });

  testWidgets('切换栏目 → 仅显示该栏目平台', (WidgetTester tester) async {
    await tester.pumpWidget(
      _page(controllerWith(config: buildWelfarePlatformConfig())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('直播'));
    await tester.pumpAndSettle();

    expect(find.text('直播甲'), findsOneWidget);
    expect(find.text('平台甲'), findsNothing);

    await tester.tap(find.text('漫画'));
    await tester.pumpAndSettle();
    expect(find.text('漫画甲'), findsOneWidget);
    expect(find.text('直播甲'), findsNothing);
  });

  testWidgets('空分类 → 显示「此分类下暂无平台」', (WidgetTester tester) async {
    await tester.pumpWidget(
      _page(
        controllerWith(
          config: const WelfarePlatformConfig(
            meta: <String, Object?>{'version': 'x'},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('此分类下暂无平台'), findsOneWidget);
  });

  testWidgets('拉取失败 → 显示错误消息与重试按钮', (WidgetTester tester) async {
    await tester.pumpWidget(_page(controllerWith()));
    await tester.pumpAndSettle();

    expect(find.text('fake 未配置福利平台数据'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('点击未支持平台（缺 serviceType）→ 进入未支持平台页', (WidgetTester tester) async {
    await tester.pumpWidget(
      _page(controllerWith(config: buildWelfarePlatformConfig())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('平台甲'));
    await tester.pumpAndSettle();

    expect(find.text('该平台暂不可用'), findsOneWidget);
  });

  testWidgets('点击原生专用平台（kanliao）→ 进入今日看料专页（UI-C1e）',
      (WidgetTester tester) async {
    const WelfarePlatformConfig config = WelfarePlatformConfig(
      meta: <String, Object?>{'version': 'x'},
      platforms: <WelfarePlatform>[
        WelfarePlatform(
          platformKey: 'kanliao-1',
          name: '今日看料',
          category: WelfarePlatformCategory.video,
          serviceType: 'kanliao',
        ),
      ],
    );
    await tester.pumpWidget(_page(controllerWith(config: config)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('今日看料'));
    await tester.pumpAndSettle();

    // UI-C1e：今日看料原生专用页已落地，路由直达专页（不再进未支持页）。
    expect(find.byType(KanliaoHomePage), findsOneWidget);
  });

  testWidgets('点击 JS 福利 Spider 平台 → 进入 JS 引擎执行页', (WidgetTester tester) async {
    const WelfarePlatformConfig config = WelfarePlatformConfig(
      meta: <String, Object?>{'version': 'x'},
      platforms: <WelfarePlatform>[
        WelfarePlatform(
          platformKey: 'js-spider-1',
          name: 'JS蜘蛛',
          category: WelfarePlatformCategory.video,
          serviceType: 'welfare_spider',
          scriptType: 'javascript',
          api: 'welfare-js/js_demo.js',
          defaultHosts: <String>['https://a.example.com'],
        ),
      ],
    );
    await tester.pumpWidget(_page(controllerWith(config: config)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('JS蜘蛛'));
    await tester.pumpAndSettle();

    // 路由到引擎执行页（对齐 iOS `FuliPlatformMainView + WelfareJSSpiderService`）；
    // 测试环境无网络 → 引擎初始化失败 → 首页错误态。
    expect(find.byType(WelfareSpiderMainPage), findsOneWidget);
    expect(find.text('未能解析到分类，请检查域名或网络'), findsOneWidget);
  });

  testWidgets('点击 Python 福利 Spider 平台 → 进入 Python 桥执行页', (WidgetTester tester) async {
    const WelfarePlatformConfig config = WelfarePlatformConfig(
      meta: <String, Object?>{'version': 'x'},
      platforms: <WelfarePlatform>[
        WelfarePlatform(
          platformKey: 'py-spider-1',
          name: 'Py蜘蛛',
          category: WelfarePlatformCategory.video,
          serviceType: 'python_spider',
          scriptType: 'python',
          api: 'welfare-js/py_demo.py',
          defaultHosts: <String>['https://a.example.com'],
        ),
      ],
    );
    await tester.pumpWidget(_page(controllerWith(config: config)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Py蜘蛛'));
    await tester.pumpAndSettle();

    expect(find.byType(WelfareSpiderMainPage), findsOneWidget);
    expect(find.text('未能解析到分类，请检查域名或网络'), findsOneWidget);
  });

  testWidgets('点击非 JS 福利 Spider 平台 → 进入脚本状态页', (WidgetTester tester) async {
    const WelfarePlatformConfig config = WelfarePlatformConfig(
      meta: <String, Object?>{'version': 'x'},
      platforms: <WelfarePlatform>[
        WelfarePlatform(
          platformKey: 'spider-1',
          name: '脚本蜘蛛',
          category: WelfarePlatformCategory.video,
          serviceType: 'welfare_spider',
          api: 'welfare-js/plain.py',
          defaultHosts: <String>['https://a.example.com'],
        ),
      ],
    );
    await tester.pumpWidget(_page(controllerWith(config: config)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('脚本蜘蛛'));
    await tester.pumpAndSettle();

    expect(find.byType(WelfareSpiderHomePage), findsOneWidget);
  });
}