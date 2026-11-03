/// 源发现页自适应筛选与「全部」回退回归（对齐 iOS SourceDiscoveryView
/// `extractAdaptiveFilters` / `reloadCategoryWithFilters` / `displayCategories`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/domain/entities/remote_source/remote_source.dart';
import 'package:vbox/domain/entities/spider/spider.dart';
import 'package:vbox/domain/usecases/usecases.dart';
import 'package:vbox/presentation/ui_mode/ui_mode.dart';
import 'package:vbox/presentation/widgets/source_discovery_view.dart';

/// 筛选记录版用例：分类请求记录 filters，返回带地区/年份的数据。
class _FilterBrowseUseCases extends ContentBrowseUseCases {
  _FilterBrowseUseCases() : super(loadAllSources: _emptySources);

  static Future<Result<AllSourcesContainer>> _emptySources() async =>
      const Success<AllSourcesContainer>(AllSourcesContainer());

  final List<Map<String, String>> filterCalls = <Map<String, String>>[];

  @override
  Future<Result<List<SiteConfig>>> listSites() async =>
      const Success<List<SiteConfig>>(<SiteConfig>[
        SiteConfig(key: 's1', name: '站点1', type: 0, api: 'https://s1.example.com'),
      ]);

  @override
  Future<Result<HomeContentResult>> homeContent(String siteKey) async =>
      const Success<HomeContentResult>(
        HomeContentResult(
          classes: <VodCategory>[VodCategory(typeId: '1', typeName: '电影')],
          list: <VodItem>[],
        ),
      );

  @override
  Future<Result<CategoryContentResult>> categoryContent(
    String siteKey, {
    String? tid,
    int page = 1,
    Map<String, String>? filters,
  }) async {
    filterCalls.add(filters ?? const <String, String>{});
    return Success<CategoryContentResult>(
      CategoryContentResult(
        list: <VodItem>[
          VodItem(
            vodId: '$page',
            vodName: '片$page',
            vodPic: '',
            vodArea: '大陆/美国',
            vodYear: '2024年',
          ),
        ],
        pagecount: 1,
      ),
    );
  }
}

/// 无分类版用例：homeContent 返回空分类 + 非空推荐（触发「全部」回退）。
class _NoClassBrowseUseCases extends _FilterBrowseUseCases {
  @override
  Future<Result<HomeContentResult>> homeContent(String siteKey) async =>
      const Success<HomeContentResult>(
        HomeContentResult(
          classes: <VodCategory>[],
          list: <VodItem>[VodItem(vodId: '9', vodName: '推荐片', vodPic: '')],
        ),
      );
}

Widget _host(ContentBrowseUseCases uc) => MultiProvider(
      providers: [
        Provider<ContentBrowseUseCases>.value(value: uc),
        // 视图网格依赖形态控制器（对齐 app.dart 根注入）。
        ChangeNotifierProvider<UiFormController>.value(
          value: UiFormController(),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: SourceDiscoveryView())),
    );

void main() {
  group('自适应筛选提取（对齐 iOS extractAdaptiveFilters）', () {
    test('地区按 / ， 、 拆分去重 + Unicode 升序 + 「全部」前缀（对齐 iOS sorted()）', () {
      final AdaptiveFilterOptions opts = extractAdaptiveFilters(<VodItem>[
        const VodItem(vodId: '1', vodName: 'a', vodPic: '', vodArea: '大陆/美国'),
        const VodItem(vodId: '2', vodName: 'b', vodPic: '', vodArea: '大陆，香港'),
        const VodItem(vodId: '3', vodName: 'c', vodPic: '', vodArea: ' 美国 、台湾'),
      ]);
      // iOS `Array(areaSet).sorted()` 为 Unicode 标量升序：台(U+53F0) < 大(U+5927)。
      expect(opts.area, <String>['全部', '台湾', '大陆', '美国', '香港']);
    });

    test('年份提取前 4 位数字去重降序', () {
      final AdaptiveFilterOptions opts = extractAdaptiveFilters(<VodItem>[
        const VodItem(vodId: '1', vodName: 'a', vodPic: '', vodYear: '2024年'),
        const VodItem(vodId: '2', vodName: 'b', vodPic: '', vodYear: '2023'),
        const VodItem(vodId: '3', vodName: 'c', vodPic: '', vodYear: '2024'),
      ]);
      expect(opts.year, <String>['全部', '2024', '2023']);
    });

    test('类型维度对齐 iOS 现状恒为空（classSet 未填充）', () {
      final AdaptiveFilterOptions opts = extractAdaptiveFilters(<VodItem>[
        const VodItem(vodId: '1', vodName: 'a', vodPic: '', vodArea: '大陆'),
      ]);
      expect(opts.classOptions, isEmpty);
      expect(opts.sort, <String>['全部', 'hits', 'addtime', 'score', 'rand']);
    });

    test('排序显示名映射（对齐 iOS sortDisplayValue）', () {
      expect(SourceDiscoveryView.sortDisplayValue('全部'), '默认');
      expect(SourceDiscoveryView.sortDisplayValue('hits'), '热播');
      expect(SourceDiscoveryView.sortDisplayValue('addtime'), '最新');
      expect(SourceDiscoveryView.sortDisplayValue('score'), '高分');
      expect(SourceDiscoveryView.sortDisplayValue('rand'), '随机');
    });
  });

  group('筛选栏 UI 流程', () {
    testWidgets('进入分类显示筛选栏，选地区后带筛选重载第 1 页',
        (WidgetTester tester) async {
      final _FilterBrowseUseCases uc = _FilterBrowseUseCases();
      await tester.pumpWidget(_host(uc));
      await tester.pump();
      await tester.pump();

      // 进入分类「电影」→ 筛选栏出现（地区/年份/排序；类型恒空不显示）。
      await tester.tap(find.text('电影'));
      await tester.pump();
      await tester.pump();
      expect(find.text('地区'), findsOneWidget);
      expect(find.text('年份'), findsOneWidget);
      expect(find.text('排序'), findsOneWidget);
      expect(find.text('类型'), findsNothing);
      // 首载无筛选。
      expect(uc.filterCalls.last, isEmpty);
      // 排序 chip 显示映射名「默认」。
      expect(find.text('默认'), findsOneWidget);

      // 选地区「大陆」→ 带筛选重载第 1 页。
      await tester.tap(find.text('地区'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('大陆'));
      await tester.pumpAndSettle();
      expect(uc.filterCalls.last, <String, String>{'area': '大陆'});
      // 重载后数据渲染。
      expect(find.text('片1'), findsOneWidget);
    });

    testWidgets('选排序后带筛选重载（映射值反传）', (WidgetTester tester) async {
      final _FilterBrowseUseCases uc = _FilterBrowseUseCases();
      await tester.pumpWidget(_host(uc));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('电影'));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('默认'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('热播'));
      await tester.pumpAndSettle();
      expect(uc.filterCalls.last, <String, String>{'sort': 'hits'});
    });

    testWidgets('回「推荐」筛选栏消失；切回分类筛选重置', (WidgetTester tester) async {
      final _FilterBrowseUseCases uc = _FilterBrowseUseCases();
      await tester.pumpWidget(_host(uc));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('电影'));
      await tester.pump();
      await tester.pump();
      expect(find.text('地区'), findsOneWidget);

      // 选地区。
      await tester.tap(find.text('地区'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('大陆'));
      await tester.pumpAndSettle();

      // 回推荐 → 筛选栏消失。
      await tester.tap(find.text('推荐'));
      await tester.pump();
      expect(find.text('地区'), findsNothing);

      // 再进分类 → 筛选已重置（首载 filters 为空）。
      await tester.tap(find.text('电影'));
      await tester.pump();
      await tester.pump();
      expect(find.text('地区'), findsOneWidget);
      expect(uc.filterCalls.last, isEmpty);
    });
  });

  group('「全部」回退分类（对齐 iOS displayCategories）', () {
    testWidgets('分类为空但有推荐 → 显示「全部」chip，选中展示推荐内容',
        (WidgetTester tester) async {
      final _NoClassBrowseUseCases uc = _NoClassBrowseUseCases();
      await tester.pumpWidget(_host(uc));
      await tester.pump();
      await tester.pump();

      // 分类栏回退为单一「全部」chip。
      expect(find.text('全部'), findsOneWidget);
      expect(find.text('推荐'), findsOneWidget);
      // 推荐内容可见。
      expect(find.text('推荐片'), findsOneWidget);

      // 点击「全部」→ 仍展示推荐内容（不发起分类请求）。
      final int callsBefore = uc.filterCalls.length;
      await tester.tap(find.text('全部'));
      await tester.pump();
      await tester.pump();
      expect(find.text('推荐片'), findsOneWidget);
      expect(uc.filterCalls.length, callsBefore);
    });
  });
}
