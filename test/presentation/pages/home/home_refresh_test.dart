/// 第 6 批 · UI-B2：首页下拉刷新（豆瓣首页）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/domain/entities/douban/douban_models.dart';
import 'package:vbox/domain/usecases/douban_usecases.dart';
import 'package:vbox/presentation/pages/douban/douban_home_page.dart';

/// 计数版豆瓣用例（仅校验下拉刷新是否重新拉取首页）。
class _CountingDoubanUseCases extends DoubanUseCases {
  _CountingDoubanUseCases(this.feed);

  final DoubanHomeFeed feed;
  int homeFeedCalls = 0;

  @override
  Future<Result<DoubanHomeFeed>> homeFeed() async {
    homeFeedCalls++;
    return Success<DoubanHomeFeed>(feed);
  }

  @override
  Future<Result<List<DoubanChartSubject>>> ranking(
    DoubanChartCategory category, {
    int page = 1,
  }) async =>
      const Success<List<DoubanChartSubject>>(<DoubanChartSubject>[]);

  @override
  Future<Result<List<DoubanSubject>>> category(
    DoubanCategory category,
    DoubanFilterParams filters, {
    int page = 1,
  }) async =>
      const Success<List<DoubanSubject>>(<DoubanSubject>[]);
}

DoubanSubject _subject(int i) => DoubanSubject(
      id: '$i',
      title: '样品 $i',
      year: '202$i',
      genres: const <String>['剧情'],
    );

DoubanHomeFeed _feed() => DoubanHomeFeed(
      banner: <DoubanSubject>[_subject(1), _subject(2)],
      sections: <DoubanHomeSection>[
        DoubanHomeSection(
          title: '热门电影',
          items: <DoubanSubject>[_subject(3), _subject(4)],
        ),
      ],
    );

void main() {
  testWidgets('UI-B2：下拉刷新触发重新拉取首页（RefreshIndicator）',
      (WidgetTester tester) async {
    final _CountingDoubanUseCases uc = _CountingDoubanUseCases(_feed());
    await tester.pumpWidget(
      Provider<DoubanUseCases>.value(
        value: uc,
        child: const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(body: DoubanHomeView()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 首屏加载一次。
    expect(find.byType(RefreshIndicator), findsOneWidget);
    expect(uc.homeFeedCalls, 1);

    // 下拉 → 触发 onRefresh（重新拉取）。
    await tester.fling(find.text('热门电影'), const Offset(0, 320), 1200);
    await tester.pumpAndSettle();

    expect(uc.homeFeedCalls, 2);
  });
}
