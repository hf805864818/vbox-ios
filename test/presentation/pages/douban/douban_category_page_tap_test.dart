/// 豆瓣分类页条目点击 → 进搜索页自动搜索（对齐 iOS
/// `settings.triggerSearch(subject.title)`；弹层嵌入模式先关弹层再跳转）。
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
import 'package:vbox/presentation/pages/douban/douban_category_page.dart';
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

const String _subjectTitle = '流浪地球3';

/// 宿主：按钮打开 modal bottom sheet，内嵌 `DoubanCategoryPage(embedded: true)`
/// （对齐首页快捷分类弹层形态）。
Widget _host({
  required DoubanUseCases douban,
  required _FakeContentBrowseUseCases uc,
  required SearchHistoryUseCases history,
}) {
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
      Provider<DoubanUseCases>.value(value: douban),
      Provider<ContentBrowseUseCases>.value(value: uc),
      Provider<SearchHistoryUseCases>.value(value: history),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => Center(
            child: ElevatedButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (BuildContext sheetContext) => const SizedBox(
                  height: 560,
                  child: DoubanCategoryPage(
                    initialCategory: DoubanCategory.movie,
                    embedded: true,
                  ),
                ),
              ),
              child: const Text('打开分类弹层'),
            ),
          ),
        ),
      ),
    ),
  );
}

DoubanUseCases _doubanWithSubjects() => buildDoubanUseCases(
      subjects: const <DoubanSubject>[
        DoubanSubject(id: 'd1', title: _subjectTitle, rating: 8.5),
        DoubanSubject(id: 'd2', title: '另一个条目', rating: 7.0),
      ],
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await PrefsManager.instance.init();
    await PrefsManager.instance.set('show_search_debug', false);
  });

  testWidgets('弹层内点击条目：关弹层 + 进搜索页自动搜索关键词',
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

    await tester.pumpWidget(_host(
      douban: _doubanWithSubjects(),
      uc: uc,
      history: SearchHistoryUseCases(InMemorySearchHistoryRepository()),
    ));

    // 打开分类弹层（首页快捷分类入口形态）。
    await tester.tap(find.text('打开分类弹层'));
    await tester.pumpAndSettle();
    expect(find.text(_subjectTitle), findsOneWidget,
        reason: '弹层内应显示分类条目');

    // 点击条目 → 关弹层 + 进搜索页（小视口下条目可能部分越界，先滚到可见）。
    await tester.ensureVisible(find.text(_subjectTitle));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_subjectTitle));
    await tester.pumpAndSettle();

    expect(find.byType(SearchPage), findsOneWidget,
        reason: '点击条目应进入搜索页');
    expect(
      find.byType(DoubanCategoryPage, skipOffstage: false),
      findsNothing,
      reason: '嵌入模式应先关闭弹层再跳转（含离屏路由检查）',
    );
    expect(uc.searched, contains(_subjectTitle),
        reason: '进搜索页应自动发起搜索（对齐 iOS triggerSearch）');
  });
}
