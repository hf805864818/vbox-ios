/// 备用全屏「选择源」页单测（批次 E · E2-6）。
///
/// 对齐基准：iOS `SourcePickerSheet.swift:5-105`（搜索框 + 分类分组 + 类型徽标源行）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/site_config.dart';
import 'package:vbox/presentation/pages/home/source_picker_page.dart';

SiteConfig _site(
  String key, {
  String? name,
  int type = 0,
  String? api,
  String? group,
}) =>
    SiteConfig(
      key: key,
      name: name ?? key,
      type: type,
      api: api,
      group: group,
    );

List<SiteConfig> _allCategories() => <SiteConfig>[
      _site('cloud_baidu', name: '百度网盘'),
      _site('api_a', name: 'API源'),
      _site('site_a', name: '站源A', type: 2),
      _site('js_a', name: 'JS源', type: 3, api: 'https://x/a.js'),
      _site('forum_a', name: '论坛源', type: 3, api: 'https://x/forum'),
    ];

void main() {
  testWidgets('五类分组全部渲染 + 源行名称与分类胶囊', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: SourcePickerPage(sites: _allCategories())),
    );

    expect(find.text('选择源'), findsOneWidget);
    expect(find.text('搜索源...'), findsOneWidget);
    // 分组标题（与行内分类胶囊同文案），故用 findsWidgets。
    for (final String group in <String>['网盘', 'API', '站源', 'JS', '论坛']) {
      expect(find.text(group), findsWidgets, reason: '缺少分组 $group');
    }
    for (final String name in <String>['百度网盘', 'API源', '站源A', 'JS源', '论坛源']) {
      expect(find.text(name), findsOneWidget);
    }
  });

  testWidgets('搜索过滤命中 + 清除按钮还原 + 无匹配空态', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: SourcePickerPage(sites: _allCategories())),
    );

    // 命中：仅保留「百度网盘」。
    await tester.enterText(find.byType(TextField), '百度');
    await tester.pumpAndSettle();
    expect(find.text('百度网盘'), findsOneWidget);
    expect(find.text('API源'), findsNothing);

    // 清除按钮 → 还原全部。
    await tester.tap(find.byIcon(Icons.cancel));
    await tester.pumpAndSettle();
    expect(find.text('API源'), findsOneWidget);

    // 无匹配 → 空态。
    await tester.enterText(find.byType(TextField), '不存在的源');
    await tester.pumpAndSettle();
    expect(find.text('未找到匹配的源'), findsOneWidget);
    expect(find.text('百度网盘'), findsNothing);
  });

  testWidgets('点击源行返回该源 key + 选中态 checkmark', (WidgetTester tester) async {
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext c) {
            hostContext = c;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    );

    final Future<String?> picked = showVboxSourcePickerPage(
      hostContext,
      // 仅两行，确保都在首屏可见（避免 ListView 视口外点击失败）。
      sites: <SiteConfig>[
        _site('cloud_baidu', name: '百度网盘'),
        _site('api_a', name: 'API源'),
      ],
      selectedKey: 'api_a',
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check), findsOneWidget); // 仅 api_a 选中
    await tester.tap(find.text('API源'));
    await tester.pumpAndSettle();

    expect(await picked, 'api_a');
  });

  testWidgets('无源时分组为空 → 空态', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SourcePickerPage(sites: <SiteConfig>[])),
    );
    expect(find.text('未找到匹配的源'), findsOneWidget);
  });
}
