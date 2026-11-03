/// 视觉回归 Golden 基线：空搜索页（批次 D · D-02）。
///
/// 对齐 iOS 基准图 `搜索页面(未搜索资源的时候).PNG`：顶栏搜索框 + 豆瓣榜单栏目 +
/// 全部站点列表 + 搜索历史。机制同 `douban_pages_golden_test.dart`：真实页面渲染
/// → `matchesGoldenFile` 像素锁；与 iOS 基准图的 SSIM 由
/// `scripts/visual_regression.py`（清单模式）产出。
///
/// 封面与站点图标统一留空 → 占位态，避免网络图造成基线抖动。
///
/// 生成基线：`flutter test test/golden --update-goldens`
/// CI 校验：`flutter test test/golden`（像素不一致即失败）
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/domain/entities/douban/douban_models.dart';
import 'package:vbox/domain/entities/remote_source/remote_source.dart';
import 'package:vbox/domain/entities/spider/spider.dart';
import 'package:vbox/domain/usecases/usecases.dart';
import 'package:vbox/presentation/pages/search/search_page.dart';
import 'package:vbox/presentation/ui_mode/ui_mode_resolver.dart';

import '../support/fakes.dart';

/// 假内容浏览用例：返回注入站点，首页/搜索返回空（本基准仅锁空态）。
class _FakeContentBrowseUseCases extends ContentBrowseUseCases {
  _FakeContentBrowseUseCases({this.sites = const <SiteConfig>[]})
      : super(
          loadAllSources: () async =>
              const Success<AllSourcesContainer>(AllSourcesContainer()),
        );

  final List<SiteConfig> sites;

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
  }) async =>
      const Success<SearchContentResult>(SearchContentResult(page: 1, list: <VodItem>[]));
}

SiteConfig _site(String key, String name) =>
    SiteConfig(key: key, name: name, type: 0, api: 'https://$key.example.com');

Widget _page() {
  final SearchHistoryUseCases history = SearchHistoryUseCases(
    InMemorySearchHistoryRepository(<String>['流浪地球', '三体', '漫长的季节']),
  );
  final DoubanUseCases douban = buildDoubanUseCases(
    subjects: <DoubanSubject>[
      const DoubanSubject(id: 'd1', title: '豆瓣条目一', rating: 8.5, year: '2024'),
      const DoubanSubject(id: 'd2', title: '豆瓣条目二', rating: 7.9, year: '2023'),
      const DoubanSubject(id: 'd3', title: '豆瓣条目三', rating: 9.1, year: '2025'),
    ],
  );
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<UiFormController>.value(
        value: UiFormController(
          env: const UiFormEnv(override: UiFormOverride.portrait, hasTouch: true),
        ),
      ),
      Provider<ContentBrowseUseCases>.value(
        value: _FakeContentBrowseUseCases(
          sites: <SiteConfig>[
            _site('s1', '站点甲'),
            _site('s2', '站点乙'),
            _site('s3', '站点丙'),
          ],
        ),
      ),
      Provider<SearchHistoryUseCases>.value(value: history),
      Provider<DoubanUseCases>.value(value: douban),
    ],
    child: const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SearchPage(),
    ),
  );
}

void main() {
  testWidgets('search_empty_portrait（空搜索页：豆瓣榜单 + 全部站点 + 历史）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: key, child: _page()));
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(key),
      matchesGoldenFile('goldens/search_empty_portrait.png'),
    );
  });
}