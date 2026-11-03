/// 站点诊断页面单测（批次 G · G-08）。
///
/// 唯一真相源：iOS `vbox/Views/SiteDiagnosticsView.swift`
///   · 标题「接口状态诊断」· 摘要卡 6 项 · 9 项筛选器 · 结果列表 + 展开详情；
///   · 设置入口 `SettingsViews.siteDiagnosticsSection`（在 settings_page_test 覆盖）。
///
/// 无真实网络 / 无原生依赖：注入 `SiteDiagnosticsManager`（fake JSC/QuickJS 桥）+
/// 假 [ContentBrowseUseCases] / [RemoteSourceUseCases]。
library;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/usecases/usecases.dart';
import 'package:vbox/platform/runtime/jsc_ffi.dart';
import 'package:vbox/platform/runtime/quickjs_ffi.dart';
import 'package:vbox/presentation/pages/diagnostics/site_diagnostics_manager.dart';
import 'package:vbox/presentation/pages/diagnostics/site_diagnostics_page.dart';

import '../../../support/fakes.dart';

/// 可用桥：`loadScript` 无异常（语法测试通过）。
class _OkBridge implements JsCoreNativeBridge, QuickJsNativeBridge {
  @override
  bool get isAvailable => true;

  @override
  int createRuntime() => 1;

  @override
  int createContext(int runtime) => 1;

  @override
  void freeContext(int context) {}

  @override
  void freeRuntime(int runtime) {}

  @override
  String? eval(int context, String script) => '';
}

Widget _page({
  required ContentBrowseUseCases browse,
  SiteDiagnosticsManager? manager,
}) {
  return MultiProvider(
    providers: [
      Provider<ContentBrowseUseCases>.value(value: browse),
      Provider<RemoteSourceUseCases>.value(
        value: RemoteSourceUseCases(InMemoryRemoteSourceRepository()),
      ),
    ],
    child: MaterialApp(home: SiteDiagnosticsPage(manager: manager)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final PrefsManager prefs = PrefsManager.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await prefs.init();
  });

  setUp(() async {
    await prefs.clearAll();
  });

  ContentBrowseUseCases browseWithThreeSites() => buildContentBrowseUseCases(
        sites: <Map<String, Object?>>[
          siteJson(key: 'api站', type: 0, api: 'https://api.example.com'),
          siteJson(key: '站源站', type: 2),
          siteJson(key: '空蜘蛛', type: 3), // api 为空 → noApi
        ],
      );

  testWidgets('G-08：标题 / 摘要卡 6 项 / 9 项筛选器齐备', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(
      browse: browseWithThreeSites(),
      manager: SiteDiagnosticsManager(
        jscBridge: _OkBridge(),
        qjsBridge: _OkBridge(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('接口状态诊断'), findsOneWidget);
    // 摘要卡 6 项（部分标签与行内徽标/状态文案同名，故按 findsWidgets 校验存在性）
    for (final String label in <String>[
      '总计',
      '引擎就绪',
      '仅API',
      '可搜索',
      'JSC引擎',
      'QJS引擎',
    ]) {
      expect(find.text(label), findsWidgets);
    }
    // 9 项筛选器
    for (final String label in <String>[
      '全部',
      '可搜索',
      '有异常',
      '仅JSC',
      '仅QJS',
      'API(type0)',
      'API(type1)',
      '站源',
      'JS蜘蛛',
    ]) {
      expect(find.text(label), findsWidgets);
    }
    // 诊断完成后列表渲染 3 个站点
    expect(find.text('共 3 个接口'), findsWidgets);
    expect(find.text('api站'), findsOneWidget);
    expect(find.text('站源站'), findsOneWidget);
    expect(find.text('空蜘蛛'), findsOneWidget);
    // 状态文案（对齐 iOS SiteStatus.rawValue）
    expect(find.text('仅API'), findsWidgets);
    expect(find.text('引擎就绪'), findsWidgets);
    expect(find.text('无API地址'), findsOneWidget);
  });

  testWidgets('G-08：筛选「有异常」只保留失败项', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(
      browse: browseWithThreeSites(),
      manager: SiteDiagnosticsManager(
        jscBridge: _OkBridge(),
        qjsBridge: _OkBridge(),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('有异常'));
    await tester.pumpAndSettle();

    expect(find.text('空蜘蛛'), findsOneWidget);
    expect(find.text('api站'), findsNothing);
    expect(find.text('站源站'), findsNothing);
  });

  testWidgets('G-08：点开带错误项 → 展开「问题详情」', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(
      browse: browseWithThreeSites(),
      manager: SiteDiagnosticsManager(
        jscBridge: _OkBridge(),
        qjsBridge: _OkBridge(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('问题详情:'), findsNothing);

    await tester.tap(find.text('空蜘蛛'));
    await tester.pumpAndSettle();

    expect(find.text('问题详情:'), findsOneWidget);
    expect(find.text('api 字段为空'), findsOneWidget);
  });

  testWidgets('G-08：信息行展示远程源状态（configVersion 胶囊）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(
      browse: browseWithThreeSites(),
      manager: SiteDiagnosticsManager(
        jscBridge: _OkBridge(),
        qjsBridge: _OkBridge(),
      ),
    ));
    await tester.pumpAndSettle();

    // 缓存缺失 → idle → displayText「未同步」。
    expect(find.text('未同步'), findsOneWidget);
  });

  testWidgets('G-08：刷新按钮重新触发诊断', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(
      browse: browseWithThreeSites(),
      manager: SiteDiagnosticsManager(
        jscBridge: _OkBridge(),
        qjsBridge: _OkBridge(),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.pumpAndSettle();

    expect(find.text('共 3 个接口'), findsWidgets);
  });
}