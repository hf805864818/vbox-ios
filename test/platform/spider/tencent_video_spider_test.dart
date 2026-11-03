/// 平台层单测：腾讯视频原生 Spider（B-11）。
///
/// 注入 fake [SpiderHttpTransport]，按请求 URL / body 分流返回 mock JSON，
/// 离线验证（对齐 iOS `TencentVideoNativeSpider`）：
/// - 搜索：类型白名单 + 外站过滤 + cid 去重 + HTML 标签移除
/// - 详情：基础信息 + 演员 + 剧集列表（含 `预告` 分流）+ tabs 分页
library;

import 'dart:convert' show utf8;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/spider_models.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';
import 'package:vbox/platform/spider/tencent_video_spider.dart';

class _FakeTransport implements SpiderHttpTransport {
  _FakeTransport(this.responder);

  final SpiderTransportResponse Function(SpiderTransportRequest) responder;

  @override
  Future<SpiderTransportResponse> send(SpiderTransportRequest request) async =>
      responder(request);
}

SpiderTransportResponse _jsonResp(String json) => SpiderTransportResponse(
      status: 200,
      headers: const <String, String>{'content-type': 'application/json'},
      bodyBytes: utf8.encode(json),
    );

const String _searchJson = '''
{
  "data": {
    "normalList": {
      "itemList": [
        {"doc": {"id": "cid1"}, "videoInfo": {"title": "测试<em>剧</em>", "typeName": "电视剧", "imgUrl": "http://p/1.jpg", "year": "2024", "subTitle": ""}},
        {"doc": {"id": "cid1"}, "videoInfo": {"title": "重复", "typeName": "电视剧", "subTitle": ""}},
        {"doc": {"id": "cid2"}, "videoInfo": {"title": "外站片", "typeName": "电影", "subTitle": "外站"}},
        {"doc": {"id": "cid3"}, "videoInfo": {"title": "综艺片", "typeName": "综艺", "subTitle": ""}}
      ]
    }
  }
}
''';

const String _detailJson = '''
{
  "data": {
    "module_list_datas": [
      {"module_datas": [
        {"item_data_lists": {"item_datas": [
          {"item_params": {
            "title": "测试长剧", "new_pic_hz": "http://p/cover.jpg", "year": "2024",
            "area_name": "大陆", "cover_description": "简介", "sub_genre": "爱情"
          },
          "sub_items": {"star_list": {"item_datas": [
            {"item_params": {"name": "张三"}}, {"item_params": {"name": "李四"}}
          ]}}}
        ]}}
      ]}
    ]
  }
}
''';

const String _episodeJson = '''
{
  "data": {
    "module_list_datas": [
      {"module_datas": [
        {"item_data_lists": {"item_datas": [
          {"item_id": "vid1", "item_params": {"union_title": "第1集"}},
          {"item_id": "vid2", "item_params": {"union_title": "第2集预告"}}
        ]},
        "module_params": {"tabs": "[{\\"page_context\\":\\"ctx0\\"},{\\"page_context\\":\\"ctx1\\"}]"}}
      ]}
    ]
  }
}
''';

const String _episodePage2Json = '''
{
  "data": {
    "module_list_datas": [
      {"module_datas": [
        {"item_data_lists": {"item_datas": [
          {"item_id": "vid3", "item_params": {"union_title": "第3集"}}
        ]}}
      ]}
    ]
  }
}
''';

TencentVideoNativeSpider _spider() => TencentVideoNativeSpider(
      bridge: SpiderHttpBridge(
        transport: _FakeTransport((SpiderTransportRequest req) {
          final String url = req.url.toString();
          final String body = req.body ?? '';
          if (url.contains('MultiTerminalSearch')) return _jsonResp(_searchJson);
          if (url.contains('GetPageData')) {
            if (body.contains('detail_page_introduction')) {
              return _jsonResp(_detailJson);
            }
            if (body.contains(r'"page_context":"ctx1"')) {
              return _jsonResp(_episodePage2Json);
            }
            return _jsonResp(_episodeJson);
          }
          return _jsonResp('{}');
        }),
      ),
    );

void main() {
  group('search（搜索）', () {
    test('类型白名单 + 外站过滤 + cid 去重 + HTML 标签移除', () async {
      final List<VodItem> items = await _spider().search('功夫');
      expect(items, hasLength(2));

      // cid1 去重留一条；HTML 标签移除
      expect(items[0].vodId, 'cid1');
      expect(items[0].vodName, '测试剧');
      expect(items[0].vodPic, 'http://p/1.jpg');
      expect(items[0].vodRemarks, '电视剧 ⭐2024');

      // cid2 外站过滤，cid3 综艺保留
      expect(items[1].vodId, 'cid3');
      expect(items[1].vodName, '综艺片');
    });
  });

  group('detail（详情）', () {
    test('基础信息 + 演员 + 剧集分流 + tabs 分页', () async {
      final VodItem? item = await _spider().detail('cid1');
      expect(item, isNotNull);

      expect(item!.vodName, '测试长剧');
      expect(item.vodPic, 'http://p/cover.jpg');
      expect(item.vodYear, '2024');
      expect(item.vodArea, '大陆');
      expect(item.vodContent, '简介');
      expect(item.vodActor, '张三,李四');
      expect(item.vodRemarks, '爱情 2024');
      expect(item.vodPlayFrom, '腾讯视频');

      // 剧集：第1集、第3集（正片），第2集预告（预告分流）
      const String ep1 = '第1集\$https://v.qq.com/x/cover/cid1/vid1.html';
      const String ep3 = '第3集\$https://v.qq.com/x/cover/cid1/vid3.html';
      const String ep2 = '第2集预告\$https://v.qq.com/x/cover/cid1/vid2.html';
      expect(item.vodPlayUrl, '$ep1#$ep3\$\$\$$ep2');
    });
  });

  group('removeHtmlTags', () {
    test('去除标签 + trim', () {
      expect(TencentVideoNativeSpider.removeHtmlTags(' <em>张三</em> 主演 '),
          '张三 主演');
    });
  });
}