/// 数据层单测：TMDB 远程数据源（批次 G · G-06）。
///
/// 对齐真相源：iOS `vbox/Services/TMDBService.swift`
///   · `proxiedURL`（L42-L54）：整体 URL 作为代理 `url` query 编码，
///     保留 `:/?+$,;-.~_#[]!%`，编码 `&` `=` 隔离内部参数；
///   · `searchMovie` / `fetchImages` / `fetchCredits`：端点与参数；
///   · 非 2xx / 解码失败 / 异常 → `null`。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/data/datasources/local/tmdb_config_store.dart';
import 'package:vbox/data/datasources/remote/tmdb_datasource.dart';
import 'package:vbox/domain/entities/tmdb/tmdb_models.dart';

/// 已配置代理的存储（内存态，不触真实 Prefs）。
TmdbConfigStore _readyConfig() => TmdbConfigStore()
  ..setProxyUrl('https://proxy.example.com/')
  ..setUseToken(true)
  ..setProxyToken('tok123');

void main() {
  group('代理 URL（对齐 iOS proxiedURL）', () {
    test('无 token：base?url=编码原地址', () {
      final String url = TmdbDatasource.proxiedUrl(
        'https://api.themoviedb.org/3/search/multi?api_key=K&query=x',
        proxyBaseUrl: 'https://proxy.example.com/',
        useToken: false,
        token: '',
      );
      // `&` `=` 被编码，内部参数不干扰代理自身参数。
      expect(url, startsWith('https://proxy.example.com/?url='));
      expect(url, contains('https://api.themoviedb.org/3/search/multi?api_key%3DK%26query%3Dx'));
      expect(url, isNot(contains('&query=')));
    });

    test('useToken 且 token 非空 → 附 token', () {
      final String url = TmdbDatasource.proxiedUrl(
        'https://x/y?a=b',
        proxyBaseUrl: 'https://proxy.example.com/',
        useToken: true,
        token: 'T1',
      );
      expect(url, 'https://proxy.example.com/?token=T1&url=https://x/y?a%3Db');
    });

    test('useToken 但 token 空 → 不附 token', () {
      final String url = TmdbDatasource.proxiedUrl(
        'https://x/y',
        proxyBaseUrl: 'https://proxy.example.com/',
        useToken: true,
        token: '',
      );
      expect(url, 'https://proxy.example.com/?url=https://x/y');
    });

    test('encodeForProxyQuery 保留结构与已编码 %XX', () {
      expect(
        TmdbDatasource.encodeForProxyQuery('https://a/b%20c?d=e&f=g'),
        'https://a/b%20c?d%3De%26f%3Dg',
      );
      // 中文按 UTF-8 逐字节编码。
      expect(TmdbDatasource.encodeForProxyQuery('中'), '%E4%B8%AD');
    });

    test('originalImageUrl 拼接（对齐 iOS originalImageURL）', () {
      expect(
        TmdbDatasource.originalImageUrl('/p.jpg'),
        '$kTmdbImageBaseUrl/w500/p.jpg',
      );
      expect(
        TmdbDatasource.originalImageUrl('/p.jpg', size: 'original'),
        '$kTmdbImageBaseUrl/original/p.jpg',
      );
    });
  });

  group('searchMovie（对齐 iOS searchMovie）', () {
    test('过滤非 movie/tv，取首个匹配 + 参数齐备', () async {
      late http.Request captured;
      final MockClient mock = MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'results': <Map<String, Object?>>[
              <String, Object?>{'id': 1, 'media_type': 'person', 'name': '路人'},
              <String, Object?>{
                'id': 550,
                'media_type': 'movie',
                'title': '搏击俱乐部',
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final TmdbDatasource ds =
          TmdbDatasource(client: HttpClient(inner: mock), config: _readyConfig());

      final TmdbSearchResult? hit = await ds.searchMovie('搏击俱乐部', year: '1999');

      expect(hit!.id, 550);
      expect(hit.mediaType, 'movie');
      // 代理地址 + 参数（query 编码在代理 url 参数内，解码后可见）。
      expect(captured.url.host, 'proxy.example.com');
      final String inner = captured.url.queryParameters['url']!;
      expect(inner, contains('/search/multi'));
      expect(inner, contains('api_key=${TmdbDatasource.apiKey}'));
      expect(inner, contains('language=zh-CN'));
      expect(inner, contains('year=1999'));
      expect(captured.url.queryParameters['token'], 'tok123');
    });

    test('无匹配 → null', () async {
      final MockClient mock = MockClient(
        (http.Request request) async => http.Response(
          jsonEncode(<String, Object?>{
            'results': <Map<String, Object?>>[
              <String, Object?>{'id': 1, 'media_type': 'person'},
            ],
          }),
          200,
        ),
      );
      final TmdbDatasource ds =
          TmdbDatasource(client: HttpClient(inner: mock), config: _readyConfig());
      expect(await ds.searchMovie('x'), isNull);
    });

    test('非 2xx → null', () async {
      final MockClient mock = MockClient(
        (http.Request request) async => http.Response('nope', 500),
      );
      final TmdbDatasource ds = TmdbDatasource(
        client: HttpClient(inner: mock, maxRetries: 0),
        config: _readyConfig(),
      );
      expect(await ds.searchMovie('x'), isNull);
    });

    test('非 JSON 响应 → null', () async {
      final MockClient mock = MockClient(
        (http.Request request) async => http.Response('<html>', 200),
      );
      final TmdbDatasource ds =
          TmdbDatasource(client: HttpClient(inner: mock), config: _readyConfig());
      expect(await ds.searchMovie('x'), isNull);
    });
  });

  group('fetchImages / fetchCredits（对齐 iOS）', () {
    test('fetchImages：tv 端点 + 三图集解析', () async {
      late Uri uri;
      final MockClient mock = MockClient((http.Request request) async {
        uri = request.url;
        return http.Response(
          jsonEncode(<String, Object?>{
            'id': 1399,
            'logos': <Map<String, Object?>>[
              <String, Object?>{'file_path': '/l.png', 'iso_639_1': 'zh'},
            ],
            'posters': <Map<String, Object?>>[
              <String, Object?>{'file_path': '/p.jpg', 'aspect_ratio': 0.6},
            ],
            'backdrops': <Map<String, Object?>>[
              <String, Object?>{'file_path': '/b.jpg', 'vote_average': 4},
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final TmdbDatasource ds =
          TmdbDatasource(client: HttpClient(inner: mock), config: _readyConfig());

      final TmdbImages? images = await ds.fetchImages(1399, mediaType: 'tv');
      expect(images!.id, 1399);
      expect(images.bestLogo!.filePath, '/l.png');
      expect(images.bestPoster!.filePath, '/p.jpg');
      expect(images.bestBackdrop!.filePath, '/b.jpg');
      final String inner = uri.queryParameters['url']!;
      expect(inner, contains('/tv/1399/images'));
      expect(inner, contains('include_image_language=zh,en,null'));
    });

    test('fetchCredits：movie 端点 + 演职映射', () async {
      late Uri uri;
      final MockClient mock = MockClient((http.Request request) async {
        uri = request.url;
        return http.Response(
          jsonEncode(<String, Object?>{
            'id': 550,
            'cast': <Map<String, Object?>>[
              <String, Object?>{'id': 1, 'name': '演员', 'character': '角色'},
            ],
            'crew': <Map<String, Object?>>[
              <String, Object?>{'id': 2, 'name': '导演', 'job': 'Director'},
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final TmdbDatasource ds =
          TmdbDatasource(client: HttpClient(inner: mock), config: _readyConfig());

      final TmdbCredits? credits = await ds.fetchCredits(550);
      expect(credits!.actors.single.name, '演员');
      expect(credits.directors.single.name, '导演');
      final String inner = uri.queryParameters['url']!;
      expect(inner, contains('/movie/550/credits'));
      expect(inner, contains('language=zh-CN'));
    });

    test('非 2xx → null（容错）', () async {
      final MockClient mock = MockClient(
        (http.Request request) async => http.Response('nf', 404),
      );
      final TmdbDatasource ds =
          TmdbDatasource(client: HttpClient(inner: mock), config: _readyConfig());
      expect(await ds.fetchImages(1), isNull);
      expect(await ds.fetchCredits(1), isNull);
    });
  });
}