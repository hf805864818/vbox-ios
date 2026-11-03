/// 数据层单测：福利平台配置数据源（批次 H · H-01）。
///
/// 链路：manifest（必需 `allSources`）→ `files.welfarePlatforms` →
/// 拉 `welfare_platforms.json` → 契约校验（`welfare_v1.json`）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/core/errors/failures.dart';
import 'package:vbox/core/network/http_client.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/data/datasources/remote/welfare_platform_datasource.dart';
import 'package:vbox/domain/entities/welfare/welfare.dart';

const String kManifestUrl = 'https://cdn.example.com/manifest.json';
const String kWelfareUrl = 'https://cdn.example.com/welfare_platforms.json';

/// 合法清单（含 `welfarePlatforms` 条目）。
Map<String, Object?> manifestJson({String? welfareUrl}) => <String, Object?>{
      'schemaVersion': 1,
      'configVersion': '2026.10.03.1',
      'ttlSeconds': 3600,
      'forceRefresh': false,
      'disabledKeys': <String>[],
      'files': <String, Object?>{
        'allSources': 'https://cdn.example.com/all_sources.json',
        if (welfareUrl != null) 'welfarePlatforms': welfareUrl,
      },
    };

/// 合法福利平台配置。
Map<String, Object?> welfareJson() => <String, Object?>{
      'schemaVersion': 1,
      '_meta': <String, Object?>{'version': '2026.10.03.1'},
      'categories': <Object?>[
        <String, Object?>{'key': 'video', 'name': '视频'},
        <String, Object?>{'key': 'live', 'name': '直播'},
        <String, Object?>{'key': 'comic', 'name': '漫画'},
      ],
      'platforms': <Object?>[
        <String, Object?>{
          'platformKey': 'p1',
          'name': '平台一',
          'category': 'video',
          'sortOrder': 1,
        },
        <String, Object?>{
          'platformKey': 'p2',
          'name': '直播一',
          'category': 'live',
        },
      ],
    };

http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
    });

WelfarePlatformDatasource datasourceWith(MockClient mock) =>
    WelfarePlatformDatasource(
      client: HttpClient(inner: mock, retryBaseDelay: Duration.zero),
    );

void main() {
  group('WelfarePlatformDatasource.fetch', () {
    test('合法链路 → Success 且平台解析正确（请求 manifest + 配置各一次）', () async {
      int calls = 0;
      final WelfarePlatformDatasource ds = datasourceWith(
        MockClient((http.Request r) async {
          calls++;
          if (r.url.path.endsWith('manifest.json')) {
            return jsonResponse(manifestJson(welfareUrl: kWelfareUrl));
          }
          return jsonResponse(welfareJson());
        }),
      );

      final Result<WelfarePlatformConfig> r = await ds.fetch(kManifestUrl);
      expect(r.isSuccess, isTrue);
      final WelfarePlatformConfig c = r.valueOrNull!;
      expect(c.platforms.length, 2);
      expect(c.platformsIn(WelfarePlatformCategory.video).single.name, '平台一');
      expect(calls, 2);
    });

    test('清单缺 welfarePlatforms → ValidationFailure', () async {
      final WelfarePlatformDatasource ds = datasourceWith(
        MockClient((http.Request r) async =>
            jsonResponse(manifestJson(welfareUrl: null))),
      );
      final Failure? f = (await ds.fetch(kManifestUrl)).failureOrNull;
      expect(f, isA<ValidationFailure>());
      expect(f!.message.contains('welfarePlatforms'), isTrue);
    });

    test('清单拉取失败 → Failure（网络异常）', () async {
      final WelfarePlatformDatasource ds = datasourceWith(
        MockClient((http.Request r) async {
          throw http.ClientException('offline');
        }),
      );
      expect((await ds.fetch(kManifestUrl)).isSuccess, isFalse);
    });

    test('配置非 JSON 对象 → ParseFailure', () async {
      final WelfarePlatformDatasource ds = datasourceWith(
        MockClient((http.Request r) async {
          if (r.url.path.endsWith('manifest.json')) {
            return jsonResponse(manifestJson(welfareUrl: kWelfareUrl));
          }
          return http.Response('<html>404</html>', 200, headers: <String, String>{
            'content-type': 'application/json; charset=utf-8',
          });
        }),
      );
      expect((await ds.fetch(kManifestUrl)).failureOrNull, isA<ParseFailure>());
    });

    test('配置结构非法（缺 platforms）→ ParseFailure', () async {
      final WelfarePlatformDatasource ds = datasourceWith(
        MockClient((http.Request r) async {
          if (r.url.path.endsWith('manifest.json')) {
            return jsonResponse(manifestJson(welfareUrl: kWelfareUrl));
          }
          return jsonResponse(<String, Object?>{'schemaVersion': 1});
        }),
      );
      expect((await ds.fetch(kManifestUrl)).failureOrNull, isA<ParseFailure>());
    });

    test('配置 HTTP 500（重试后）→ NetworkFailure(httpStatus)', () async {
      final WelfarePlatformDatasource ds = datasourceWith(
        MockClient((http.Request r) async {
          if (r.url.path.endsWith('manifest.json')) {
            return jsonResponse(manifestJson(welfareUrl: kWelfareUrl));
          }
          return http.Response('server error', 500);
        }),
      );
      final Failure? f = (await ds.fetch(kManifestUrl)).failureOrNull;
      expect(f, isA<NetworkFailure>());
      expect(f?.code.name, 'httpStatus');
    });

    test('配置地址非法 → ValidationFailure', () async {
      final WelfarePlatformDatasource ds = datasourceWith(
        MockClient((http.Request r) async =>
            jsonResponse(manifestJson(welfareUrl: 'not a url'))),
      );
      expect(
        (await ds.fetch(kManifestUrl)).failureOrNull,
        isA<ValidationFailure>(),
      );
    });

    test('GitHub manifest 地址 → 走代理降级链', () async {
      final List<String> hosts = <String>[];
      final WelfarePlatformDatasource ds = datasourceWith(
        MockClient((http.Request r) async {
          hosts.add(r.url.host);
          if (r.url.path.endsWith('manifest.json')) {
            return jsonResponse(manifestJson(welfareUrl: kWelfareUrl));
          }
          return jsonResponse(welfareJson());
        }),
      );

      final Result<WelfarePlatformConfig> r = await ds.fetch(
        'https://raw.githubusercontent.com/user/repo/main/manifest.json',
      );
      expect(r.isSuccess, isTrue);
      // 主代理先命中（ghfast），后续直连不再触发。
      expect(hosts.first, 'ghfast.top');
    });
  });
}