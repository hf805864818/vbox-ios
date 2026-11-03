/// 豆瓣榜单页条目点击 → 进搜索页自动搜索（对齐 iOS
/// `settings.triggerSearch(subject.title)`；同豆瓣分类页链路）。
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
import 'package:vbox/presentation/pages/douban/douban_ranking_page.dart';
import 'package:vbox/presentation/pages/search/search_page.dart';
import 'package:vbox/presentation/ui_mode/ui_mode_resolver.dart';

import '../../../support/fakes.dart';

/// 假内容浏览用例：记录搜索关键词（验证自动搜索已触发）。
class _FakeContentBrowseUseCases extends ContentBrowseUseCases {
  _FakeContentBrowseUseCases({this.sites = const <SiteConfig>[]})
      : super(
          loadAllSources: () async =>
              const Success<AllSourcesContainer>(AllSourcesContainer()),
        );

  final List<SiteConfig> sites;
  final List<String> searched = <String>[];

  @override
  Future<Result<List<SiteConfig>>> listSites() async =>
      Success<List<SiteConfig>>(sites);

  @override
  Future<Result<SearchContentResult>> searchContent(
    String siteKey,
    String keyword, {
    int page = 1,
  }) async {
    searched.add(keyword);
    return Success<SearchContentResult>(
      SearchContentResult(page: page, list: const <VodItem>[]),
    );
  }
}

/// 假豆瓣用例：固定榜单数据。
class _FakeRankingUseCases extends DoubanUseCases {
  @override
  Future<Result<List<DoubanChartSubject>>> ranking(
    DoubanChartCategory category, {
    int page = 1,
  }) async =>
      const Success<List<DoubanChartSubject>>(<DoubanChartSubject>[
        DoubanChartSubject(
          id: 'r1',
          rank: 1,
          title: '榜单条目',
          rating: 8.1,
          year: '2026',
          info: '剧情 / 犯罪',
        ),
        DoubanChartSubject(
          id: 'r2',
          rank: 2,
          title: '另一条目',
          rating: 7.0,
          year: '2025',
          info: '喜剧',
        ),
      ]);
}

const String _subjectTitle = '榜单条目';

Widget _host(_FakeContentBrowseUseCases uc) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<UiFormController>.value(
        value: UiFormController(
          env: const UiFormEnv(
            override: UiFormOverride.portrait,
            hasTouch: true,
          ),
        ),
      ),
      Provider<DoubanUseCases>.value(value: _FakeRankingUseCases()),
      Provider<ContentBrowseUseCases>.value(value: uc),
      Provider<SearchHistoryUseCases>.value(
        value: SearchHistoryUseCases(InMemorySearchHistoryRepository()),
      ),
    ],
    child: const MaterialApp(home: DoubanRankingPage()),
  );
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await PrefsManager.instance.init();
    await PrefsManager.instance.set('show_search_debug', false);
  });

  testWidgets('点击排行行：进搜索页自动搜索条目标题',
      (WidgetTester tester) async {
    final _FakeContentBrowseUseCases uc = _FakeContentBrowseUseCases(
      // 至少一个站点，搜索才会实际发起（对齐 SearchPage._submit 行为）。
      sites: <SiteConfig>[
        const SiteConfig(
          key: 's1',
          name: '站点1',
          type: 0,
          api: 'https://s1.example.com',
        ),
      ],
    );

    await tester.pumpWidget(_host(uc));
    await tester.pumpAndSettle();
    expect(find.text(_subjectTitle), findsOneWidget,
        reason: '榜单页应显示排行条目');

    await tester.tap(find.text(_subjectTitle));
    await tester.pumpAndSettle();

    expect(find.byType(SearchPage), findsOneWidget,
        reason: '点击排行行应进入搜索页（对齐 iOS triggerSearch）');
    expect(uc.searched, contains(_subjectTitle),
        reason: '进搜索页应自动发起搜索');
  });
}
