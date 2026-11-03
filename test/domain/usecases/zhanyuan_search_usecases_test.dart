/// 领域层单测：站源原生搜索用例（B-11）。
///
/// 注入 fake transport 的 [ZhanyuanSearchService] + 假站点加载器，离线验证：
/// - 并发搜索 → 每批非空结果 onBatch 流式回调
/// - 搜索历史写入调用一次
/// - 空站点跳过（不写历史、不回调）
library;

import 'dart:convert' show utf8;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/models/zhanyuan.dart';
import 'package:vbox/domain/entities/spider/spider_models.dart';
import 'package:vbox/domain/usecases/zhanyuan_search_usecases.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';
import 'package:vbox/platform/spider/zhanyuan_search_service.dart';

class _FakeTransport implements SpiderHttpTransport {
  @override
  Future<SpiderTransportResponse> send(SpiderTransportRequest request) async =>
      SpiderTransportResponse(
        status: 200,
        headers: const <String, String>{
          'content-type': 'text/html; charset=utf-8',
        },
        bodyBytes: utf8.encode(
          '<html><body><a href="/vod/1.html" class="item">测试影片</a></body></html>',
        ),
      );
}

Zhanyuan _site(String name) => Zhanyuan(
      name: name,
      searchUrl: 'https://$name.example.com',
      searchname: '//a[@class=&&&item&&&]/text()',
      searchid: '//a[@class=&&&item&&&]/@href',
      updatedAt: 0,
    );

void main() {
  test('并发搜索：逐批 onBatch 流式回调 + 历史写入', () async {
    final ZhanyuanSearchService service =
        ZhanyuanSearchService(bridge: SpiderHttpBridge(transport: _FakeTransport()));

    final List<String> history = <String>[];
    final List<List<VodItem>> batches = <List<VodItem>>[];

    final ZhanyuanSearchUseCases usecases = ZhanyuanSearchUseCases(
      loadSites: () async => <Zhanyuan>[_site('a'), _site('b')],
      addSearchHistory: (String kw) async => history.add(kw),
      service: service,
    );

    await usecases.searchAll(
      '功夫',
      onBatch: (List<VodItem> items) => batches.add(items),
    );

    expect(history, <String>['功夫']);
    expect(batches, hasLength(2));
    expect(batches[0].single.vodName, '测试影片');
    expect(batches[0].single.vodRemarks, 'a');
    expect(batches[1].single.vodRemarks, 'b');
  });

  test('回填来源站点 key（engineKey，S-设2）', () async {
    final ZhanyuanSearchService service =
        ZhanyuanSearchService(bridge: SpiderHttpBridge(transport: _FakeTransport()));

    final List<List<VodItem>> batches = <List<VodItem>>[];
    final ZhanyuanSearchUseCases usecases = ZhanyuanSearchUseCases(
      loadSites: () async => <Zhanyuan>[_site('a').copyWith(key: 'zhan_1')],
      service: service,
    );

    await usecases.searchAll(
      '功夫',
      onBatch: (List<VodItem> items) => batches.add(items),
    );

    expect(batches.single.single.engineKey, 'zhan_1');
  });

  test('空站点：跳过（不写历史、不回调）', () async {
    final ZhanyuanSearchService service =
        ZhanyuanSearchService(bridge: SpiderHttpBridge(transport: _FakeTransport()));

    bool historyCalled = false;
    int batchCalls = 0;

    final ZhanyuanSearchUseCases usecases = ZhanyuanSearchUseCases(
      loadSites: () async => <Zhanyuan>[],
      addSearchHistory: (_) async => historyCalled = true,
      service: service,
    );

    await usecases.searchAll(
      '功夫',
      onBatch: (_) => batchCalls++,
    );

    expect(historyCalled, isFalse);
    expect(batchCalls, 0);
  });
}