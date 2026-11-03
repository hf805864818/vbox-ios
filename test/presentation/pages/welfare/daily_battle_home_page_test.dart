/// 呈现层单测：每日大乱斗 / 每日大赛原生专用页（UI-C1b）。
///
/// 对齐 iOS `DailyBattleMainView` / `DailyBattleHomeTab` / `DailyBattleSearchTab`：
///   · 顶部「首页 / 搜索」双 Tab，进入即加载首页分类；
///   · 首页 → 横向分类 Tab + 2 列视频网格（封面时长角标 + 标题）；
///   · 搜索 Tab → 输入关键词 → 结果网格；
///   · 点击卡片 → [WelfareVideoBridgePage] 播放中转页。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/services/daily_battle_service.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';
import 'package:vbox/presentation/pages/welfare/daily_battle_home_page.dart';
import 'package:vbox/presentation/pages/welfare/welfare_video_bridge_page.dart';

/// 假传输：命中关键字返回既定 HTML。
class _FakeTransport implements SpiderHttpTransport {
  _FakeTransport(this.routes);

  final Map<String, String> routes;

  @override
  Future<SpiderTransportResponse> send(SpiderTransportRequest request) async {
    final String url = request.url.toString();
    for (final MapEntry<String, String> e in routes.entries) {
      if (url.contains(e.key)) {
        return SpiderTransportResponse(
          status: 200,
          headers: <String, String>{'content-type': 'text/html; charset=utf-8'},
          bodyBytes: utf8.encode(e.value),
        );
      }
    }
    return const SpiderTransportResponse(
      status: 404,
      headers: <String, String>{},
      bodyBytes: <int>[],
    );
  }
}

const String _host = 'border.bshzjjgq.cc';

const String _homeHtml = '''
<html><body>
<nav><a href="/category/mrld/">今日乱斗</a><a href="/category/bkdg/">必看大瓜</a></nav>
<article class="post-card"><a href="/post/1.html">
<img data-src="/img/1.jpg"><h2>首页视频一</h2></a></article>
</body></html>
''';

const String _categoryHtml = '''
<html><body>
<article class="post-card"><a href="/post/11.html">
<img data-src="/img/11.jpg"><h2>分类视频甲</h2><time>12:34</time></a></article>
<article class="post-card"><a href="/post/12.html">
<img data-src="/img/12.jpg"><h2>分类视频乙</h2></a></article>
</body></html>
''';

DailyBattleFuliService _service(Map<String, String> routes) =>
    DailyBattleFuliService(
      bridge: SpiderHttpBridge(transport: _FakeTransport(routes)),
    );

Widget _hostApp(DailyBattleFuliService service) => MaterialApp(
      home: DailyBattleHomePage(service: service),
    );

void main() {
  testWidgets('首页：双 Tab + 分类 Tab + 视频网格（标题 / 分类名可见）',
      (WidgetTester tester) async {
    final DailyBattleFuliService service = _service(<String, String>{
      '$_host/category/mrld/': _categoryHtml,
      _host: _homeHtml,
    });

    await tester.pumpWidget(_hostApp(service));
    await tester.pumpAndSettle();

    expect(find.text('每日大乱斗'), findsOneWidget);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('搜索'), findsOneWidget);
    expect(find.text('今日乱斗'), findsOneWidget);
    expect(find.text('必看大瓜'), findsOneWidget);
    expect(find.text('分类视频甲'), findsOneWidget);
    expect(find.text('分类视频乙'), findsOneWidget);
    // 时长角标（对齐 iOS `remarks` 标签）。
    expect(find.text('12:34'), findsOneWidget);
  });

  testWidgets('搜索 Tab：输入关键词 → 结果网格', (WidgetTester tester) async {
    final DailyBattleFuliService service = _service(<String, String>{
      '$_host/search/abc/': _categoryHtml,
      _host: _homeHtml,
    });

    await tester.pumpWidget(_hostApp(service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    expect(find.text('分类视频甲'), findsWidgets);
    expect(find.text('未找到相关内容'), findsNothing);
  });

  testWidgets('搜索 Tab：无结果 → 「未找到相关内容」空态',
      (WidgetTester tester) async {
    final DailyBattleFuliService service = _service(<String, String>{
      _host: '<html><body>无内容</body></html>',
    });

    await tester.pumpWidget(_hostApp(service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    expect(find.text('未找到相关内容'), findsOneWidget);
  });

  testWidgets('域名全部不可达 → 错误态 + 重试按钮', (WidgetTester tester) async {
    // 无任何路由命中 → 所有入口 404 → 探测失败。
    final DailyBattleFuliService service = _service(<String, String>{});

    await tester.pumpWidget(_hostApp(service));
    await tester.pumpAndSettle();

    expect(find.text('未能连接到服务器，请检查域名或网络'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('点击视频卡片 → 进入播放中转页', (WidgetTester tester) async {
    final DailyBattleFuliService service = _service(<String, String>{
      '$_host/category/mrld/': _categoryHtml,
      _host: _homeHtml,
    });

    await tester.pumpWidget(_hostApp(service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('分类视频甲'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(WelfareVideoBridgePage), findsOneWidget);
  });
}