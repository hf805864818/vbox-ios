/// 表现层 widget 测试：搜索页（批次 D · D-02）。
///
/// 注入假 [ContentBrowseUseCases] + 内存 [SearchHistoryUseCases]，形态以
/// [UiFormController] 强制；无 IO、无原生依赖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/douban/douban_models.dart';
import 'package:vbox/domain/entities/remote_source/remote_source.dart';
import 'package:vbox/domain/entities/spider/spider.dart';
import 'package:vbox/domain/usecases/usecases.dart';
import 'package:vbox/presentation/pages/search/search_page.dart';
import 'package:vbox/presentation/ui_mode/ui_mode_resolver.dart';

import '../../../support/fakes.dart';

/// 假内容浏览用例：返回注入的站点 / 榜单 / 搜索结果，并记录搜索关键词。
class _FakeContentBrowseUseCases extends ContentBrowseUseCases {
  _FakeContentBrowseUseCases({
    this.sites = const <SiteConfig>[],
    this.results,
  }) : super(
          loadAllSources: () async =>
              const Success<AllSourcesContainer>(AllSourcesContainer()),
        );

  final List<SiteConfig> sites;
  final List<VodItem> Function(String keyword)? results;
  final List<String> searched = <String>[];

  @override
  Future<Result<List<SiteConfig>>> listSites() async =>
      Success<List<SiteConfig>>(sites);

  @override
  Future<Result<HomeContentResult>> homeContent(String siteKey) async =>
      const Success<HomeContentResult>(HomeContentResult(list: <VodItem>[]));

  @override
  Future<Result<SearchContentResult>> searchContent(
    String siteKey,
    String keyword, {
    int page = 1,
  }) async {
    searched.add(keyword);
    return Success<SearchContentResult>(
      SearchContentResult(page: page, list: results?.call(keyword)),
    );
  }
}

SiteConfig site(String key, String name) =>
    SiteConfig(key: key, name: name, type: 0, api: 'https://$key.example.com');

VodItem vod(String id, String name) =>
    VodItem(vodId: id, vodName: name, vodPic: '');

Widget _app(
  _FakeContentBrowseUseCases uc,
  SearchHistoryUseCases history, {
  UiFormOverride override = UiFormOverride.portrait,
  DoubanUseCases? douban,
  String? initialKeyword,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<UiFormController>.value(
        value: UiFormController(
          env: UiFormEnv(override: override, hasTouch: true),
        ),
      ),
      Provider<ContentBrowseUseCases>.value(value: uc),
      Provider<SearchHistoryUseCases>.value(value: history),
      Provider<DoubanUseCases>.value(
        value: douban ?? buildDoubanUseCases(),
      ),
    ],
    child: MaterialApp(home: SearchPage(initialKeyword: initialKeyword)),
  );
}

void main() {
  testWidgets('空态：搜索历史 + 豆瓣榜单 + 全部站点', (WidgetTester tester) async {
    final _FakeContentBrowseUseCases uc = _FakeContentBrowseUseCases(
      sites: <SiteConfig>[site('s1', '站点1')],
    );
    final SearchHistoryUseCases history =
        SearchHistoryUseCases(InMemorySearchHistoryRepository(<String>['流浪地球', '三体']));

    await tester.pumpWidget(_app(
      uc,
      history,
      douban: buildDoubanUseCases(
        subjects: const <DoubanSubject>[
          DoubanSubject(id: 'd1', title: '豆瓣条目A', rating: 8.5),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('搜索历史'), findsOneWidget);
    expect(find.text('流浪地球'), findsOneWidget);
    expect(find.text('三体'), findsOneWidget);
    // 豆瓣栏目标签 + 数据（对齐 iOS `SearchView.doubanTabs`）
    expect(find.text('豆瓣周榜'), findsOneWidget);
    expect(find.text('豆瓣条目A'), findsOneWidget);
    // 全部站点区块（对齐 iOS「全部站点 (N)」）
    expect(find.textContaining('全部站点'), findsOneWidget);
    expect(find.text('站点1'), findsOneWidget);
  });

  testWidgets('提交搜索：进入结果态显示结果卡', (WidgetTester tester) async {
    final _FakeContentBrowseUseCases uc = _FakeContentBrowseUseCases(
      sites: <SiteConfig>[site('s1', '站点1')],
      results: (String kw) => <VodItem>[vod('r1', '搜索结果片')],
    );
    final SearchHistoryUseCases history =
        SearchHistoryUseCases(InMemorySearchHistoryRepository());

    await tester.pumpWidget(_app(uc, history));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '关键词');
    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pumpAndSettle();

    expect(uc.searched, <String>['关键词']);
    expect(find.text('搜索结果片'), findsOneWidget);
    // 结果态顶栏仍保留排行榜入口 + 提交钮，且无「取消」（对齐 iOS `SearchView`）。
    expect(find.text('取消'), findsNothing);
    expect(find.byIcon(Icons.bar_chart_rounded), findsOneWidget);
    expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
  });

  testWidgets('清空历史：历史胶囊消失', (WidgetTester tester) async {
    final _FakeContentBrowseUseCases uc = _FakeContentBrowseUseCases(
      sites: <SiteConfig>[site('s1', '站点1')],
    );
    final InMemorySearchHistoryRepository repo =
        InMemorySearchHistoryRepository(<String>['流浪地球']);

    await tester.pumpWidget(_app(uc, SearchHistoryUseCases(repo)));
    await tester.pumpAndSettle();

    expect(find.text('流浪地球'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(find.text('流浪地球'), findsNothing);
    expect(repo.length, 0);
  });

  testWidgets('初始关键词进入即自动搜索（对齐 iOS triggerSearch）',
      (WidgetTester tester) async {
    final _FakeContentBrowseUseCases uc = _FakeContentBrowseUseCases(
      sites: <SiteConfig>[site('s1', '站点1')],
      results: (String kw) => <VodItem>[vod('r1', '结果$kw')],
    );
    final SearchHistoryUseCases history =
        SearchHistoryUseCases(InMemorySearchHistoryRepository());

    await tester.pumpWidget(_app(uc, history, initialKeyword: '关键词'));
    await tester.pumpAndSettle();

    // 进入即全源并发搜索（对齐 iOS `searchStream`）：s1 命中一次并直接进入结果态。
    expect(uc.searched, <String>['关键词']);
    expect(find.text('结果关键词'), findsOneWidget);
    expect(find.text('取消'), findsNothing);
  });

  testWidgets('多来源结果态：左源列表 + 右结果（仅展示选中源）',
      (WidgetTester tester) async {
    final _FakeContentBrowseUseCases uc = _FakeContentBrowseUseCases(
      sites: <SiteConfig>[site('s1', '站点1'), site('s2', '站点2')],
      results: (String kw) => <VodItem>[vod('r1', '结果片')],
    );
    final SearchHistoryUseCases history =
        SearchHistoryUseCases(InMemorySearchHistoryRepository());

    await tester.pumpWidget(_app(
      uc,
      history,
      override: UiFormOverride.landscape,
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '关键词');
    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pumpAndSettle();

    // 多来源 → 左源列表 + 右结果（对齐 iOS `SearchResultsView.multiColumnList`）。
    expect(find.byType(VerticalDivider), findsOneWidget);
    expect(find.text('站点1'), findsWidgets);
    expect(find.text('站点2'), findsWidgets);
    // 右栏仅展示选中源的结果（对齐 iOS `currentVideos`）→ 一张卡。
    expect(find.text('结果片'), findsOneWidget);
  });

  testWidgets('搜索调试面板：开关开启时显示逐源日志流（对齐 iOS show_search_debug）',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'show_search_debug': true,
    });
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await PrefsManager.instance.init();

    final _FakeContentBrowseUseCases uc = _FakeContentBrowseUseCases(
      sites: <SiteConfig>[site('s1', '站点1')],
      results: (String kw) => <VodItem>[vod('r1', '搜索结果片')],
    );
    final SearchHistoryUseCases history =
        SearchHistoryUseCases(InMemorySearchHistoryRepository());

    await tester.pumpWidget(_app(uc, history));
    await tester.pumpAndSettle();

    // 开关开启：搜索后出现「搜索调试」面板（计数头 + 日志行 + 导出入口）。
    await tester.enterText(find.byType(TextField), '关键词');
    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pumpAndSettle();

    expect(find.text('搜索调试'), findsOneWidget);
    // 计数头对齐 iOS `N条/M源`（结果已由 `withSourceLabel` 打来源备注 → 1 源）。
    expect(find.text('1条/1源'), findsOneWidget);
    expect(find.textContaining('🔍 开始搜索'), findsOneWidget);
    expect(find.textContaining('====== 开始流式搜索'), findsOneWidget);
    expect(find.textContaining('✅ 站点1 +1条'), findsOneWidget);
    expect(find.textContaining('====== Stream全部完成'), findsOneWidget);
    expect(find.textContaining('✅ 搜索结束: 共1条/1个源'), findsOneWidget);
    expect(find.byIcon(Icons.ios_share), findsOneWidget);
  });

  testWidgets('搜索调试面板：开关关闭时不显示（对齐 iOS 默认 false）',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'show_search_debug': false,
    });
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await PrefsManager.instance.init();
    // PrefsManager 是进程级单例：同文件前序用例可能已初始化（内存 mock 不重置），
    // 显式写 false 保证开关状态确定。
    await PrefsManager.instance.set('show_search_debug', false);

    final _FakeContentBrowseUseCases uc = _FakeContentBrowseUseCases(
      sites: <SiteConfig>[site('s1', '站点1')],
      results: (String kw) => <VodItem>[vod('r1', '搜索结果片')],
    );
    final SearchHistoryUseCases history =
        SearchHistoryUseCases(InMemorySearchHistoryRepository());

    await tester.pumpWidget(_app(uc, history));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '关键词');
    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pumpAndSettle();

    // 结果正常展示，但面板与导出入口均不出现。
    expect(find.text('搜索结果片'), findsOneWidget);
    expect(find.text('搜索调试'), findsNothing);
    expect(find.byIcon(Icons.ios_share), findsNothing);
  });
}