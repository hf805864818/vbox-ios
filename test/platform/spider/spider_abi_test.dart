/// 平台层单测：Spider ABI 编解码（对齐契约 §7 + fixtures/spider_io_v1.json）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/spider_engine.dart';
import 'package:vbox/domain/entities/spider/spider_models.dart';
import 'package:vbox/platform/spider/spider_abi.dart';

void main() {
  const SpiderAbiCodec codec = SpiderAbiCodec();

  Map<String, Object?> fixture(String key) {
    final Map<String, Object?> f =
        jsonDecode(File('conformance/fixtures/spider_io_v1.json').readAsStringSync())
            .cast<String, Object?>();
    return (f[key] as Map).cast<String, Object?>();
  }

  test('encodeRequest 组装 op / params / ctx（契约 §7.1）', () {
    final Map<String, Object?> req = codec.encodeRequest(
      'searchContent',
      const <String, Object?>{'keyword': '庆余年', 'pg': 1},
      siteKey: 'js_剧迷',
      engineType: 'JavaScriptCore',
      baseUrl: 'https://example.com/js/jumi.js',
      requestId: 'req-0001',
    );

    expect(req['op'], 'searchContent');
    expect((req['params'] as Map)['keyword'], '庆余年');
    final Map<String, Object?> ctx = (req['ctx'] as Map).cast<String, Object?>();
    expect(ctx['siteKey'], 'js_剧迷');
    expect(ctx['engineType'], 'JavaScriptCore');
    expect(ctx['timeoutMs'], 15000);
    expect(ctx['requestId'], 'req-0001');
  });

  test('decodeResponse：成功响应解析 data + logs + elapsedMs', () {
    final Map<String, Object?> f = fixture('searchContent');
    final Map<String, Object?> ok =
        (f['expectedResponse'] as Map).cast<String, Object?>();
    final AbiResponse r = codec.decodeResponse(jsonEncode(ok));

    expect(r.ok, isTrue);
    expect(r.logs, isEmpty);
    final SearchContentResult result =
        SearchContentResult.fromJson(r.data ?? const {});
    expect(result.page, 1);
    expect(result.pagecount, 5);
    expect(result.list, hasLength(1));
    expect(result.list!.first.vodName, '测试影片');
  });

  test('decodeResponse：homeContent fixture 解析 classes + list', () {
    final Map<String, Object?> f = fixture('homeContent');
    final AbiResponse r =
        codec.decodeResponse(jsonEncode(f['expectedResponse']));
    final HomeContentResult result =
        HomeContentResult.fromJson(r.data ?? const {});

    expect(result.classes, hasLength(3));
    expect(result.classes!.first.typeName, '电影');
    expect(result.list, hasLength(1));
    expect(result.list!.first.vodId, '1001');
    expect(result.list!.first.vodRemarks, '更新至12集');
  });

  test('decodeResponse：playerContent fixture 回填 urls', () {
    final Map<String, Object?> f = fixture('playerContent');
    final AbiResponse r =
        codec.decodeResponse(jsonEncode(f['expectedResponse']));
    final PlayerContentResult result =
        PlayerContentResult.fromJson(r.data ?? const {});

    expect(result.parse, 0);
    expect(result.urls, hasLength(1));
    expect(result.urls!.first, 'https://cdn.example.com/ep1.m3u8');
    expect(result.header?['User-Agent'], isNotEmpty);
  });

  test('decodeResponse：错误响应映射错误码（契约 §5.1）', () {
    final Map<String, Object?> err = <String, Object?>{
      'ok': false,
      'error': <String, Object?>{
        'code': 'E_REGISTER',
        'message': 'QuickJS 蜘蛛注册失败: 未找到 __JS_SPIDER__',
      },
      'logs': <String>['[SPIDER] register failed'],
      'elapsedMs': 45,
    };

    expect(
      () => codec.decodeResponse(jsonEncode(err)),
      throwsA(
        isA<SpiderException>().having(
          (SpiderException e) => e.code,
          'code',
          SpiderErrorCode.register,
        ),
      ),
    );
  });

  test('decodeResponse：非 JSON 响应 → E_PROTOCOL', () {
    expect(
      () => codec.decodeResponse('not-json'),
      throwsA(
        isA<SpiderException>().having(
          (SpiderException e) => e.code,
          'code',
          SpiderErrorCode.protocol,
        ),
      ),
    );
  });

  test('mapErrorCode：E_* 全映射', () {
    expect(SpiderAbiCodec.mapErrorCode('E_REGISTER'), SpiderErrorCode.register);
    expect(
      SpiderAbiCodec.mapErrorCode('E_SCRIPT_LOAD'),
      SpiderErrorCode.scriptLoad,
    );
    expect(SpiderAbiCodec.mapErrorCode('E_PROTOCOL'), SpiderErrorCode.protocol);
    expect(SpiderAbiCodec.mapErrorCode('E_TIMEOUT'), SpiderErrorCode.timeout);
    expect(SpiderAbiCodec.mapErrorCode('E_RUNTIME'), SpiderErrorCode.runtime);
    expect(
      SpiderAbiCodec.mapErrorCode('E_UNSUPPORTED'),
      SpiderErrorCode.unsupported,
    );
    // 契约无取消码，归为协议异常
    expect(SpiderAbiCodec.mapErrorCode('E_CANCELLED'), SpiderErrorCode.protocol);
    expect(SpiderAbiCodec.mapErrorCode(null), SpiderErrorCode.protocol);
    expect(SpiderAbiCodec.mapErrorCode('X_ZZZ'), SpiderErrorCode.protocol);
  });
}
