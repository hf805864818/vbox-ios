/// 设置页单测（批次 I · I-03 分区骨架 / I-04 显示模式 / I-05 更新入口）。
///
/// 唯一真相源：iOS `vbox/Views/SettingsViews.swift`
///   · L106-L134（`titleBar` + `settingsContent` 分区顺序）；
///   · L136-L173（`skinSettingsSection`）；L175-L220（`playbackSettingsSection`）。
///
/// 契约键经 [PrefsManager]（内存 mock）读写，隔离真实落盘。
library;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/local/source_governance_store.dart';
import 'package:vbox/data/datasources/local/subscribe_config_store.dart';
import 'package:vbox/data/datasources/local/tg_search_config_store.dart';
import 'package:vbox/data/datasources/local/tmdb_config_store.dart';
import 'package:vbox/data/models/zhanyuan.dart';
import 'package:vbox/domain/entities/remote_source/remote_source.dart';
import 'package:vbox/domain/usecases/usecases.dart';
import 'package:vbox/presentation/pages/diagnostics/site_diagnostics_page.dart';
import 'package:vbox/presentation/pages/settings/fallback_slice_source_page.dart';
import 'package:vbox/presentation/pages/settings/parser_manage_page.dart';
import 'package:vbox/presentation/pages/settings/settings_page.dart';
import 'package:vbox/presentation/pages/settings/zhanyuan_site_manage_page.dart';
import 'package:vbox/presentation/theme/vbox_skin_controller.dart';
import 'package:vbox/presentation/ui_mode/ui_mode.dart';
import 'package:vbox/presentation/widgets/vbox/vbox.dart';

import '../../../support/fakes.dart';

Widget _page(
  UiFormController form, {
  ContentBrowseUseCases? browse,
  SourceGovernanceUseCases? governance,
  InMemoryRemoteSourceRepository? remote,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<VboxSkinController>.value(
        value: VboxSkinController(),
      ),
      ChangeNotifierProvider<UiFormController>.value(value: form),
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
      Provider<ContentBrowseUseCases>.value(
        value: browse ?? buildContentBrowseUseCases(),
      ),
      Provider<RemoteSourceUseCases>.value(
        value: RemoteSourceUseCases(
          // 可注入 fake 仓储（远程源区块交互用例），默认全新内存仓储。
          remote ?? InMemoryRemoteSourceRepository(),
        ),
      ),
      // Wave D：源治理用例（切片资源页远程默认源 / 站源管理页清单）。
      if (governance != null)
        Provider<SourceGovernanceUseCases>.value(value: governance),
    ],
    child: const MaterialApp(home: SettingsPage()),
  );
}

/// 取某标题所在设置行内的尾部开关。
Finder _switchInRow(String title) => find.descendant(
      of: find.ancestor(
        of: find.text(title),
        matching: find.byType(VboxSettingsRow),
      ),
      matching: find.byType(Switch),
    );

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
    // Wave D：源治理存储为全局单例，逐例复位避免跨例污染。
    SourceGovernanceStore.instance.resetForTest();
  });

  testWidgets('I-03：分区骨架齐备', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(UiFormController()));
    await tester.pumpAndSettle();

    expect(find.text('皮肤'), findsOneWidget);
    expect(find.text('显示模式'), findsWidgets); // 分区标题 + 行标题
    expect(find.text('播放设置'), findsOneWidget);
    expect(find.text('工具'), findsOneWidget);
    // G-07：订阅配置分区 + 管理订阅源入口。
    expect(find.text('订阅配置'), findsOneWidget);
    expect(find.text('管理订阅源'), findsOneWidget);
    expect(find.text('站点诊断'), findsOneWidget); // G-08 分区标题
    expect(find.text('存储管理'), findsOneWidget);
    expect(find.text('日志调试'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
    expect(find.text('TMDB 设置'), findsOneWidget);
    // Wave D：源治理分区（O-源1/2/3）落地，原「更多设置（待实现）」占位移除。
    expect(find.text('切片资源'), findsOneWidget);
    expect(find.text('站源管理'), findsOneWidget);
    expect(find.text('更多设置（待实现）'), findsNothing);
    expect(find.text('启用兜底切片资源'), findsOneWidget);
    expect(find.text('管理自定义切片源'), findsOneWidget);
    expect(find.text('管理自定义解析器'), findsOneWidget);
    expect(find.text('管理站源（启用/禁用）'), findsOneWidget);
  });

  testWidgets('O-源1：兜底切片资源开关 → 写入契约键 fallback_enabled',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(UiFormController()));
    await tester.pumpAndSettle();

    // 契约键缺省 true（对齐 iOS `fallbackEnabled` 默认开启）。
    await tester.tap(_switchInRow('启用兜底切片资源'));
    await tester.pumpAndSettle();

    expect(await prefs.getBool('fallback_enabled'), isFalse);
  });

  testWidgets('O-源3：管理自定义切片源 → 进入切片资源管理页', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(UiFormController()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('管理自定义切片源'));
    await tester.pumpAndSettle();

    expect(find.byType(FallbackSliceSourcePage), findsOneWidget);
    expect(find.text('切片资源管理'), findsOneWidget);
    expect(find.text('添加自定义切片源'), findsOneWidget);
  });

  testWidgets('O-源2：管理自定义解析器 → 进入解析器管理页', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(UiFormController()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('管理自定义解析器'));
    await tester.pumpAndSettle();

    expect(find.byType(ParserManagePage), findsOneWidget);
    expect(find.text('解析器管理'), findsOneWidget);
    expect(find.text('暂无自定义解析器'), findsOneWidget);
  });

  testWidgets('O-源3：管理站源 → 进入站源管理页', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(UiFormController()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('管理站源（启用/禁用）'));
    await tester.pumpAndSettle();

    expect(find.byType(ZhanyuanSiteManagePage), findsOneWidget);
    expect(find.text('站源管理'), findsWidgets);
    expect(find.text('搜索站点'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
  });

  testWidgets('O-源3：切片资源管理页经 Provider 读取远程默认源',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final SourceGovernanceUseCases governance = SourceGovernanceUseCases(
      loadAllSources: () async => const Success<AllSourcesContainer>(
        AllSourcesContainer(
          apiSources: <String, Object?>{
            'sites': <Map<String, Object?>>[
              <String, Object?>{
                'key': 'api_1',
                'name': '接口源',
                'type': 0,
                'api': 'https://api.example.com/api.php',
              },
            ],
          },
        ),
      ),
    );

    await tester.pumpWidget(_page(UiFormController(), governance: governance));
    await tester.pumpAndSettle();

    await tester.tap(find.text('管理自定义切片源'));
    await tester.pumpAndSettle();

    // 经 Provider 取得用例 → 远程默认源（apiEndpoint 站点）只读展示。
    expect(find.text('远程默认源'), findsOneWidget);
    expect(find.text('接口源'), findsOneWidget);
  });

  testWidgets('O-源3：站源管理页经 Provider 展示订阅站源清单',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final SourceGovernanceUseCases governance = SourceGovernanceUseCases(
      loadAllSources: () async => const Success<AllSourcesContainer>(
        AllSourcesContainer(),
      ),
      loadAllZhanyuanSites: () async => const <Zhanyuan>[
        Zhanyuan(
          key: 'zhan_1',
          name: '订阅站源',
          searchUrl: 'https://zhan.example.com',
          isActive: true,
          updatedAt: 0,
        ),
      ],
    );

    await tester.pumpWidget(_page(UiFormController(), governance: governance));
    await tester.pumpAndSettle();

    await tester.tap(find.text('管理站源（启用/禁用）'));
    await tester.pumpAndSettle();

    expect(find.text('订阅站源'), findsOneWidget);
    expect(find.text('启用 1/1 个站点'), findsOneWidget);
  });

  testWidgets('G-08：站点诊断入口展示接口总数并可进入诊断页', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ContentBrowseUseCases browse = buildContentBrowseUseCases(
      sites: <Map<String, Object?>>[
        siteJson(key: 'a', type: 0, api: 'https://a.example.com/api'),
        siteJson(key: 'b', type: 2),
      ],
    );
    await tester.pumpWidget(_page(UiFormController(), browse: browse));
    await tester.pumpAndSettle();

    // 入口行：标题「接口状态检测」+ 尾部「共 N 个接口」。
    expect(find.text('接口状态检测'), findsOneWidget);
    expect(find.text('共 2 个接口'), findsOneWidget);

    await tester.tap(find.text('接口状态检测'));
    await tester.pumpAndSettle();
    expect(find.byType(SiteDiagnosticsPage), findsOneWidget);
    expect(find.text('接口状态诊断'), findsOneWidget);
    // 诊断页启动后回填远程源信息行。
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('I-03：工具分区仅网盘管理（远程源页已收敛，对齐 iOS）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(UiFormController()));
    await tester.pumpAndSettle();

    // 对齐 iOS：设置页工具区 = 网盘管理（书架已按 iOS 真相源移除）；
    // 「远程源」独立页无 iOS 对应（订阅管理走上方「管理订阅源」、源发现走
    // 首页站点态覆盖层、远程默认源开关走订阅配置内联区块），入口已移除；
    // 无「备份还原」（其唯一入口在个人中心功能宫格且仅登录态显示，
    // ProfileView L464-466）。
    expect(find.text('书架'), findsNothing);
    expect(find.text('远程源'), findsNothing);
    expect(find.text('网盘管理'), findsOneWidget);
    expect(find.text('备份还原'), findsNothing);
  });

  testWidgets('I-03：皮肤四选 + 跟随系统开关存在', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(UiFormController()));
    await tester.pumpAndSettle();

    expect(find.byType(VboxSkinPicker), findsOneWidget);
    expect(find.text('黑暗/浅色跟随手机外观'), findsOneWidget);
    expect(_switchInRow('黑暗/浅色跟随手机外观'), findsOneWidget);
  });

  testWidgets('I-04：选择显示模式 → 写入 app_ui_form_override 并热切换',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final UiFormController form = UiFormController();
    await tester.pumpWidget(_page(form));
    await tester.pumpAndSettle();
    expect(form.override, UiFormOverride.auto);

    await tester.tap(find.text('当前：自动'));
    await tester.pumpAndSettle();
    // 对话框列出三档（自动 / 手机竖屏 / 大屏横屏）。
    expect(find.text('手机（竖屏）'), findsOneWidget);
    expect(find.text('大屏（横屏）'), findsOneWidget);

    await tester.tap(find.text('手机（竖屏）'));
    await tester.pumpAndSettle();

    expect(form.override, UiFormOverride.portrait);
    expect(await prefs.getString('app_ui_form_override'), 'portrait');
    expect(find.text('当前：手机（竖屏）'), findsOneWidget);
    // 切换成功后的 VboxToast 会挂 2s 自动关闭 Timer，需排空以免 teardown 断言失败。
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('I-03：自定义弹幕源开关 → 写入契约键并展开地址输入行',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(UiFormController()));
    await tester.pumpAndSettle();

    // 关闭态：无输入行。
    expect(find.byType(VboxSettingsInputRow), findsNothing);

    await tester.tap(_switchInRow('自定义弹幕源'));
    await tester.pumpAndSettle();

    expect(await prefs.getBool('custom_danmaku_source_enabled'), isTrue);
    expect(find.byType(VboxSettingsInputRow), findsOneWidget);
  });

  testWidgets('I-05：关于分区展示版本号 + 检查更新入口', (WidgetTester tester) async {
    // G-09 后订阅配置区块新增内联远程源编辑区，页面总高增加，视口需相应放大。
    tester.view.physicalSize = const Size(390, 3400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(UiFormController()));
    await tester.pumpAndSettle();

    expect(find.text('版本'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
  });

  testWidgets('G-09：订阅配置区块内联远程默认源编辑区（无需进入子页）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(UiFormController()));
    await tester.pumpAndSettle();

    // 内联编辑区齐备（对齐 iOS subscriptionSection：开关 + 地址 + 按钮 + 状态行）。
    expect(find.text('启用远程默认源'), findsOneWidget);
    expect(find.text('默认源地址'), findsOneWidget);
    expect(find.text('manifest.json 地址'), findsOneWidget);
    expect(find.text('刷新远程源'), findsOneWidget);
    expect(find.text('清缓存'), findsOneWidget);
    expect(find.textContaining('配置版本：'), findsOneWidget);
    // 双模式兼容行（对齐 iOS 同区块独立开关）。
    expect(find.text('双模式兼容'), findsOneWidget);
    expect(_switchInRow('双模式兼容'), findsOneWidget);

    // 内联区块的启用开关可直接切换（区块自带 Switch，非导航行）。
    final Finder inlineSwitch = find.descendant(
      of: find.ancestor(
        of: find.text('启用远程默认源'),
        matching: find.byType(Row),
      ),
      matching: find.byType(Switch),
    );
    expect(inlineSwitch, findsOneWidget);
    final bool before =
        tester.widget<Switch>(inlineSwitch).value;
    await tester.tap(inlineSwitch);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(inlineSwitch).value, !before);
  });

  testWidgets('G-09：双模式兼容开关 → 写入契约键 enable_dual_mode',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(UiFormController()));
    await tester.pumpAndSettle();

    // 契约缺省 true（对齐 iOS `SpiderManager.enableDualMode` 默认开）。
    await tester.tap(_switchInRow('双模式兼容'));
    await tester.pumpAndSettle();

    expect(await prefs.getBool('enable_dual_mode'), isFalse);
  });

  // ---- 远程默认源区块交互用例（原 remote_source_page_test.dart 迁入：入口
  // ---- 收敛后区块仅在设置页提供，对齐 iOS `SettingsViews.subscriptionSection`）。

  testWidgets('G-09：清单刷新：强制拉取并展示远程版本', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final InMemoryRemoteSourceRepository remote =
        InMemoryRemoteSourceRepository()..fetchResult = buildManifest();
    await tester.pumpWidget(_page(UiFormController(), remote: remote));
    await tester.pumpAndSettle();

    // idle 态副标题。
    expect(find.text('未同步'), findsOneWidget);

    await tester.ensureVisible(find.text('刷新远程源'));
    await tester.tap(find.text('刷新远程源'));
    await tester.pumpAndSettle();

    expect(remote.fetchCount, 1);
    // 刷新成功后副标题为 loadedRemote displayText（对齐原远程源页用例断言）。
    expect(find.textContaining('远程配置 2026.09.29.1'), findsOneWidget);
  });

  testWidgets('G-09：刷新失败：区块副标题显示失败信息', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 未设置 fetchResult → fake 返回 UnknownFailure。
    final InMemoryRemoteSourceRepository remote =
        InMemoryRemoteSourceRepository();
    await tester.pumpWidget(_page(UiFormController(), remote: remote));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('刷新远程源'));
    await tester.tap(find.text('刷新远程源'));
    await tester.pumpAndSettle();

    expect(remote.fetchCount, 1);
    expect(find.textContaining('失败：'), findsOneWidget);
  });

  testWidgets('G-09：清缓存 → 触发仓储 clearCache，版本回退为「无」',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final InMemoryRemoteSourceRepository remote =
        InMemoryRemoteSourceRepository()
          ..cached = buildManifest()
          ..cachedAt = 1700000000
          ..settingsValue = const RemoteSourceSettings(
            enabled: true,
            manifestUrl: 'https://example.com/m.json',
            lastConfigVersion: '2026.09.29.1',
            lastSyncTimeSeconds: 1700000000,
          );
    await tester.pumpWidget(_page(UiFormController(), remote: remote));
    await tester.pumpAndSettle();

    // 对齐 iOS `SettingsViews` 远程源区块：开关 + 默认源地址 + 版本/时间信息行。
    expect(find.text('启用远程默认源'), findsOneWidget);
    expect(find.text('默认源地址'), findsOneWidget);
    expect(find.text('https://example.com/m.json'), findsOneWidget);
    expect(find.textContaining('配置版本：2026.09.29.1'), findsOneWidget);
    expect(find.textContaining('同步时间：'), findsOneWidget);

    await tester.ensureVisible(find.text('清缓存'));
    await tester.tap(find.text('清缓存'));
    await tester.pumpAndSettle();

    expect(remote.clearCacheCount, 1);
    expect(find.textContaining('已清空远程源缓存'), findsOneWidget);
    expect(find.textContaining('配置版本：无'), findsOneWidget);
  });
}