/// 数据层单测：CMS V10 数据源（纯解析 + MockClient 请求链路）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/core/errors/failures.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/data/datasources/remote/remote.dart';

const String kBase = 'https://cms.example.com/api.php/provide/vod/';

CmsV10Datasource datasourceWith(
  MockClient mock, {
  Map<String, String> headers = const <String, String>{},
}) =>
    CmsV10Datasource(
      client: HttpClient(inner: mock, retryBaseDelay: Duration.zero),
      headers: headers,
    );

void main() {
  group('纯解析函数', () {
    test('normalizeCmsUrl：绝对 / 协议相对 / 站内路径 / 裸域名', () {
      expect(normalizeCmsUrl('http://a.com/x.jpg', 'b.com'), 'http://a.com/x.jpg');
      expect(normalizeCmsUrl('https://a.com/x.jpg', 'b.com'), 'https://a.com/x.jpg');
      expect(normalizeCmsUrl('//cdn.com/x.jpg', 'b.com'), 'https://cdn.com/x.jpg');
      expect(normalizeCmsUrl('/upload/x.jpg', 'b.com'), 'https://b.com/upload/x.jpg');
      expect(normalizeCmsUrl('upload/x.jpg', 'b.com'), 'https://upload/x.jpg');
      expect(normalizeCmsUrl('   ', 'b.com'), '');
    });

    test('normalizeCmsPic 复用 normalizeCmsUrl', () {
      expect(normalizeCmsPic('/p.jpg', 'b.com'), 'https://b.com/p.jpg');
    });

    test('parseCmsPlayUrl：标准 名称\$地址 串', () {
      final List<CmsV10Episode> eps = parseCmsPlayUrl(
        '第1集\$https://v.com/1.m3u8#第2集\$https://v.com/2.m3u8',
        'cms.example.com',
      );
      expect(eps.length, 2);
      expect(eps.first.name, '第1集');
      expect(eps.first.url, 'https://v.com/1.m3u8');
      expect(eps.last.name, '第2集');
    });

    test('parseCmsPlayUrl：无名称按序号生成、相对地址归一、空段跳过', () {
      final List<CmsV10Episode> eps = parseCmsPlayUrl(
        'https://v.com/a.m3u8##/b.m3u8#\$',
        'cms.example.com',
      );
      expect(eps.length, 2);
      expect(eps.first.name, '第1集');
      expect(eps.first.url, 'https://v.com/a.m3u8');
      expect(eps.last.name, '第3集');
      expect(eps.last.url, 'https://cms.example.com/b.m3u8');
    });

    test('parseCmsPlayUrl：空串 → 空列表', () {
      expect(parseCmsPlayUrl('', 'h'), isEmpty);
      expect(parseCmsPlayUrl('   ', 'h'), isEmpty);
    });
  });

  group('buildUri', () {
    test('强制 at=json 且保留站点自有查询参数', () {
      final Uri? uri = CmsV10Datasource(
        client: HttpClient(inner: MockClient((http.Request r) async =>
            http.Response('{}', 200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              }))),
      ).buildUri('$kBase?token=abc', <String, String>{'ac': 'list'});
      expect(uri, isNotNull);
      expect(uri!.queryParameters['token'], 'abc');
      expect(uri.queryParameters['at'], 'json');
      expect(uri.queryParameters['ac'], 'list');
    });

    test('非法地址返回 null', () {
      final CmsV10Datasource ds = datasourceWith(
        MockClient((http.Request r) async => http.Response('{}', 200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              })),
      );
      expect(ds.buildUri('ftp://a.com/x', <String, String>{}), isNull);
      expect(ds.buildUri('not a url', <String, String>{}), isNull);
    });
  });

  group('fetchCategories', () {
    test('解析分类列表', () async {
      Uri? requested;
      final CmsV10Datasource ds = datasourceWith(
        MockClient((http.Request r) async {
          requested = r.url;
          return http.Response(
            jsonEncode(<String, Object?>{
              'class': <Object?>[
                <String, Object?>{'type_id': 1, 'type_name': '电影', 'type_pid': 0},
                <String, Object?>{'type_id': '2', 'type_name': '剧集'},
              ],
            }),
            200,
            headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final Result<List<CmsV10Category>> r = await ds.fetchCategories(kBase);
      expect(r.isSuccess, isTrue);
      expect(r.valueOrNull?.length, 2);
      expect(r.valueOrNull?.first.typeName, '电影');
      expect(r.valueOrNull?.last.typeId, '2');
      // 裸参直连命中（对齐 iOS tryFetchJSON：ac 参数不带 at=json）。
      expect(requested?.queryParameters['ac'], 'list');
      expect(requested?.queryParameters['at'], isNull);
    });

    test('分类为空 → ParseFailure', () async {
      final CmsV10Datasource ds = datasourceWith(
        MockClient((http.Request r) async => http.Response('{"class":[]}', 200)),
      );
      final Result<List<CmsV10Category>> r = await ds.fetchCategories(kBase);
      expect(r.failureOrNull, isA<ParseFailure>());
    });
  });

  group('参数降级链（对齐 iOS 裸参语义）', () {
    test('裸参直连返回 JSON → 成功且不再重试', () async {
      int hits = 0;
      final CmsV10Datasource ds = datasourceWith(
        MockClient((http.Request r) async {
          hits += 1;
          expect(r.url.queryParameters['at'], isNull,
              reason: '首击应不带 at=json');
          return http.Response(
            jsonEncode(<String, Object?>{
              'class': <Object?>[
                <String, Object?>{'type_id': 1, 'type_name': '电影'},
              ],
            }),
            200,
            headers: <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
      );
      final Result<List<CmsV10Category>> r = await ds.fetchCategories(kBase);
      expect(r.isSuccess, isTrue);
      expect(hits, 1, reason: '裸参命中后不应重试');
    });

    test('裸参非 JSON（默认 XML 老站）→ 自动重试 at=json', () async {
      final List<Uri> requested = <Uri>[];
      final CmsV10Datasource ds = datasourceWith(
        MockClient((http.Request r) async {
          requested.add(r.url);
          if (r.url.queryParameters['at'] != 'json') {
            return http.Response('<?xml version="1.0"?><rss/>', 200);
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'class': <Object?>[
                <String, Object?>{'type_id': 1, 'type_name': '电影'},
              ],
            }),
            200,
            headers: <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
      );
      final Result<List<CmsV10Category>> r = await ds.fetchCategories(kBase);
      expect(r.isSuccess, isTrue, reason: '老 XML 站经 at=json 重试后应成功');
      expect(requested.length, 2);
      expect(requested.first.queryParameters['at'], isNull);
      expect(requested.last.queryParameters['at'], 'json');
    });

    test('两种参数均非 JSON → ParseFailure（收敛裸参错误）', () async {
      final CmsV10Datasource ds = datasourceWith(
        MockClient((http.Request r) async =>
            http.Response('<html>not json</html>', 200)),
      );
      final Result<List<CmsV10Category>> r = await ds.fetchCategories(kBase);
      expect(r.failureOrNull, isA<ParseFailure>());
    });
  });

  group('fetchVideos', () {
    test('解析列表并归一封面地址（ac=list，对齐 iOS）', () async {
      Uri? requested;
      final CmsV10Datasource ds = datasourceWith(
        MockClient((http.Request r) async {
          requested = r.url;
          return http.Response(
            jsonEncode(<String, Object?>{
              'page': 3,
              'pagecount': 9,
              'limit': 20,
              'total': 175,
              'list': <Object?>[
                <String, Object?>{
                  'vod_id': 100,
                  'vod_name': '示例',
                  'vod_pic': '/upload/1.jpg',
                  'vod_remarks': '更新至 12 集',
                  'vod_year': '2026',
                  'type_name': '剧集',
                },
              ],
            }), 200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              });
        }),
      );

      final Result<CmsV10VideoPage> r = await ds.fetchVideosPaged(
        kBase,
        typeId: '2',
        page: 3,
        filters: <String, String>{'area': '大陆', 'year': '全部'},
      );
      expect(r.isSuccess, isTrue);
      final CmsV10VideoPage p = r.valueOrNull!;
      final CmsV10Video v = p.items.single;
      expect(v.vodId, '100');
      expect(v.name, '示例');
      expect(v.pic, 'https://cms.example.com/upload/1.jpg');
      expect(v.remarks, '更新至 12 集');
      // 分页元信息（对齐 iOS _hasMore）。
      expect(p.pagecount, 9);
      expect(p.limit, 20);
      expect(p.total, 175);
      expect(p.hasMore(3), isTrue);
      expect(p.hasMore(9), isFalse);
      // 请求形态（对齐 iOS fetchSingleSourceCategoryContent：ac=list + 筛选
      // 参数拼接，跳过「全部」）。
      expect(requested?.queryParameters['ac'], 'list');
      expect(requested?.queryParameters['pg'], '3');
      expect(requested?.queryParameters['t'], '2');
      expect(requested?.queryParameters['area'], '大陆');
      expect(requested?.queryParameters.containsKey('year'), isFalse);
      expect(requested?.queryParameters.containsKey('at'), isFalse);
    });

    test('搜索走 ac=detail&wd（对齐 iOS fetchSearchVideos）', () async {
      Uri? requested;
      final CmsV10Datasource ds = datasourceWith(
        MockClient((http.Request r) async {
          requested = r.url;
          return http.Response(
            jsonEncode(<String, Object?>{
              'list': <Object?>[
                <String, Object?>{'vod_id': 5, 'vod_name': '搜索片', 'vod_pic': ''},
              ],
            }), 200,
            headers: <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
      );
      final Result<List<CmsV10Video>> r =
          await ds.fetchSearchVideos(kBase, keyword: ' 搜索片 ', page: 2);
      expect(r.isSuccess, isTrue);
      expect(r.valueOrNull!.single.name, '搜索片');
      expect(requested?.queryParameters['ac'], 'detail');
      expect(requested?.queryParameters['wd'], '搜索片');
      expect(requested?.queryParameters['pg'], '2');
    });

    test('页码非法 → ValidationFailure（不发请求）', () async {
      int calls = 0;
      final CmsV10Datasource ds = datasourceWith(
        MockClient((http.Request r) async {
          calls++;
          return http.Response('{}', 200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              });
        }),
      );
      expect(
        (await ds.fetchVideos(kBase, page: 0)).failureOrNull,
        isA<ValidationFailure>(),
      );
      expect(calls, 0);
    });

    test('空列表是合法结果（返回空数组而非错误）', () async {
      final CmsV10Datasource ds = datasourceWith(
        MockClient((http.Request r) async => http.Response('{"list":[]}', 200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              })),
      );
      final Result<List<CmsV10Video>> r = await ds.fetchVideos(kBase);
      expect(r.isSuccess, isTrue);
      expect(r.valueOrNull, isEmpty);
    });
  });

  group('fetchDetail', () {
    const String detailJson = '{"list":[{"vod_id":"7","vod_name":"详情",'
      '"vod_pic":"https://p.com/x.jpg","vod_content":"<p>简介</p>",'
      '"vod_score":"8.8","vod_actor":"演员","vod_director":"导演",'
      '"vod_play_url":"第1集\$https://v.com/1.m3u8#第2集\$//v.com/2.m3u8"}]}';

    test('解析详情与剧集', () async {
      Uri? requested;
      final CmsV10Datasource ds = datasourceWith(
        MockClient((http.Request r) async {
          requested = r.url;
          return http.Response(detailJson, 200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              });
        }),
      );
      final Result<CmsV10Detail> r = await ds.fetchDetail(kBase, '7');
      expect(r.isSuccess, isTrue);
      final CmsV10Detail d = r.valueOrNull!;
      expect(d.video.name, '详情');
      expect(d.episodes.length, 2);
      expect(d.episodes.last.url, 'https://v.com/2.m3u8');
      expect(d.isPlayable, isTrue);
      expect(d.score, '8.8');
      expect(requested?.queryParameters['ids'], '7');
    });

    test('ids 为空 → ValidationFailure', () async {
      final CmsV10Datasource ds = datasourceWith(
        MockClient((http.Request r) async => http.Response(detailJson, 200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              })),
      );
      expect(
        (await ds.fetchDetail(kBase, '  ')).failureOrNull,
        isA<ValidationFailure>(),
      );
    });

    test('详情为空 → ParseFailure', () async {
      final CmsV10Datasource ds = datasourceWith(
        MockClient((http.Request r) async => http.Response('{"list":[]}', 200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              })),
      );
      expect(
        (await ds.fetchDetail(kBase, '9')).failureOrNull,
        isA<ParseFailure>(),
      );
    });
  });

  group('错误归一', () {
    test('HTTP 404 → NetworkFailure(httpStatus)', () async {
      final CmsV10Datasource ds = datasourceWith(
        MockClient((http.Request r) async => http.Response('nope', 404)),
      );
      final Failure? f = (await ds.fetchCategories(kBase)).failureOrNull;
      expect(f, isA<NetworkFailure>());
      expect(f?.code.name, 'httpStatus');
    });

    test('非 JSON 响应 → ParseFailure', () async {
      final CmsV10Datasource ds = datasourceWith(
        MockClient((http.Request r) async => http.Response('<xml/>', 200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              })),
      );
      expect(
        (await ds.fetchCategories(kBase)).failureOrNull,
        isA<ParseFailure>(),
      );
    });

    test('非法站点地址 → ValidationFailure', () async {
      final CmsV10Datasource ds = datasourceWith(
        MockClient((http.Request r) async => http.Response('{}', 200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              })),
      );
      expect(
        (await ds.fetchCategories('ftp://a.com/x')).failureOrNull,
        isA<ValidationFailure>(),
      );
    });

    test('网络异常 → Failure（非异常抛出）', () async {
      final CmsV10Datasource ds = datasourceWith(
        MockClient((http.Request r) async {
          throw http.ClientException('boom');
        }),
      );
      final Result<List<CmsV10Category>> r = await ds.fetchCategories(kBase);
      expect(r.isSuccess, isFalse);
      expect(r.failureOrNull, isNotNull);
    });
  });
}
