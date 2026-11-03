/// 呈现层单测：福利平台设置页 + 域名编辑页（批次 H · H-07）。
///
/// 对齐 iOS `WelfareSettingsView` / `RemoteWelfareSettingsView`：
///   · 远程源开关（开/关切换 remote 主体 / 远程源关闭态）；
///   · 远程源状态区（状态行 + 立即同步）；
///   · 代理设置（输入 + 保存 / 清除 + 平台代理开关折叠列表，未设代理置灰）；
///   · 平台列表按分类分组（名称 + `[platformKey]` + 描述 + 当前域名：自定义优先）；
///   · 域名编辑页（添加校验 / 默认域名勾选 / 自定义域名增删清空）。
///
/// 约定：长页为 ListView（懒加载），断言 / 点击前先 [scrollTo] 使目标可见；
/// 触发 VboxToast 的用例末尾 `pump(3s)` 排空 2s 自动关闭 Timer（项目惯例）。
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
import 'package:vbox/presentation/pages/welfare/welfare_settings_page.dart';
import 'package:vbox/presentation/welfare/welfare_platform_controller.dart';

import '../../../support/fakes.dart';

const WelfarePlatform _platformA = WelfarePlatform(
  platformKey: 'video-1',
  name: '平台甲',
  category: WelfarePlatformCategory.video,
  desc: '描述甲',
  defaultHosts: <String>['https://default-a.example.com', 'https://default-a2.example.com'],
);

const WelfarePlatform _platformB = WelfarePlatform(
  platformKey: 'video-2',
  name: '平台乙',
  category: WelfarePlatformCategory.video,
  desc: '描述乙',
  defaultHosts: <String>['https://default-b.example.com'],
);

const WelfarePlatform _liveA = WelfarePlatform(
  platformKey: 'live-1',
  name: '直播甲',
  category: WelfarePlatformCategory.live,
  desc: '描述直播',
  defaultHosts: <String>['https://default-live.example.com'],
);

const WelfarePlatformConfig _config = WelfarePlatformConfig(
  meta: <String, Object?>{'version': '2026.10.03.1'},
  platforms: <WelfarePlatform>[_platformA, _platformB, _liveA],
);

Future<WelfarePlatformController> _readyController(
  WelfarePlatformConfig config,
) async {
  final WelfarePlatformController controller = WelfarePlatformController(
    datasource: InMemoryWelfarePlatformDatasource(config: config),
    cache: InMemoryWelfarePlatformCache(config: config),
    prefs: PrefsManager.instance,
  );
  await controller.bootstrap();
  return controller;
}

Widget _page(
  WelfarePlatformController controller, {
  WelfareProxyStore? proxyStore,
  WelfareDomainStore? domainStore,
}) =>
    ChangeNotifierProvider<WelfarePlatformController>.value(
      value: controller,
      child: MaterialApp(
        home: WelfareSettingsPage(
          proxyStore: proxyStore,
          domainStore: domainStore,
        ),
      ),
    );

/// 滚动主 ListView 直到 [finder] 可见（List 懒加载，视口外不构建）。
Future<void> scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

/// 打开设置页并进入「平台甲」的域名编辑页。
Future<void> openDomainEdit(
  WidgetTester tester, {
  required WelfareProxyStore proxyStore,
  required WelfareDomainStore domainStore,
}) async {
  final WelfarePlatformController controller = await _readyController(_config);
  await tester.pumpWidget(_page(controller, proxyStore: proxyStore, domainStore: domainStore));
  await tester.pumpAndSettle();
  await scrollTo(tester, find.text('平台甲'));
  await tester.tap(find.text('平台甲'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late WelfareProxyStore proxyStore;
  late WelfareDomainStore domainStore;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await PrefsManager.instance.init();
  });

  setUp(() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.clear();
    proxyStore = WelfareProxyStore(prefs: PrefsManager.instance);
    domainStore = WelfareDomainStore(prefs: PrefsManager.instance);
  });

  group('远程源开关', () {
    testWidgets('默认开启 → 远程源版主体（状态区 + 代理设置 + 平台列表 + 调试）',
        (WidgetTester tester) async {
      final WelfarePlatformController controller = await _readyController(_config);
      await tester.pumpWidget(_page(controller, proxyStore: proxyStore, domainStore: domainStore));
      await tester.pumpAndSettle();

      // 顶部：开关 + 状态区 + 代理设置。
      expect(find.text('使用福利远程源'), findsOneWidget);
      expect(find.text('远程源状态'), findsOneWidget);
      expect(find.textContaining('已就绪 · 3 个平台'), findsOneWidget);
      expect(find.text('立即同步'), findsOneWidget);
      expect(find.text('代理设置'), findsOneWidget);

      // 平台列表：视频分类分组。
      await scrollTo(tester, find.text('视频'));
      expect(find.text('平台甲'), findsOneWidget);
      expect(find.text('平台乙'), findsOneWidget);
      expect(find.textContaining('[video-1]'), findsOneWidget);
      expect(find.text('描述甲'), findsOneWidget);

      // 直播分类。
      await scrollTo(tester, find.text('直播'));
      expect(find.text('直播甲'), findsOneWidget);

      // 调试区。
      await scrollTo(tester, find.text('调试'));
      expect(find.text('清空远程源缓存'), findsOneWidget);
    });

    testWidgets('关闭开关 → 远程源关闭态（提示开启远程源，平台列表消失）',
        (WidgetTester tester) async {
      final WelfarePlatformController controller = await _readyController(_config);
      await tester.pumpWidget(_page(controller, proxyStore: proxyStore, domainStore: domainStore));
      await tester.pumpAndSettle();

      // 远程源开关是页面第一个 Switch。
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(find.text('请开启上方「使用福利远程源」'), findsOneWidget);
      expect(find.text('平台甲'), findsNothing);
      expect(find.text('远程源状态'), findsNothing);
      expect(find.text('代理设置'), findsOneWidget);
    });
  });

  group('远程源状态副标题（W-福8）', () {
    testWidgets('已就绪且有 version → 副标题展示 version', (WidgetTester tester) async {
      final WelfarePlatformController controller = await _readyController(_config);
      await tester.pumpWidget(_page(controller, proxyStore: proxyStore, domainStore: domainStore));
      await tester.pumpAndSettle();

      expect(find.text('远程源状态'), findsOneWidget);
      expect(find.text('version: 2026.10.03.1'), findsOneWidget);
    });

    testWidgets('已就绪但无 version → 副标题回退「上次成功」', (WidgetTester tester) async {
      final WelfarePlatformController controller =
          await _readyController(const WelfarePlatformConfig(
        meta: <String, Object?>{},
        platforms: <WelfarePlatform>[_platformA],
      ));
      await tester.pumpWidget(_page(controller, proxyStore: proxyStore, domainStore: domainStore));
      await tester.pumpAndSettle();

      expect(find.textContaining('上次成功：'), findsOneWidget);
    });

    testWidgets('拉取失败 → 副标题展示错误信息', (WidgetTester tester) async {
      final WelfarePlatformController controller = WelfarePlatformController(
        datasource: InMemoryWelfarePlatformDatasource(),
        cache: InMemoryWelfarePlatformCache(),
        prefs: PrefsManager.instance,
      );
      await controller.bootstrap();
      await tester.pumpWidget(_page(controller, proxyStore: proxyStore, domainStore: domainStore));
      await tester.pumpAndSettle();

      expect(find.text('拉取失败'), findsOneWidget);
      expect(find.text('fake 未配置福利平台数据'), findsOneWidget);
    });
  });

  group('代理设置', () {
    testWidgets('保存代理 → 显示清除按钮，平台代理开关计数可用', (WidgetTester tester) async {
      final WelfarePlatformController controller = await _readyController(_config);
      await tester.pumpWidget(_page(controller, proxyStore: proxyStore, domainStore: domainStore));
      await tester.pumpAndSettle();

      // 未设代理：无「清除代理」，计数显示「未设置代理」。
      await scrollTo(tester, find.text('平台代理开关'));
      expect(find.text('清除代理'), findsNothing);
      expect(find.text('未设置代理'), findsOneWidget);

      await scrollTo(tester, find.byType(TextField).first);
      await tester.enterText(
        find.byType(TextField).first,
        'https://proxy.example.com/?token=abc&url=',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存代理'));
      await tester.pumpAndSettle();

      expect(proxyStore.hasValidProxy, isTrue);
      expect(proxyStore.proxyURL, 'https://proxy.example.com/?token=abc&url=');
      await scrollTo(tester, find.text('清除代理'));
      expect(find.text('清除代理'), findsOneWidget);
      await scrollTo(tester, find.text('0/3 已开启'));
      expect(find.text('0/3 已开启'), findsOneWidget);

      // 排空「代理已保存」toast。
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('展开平台代理开关 → 逐平台开关行，可切换并计数', (WidgetTester tester) async {
      final WelfarePlatformController controller = await _readyController(_config);
      await tester.pumpWidget(_page(controller, proxyStore: proxyStore, domainStore: domainStore));
      await tester.pumpAndSettle();

      // 设置代理。
      await scrollTo(tester, find.byType(TextField).first);
      await tester.enterText(find.byType(TextField).first, 'https://proxy.example.com/');
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存代理'));
      await tester.pumpAndSettle();

      // 展开折叠列表。
      await scrollTo(tester, find.text('平台代理开关'));
      await tester.tap(find.text('平台代理开关'));
      await tester.pumpAndSettle();

      // 打开「平台甲」开关行内的 Switch（平台列表行无 Switch，可唯一定位）。
      final Finder platformASwitch = find
          .descendant(
            of: find.ancestor(
              of: find.text('平台甲'),
              matching: find.byType(ListTile),
            ),
            matching: find.byType(Switch),
          )
          .first;
      await tester.ensureVisible(platformASwitch);
      await tester.pumpAndSettle();
      await tester.tap(platformASwitch);
      await tester.pumpAndSettle();

      expect(proxyStore.isProxyEnabled('平台甲'), isTrue);
      await scrollTo(tester, find.text('1/3 已开启'));
      expect(find.text('1/3 已开启'), findsOneWidget);

      // 排空 toast。
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('清除代理 → 连带清空平台开关，恢复「未设置代理」', (WidgetTester tester) async {
      final WelfarePlatformController controller = await _readyController(_config);
      await tester.pumpWidget(_page(controller, proxyStore: proxyStore, domainStore: domainStore));
      await tester.pumpAndSettle();

      // 保存代理。
      await scrollTo(tester, find.byType(TextField).first);
      await tester.enterText(find.byType(TextField).first, 'https://proxy.example.com/');
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存代理'));
      await tester.pumpAndSettle();

      // 先开启一个平台开关（平台列表行无 Switch，可唯一定位开关行）。
      await scrollTo(tester, find.text('平台代理开关'));
      await tester.tap(find.text('平台代理开关'));
      await tester.pumpAndSettle();
      final Finder platformASwitch = find
          .descendant(
            of: find.ancestor(
              of: find.text('平台甲'),
              matching: find.byType(ListTile),
            ),
            matching: find.byType(Switch),
          )
          .first;
      await tester.ensureVisible(platformASwitch);
      await tester.pumpAndSettle();
      await tester.tap(platformASwitch);
      await tester.pumpAndSettle();
      expect(proxyStore.isProxyEnabled('平台甲'), isTrue);

      // 清除代理。
      await scrollTo(tester, find.text('清除代理'));
      await tester.tap(find.text('清除代理'));
      await tester.pumpAndSettle();

      expect(proxyStore.hasValidProxy, isFalse);
      expect(proxyStore.enabledPlatforms, isEmpty);
      await scrollTo(tester, find.text('未设置代理'));
      expect(find.text('未设置代理'), findsOneWidget);
      expect(find.text('清除代理'), findsNothing);

      // 排空 toast（保存 + 清除）。
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('平台列表与当前域名', () {
    testWidgets('无自定义域名 → 显示默认首个域名', (WidgetTester tester) async {
      final WelfarePlatformController controller = await _readyController(_config);
      await tester.pumpWidget(_page(controller, proxyStore: proxyStore, domainStore: domainStore));
      await tester.pumpAndSettle();

      await scrollTo(tester, find.text('平台甲'));
      expect(find.text('https://default-a.example.com'), findsOneWidget);
      await scrollTo(tester, find.text('直播甲'));
      expect(find.text('https://default-live.example.com'), findsOneWidget);
    });

    testWidgets('自定义域名优先于默认域名显示', (WidgetTester tester) async {
      domainStore.addDomain('平台甲', 'https://custom-a.example.com');
      final WelfarePlatformController controller = await _readyController(_config);
      await tester.pumpWidget(_page(controller, proxyStore: proxyStore, domainStore: domainStore));
      await tester.pumpAndSettle();

      await scrollTo(tester, find.text('平台甲'));
      expect(find.text('https://custom-a.example.com'), findsOneWidget);
      expect(find.text('https://default-a.example.com'), findsNothing);
    });

    testWidgets('启用代理的平台行显示代理标识', (WidgetTester tester) async {
      proxyStore.setProxyURL('https://proxy.example.com/');
      proxyStore.setProxyEnabled(true, '平台甲');
      final WelfarePlatformController controller = await _readyController(_config);
      await tester.pumpWidget(_page(controller, proxyStore: proxyStore, domainStore: domainStore));
      await tester.pumpAndSettle();

      await scrollTo(tester, find.text('平台甲'));
      final Finder platformARow = find.ancestor(
        of: find.text('平台甲'),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(of: platformARow, matching: find.byIcon(Icons.network_check)),
        findsOneWidget,
      );
    });
  });

  group('域名编辑页', () {
    testWidgets('表单齐备：平台信息 / 添加 / 默认域名勾选 / 自定义域名 / 完成',
        (WidgetTester tester) async {
      await openDomainEdit(tester, proxyStore: proxyStore, domainStore: domainStore);

      expect(find.text('编辑域名'), findsOneWidget);
      expect(find.text('平台'), findsOneWidget);
      expect(find.textContaining('[video-1]'), findsOneWidget);
      expect(find.text('添加新域名'), findsOneWidget);

      await scrollTo(tester, find.text('默认域名（按优先级）'));
      expect(find.text('默认域名（按优先级）'), findsOneWidget);
      // 平台甲有两个默认域名，当前域名（无自定义）为第一个 → 仅一个勾选。
      expect(find.byIcon(Icons.check_circle), findsOneWidget);

      await scrollTo(tester, find.text('自定义域名'));
      expect(find.text('暂无自定义域名。添加后会显示在这里，可随时删除。'), findsOneWidget);

      await scrollTo(tester, find.text('完成'));
      expect(find.text('完成'), findsOneWidget);
    });

    testWidgets('添加域名（格式校验 + 持久化）', (WidgetTester tester) async {
      await openDomainEdit(tester, proxyStore: proxyStore, domainStore: domainStore);

      // 非法域名 → 提示，不写入。
      await scrollTo(tester, find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'not-a-url');
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('添加域名'));
      await tester.tap(find.text('添加域名'));
      await tester.pumpAndSettle();
      expect(find.text('域名格式错误'), findsOneWidget);
      expect(domainStore.domains('平台甲'), isEmpty);
      await tester.pump(const Duration(seconds: 3));

      // 合法域名 → 写入并清空输入框。
      await tester.enterText(find.byType(TextField), 'https://custom-a.example.com');
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加域名'));
      await tester.pumpAndSettle();

      expect(domainStore.domains('平台甲'), <String>['https://custom-a.example.com']);
      await scrollTo(tester, find.text('https://custom-a.example.com'));
      expect(find.text('https://custom-a.example.com'), findsOneWidget);
      // 空态提示消失。
      expect(find.text('暂无自定义域名。添加后会显示在这里，可随时删除。'), findsNothing);

      // 排空 toast。
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('删除单项 / 全部删除', (WidgetTester tester) async {
      domainStore.setDomains(
        <String>['https://a.example.com', 'https://b.example.com'],
        '平台甲',
      );
      await openDomainEdit(tester, proxyStore: proxyStore, domainStore: domainStore);

      // 删除单项。
      await scrollTo(tester, find.text('https://a.example.com'));
      await tester.tap(find.descendant(
        of: find.ancestor(
          of: find.text('https://a.example.com'),
          matching: find.byType(ListTile),
        ),
        matching: find.byIcon(Icons.cancel),
      ));
      await tester.pumpAndSettle();

      expect(domainStore.domains('平台甲'), <String>['https://b.example.com']);
      expect(find.text('https://a.example.com'), findsNothing);
      await tester.pump(const Duration(seconds: 3));

      // 全部删除。
      await scrollTo(tester, find.text('全部删除自定义域名'));
      await tester.tap(find.text('全部删除自定义域名'));
      await tester.pumpAndSettle();

      expect(domainStore.domains('平台甲'), isEmpty);
      await scrollTo(tester, find.text('暂无自定义域名。添加后会显示在这里，可随时删除。'));
      expect(find.text('暂无自定义域名。添加后会显示在这里，可随时删除。'), findsOneWidget);

      // 排空 toast。
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('完成 → 返回设置页', (WidgetTester tester) async {
      await openDomainEdit(tester, proxyStore: proxyStore, domainStore: domainStore);
      await scrollTo(tester, find.text('完成'));
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(find.text('福利平台设置'), findsOneWidget);
    });
  });
}
