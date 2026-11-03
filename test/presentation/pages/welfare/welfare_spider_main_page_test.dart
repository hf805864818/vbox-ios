/// 呈现层单测：福利 Spider 引擎执行页（批次 H · H-03 续段）。
///
/// 对齐 iOS `FuliPlatformMainView`：动态分类 Tab（含二级子分类）+ 搜索 Tab
/// + 2 列视频网格。覆盖：首页加载出 Tab、分类视频渲染、搜索流程、
/// 点击视频卡片进入播放中转页。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/welfare/welfare.dart';
import 'package:vbox/domain/services/fuli_base_service.dart';
import 'package:vbox/presentation/pages/welfare/welfare_spider_main_page.dart';

/// 假服务：可配置各抓取结果。
class _FakeFuliService extends FuliBaseService {
  _FakeFuliService({required this.homeResult})
      : super(
          platformKey: 'demo',
          platformName: '演示平台',
          defaultHosts: const <String>['https://a.example.com'],
        );

  final FuliHomeResult homeResult;

  @override
  String get currentHost => 'https://a.example.com';

  @override
  bool get isHostReady => true;

  @override
  void reprobe() {}

  @override
  void resetDomain() {}

  @override
  Future<FuliHomeResult> fetchHomeContent() async => homeResult;

  @override
  Future<FuliCategoryResult> fetchCategoryContent({
    required FuliCategory category,
    FuliCategory? subCategory,
    required int page,
  }) async {
    if (category.typeId == 'c1') {
      return const FuliCategoryResult(
        videos: <FuliVideo>[
          FuliVideo(
            vodId: 'v-c1-1',
            vodName: '分类一影片',
            vodPic: 'https://img.example.com/c1.jpg',
          ),
        ],
        page: 1,
        hasMore: false,
      );
    }
    return const FuliCategoryResult(
      videos: <FuliVideo>[],
      page: 1,
      hasMore: false,
    );
  }

  @override
  Future<FuliSearchResult> fetchSearch({
    required String keyword,
    required int page,
  }) async {
    return FuliSearchResult(
      videos: <FuliVideo>[
        FuliVideo(
          vodId: 'v-search-1',
          vodName: '搜索影片「$keyword」',
          vodPic: 'https://img.example.com/s.jpg',
        ),
      ],
      page: page,
      hasMore: false,
    );
  }

  @override
  Future<FuliDetail> fetchDetail(String vodId) async {
    return FuliDetail(
      vodId: vodId,
      vodName: '演示影片详情',
      vodPic: '',
      vodContent: null,
      playFrom: '在线播放',
      episodes: const <FuliEpisode>[
        FuliEpisode(name: '第1集', url: 'https://cdn.example.com/e1.m3u8'),
      ],
    );
  }
}

FuliHomeResult _home() => const FuliHomeResult(
      categories: <FuliCategory>[
        FuliCategory(typeId: 'c1', typeName: '分类一'),
        FuliCategory(typeId: 'c2', typeName: '分类二'),
      ],
      videos: <FuliVideo>[],
    );

WelfarePlatform _platform() => const WelfarePlatform(
      platformKey: 'demo',
      name: '演示平台',
      category: WelfarePlatformCategory.video,
      serviceType: 'welfare_spider',
      scriptType: 'javascript',
      api: './sources/welfare-js/demo.js',
      defaultHosts: <String>['https://a.example.com'],
    );

Widget _page(_FakeFuliService service) => MaterialApp(
      home: WelfareSpiderMainPage(
        platform: _platform(),
        service: service,
      ),
    );

void main() {
  testWidgets('首页加载：分类 Tab + 搜索 Tab 渲染，默认分类视频可见',
      (WidgetTester tester) async {
    await tester.pumpWidget(_page(_FakeFuliService(homeResult: _home())));
    await tester.pumpAndSettle();

    // Tab 栏：两个分类 + 搜索。
    expect(find.text('分类一'), findsOneWidget);
    expect(find.text('分类二'), findsOneWidget);
    expect(find.text('搜索'), findsOneWidget);

    // 默认分类（分类一）视频可见。
    expect(find.text('分类一影片'), findsOneWidget);
  });

  testWidgets('切换分类 Tab → 显示该分类视频', (WidgetTester tester) async {
    await tester.pumpWidget(_page(_FakeFuliService(homeResult: _home())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('分类二'));
    await tester.pumpAndSettle();

    // 分类二为空 → 空态「暂无内容」。
    expect(find.text('暂无内容'), findsOneWidget);
  });

  testWidgets('搜索 Tab：输入关键词 → 搜索 → 结果渲染', (WidgetTester tester) async {
    await tester.pumpWidget(_page(_FakeFuliService(homeResult: _home())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '美女');
    // 输入后先出一帧：onChanged 触发 setState 使「搜索」按钮由禁用变为可用。
    await tester.pumpAndSettle();
    // 此时「搜索」同时命中 Tab 与搜索按钮，按钮是 TextButton。
    await tester.tap(find.widgetWithText(TextButton, '搜索'));
    await tester.pumpAndSettle();

    expect(find.text('搜索影片「美女」'), findsOneWidget);
  });

  testWidgets('点击视频卡片 → 进入播放中转页', (WidgetTester tester) async {
    await tester.pumpWidget(_page(_FakeFuliService(homeResult: _home())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('分类一影片'));
    await tester.pumpAndSettle();

    // 桥接页 AppBar 标题「播放」+ 详情标题。
    expect(find.text('播放'), findsOneWidget);
    expect(find.text('演示影片详情'), findsOneWidget);
    expect(find.text('立即播放'), findsOneWidget);
  });
}
