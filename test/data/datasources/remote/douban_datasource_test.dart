/// 数据层单测：豆瓣数据源（批次 D · D-03）。
///
/// 注入 http MockClient 到 [HttpClient]，验证 rexxar 合集与 chart 榜单的
/// 请求 URL、JSON 解析与容错（非 2xx / 非 JSON）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/core/errors/exceptions.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/data/datasources/remote/douban_datasource.dart';
import 'package:vbox/domain/entities/douban/douban_models.dart';

void main() {
  group('DoubanDatasource.fetchCollection', () {
    test('解析 subject_collection_items', () async {
      final MockClient mock = MockClient((http.Request request) async {
        expect(
          request.url.toString(),
          startsWith(
            '${DoubanDatasource.baseURL}/subject_collection/movie_hot_gaia/items',
          ),
        );
        return http.Response(
          jsonEncode(<String, Object?>{
            'subject_collection_items': <Map<String, Object?>>[
              <String, Object?>{
                'id': '1001',
                'title': '片A',
                'rating': <String, Object?>{'value': 8.5, 'count': 100},
                'year': '2024',
                'genres': <String>['剧情', '犯罪'],
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });

      final DoubanDatasource ds =
          DoubanDatasource(client: HttpClient(inner: mock));
      final List<DoubanSubject> list =
          await ds.fetchCollection('movie_hot_gaia');

      expect(list, hasLength(1));
      expect(list.single.id, '1001');
      expect(list.single.title, '片A');
      expect(list.single.rating, 8.5);
      expect(list.single.ratingCount, 100);
      expect(list.single.genres, <String>['剧情', '犯罪']);
      expect(list.single.hasRating, isTrue);
    });

    test('非 2xx → NetworkException', () async {
      final MockClient mock = MockClient(
        (http.Request request) async => http.Response('forbidden', 403),
      );
      final DoubanDatasource ds =
          DoubanDatasource(client: HttpClient(inner: mock));

      expect(
        () => ds.fetchCollection('movie_hot_gaia'),
        throwsA(isA<NetworkException>()),
      );
    });
  });

  group('DoubanDatasource.fetchChartRanking', () {
    test('解析 chart top_list 数组（缺失 rank 用序号补位）', () async {
      final MockClient mock = MockClient((http.Request request) async {
        expect(request.url.host, 'movie.douban.com');
        expect(request.url.path, '/j/chart/top_list');
        return http.Response(
          jsonEncode(<Map<String, Object?>>[
            <String, Object?>{
              'id': '1',
              'title': '榜A',
              'cover_url': '//img.douban.com/a.jpg',
              'score': '9.2',
              'vote_count': 500,
              'release_date': '2023-01-01',
              'types': <String>['剧情', '犯罪'],
            },
            <String, Object?>{
              'id': '2',
              'title': '榜B',
              'rank': 3,
              'score': '8.0',
              'release_date': '2022-05-01',
            },
          ]),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });

      final DoubanDatasource ds =
          DoubanDatasource(client: HttpClient(inner: mock));
      final List<DoubanChartSubject> list = await ds.fetchChartRanking(
        DoubanChartCategory.all.first,
        start: 0,
      );

      expect(list, hasLength(2));
      expect(list[0].rank, 1); // 缺省 rank → 序号补位
      expect(list[0].rating, 9.2);
      expect(list[0].year, '2023');
      expect(list[0].info, '剧情 / 犯罪');
      expect(list[0].coverUrl, 'https://img.douban.com/a.jpg');
      expect(list[1].rank, 3); // 显式 rank
    });
  });

  group('DoubanDatasource.fetchCollectionWithTVCovers', () {
    test('无列表封面 → 逐条补拉详情并回填', () async {
      final List<String> requested = <String>[];
      final MockClient mock = MockClient((http.Request request) async {
        requested.add(request.url.path);
        if (request.url.path.endsWith('/items')) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'subject_collection_items': <Map<String, Object?>>[
                <String, Object?>{
                  'id': '37817080',
                  'title': '综艺A',
                  'pic': <String, Object?>{
                    'large': '//img.doubanio.com/m.jpg',
                    'normal': '//img.doubanio.com/s.jpg',
                  },
                },
              ],
            }),
            200,
            headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.path == '/rexxar/api/v2/tv/37817080') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'cover_url': 'https://img.doubanio.com/detail.jpg',
              'pic': <String, Object?>{'large': 'https://img.doubanio.com/pic.jpg'},
            }),
            200,
            headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('', 404);
      });

      final DoubanDatasource ds =
          DoubanDatasource(client: HttpClient(inner: mock));
      final List<DoubanSubject> list =
          await ds.fetchCollectionWithTVCovers('tv_animation', count: 1);

      // 详情 cover_url 优先，回填后 hasListCover 置真。
      expect(list.single.coverUrl, 'https://img.doubanio.com/detail.jpg');
      expect(list.single.hasListCover, isTrue);
      expect(requested, contains('/rexxar/api/v2/tv/37817080'));
    });

    test('详情仅 pic → 取 pic.large', () async {
      final MockClient mock = MockClient((http.Request request) async {
        if (request.url.path.endsWith('/items')) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'subject_collection_items': <Map<String, Object?>>[
                <String, Object?>{'id': '7', 'title': '动漫A'},
              ],
            }),
            200,
            headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            'pic': <String, Object?>{'large': 'https://img.doubanio.com/pic7.jpg'},
          }),
          200,
          headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
        );
      });

      final DoubanDatasource ds =
          DoubanDatasource(client: HttpClient(inner: mock));
      final List<DoubanSubject> list =
          await ds.fetchCollectionWithTVCovers('tv_animation', count: 1);

      expect(list.single.coverUrl, 'https://img.doubanio.com/pic7.jpg');
    });

    test('已有列表封面 → 不补拉详情', () async {
      final List<String> requested = <String>[];
      final MockClient mock = MockClient((http.Request request) async {
        requested.add(request.url.path);
        return http.Response(
          jsonEncode(<String, Object?>{
            'subject_collection_items': <Map<String, Object?>>[
              <String, Object?>{
                'id': '1001',
                'title': '片A',
                'cover_url': '//img.doubanio.com/a.jpg',
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
        );
      });

      final DoubanDatasource ds =
          DoubanDatasource(client: HttpClient(inner: mock));
      final List<DoubanSubject> list =
          await ds.fetchCollectionWithTVCovers('tv_american', count: 1);

      expect(list.single.coverUrl, 'https://img.doubanio.com/a.jpg');
      expect(requested.where((String p) => p.contains('/tv/')), isEmpty);
    });

    test('详情补拉失败 → 保留列表 pic 封面，不抛错', () async {
      final MockClient mock = MockClient((http.Request request) async {
        if (request.url.path.endsWith('/items')) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'subject_collection_items': <Map<String, Object?>>[
                <String, Object?>{
                  'id': '2',
                  'title': '综艺B',
                  'pic': <String, Object?>{'large': '//img.doubanio.com/b.jpg'},
                },
              ],
            }),
            200,
            headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('', 404);
      });

      final DoubanDatasource ds =
          DoubanDatasource(client: HttpClient(inner: mock));
      final List<DoubanSubject> list =
          await ds.fetchCollectionWithTVCovers('tv_variety_show', count: 1);

      expect(list.single.coverUrl, 'https://img.doubanio.com/b.jpg');
    });
  });

  group('DoubanSubject 封面口径（对齐 iOS coverImageURL）', () {
    test('含 cover_url → hasListCover true，无需补拉', () {
      final DoubanSubject s = DoubanSubject.fromJson(<String, Object?>{
        'id': '1',
        'title': 'A',
        'cover_url': '//img.doubanio.com/a.jpg',
      });
      expect(s.hasListCover, isTrue);
      expect(s.needsTvCoverFetch, isFalse);
      expect(s.coverUrl, 'https://img.doubanio.com/a.jpg');
    });

    test('仅有 pic → hasListCover false，需要补拉', () {
      final DoubanSubject s = DoubanSubject.fromJson(<String, Object?>{
        'id': '2',
        'title': 'B',
        'pic': <String, Object?>{'large': '//img.doubanio.com/b.jpg'},
      });
      expect(s.hasListCover, isFalse);
      expect(s.needsTvCoverFetch, isTrue);
      // 列表 pic 仍可先展示（补拉回填后会被详情值覆盖）。
      expect(s.coverUrl, 'https://img.doubanio.com/b.jpg');
    });

    test('withCoverUrl 回填并归一化', () {
      const DoubanSubject s =
          DoubanSubject(id: '3', title: 'C', hasListCover: false);
      final DoubanSubject filled = s.withCoverUrl('//img.doubanio.com/c.jpg');
      expect(filled.coverUrl, 'https://img.doubanio.com/c.jpg');
      expect(filled.hasListCover, isTrue);
      expect(filled.needsTvCoverFetch, isFalse);
    });
  });
}