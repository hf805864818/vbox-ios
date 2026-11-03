/// 数据层单测：远程源清单数据源。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/core/errors/failures.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/data/datasources/remote/remote.dart';
import 'package:vbox/domain/entities/remote_source/remote_source.dart';

const String kManifestUrl = 'https://cdn.example.com/manifest.json';

Map<String, Object?> validManifest() => <String, Object?>{
      'schemaVersion': 1,
      'configVersion': '2026.09.29.1',
      'minAppVersion': '1.0.0',
      'updatedAt': '2026-09-29T10:00:00Z',
      'ttlSeconds': 21600,
      'forceRefresh': false,
      'disabledKeys': <String>['parsers'],
      'files': <String, Object?>{
        'allSources': 'https://cdn.example.com/all_sources.json',
        'parsers': 'https://cdn.example.com/parsers.json',
      },
    };

RemoteManifestDatasource datasourceWith(MockClient mock) =>
    RemoteManifestDatasource(
      client: HttpClient(inner: mock, retryBaseDelay: Duration.zero),
    );

void main() {
  group('RemoteManifestDatasource.fetch', () {
    test('合法清单 → Success 且字段解析正确', () async {
      Uri? requested;
      final RemoteManifestDatasource ds = datasourceWith(
        MockClient((http.Request r) async {
          requested = r.url;
          return http.Response(jsonEncode(validManifest()), 200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              });
        }),
      );

      final Result<RemoteManifest> r = await ds.fetch(kManifestUrl);
      expect(r.isSuccess, isTrue);
      final RemoteManifest m = r.valueOrNull!;
      expect(m.configVersion, '2026.09.29.1');
      expect(m.ttlSeconds, 21600);
      expect(m.hasRequiredFiles, isTrue);
      expect(m.hasValidConfigVersion, isTrue);
      expect(m.disabledKeys, <String>['parsers']);
      expect(m.files['parsers'], 'https://cdn.example.com/parsers.json');
      expect(requested, Uri.parse(kManifestUrl));
    });

    test('缺少 allSources → ParseFailure', () async {
      final Map<String, Object?> body = validManifest();
      body['files'] = <String, Object?>{
        'parsers': 'https://cdn.example.com/parsers.json',
      };
      final RemoteManifestDatasource ds = datasourceWith(
        MockClient((http.Request r) async => http.Response(jsonEncode(body), 200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              })),
      );
      final Result<RemoteManifest> r = await ds.fetch(kManifestUrl);
      expect(r.failureOrNull, isA<ParseFailure>());
      expect((r.failureOrNull?.message ?? '').contains('allSources'), isTrue);
    });

    test('configVersion 格式非法 → ParseFailure', () async {
      final Map<String, Object?> body = validManifest();
      body['configVersion'] = 'v1.0';
      final RemoteManifestDatasource ds = datasourceWith(
        MockClient((http.Request r) async => http.Response(jsonEncode(body), 200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              })),
      );
      expect(
        (await ds.fetch(kManifestUrl)).failureOrNull,
        isA<ParseFailure>(),
      );
    });

    test('非 JSON 响应 → ParseFailure', () async {
      final RemoteManifestDatasource ds = datasourceWith(
        MockClient((http.Request r) async => http.Response('<html>404</html>', 200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              })),
      );
      expect(
        (await ds.fetch(kManifestUrl)).failureOrNull,
        isA<ParseFailure>(),
      );
    });

    test('JSON 数组（非对象）→ ParseFailure', () async {
      final RemoteManifestDatasource ds = datasourceWith(
        MockClient((http.Request r) async => http.Response('[1,2]', 200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              })),
      );
      expect(
        (await ds.fetch(kManifestUrl)).failureOrNull,
        isA<ParseFailure>(),
      );
    });

    test('HTTP 500（重试后）→ NetworkFailure(httpStatus)', () async {
      int calls = 0;
      final RemoteManifestDatasource ds = datasourceWith(
        MockClient((http.Request r) async {
          calls++;
          return http.Response('server error', 500);
        }),
      );
      final Failure? f = (await ds.fetch(kManifestUrl)).failureOrNull;
      expect(f, isA<NetworkFailure>());
      expect(f?.code.name, 'httpStatus');
      // 默认 maxRetries=2 → 共 3 次尝试
      expect(calls, 3);
    });

    test('网络异常 → Failure（不抛异常）', () async {
      final RemoteManifestDatasource ds = datasourceWith(
        MockClient((http.Request r) async {
          throw http.ClientException('offline');
        }),
      );
      final Result<RemoteManifest> r = await ds.fetch(kManifestUrl);
      expect(r.isSuccess, isFalse);
      expect(r.failureOrNull, isNotNull);
    });

    test('非法地址 → ValidationFailure（不发请求）', () async {
      int calls = 0;
      final RemoteManifestDatasource ds = datasourceWith(
        MockClient((http.Request r) async {
          calls++;
          return http.Response('{}', 200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              });
        }),
      );
      for (final String bad in <String>['', 'not a url', 'ftp://a.com/m.json', 'https://']) {
        expect(
          (await ds.fetch(bad)).failureOrNull,
          isA<ValidationFailure>(),
          reason: bad,
        );
      }
      expect(calls, 0);
    });

    test('forceRefresh → 带 cache-control: no-cache', () async {
      String? cacheControl;
      final RemoteManifestDatasource ds = datasourceWith(
        MockClient((http.Request r) async {
          cacheControl = r.headers['cache-control'];
          return http.Response(jsonEncode(validManifest()), 200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              });
        }),
      );
      await ds.fetch(kManifestUrl, forceRefresh: true);
      expect(cacheControl, 'no-cache');

      cacheControl = 'sentinel';
      await ds.fetch(kManifestUrl);
      expect(cacheControl, isNull);
    });
  });
}
