/// 核心层网络测试：HttpClient 头合并（等效键覆盖回归）。
///
/// 背景：HTTP 头名大小写不敏感，但 Dart Map 大小写敏感——修复前调用方传
/// `Accept: application/json` 会与默认注入的 `accept: */*` **同时发出**，
/// 豆瓣 WAF 等服务端对畸形重复头直接 400。本组用例锁定 `_dispatch` 的
/// 等效键检测行为（对齐 iOS：单请求单 Accept 头）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/core/constants/app_constants.dart';
import 'package:vbox/core/network/http_client.dart';

void main() {
  test('缺省头：调用方未提供时注入默认 UA 与 accept: */*', () async {
    http.Request? captured;
    final HttpClient client = HttpClient(
      inner: MockClient((http.Request request) async {
        captured = request;
        return http.Response('{}', 200);
      }),
    );

    await client.get(Uri.parse('https://example.com/x'));

    expect(captured, isNotNull);
    expect(captured!.headers['user-agent'], NetConstants.defaultUserAgent);
    expect(captured!.headers['accept'], '*/*');
  });

  test('等效键覆盖：调用方大写 Accept / User-Agent 不再注入默认值（无双头）',
      () async {
    http.Request? captured;
    final HttpClient client = HttpClient(
      inner: MockClient((http.Request request) async {
        captured = request;
        return http.Response('{}', 200);
      }),
    );

    await client.get(
      Uri.parse('https://movie.douban.com/j/chart/top_list'),
      headers: <String, String>{
        'Accept': 'application/json',
        'User-Agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
      },
    );

    expect(captured, isNotNull);
    // 忽略大小写仅一个 Accept 头，且值保持调用方原样（键不重写）。
    expect(
      captured!.headers.keys
          .where((String k) => k.toLowerCase() == 'accept')
          .length,
      1,
    );
    expect(captured!.headers['Accept'], 'application/json');
    expect(
      captured!.headers.keys
          .where((String k) => k.toLowerCase() == 'user-agent')
          .length,
      1,
    );
    expect(
      captured!.headers['User-Agent'],
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
    );
  });

  test('小写键同样生效：调用方小写 accept 覆盖默认（不产生双头）', () async {
    http.Request? captured;
    final HttpClient client = HttpClient(
      inner: MockClient((http.Request request) async {
        captured = request;
        return http.Response('{}', 200);
      }),
    );

    await client.get(
      Uri.parse('https://example.com/y'),
      headers: const <String, String>{'accept': 'text/html'},
    );

    expect(captured!.headers['accept'], 'text/html');
  });

  test('3xx 响应 isRedirect 为真（重定向判定回归）', () async {
    final HttpClient client = HttpClient(
      inner: MockClient((http.Request request) async {
        return http.Response('', 308);
      }),
    );

    final HttpClientResponse res =
        await client.get(Uri.parse('https://example.com/r'));

    expect(res.isRedirect, isTrue);
    expect(res.isOk, isFalse);
  });
}
