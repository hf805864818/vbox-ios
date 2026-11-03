/// UI-A1：首页双态常驻保活（IndexedStack 对齐 iOS ZStack）+ 快捷分类弹层。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/domain/entities/douban/douban_models.dart';
import 'package:vbox/domain/entities/remote_source/remote_source.dart';
import 'package:vbox/domain/entities/spider/spider.dart';
import 'package:vbox/domain/usecases/usecases.dart';
import 'package:vbox/presentation/pages/douban/douban_home_page.dart';
import 'package:vbox/presentation/pages/home/home_page.dart';
import 'package:vbox/presentation/ui_mode/ui_mode_resolver.dart';

import '../../../support/fakes.dart';

/// 计数版豆瓣用例（记录 homeFeed / category 调用，供保活与弹层断言）。
class _CountingDoubanUseCases extends DoubanUseCases {
  _CountingDoubanUseCases(this.feed);

  final DoubanHomeFeed feed;
  int homeFeedCalls = 0;
  int categoryCalls = 0;

  @override
  Future<Result<DoubanHomeFeed>> homeFeed() async {
    homeFeedCalls++;
    return Success<DoubanHomeFeed>(feed);
  }

  @override
  Future<Result<List<DoubanSubject>>> category(
    DoubanCategory category,
    DoubanFilterParams filters, {
    int page = 1,
  }) async {
    categoryCalls++;
    return const Success<List<DoubanSubject>>(<DoubanSubject>[]);
  }
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

Widget _hostHome(_CountingDoubanUseCases uc) => MultiProvider(
      providers: <SingleChildWidget>[
        Provider<ContentBrowseUseCases>.value(value: buildContentBrowseUseCases()),
        Provider<DoubanUseCases>.value(value: uc),
      ],
      child: const MaterialApp(home: Scaffold(body: VboxHomePage())),
    );

/// 站点态数据假用例：固定单站点 + 单分类 + 单推荐项（供「切换源即切站点态」断言）。
class _SitesBrowseUseCases extends ContentBrowseUseCases {
  _SitesBrowseUseCases()
      : super(
          loadAllSources: () async =>
              const Success<AllSourcesContainer>(AllSourcesContainer()),
        );

  @override
  Future<Result<List<SiteConfig>>> listSites() async =>
      const Success<List<SiteConfig>>(<SiteConfig>[
        SiteConfig(
          key: 's1',
          name: '站点1',
          type: 0,
          api: 'https://s1.example.com',
        ),
      ]);

  @override
  Future<Result<HomeContentResult>> homeContent(String siteKey) async =>
      const Success<HomeContentResult>(
        HomeContentResult(
          classes: <VodCategory>[VodCategory(typeId: '1', typeName: '电影')],
          list: <VodItem>[VodItem(vodId: '1', vodName: '推荐片', vodPic: '')],
        ),
      );
}

void main() {
  // DoubanHomeView._cachedFeed 是进程级 static 缓存：跨用例残留会让
  // 「重组后不重新拉取」等断言失真（上个用例写入缓存后 homeFeed 不再被调用）。
  setUp(DoubanHomeView.resetHomeFeedCacheForTest);

  group('UI-A1 双态常驻保活（对齐 iOS ZStack 结构）', () {
    testWidgets('豆瓣态与站点态同时挂载于 IndexedStack（不销毁重建）',
        (WidgetTester tester) async {
      final _CountingDoubanUseCases uc = _CountingDoubanUseCases(_feed());
      await tester.pumpWidget(_hostHome(uc));
      await tester.pumpAndSettle();

      // 内容区 IndexedStack：两态常驻（旧条件切换实现只挂单态，此断言防回归）。
      final IndexedStack stack =
          tester.widget<IndexedStack>(find.byType(IndexedStack).first);
      expect(stack.index, 0, reason: '默认豆瓣态');
      expect(
        find.descendant(
          of: find.byType(IndexedStack).first,
          matching: find.byType(DoubanHomeView),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(IndexedStack).first,
          matching: find.byType(RefreshIndicator),
        ),
        findsOneWidget,
        reason: '站点态未激活也常驻（对齐 iOS opacity 控制的常驻语义）',
      );
    });

    testWidgets('重组后豆瓣态 State 保持（不重新拉取 homeFeed）',
        (WidgetTester tester) async {
      final _CountingDoubanUseCases uc = _CountingDoubanUseCases(_feed());
      await tester.pumpWidget(_hostHome(uc));
      await tester.pumpAndSettle();
      expect(uc.homeFeedCalls, 1);

      // 触发一次重组（尺寸变化 → build 重跑），常驻态不应重新初始化数据。
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1.0; // 500 逻辑宽（默认 dpr=3 → 166px 会溢出顶栏）
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();

      expect(
        uc.homeFeedCalls,
        1,
        reason: 'IndexedStack 保活下 DoubanHomeView 不销毁重建，不重新拉取',
      );
    });
  });

  group('UI-A1 快捷分类胶囊 → 详情弹层（对齐 iOS CategoryTilesView sheet）', () {
    testWidgets('胶囊行出现在 banner 之后；点击弹出「找电影」sheet',
        (WidgetTester tester) async {
      final _CountingDoubanUseCases uc = _CountingDoubanUseCases(_feed());
      await tester.pumpWidget(
        MultiProvider(
          providers: <SingleChildWidget>[
            Provider<DoubanUseCases>.value(value: uc),
          ],
          child: const MaterialApp(home: Scaffold(body: DoubanHomeView())),
        ),
      );
      await tester.pumpAndSettle();

      // 胶囊行渲染（6 固定项）。
      expect(find.text('电影'), findsOneWidget);
      expect(find.text('榜单'), findsOneWidget);
      expect(find.text('热门'), findsOneWidget);

      // 点击「电影」胶囊 → 弹出 sheet（embedded 标题「找电影」）。
      await tester.tap(find.text('电影'));
      await tester.pumpAndSettle();
      expect(find.text('找电影'), findsOneWidget);
      expect(uc.categoryCalls, 1);

      // 关闭 sheet（点 barrier）→ 高亮清除。
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('找电影'), findsNothing);
    });

    testWidgets('sheet 关闭后胶囊高亮清除（对齐 iOS onDismiss 清 activeType）',
        (WidgetTester tester) async {
      final _CountingDoubanUseCases uc = _CountingDoubanUseCases(_feed());
      await tester.pumpWidget(
        MultiProvider(
          providers: <SingleChildWidget>[
            Provider<DoubanUseCases>.value(value: uc),
          ],
          child: const MaterialApp(home: Scaffold(body: DoubanHomeView())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('剧集'));
      await tester.pumpAndSettle();
      expect(find.text('找剧集'), findsOneWidget);

      // sheet 打开期间胶囊白字高亮（选中态）。sheet 内部亦有「剧集」字样，
      // 故以「存在白色前景的『剧集』Text」谓词断言，不依赖 finder 唯一性。
      bool hasWhiteHighlighted() => tester
          .widgetList<Text>(find.text('剧集'))
          .any((Text t) => t.style?.color == Colors.white);
      expect(hasWhiteHighlighted(), isTrue);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // 关闭后恢复未选中前景色（不再是白色）。
      expect(hasWhiteHighlighted(), isFalse);
    });
  });

  group('UI-A1 切换源 → 立即站点态（对齐 iOS selectedSource 覆盖展示）', () {
    testWidgets('选中源即切站点态并渲染分类栏 + 网格（不等待网络）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MultiProvider(
          providers: <SingleChildWidget>[
            Provider<ContentBrowseUseCases>.value(value: _SitesBrowseUseCases()),
            Provider<DoubanUseCases>.value(
              value: _CountingDoubanUseCases(_feed()),
            ),
            ChangeNotifierProvider<UiFormController>.value(
              value: UiFormController(),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: VboxHomePage())),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<IndexedStack>(find.byType(IndexedStack).first).index,
        0,
        reason: '默认豆瓣态',
      );

      // 打开切换源浮层 → 选「站点1」。
      await tester.tap(find.byIcon(Icons.grid_view_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('站点1').last);
      await tester.pumpAndSettle();

      // 选中源即覆盖展示站点态（分类滑动栏 + 网格），不再残留豆瓣大封面。
      final IndexedStack stack =
          tester.widget<IndexedStack>(find.byType(IndexedStack).first);
      expect(stack.index, 1, reason: '选中源 → 立即切到站点态（不等网络）');
      expect(find.text('推荐'), findsOneWidget);
      expect(find.text('电影'), findsOneWidget);
      expect(find.text('推荐片'), findsOneWidget);
    });
  });
}
