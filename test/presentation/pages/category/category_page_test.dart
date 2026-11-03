/// 表现层 widget 测试：分类网格（批次 D · D-06）。
///
/// 注入假 [ContentBrowseUseCases]（子类覆盖 listSites / categories /
/// categoryContent），形态以 [UiFormController] 强制；无 IO、无原生依赖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/domain/entities/remote_source/remote_source.dart';
import 'package:vbox/domain/entities/spider/spider.dart';
import 'package:vbox/domain/usecases/usecases.dart';
import 'package:vbox/presentation/pages/category/category_page.dart';
import 'package:vbox/presentation/ui_mode/ui_mode_resolver.dart';

/// 假内容浏览用例：返回注入的站点 / 分类 / 分类内容，并记录分页请求。
class _FakeContentBrowseUseCases extends ContentBrowseUseCases {
  _FakeContentBrowseUseCases({
    this.sites = const <SiteConfig>[],
    this.categoryList = const <VodCategory>[],
    this.videos,
    this.pagecount,
  }) : super(
          loadAllSources: () async =>
              const Success<AllSourcesContainer>(AllSourcesContainer()),
        );

  final List<SiteConfig> sites;
  final List<VodCategory> categoryList;
  final List<VodItem> Function(String? tid, int page)? videos;
  final int? pagecount;
  final List<int> requestedPages = <int>[];

  @override
  Future<Result<List<SiteConfig>>> listSites() async =>
      Success<List<SiteConfig>>(sites);

  @override
  Future<Result<List<VodCategory>>> categories(String siteKey) async =>
      Success<List<VodCategory>>(categoryList);

  @override
  Future<Result<CategoryContentResult>> categoryContent(
    String siteKey, {
    String? tid,
    int page = 1,
    Map<String, String>? filters,
  }) async {
    requestedPages.add(page);
    return Success<CategoryContentResult>(
      CategoryContentResult(
        page: page,
        pagecount: pagecount,
        list: videos?.call(tid, page) ?? const <VodItem>[],
      ),
    );
  }
}

SiteConfig site(String key, String name) =>
    SiteConfig(key: key, name: name, type: 0, api: 'https://$key.example.com');

VodCategory cat(String id, String name) =>
    VodCategory(typeId: id, typeName: name);

VodItem vod(String id, String name) =>
    VodItem(vodId: id, vodName: name, vodPic: '');

Widget _app(
  _FakeContentBrowseUseCases uc, {
  UiFormOverride override = UiFormOverride.portrait,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<UiFormController>.value(
        value: UiFormController(
          env: UiFormEnv(override: override, hasTouch: true),
        ),
      ),
      Provider<ContentBrowseUseCases>.value(value: uc),
    ],
    child: const MaterialApp(home: CategoryPage()),
  );
}

void main() {
  testWidgets('无站点：错误提示', (WidgetTester tester) async {
    await tester.pumpWidget(_app(_FakeContentBrowseUseCases()));
    await tester.pumpAndSettle();

    expect(find.textContaining('无可用站点'), findsOneWidget);
  });

  testWidgets('分类胶囊 + 海报网格渲染', (WidgetTester tester) async {
    final _FakeContentBrowseUseCases uc = _FakeContentBrowseUseCases(
      sites: <SiteConfig>[site('s1', '站点1')],
      categoryList: <VodCategory>[cat('1', '电影'), cat('2', '剧集')],
      videos: (_, __) => <VodItem>[vod('1', '电影片')],
    );
    await tester.pumpWidget(_app(uc));
    await tester.pumpAndSettle();

    expect(find.text('站点1'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('电影'), findsOneWidget);
    expect(find.text('剧集'), findsOneWidget);
    expect(find.text('电影片'), findsOneWidget);
  });

  testWidgets('切换分类胶囊：重载该分类网格', (WidgetTester tester) async {
    final _FakeContentBrowseUseCases uc = _FakeContentBrowseUseCases(
      sites: <SiteConfig>[site('s1', '站点1')],
      categoryList: <VodCategory>[cat('1', '电影'), cat('2', '剧集')],
      videos: (String? tid, int page) {
        if (tid == '2') return <VodItem>[vod('2', '剧集片')];
        return <VodItem>[vod('1', '电影片')];
      },
    );
    await tester.pumpWidget(_app(uc));
    await tester.pumpAndSettle();

    expect(find.text('电影片'), findsOneWidget);

    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();

    expect(find.text('剧集片'), findsOneWidget);
    expect(find.text('电影片'), findsNothing);
  });

  testWidgets('滚动到底：自动加载下一页', (WidgetTester tester) async {
    final _FakeContentBrowseUseCases uc = _FakeContentBrowseUseCases(
      sites: <SiteConfig>[site('s1', '站点1')],
      categoryList: <VodCategory>[cat('1', '电影')],
      pagecount: 2,
      videos: (String? tid, int page) {
        if (page >= 2) return <VodItem>[vod('999', '末页片')];
        return List<VodItem>.generate(
          20,
          (int i) => vod('$i', '第$i片'),
        );
      },
    );
    await tester.pumpWidget(_app(uc));
    await tester.pumpAndSettle();

    expect(find.text('第0片'), findsOneWidget);
    expect(find.text('末页片'), findsNothing);
    expect(uc.requestedPages, <int>[1]);

    await tester.drag(find.byType(GridView), const Offset(0, -5000));
    await tester.pumpAndSettle();

    expect(uc.requestedPages, <int>[1, 2]);
    expect(find.text('末页片'), findsOneWidget);
  });

  testWidgets('切换源浮层：切换站点重载', (WidgetTester tester) async {
    final _FakeContentBrowseUseCases uc = _FakeContentBrowseUseCases(
      sites: <SiteConfig>[site('s1', '站点1'), site('s2', '站点2')],
      categoryList: <VodCategory>[cat('1', '电影')],
      videos: (_, __) => <VodItem>[vod('1', '电影片')],
    );
    await tester.pumpWidget(_app(uc));
    await tester.pumpAndSettle();

    expect(find.text('站点1'), findsOneWidget);

    // 源切换：顶部源名 + 下拉箭头 → 左上角悬浮源浮层（对齐 iOS showSourceDropdown）。
    await tester.tap(find.text('站点1'));
    await tester.pumpAndSettle();
    expect(find.text('切换源'), findsOneWidget);
    await tester.tap(find.text('站点2'));
    await tester.pumpAndSettle();

    expect(find.text('站点1'), findsNothing);
    expect(find.text('站点2'), findsOneWidget);
    expect(find.text('电影片'), findsOneWidget);
  });

  testWidgets('网格卡片掉落回弹入场（对齐 iOS hasAppeared）：同排错峰 → 回弹可见',
      (WidgetTester tester) async {
    final _FakeContentBrowseUseCases uc = _FakeContentBrowseUseCases(
      sites: <SiteConfig>[site('s1', '站点1')],
      categoryList: <VodCategory>[cat('1', '电影')],
      videos: (_, __) => <VodItem>[
        vod('1', '首卡片'),
        vod('2', '次卡片'),
      ],
    );
    await tester.pumpWidget(_app(uc));
    // 数据已加载（假用例同步返回），错峰延迟（次卡 80ms）尚未触发。
    await tester.pump(const Duration(milliseconds: 30));

    final Finder secondary = find.ancestor(
      of: find.text('次卡片'),
      matching: find.byType(AnimatedOpacity),
    );
    expect(secondary, findsOneWidget, reason: '网格卡片应包入场动效容器');
    expect(
      tester.widget<AnimatedOpacity>(secondary).opacity,
      0.0,
      reason: '错峰未到时次卡应仍隐藏（对齐 iOS fallDelay）',
    );

    // 推进错峰 + 回弹动画：全部卡片完全可见。
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(secondary).opacity, 1.0,
        reason: '回弹完成后卡片完全可见');
    expect(find.text('首卡片'), findsOneWidget);
  });
}