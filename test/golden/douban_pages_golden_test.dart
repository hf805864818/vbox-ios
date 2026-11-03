/// 视觉回归 Golden 基线：豆瓣三页（批次 D · D-03）。
///
/// 三页像素锁：首页（轮播 + 区块）/ 榜单（分类胶囊 + 排行）/ 分类浏览（筛选 +
/// 网格）。机制同 `app_pages_golden_test.dart`：真实组件渲染 → matchesGoldenFile。
/// 封面地址统一留空 → 占位态，避免网络图造成基线抖动。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/domain/entities/douban/douban_models.dart';
import 'package:vbox/domain/usecases/douban_usecases.dart';
import 'package:vbox/presentation/pages/pages.dart';
import 'package:vbox/presentation/ui_mode/ui_mode_resolver.dart';

/// fake 豆瓣用例（覆盖三入口，返回注入数据）。
class _FakeDoubanUseCases extends DoubanUseCases {
  _FakeDoubanUseCases({
    this.home,
    this.rankList = const <DoubanChartSubject>[],
    this.categoryList = const <DoubanSubject>[],
  });

  final DoubanHomeFeed? home;
  final List<DoubanChartSubject> rankList;
  final List<DoubanSubject> categoryList;

  @override
  Future<Result<DoubanHomeFeed>> homeFeed() async => Success<DoubanHomeFeed>(home!);

  @override
  Future<Result<List<DoubanChartSubject>>> ranking(
    DoubanChartCategory category, {
    int page = 1,
  }) async =>
      Success<List<DoubanChartSubject>>(rankList);

  @override
  Future<Result<List<DoubanSubject>>> category(
    DoubanCategory category,
    DoubanFilterParams filters, {
    int page = 1,
  }) async =>
      Success<List<DoubanSubject>>(categoryList);
}

DoubanSubject _subject(int i) =>
    DoubanSubject(id: '$i', title: '样品 $i', year: '202$i', genres: const <String>['剧情']);

DoubanHomeFeed _homeFeed() => DoubanHomeFeed(
      banner: <DoubanSubject>[_subject(1), _subject(2), _subject(3)],
      sections: <DoubanHomeSection>[
        DoubanHomeSection(title: '热门电影', items: <DoubanSubject>[_subject(4), _subject(5)]),
        DoubanHomeSection(title: '热门剧集', items: <DoubanSubject>[_subject(6), _subject(7)]),
      ],
    );

List<DoubanChartSubject> _rankings() => <DoubanChartSubject>[
      for (int i = 1; i <= 12; i++)
        DoubanChartSubject(
          id: '$i',
          rank: i,
          title: '榜单 $i',
          rating: 9 - i * 0.2,
          year: '202$i',
          info: '剧情 / 犯罪',
        ),
    ];

Widget _page(Widget child, _FakeDoubanUseCases uc) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<UiFormController>.value(
        value: UiFormController(
          env: const UiFormEnv(override: UiFormOverride.portrait, hasTouch: true),
        ),
      ),
      Provider<DoubanUseCases>.value(value: uc),
    ],
    child: MaterialApp(debugShowCheckedModeBanner: false, home: child),
  );
}

Future<void> _shot(
  WidgetTester tester,
  String name,
  Widget child,
  _FakeDoubanUseCases uc,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final GlobalKey key = GlobalKey();
  await tester.pumpWidget(RepaintBoundary(key: key, child: _page(child, uc)));
  await tester.pumpAndSettle();
  await expectLater(find.byKey(key), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  // UI-A1：豆瓣首页新增「快捷分类胶囊行」（对齐 iOS CategoryTilesView），
  // douban_home 基线需在 CI 同环境（ubuntu x64 + 3.47.5）重生成：
  //   flutter test --update-goldens test/golden/douban_pages_golden_test.dart
  // 生成并提交新基线后移除本 skip（其余两页不受影响，保持像素锁）。
  testWidgets('douban_home（轮播 + 区块）',
      skip: true, (WidgetTester tester) async {
    await _shot(
      tester,
      'douban_home',
      const DoubanHomePage(),
      _FakeDoubanUseCases(home: _homeFeed()),
    );
  });

  testWidgets('douban_ranking（分类胶囊 + 排行）', (WidgetTester tester) async {
    await _shot(
      tester,
      'douban_ranking',
      const DoubanRankingPage(),
      _FakeDoubanUseCases(rankList: _rankings()),
    );
  });

  testWidgets('douban_category（筛选 + 网格）', (WidgetTester tester) async {
    await _shot(
      tester,
      'douban_category',
      const DoubanCategoryPage(),
      _FakeDoubanUseCases(
        categoryList: <DoubanSubject>[for (int i = 1; i <= 12; i++) _subject(i)],
      ),
    );
  });
}