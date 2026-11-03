/// 平台层单测：站源原生搜索服务（B-11）。
///
/// 注入 fake [SpiderHttpTransport]，离线验证（对齐 iOS `ZhanyuanSearchService`）：
/// - `&&&` 语法 → XPath 归一
/// - 搜索 URL 构建（websearchurl 优先 + Apple CMS 兜底）
/// - XPath 模式 / 详情页模板模式两路解析
/// - 详情页播放列表（`detaillist` 规则 + `.//a` 兜底）
/// - URL / 图片 URL 补全
library;

import 'dart:convert' show utf8;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/models/zhanyuan.dart';
import 'package:vbox/domain/entities/spider/spider_models.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';
import 'package:vbox/platform/spider/zhanyuan_search_service.dart';

class _FakeTransport implements SpiderHttpTransport {
  _FakeTransport(this.responder);

  final SpiderTransportResponse Function(SpiderTransportRequest) responder;

  @override
  Future<SpiderTransportResponse> send(SpiderTransportRequest request) async =>
      responder(request);
}

SpiderTransportResponse _htmlResp(String html) => SpiderTransportResponse(
      status: 200,
      headers: const <String, String>{
        'content-type': 'text/html; charset=utf-8',
      },
      bodyBytes: utf8.encode(html),
    );

ZhanyuanSearchService _service(String html) =>
    ZhanyuanSearchService(bridge: SpiderHttpBridge(transport: _FakeTransport((_) => _htmlResp(html))));

Zhanyuan _site({
  String name = '测试站',
  String searchUrl = 'https://example.com',
  String searchname = '',
  String searchid = '',
  String searchpic = '',
  String searchstarr = '',
  String websearchurl = '',
  String detaillist = '',
  String detailjs = '',
  String detailjsurl = '',
}) =>
    Zhanyuan(
      name: name,
      searchUrl: searchUrl,
      searchname: searchname,
      searchid: searchid,
      searchpic: searchpic,
      searchstarr: searchstarr,
      websearchurl: websearchurl,
      detaillist: detaillist,
      detailjs: detailjs,
      detailjsurl: detailjsurl,
      updatedAt: 0,
    );

void main() {
  group('normalizeXPath（&&& 语法归一）', () {
    test('[@class=&&&xxx&&&] → contains(@class)', () {
      expect(
        ZhanyuanSearchService.normalizeXPath('//a[@class=&&&item&&&]/text()'),
        "//a[contains(@class, 'item')]/text()",
      );
    });

    test('[@attr=&&&xxx&&&] → [@attr=\'xxx\']', () {
      expect(
        ZhanyuanSearchService.normalizeXPath('//a[@href=&&&detail&&&]'),
        "//a[@href='detail']",
      );
    });
  });

  group('buildSearchURL（搜索 URL 构建）', () {
    test('websearchurl 空 → Apple CMS 搜索 URL', () {
      expect(
        ZhanyuanSearchService.buildSearchURL(_site(), '功夫'),
        'https://example.com/vodsearch/-------------.html?wd=%E5%8A%9F%E5%A4%AB',
      );
    });

    test('websearchurl 带 wd= 空占位 → 替换', () {
      expect(
        ZhanyuanSearchService.buildSearchURL(
          _site(websearchurl: 'https://s.com/search?wd='),
          '功夫',
        ),
        'https://s.com/search?wd=%E5%8A%9F%E5%A4%AB',
      );
    });

    test('websearchurl ** 占位替换', () {
      expect(
        ZhanyuanSearchService.buildSearchURL(
          _site(websearchurl: 'https://s.com/search/**'),
          '功夫',
        ),
        'https://s.com/search/%E5%8A%9F%E5%A4%AB?wd=%E5%8A%9F%E5%A4%AB',
      );
    });
  });

  group('searchZhanyuan（XPath 模式）', () {
    test('searchname/searchid XPath 规则 + 站点分组 + URL 补全', () async {
      const String html = '''
      <html><body>
        <a href="/vod/1.html" class="item">测试影片</a>
        <a href="/vod/2.html" class="item">另一部</a>
      </body></html>
      ''';
      final ZhanyuanSearchService svc = _service(html);
      final List<VodItem> items = await svc.searchZhanyuan(
        _site(
          searchname: '//a[@class=&&&item&&&]/text()',
          searchid: '//a[@class=&&&item&&&]/@href',
        ),
        '功夫',
      );
      expect(items, hasLength(2));
      expect(items[0].vodId, 'https://example.com/vod/1.html');
      expect(items[0].vodName, '测试影片');
      expect(items[0].vodRemarks, '测试站');
      expect(items[1].vodId, 'https://example.com/vod/2.html');
    });
  });

  group('searchZhanyuan（详情页模板模式）', () {
    test('searchid 带 # 模板 → 链接 + 名称 + 图片提取', () async {
      const String html = '''
      <html><body>
        <a href="/vod/1.html"><img data-original="/pic/1.jpg">影片A</a>
      </body></html>
      ''';
      final ZhanyuanSearchService svc = _service(html);
      final List<VodItem> items = await svc.searchZhanyuan(
        _site(searchid: 'https://s.com/vod/#.html'),
        '功夫',
      );
      expect(items, hasLength(1));
      expect(items.single.vodId, 'https://example.com/vod/1.html');
      expect(items.single.vodName, '影片A');
      expect(items.single.vodPic, 'https://example.com/pic/1.jpg');
    });
  });

  group('fetchDetail（详情播放列表）', () {
    test('detaillist 规则 + .//a 兜底（detailjs 空）', () async {
      const String html = '''
      <html><body>
        <h1>测试长剧</h1>
        <ul class="stui-content__playlist">
          <a href="/x/1.html">第1集</a>
          <a href="/x/2.html">第2集</a>
        </ul>
      </body></html>
      ''';
      final ZhanyuanSearchService svc = _service(html);
      final VodItem item = await svc.fetchDetail(
        'https://example.com/vod/1.html',
        _site(detaillist: "//ul[contains(@class,'stui-content__playlist')]"),
      );
      expect(item.vodName, '测试长剧');
      expect(item.vodPlayFrom, '测试站');
      expect(item.vodPlayUrl,
          '第1集\$https://example.com/x/1.html#第2集\$https://example.com/x/2.html');
    });
  });

  group('completeURL / completeImageURL', () {
    test('绝对 / 协议相对 / 根相对 / 裸相对', () {
      const String base = 'https://example.com';
      expect(ZhanyuanSearchService.completeURL('https://a.com/x', base), 'https://a.com/x');
      expect(ZhanyuanSearchService.completeURL('//a.com/x', base), 'https://a.com/x');
      expect(ZhanyuanSearchService.completeURL('/x', base), 'https://example.com/x');
      expect(ZhanyuanSearchService.completeURL('x', base), 'https://example.com/x');
      expect(ZhanyuanSearchService.completeImageURL('', base), '');
    });
  });
}