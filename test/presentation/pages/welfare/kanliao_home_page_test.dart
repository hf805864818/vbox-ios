/// 呈现层单测：今日看料原生专用页（UI-C1e）。
///
/// 对齐 iOS `KanliaoHomeView` / `KanliaoVideoGrid`：
///   · 进入即加载分类 → 横向分类 Tab + 2 列视频网格；
///   · 分类为空 → 「暂无可用分类」空态；
///   · 点击卡片 → [WelfareVideoBridgePage] 播放中转页。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/services/kanliao_service.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';
import 'package:vbox/presentation/pages/welfare/kanliao_home_page.dart';
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

const String _homeHtml = '''
<html><body>
<nav class="navbar">
<a href="/category/dy/">抖音</a>
<a href="/category/ks/">快手</a>
<a href="/category/hy/">虎牙</a>
</nav>
<article class="post-card">article</article>
</body></html>
''';

const String _categoryHtml = '''
<html><body>
<article class="post-card"><a href="/post/11.html">
<img data-src="/img/11.jpg"><h2>分类视频甲</h2></a></article>
<article class="post-card"><a href="/post/12.html">
<img data-src="/img/12.jpg"><h2>分类视频乙</h2></a></article>
</body></html>
''';

KanliaoFuliService _service(Map<String, String> routes) => KanliaoFuliService(
      bridge: SpiderHttpBridge(transport: _FakeTransport(routes)),
    );

Widget _host(KanliaoFuliService service) => MaterialApp(
      home: KanliaoHomePage(service: service),
    );

void main() {
  testWidgets('有分类 → 分类 Tab + 视频网格（标题 / 分类名可见）',
      (WidgetTester tester) async {
    final KanliaoFuliService service = _service(<String, String>{
      'kanliao2.one/category/dy/': _categoryHtml,
      'kanliao2.one': _homeHtml,
    });

    await tester.pumpWidget(_host(service));
    await tester.pumpAndSettle();

    expect(find.text('今日看料'), findsOneWidget);
    expect(find.text('抖音'), findsOneWidget);
    expect(find.text('快手'), findsOneWidget);
    expect(find.text('分类视频甲'), findsOneWidget);
    expect(find.text('分类视频乙'), findsOneWidget);
    expect(find.text('暂无可用分类'), findsNothing);
  });

  testWidgets('解析不到分类 → 回退内置分类（首个「热点关注」Tab）',
      (WidgetTester tester) async {
    // 首页正文无导航链接 → 分类解析为空 → 服务回退内置 11 分类（对齐 iOS
    // `fallbackCategories`），故渲染首个「热点关注」Tab，不出现空态。
    final KanliaoFuliService service = _service(<String, String>{
      'kanliao2.one': '<html><body>article 但无导航</body></html>',
    });

    await tester.pumpWidget(_host(service));
    await tester.pumpAndSettle();

    expect(find.text('热点关注'), findsOneWidget);
    expect(find.text('暂无可用分类'), findsNothing);
  });

  testWidgets('点击视频卡片 → 进入播放中转页', (WidgetTester tester) async {
    final KanliaoFuliService service = _service(<String, String>{
      'kanliao2.one/category/dy/': _categoryHtml,
      'kanliao2.one': _homeHtml,
    });

    await tester.pumpWidget(_host(service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('分类视频甲'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(WelfareVideoBridgePage), findsOneWidget);
  });
}