/// 呈现层单测：香蕉秀 XJSP 原生专用页（UI-C1a）。
///
/// 对齐 iOS `YBoxXjspMainView`：
///   · 顶部「首页 / 短视频 / 演员」三 Tab，进入即加载首页分类；
///   · 首页 → 横向分类 Tab + 2 列视频网格（封面标签 + 标题）；
///   · 短视频 Tab → `mini:` 前缀短视频网格；
///   · 演员 Tab → 演员双列网格（「N部」角标）；
///   · 点击卡片 → [WelfareVideoBridgePage] 播放中转页。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/services/banana_xjsp_service.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';
import 'package:vbox/presentation/pages/welfare/banana_xjsp_home_page.dart';
import 'package:vbox/presentation/pages/welfare/welfare_video_bridge_page.dart';

/// 假传输：命中关键字返回既定 JSON（未命中 → 404）。
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
          headers: <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
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

const String _categoriesPath = '/vod/listing-0-0-0-0-0-0-0-0-0-1';

const String _categoriesJson = '{"retcode":0,"data":{"categories":['
    '{"cateid":"9","catename":"国产精品"},'
    '{"cateid":"16","catename":"香蕉原创"}]}}';

const String _videosJson = '{"retcode":0,"data":{"vodrows":['
    '{"vodid":"vod1","title":"视频一","duration":"12:34","scorenum":"8.5",'
    '"areaname":"国产"},'
    '{"vodid":"vod2","title":"视频二","duration":"01:02"}]}}';

const String _miniJson = '{"retcode":0,"data":{"rows":['
    '{"vodrow":{"vodid":"mv1","title":"短视频一","duration":"00:15"},'
    '"user":{"nickname":"作者甲"}}]}}';

const String _actorsJson = '{"retcode":0,"data":{"actorrows":['
    '{"spid":"sp1","spname":"演员甲","itemcount":"12"}]}}';

BananaXjspFuliService _service(Map<String, String> routes) =>
    BananaXjspFuliService(
      bridge: SpiderHttpBridge(transport: _FakeTransport(routes)),
    );

Widget _hostApp(BananaXjspFuliService service) => MaterialApp(
      home: BananaXjspHomePage(service: service),
    );

void main() {
  testWidgets('首页：三 Tab + 分类 Tab + 视频网格（标题 / 标签可见）',
      (WidgetTester tester) async {
    final BananaXjspFuliService service = _service(<String, String>{
      '/vod/listing-9-0-0-0-0-0-0-0-0-1': _videosJson,
      _categoriesPath: _categoriesJson,
    });

    await tester.pumpWidget(_hostApp(service));
    await tester.pumpAndSettle();

    expect(find.text('香蕉秀'), findsOneWidget);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('短视频'), findsOneWidget);
    expect(find.text('演员'), findsOneWidget);
    expect(find.text('国产精品'), findsOneWidget);
    expect(find.text('香蕉原创'), findsOneWidget);
    expect(find.text('视频一'), findsOneWidget);
    expect(find.text('视频二'), findsOneWidget);
    // 底部胶囊标签（对齐 iOS `bottomLabel`：评分 · 地区 · 时长）。
    expect(find.text('8.5 · 国产 · 12:34'), findsOneWidget);
  });

  testWidgets('短视频 Tab：黑底入口页 +「开始浏览」按钮', (WidgetTester tester) async {
    final BananaXjspFuliService service = _service(<String, String>{
      '/minivod/reqlist': _miniJson,
      _categoriesPath: _categoriesJson,
    });

    await tester.pumpWidget(_hostApp(service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('短视频'));
    await tester.pumpAndSettle();

    // 对齐 iOS `YBoxBananaShortVideoTab` 入口态。
    expect(find.text('开始浏览'), findsOneWidget);
  });

  testWidgets('演员 Tab：双列网格 +「N部」角标', (WidgetTester tester) async {
    final BananaXjspFuliService service = _service(<String, String>{
      '/special/listing-0-0-1': _actorsJson,
      _categoriesPath: _categoriesJson,
    });

    await tester.pumpWidget(_hostApp(service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('演员'));
    await tester.pumpAndSettle();

    expect(find.text('演员甲'), findsOneWidget);
    expect(find.text('12部'), findsOneWidget);
  });

  testWidgets('域名全部不可达 → 错误态 + 重试按钮', (WidgetTester tester) async {
    // 无任何路由命中 → 所有入口 404 → 分类探测失败。
    final BananaXjspFuliService service = _service(<String, String>{});

    await tester.pumpWidget(_hostApp(service));
    await tester.pumpAndSettle();

    expect(find.text('未能连接到服务器，请检查域名或网络'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('点击视频卡片 → 进入播放中转页', (WidgetTester tester) async {
    final BananaXjspFuliService service = _service(<String, String>{
      '/vod/listing-9-0-0-0-0-0-0-0-0-1': _videosJson,
      _categoriesPath: _categoriesJson,
    });

    await tester.pumpWidget(_hostApp(service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('视频一'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(WelfareVideoBridgePage), findsOneWidget);
  });
}
