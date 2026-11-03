import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/remote/baidu_ibox_client.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';
import 'package:vbox/platform/webview/webview_bridge.dart';

/// 假传输（离线；记录请求便于断言 Cookie 语义）。
class _FakeTransport implements SpiderHttpTransport {
  _FakeTransport(this.handler);

  final SpiderTransportResponse Function(SpiderTransportRequest request) handler;
  final List<SpiderTransportRequest> requests = <SpiderTransportRequest>[];

  @override
  Future<SpiderTransportResponse> send(SpiderTransportRequest request) async {
    requests.add(request);
    return handler(request);
  }
}

/// 假 WebView 桥（C3 回退用）：可配置 loadPage 返回的 html 与 XHR 响应。
class _FakeWebViewBridge implements WebViewBridge {
  _FakeWebViewBridge({
    this.html = '',
    this.xhr = const <String, String>{},
  });

  final String html;
  final Map<String, String> xhr;

  final List<String> loaded = <String>[];
  final List<String> requested = <String>[];

  @override
  bool get isAvailable => true;

  @override
  Future<WebViewPageResult> loadPage({
    required String url,
    String? userAgent,
    Map<String, String> cookies = const <String, String>{},
    Duration timeout = const Duration(seconds: 30),
    String? evaluateJs,
  }) async {
    loaded.add(url);
    return (html: html, url: url, cookie: '', jsResult: '');
  }

  @override
  Future<WebViewXhrResult> request({
    required String url,
    String method = 'GET',
    Map<String, String> headers = const <String, String>{},
    String? body,
    String? hostUrl,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    requested.add(url);
    for (final MapEntry<String, String> e in xhr.entries) {
      if (url.contains(e.key)) {
        return (status: 200, body: e.value, headers: const <String, String>{});
      }
    }
    return (status: 200, body: '{}', headers: const <String, String>{});
  }

  @override
  Future<String> currentCookieString({String? domain}) async => '';

  @override
  Widget? buildView({required String url, String? userAgent}) =>
      const SizedBox.shrink();
}

SpiderTransportResponse _res(
  String body, {
  List<String> cookies = const <String>[],
}) =>
    SpiderTransportResponse(
      status: 200,
      headers: const <String, String>{},
      bodyBytes: utf8.encode(body),
      setCookies: cookies,
    );

/// 默认响应链（wap/init → verify → 桌面页 → templatevariable → share/list）。
SpiderTransportResponse _route(SpiderTransportRequest r) {
  final String url = r.url.toString();
  if (url.contains('/wap/init')) {
    return _res(
      '<html><script>yunData.FILEINFO = ['
      '{"fs_id":"111","server_filename":"EP01.mp4","isdir":"0"}'
      '];</script></html>',
      cookies: <String>['BAIDUID=abc; Path=/'],
    );
  }
  if (url.contains('/share/verify')) {
    return _res(
      '{"errno":0,"randsk":"rnd%2Fsk"}',
      cookies: <String>['BDCLND=rnd%2Fsk; Path=/'],
    );
  }
  if (url.contains('/api/gettemplatevariable')) {
    return _res('{"bdstoken":"tok123","shareid":"777","share_uk":"888"}');
  }
  if (url.contains('/share/list')) {
    if (url.contains('root=1')) {
      return _res(
        '{"errno":0,"data":{"share_id":"777","uk":"888","list":['
        '{"fs_id":"222","server_filename":"EP02.mp4","isdir":"0"},'
        '{"fs_id":"333","server_filename":"Season1","isdir":"1","path":"/Season1"}'
        ']}}',
      );
    }
    return _res(
      '{"errno":0,"data":{"list":['
      '{"fs_id":"444","server_filename":"EP03.mkv","isdir":"0"}'
      ']}}',
    );
  }
  return _res('{}');
}

/// C2 响应链（`/api/list` · `share/transfer` · `locatedownload` · `mediainfo`）；
/// 分享链段复用 [_route]。
SpiderTransportResponse _routeC2(SpiderTransportRequest r) {
  final String url = r.url.toString();
  if (url.contains('/api/list')) {
    return _res('{"errno":0,"data":{"list":[]}}');
  }
  if (url.contains('/share/transfer')) {
    return _res('{"errno":0,"extra":{"list":[{"to":"/vbox/EP01.mp4"}]}}');
  }
  if (url.contains('method=locatedownload') || url.contains('/pcs/file')) {
    return _res(
      '{"errno":0,"urls":[{"url":"https://cdn.example.com/ep01.mp4"}]}',
    );
  }
  if (url.contains('/api/mediainfo')) {
    return _res('{"errno":0,"info":{"dlink":"https://dlna.example.com/ep01.m3u8"}}');
  }
  if (url.contains('/api/create') ||
      url.contains('/api/filemanager') ||
      url.contains('/disk/main')) {
    return _res('{"errno":0}');
  }
  return _route(r);
}

void main() {
  group('百度 iBox 工具（对齐 iOS 同名函数）', () {
    test('parseToken：完整 Cookie（含 BDUSS/STOKEN）→ 原样规范化', () {
      final ({String bduss, String cookie}) r =
          BaiduIBoxClient.parseToken('Cookie: BDUSS=abc\r\nSTOKEN=st;   BAIDUID=b');
      expect(r.bduss, 'abc');
      expect(r.cookie, 'BDUSS=abc; STOKEN=st;   BAIDUID=b');
      expect(r.cookie.contains('\r'), isFalse);
    });

    test('parseToken：BDUSS|STOKEN 竖线形态 → 合成 Cookie', () {
      final ({String bduss, String cookie}) r =
          BaiduIBoxClient.parseToken('abc|STOKEN=st');
      expect(r.bduss, 'abc');
      expect(r.cookie, 'BDUSS=abc; STOKEN=st');
    });

    test('parseToken：裸 BDUSS → BDUSS= 前缀', () {
      expect(BaiduIBoxClient.parseToken('abc').cookie, 'BDUSS=abc');
    });

    test('mergeCookieStrings：忽略属性名 + 后到覆盖', () {
      final String merged = BaiduIBoxClient.mergeCookieStrings(<String>[
        'BDUSS=old; Path=/; Expires=Wed',
        'BDUSS=new; STOKEN=st; Secure',
      ]);
      expect(merged, 'BDUSS=new; STOKEN=st');
    });

    test('errorMessage：关键 errno 文案', () {
      expect(BaiduIBoxClient.errorMessage(-9), '提取码错误');
      expect(BaiduIBoxClient.errorMessage(200025), contains('分享验证态未绑定'));
      expect(BaiduIBoxClient.errorMessage(5), contains('分享链接不存在'));
    });

    test('extractSurl / extractPwd：保留前导 1 与提取码', () {
      expect(
        BaiduIBoxClient.extractSurl('https://pan.baidu.com/s/1abc?pwd=1234'),
        '1abc',
      );
      expect(
        BaiduIBoxClient.extractPwd('https://pan.baidu.com/s/1abc?pwd=1234'),
        '1234',
      );
      expect(BaiduIBoxClient.shortSurl('1abc'), 'abc');
    });
  });

  group('百度 iBox 分享链（C1）', () {
    late PrefsManager prefs;
    late _FakeTransport transport;
    late BaiduIBoxClient client;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      prefs = PrefsManager.instance;
      await prefs.init();
      await prefs.clearAll();
      transport = _FakeTransport(_route);
      client = BaiduIBoxClient(transport: transport, prefs: prefs);
    });

    test('extractShareMeta：多文件选集（yunData + root + 子目录）', () async {
      final BaiduShareMeta meta = await client.extractShareMeta(
        shareUrl: 'https://pan.baidu.com/s/1abc?pwd=1234',
        cookie: 'BDUSS=u',
        returnAll: true,
      );
      expect(meta.shareid, '777');
      expect(meta.shareUk, '888');
      expect(meta.bdstoken, 'tok123');
      expect(meta.randsk, 'rnd/sk');
      expect(meta.files.map((BaiduFileItem f) => f.name),
          <String>['EP01.mp4', 'EP02.mp4', 'EP03.mkv']);
      expect(meta.cookie.contains('BDCLND='), isTrue);
    });

    test('share/verify 必须不带 Cookie（对齐 iOS）', () async {
      await client.extractShareMeta(
        shareUrl: 'https://pan.baidu.com/s/1abc?pwd=1234',
        cookie: 'BDUSS=u',
        returnAll: true,
      );
      final SpiderTransportRequest verify = transport.requests
          .firstWhere((SpiderTransportRequest r) =>
              r.url.toString().contains('/share/verify'));
      expect(verify.headers['Cookie'], '');
      expect(verify.method, 'POST');
      expect(verify.body, contains('pwd=1234'));
    });

    test('root-shorturl 不带账号态 Cookie；dir 列举带账号态', () async {
      await client.extractShareMeta(
        shareUrl: 'https://pan.baidu.com/s/1abc?pwd=1234',
        cookie: 'BDUSS=u; STOKEN=st',
        returnAll: true,
      );
      final SpiderTransportRequest root = transport.requests.firstWhere(
          (SpiderTransportRequest r) =>
              r.url.toString().contains('root=1'));
      expect(root.headers['Cookie']!.contains('BDUSS'), isFalse);
      expect(root.headers['Cookie']!.contains('STOKEN'), isFalse);
      final SpiderTransportRequest dir = transport.requests.firstWhere(
          (SpiderTransportRequest r) =>
              r.url.toString().contains('is_from_web=true'));
      expect(dir.headers['Cookie']!.contains('BDUSS=u'), isTrue);
    });

    test('分享上下文缓存：二次调用命中缓存不再请求', () async {
      await client.extractShareMeta(
        shareUrl: 'https://pan.baidu.com/s/1abc?pwd=1234',
        cookie: 'BDUSS=u',
      );
      final int after = transport.requests.length;
      final BaiduShareMeta again = await client.extractShareMeta(
        shareUrl: 'https://pan.baidu.com/s/1abc?pwd=1234',
        cookie: 'BDUSS=u',
      );
      expect(transport.requests.length, after);
      expect(again.files, isNotEmpty);
      expect(
        await prefs.getString(BaiduIBoxClient.shareContextCacheKey),
        isNotEmpty,
      );
    });

    test('未拿到 shareid/uk → 明确报错', () async {
      final BaiduIBoxClient bad = BaiduIBoxClient(
        transport: _FakeTransport((SpiderTransportRequest r) =>
            _res('{"errno":0,"data":{"list":[]}}')),
        prefs: prefs,
      );
      await expectLater(
        bad.extractShareMeta(
          shareUrl: 'https://pan.baidu.com/s/1abc',
          cookie: 'BDUSS=u',
          returnAll: true,
        ),
        throwsA(isA<BaiduIBoxException>()),
      );
    });
  });

  group('百度 iBox 转存 + DLNA 取链（C2）', () {
    late PrefsManager prefs;
    late _FakeTransport transport;
    late BaiduIBoxClient client;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      prefs = PrefsManager.instance;
      await prefs.init();
      await prefs.clearAll();
      transport = _FakeTransport(_routeC2);
      client = BaiduIBoxClient(transport: transport, prefs: prefs);
    });

    test('pureAccountCookie：剔除 BDCLND 分享态字段', () {
      expect(
        BaiduIBoxClient.pureAccountCookie('BDUSS=u; BDCLND=rnd%2Fsk; STOKEN=st'),
        'BDUSS=u; STOKEN=st',
      );
    });

    test('queryEncodeStrict：& / = / 空格均编码', () {
      expect(BaiduIBoxClient.queryEncodeStrict('a&b=c d'), 'a%26b%3Dc%20d');
    });

    test('fetchUserBdstoken：templatevariable 返回用户态 bdstoken', () async {
      expect(await client.fetchUserBdstoken(cookie: 'BDUSS=u'), 'tok123');
    });

    test('fetchUserBdstoken：第 1 层 errno=-6 → Cookie 补全重试取得 bdstoken', () async {
      int tplCalls = 0;
      String? enrichedCookieSeen;
      final _FakeTransport t = _FakeTransport((SpiderTransportRequest r) {
        final String url = r.url.toString();
        final String cookie = r.headers['Cookie'] ?? '';
        if (url.contains('/api/gettemplatevariable')) {
          tplCalls++;
          // 第 1 层（无指纹 Cookie）被风控；补全后（带 BAIDUID）放行。
          if (cookie.contains('BAIDUID=')) {
            enrichedCookieSeen = cookie;
            return _res('{"errno":0,"result":{"bdstoken":"enriched-tok"}}');
          }
          return _res('{"errno":-6}');
        }
        if (url == 'https://www.baidu.com/' ||
            url.startsWith('https://www.baidu.com')) {
          // 服务端种指纹 Cookie。
          return _res('<html></html>',
              cookies: <String>['BAIDUID=fingerprint123; Path=/; Domain=.baidu.com']);
        }
        return _res('<html></html>');
      });
      final BaiduIBoxClient c = BaiduIBoxClient(transport: t, prefs: prefs);
      String? fetchedSource;
      final String token = await c.fetchUserBdstoken(
        cookie: 'BDUSS=u',
        onFetched: (String bdstoken, String source, String mergedCookie) {
          fetchedSource = source;
        },
      );
      expect(token, 'enriched-tok');
      expect(tplCalls, 2, reason: '补全前 errno=-6 一次 + 补全后重试一次');
      expect(enrichedCookieSeen, contains('BAIDUID=fingerprint123'));
      expect(enrichedCookieSeen, contains('BDUSS=u'), reason: '账号 Cookie 保留');
      expect(fetchedSource, 'urlsession-templatevariable');
    });

    test('fetchUserBdstoken：Cookie 补全仍失败 → 继续 WebView 兜底（不回退保存值短路）', () async {
      final _FakeTransport t = _FakeTransport(
          (SpiderTransportRequest r) => _res('<html></html>'));
      final _FakeWebViewBridge web = _FakeWebViewBridge(
        html: '<script>bdstoken="webtok"</script>',
      );
      final BaiduIBoxClient c =
          BaiduIBoxClient(transport: t, prefs: prefs, webView: web);
      expect(await c.fetchUserBdstoken(cookie: 'BDUSS=u'), 'webtok');
    });

    test('fetchUserBdstoken：Dart 层被风控 → 浏览器栈 XHR（WebView2）取得 bdstoken', () async {
      String? fetchedSource;
      final _FakeTransport t = _FakeTransport((SpiderTransportRequest r) {
        // Dart 直发的 gettemplatevariable 一律被风控（errno=-6）。
        if (r.url.toString().contains('/api/gettemplatevariable')) {
          return _res('{"errno":-6}');
        }
        return _res('<html></html>');
      });
      final _FakeWebViewBridge web = _FakeWebViewBridge(
        xhr: <String, String>{
          '/api/gettemplatevariable': '{"errno":0,"result":{"bdstoken":"browser-tok"}}',
        },
      );
      final BaiduIBoxClient c =
          BaiduIBoxClient(transport: t, prefs: prefs, webView: web);
      final String token = await c.fetchUserBdstoken(
        cookie: 'BDUSS=u',
        onFetched: (String bdstoken, String source, String mergedCookie) {
          fetchedSource = source;
        },
      );
      expect(token, 'browser-tok');
      expect(fetchedSource, 'webview-xhr-templatevariable');
      expect(
        web.requested.any((String u) => u.contains('/api/gettemplatevariable')),
        isTrue,
        reason: '浏览器栈 XHR 层确实发出过 gettemplatevariable',
      );
    });

    test('fetchUserBdstoken：补全改变输入 → 浏览器栈用补全后的最优 Cookie 一次通过', () async {
      final _FakeTransport t = _FakeTransport((SpiderTransportRequest r) {
        // Dart 直发永远被风控（覆盖「Cookie + 请求指纹」叠加场景）。
        if (r.url.toString().contains('/api/gettemplatevariable')) {
          return _res('{"errno":-6}');
        }
        if (r.url.toString().startsWith('https://www.baidu.com')) {
          return _res('<html></html>',
              cookies: <String>['BAIDUID=fingerprint123; Path=/; Domain=.baidu.com']);
        }
        return _res('<html></html>');
      });
      final _FakeWebViewBridge web = _FakeWebViewBridge(
        xhr: <String, String>{
          '/api/gettemplatevariable':
              '{"errno":0,"result":{"bdstoken":"browser-tok2"}}', // 补全 Cookie → 放行。
        },
      );
      final BaiduIBoxClient c =
          BaiduIBoxClient(transport: t, prefs: prefs, webView: web);
      expect(await c.fetchUserBdstoken(cookie: 'BDUSS=u'), 'browser-tok2');
      expect(
        web.requested
            .where((String u) => u.contains('/api/gettemplatevariable'))
            .length,
        1,
        reason: '浏览器栈在补全之后只调用一次（用补全后的最优 Cookie），'
            '避免重复触发 Windows 无头 WebView2（崩溃保护对象）',
      );
    });

    test('ensureTransferDir：目录可列举则不创建', () async {
      await client.ensureTransferDir(cookie: 'BDUSS=u', bdstoken: 'tok123');
      expect(
        transport.requests
            .any((SpiderTransportRequest r) => r.url.toString().contains('/api/create')),
        isFalse,
      );
    });

    test('ensureTransferDir：不可列举 → api/create → 再校验通过', () async {
      int listCalls = 0;
      final _FakeTransport t = _FakeTransport((SpiderTransportRequest r) {
        final String url = r.url.toString();
        if (url.contains('/api/list')) {
          listCalls++;
          return _res(listCalls == 1 ? '{"errno":-9}' : '{"errno":0}');
        }
        if (url.contains('/api/create')) return _res('{"errno":0}');
        return _res('{}');
      });
      final BaiduIBoxClient c = BaiduIBoxClient(transport: t, prefs: prefs);
      await c.ensureTransferDir(cookie: 'BDUSS=u', bdstoken: 'tok123');
      final SpiderTransportRequest create = t.requests.firstWhere(
          (SpiderTransportRequest r) => r.url.toString().contains('/api/create'));
      expect(create.method, 'POST');
      expect(create.body, contains('size=0'));
      expect(create.body, contains('method=post'));
      expect(create.body, contains('path=/vbox'));
      expect(create.body, contains('block_list=%5B%5D'));
    });

    test('transferFile：BDCLND 原始 sekey 不二次编码 + 返回 extra.to', () async {
      final String path = await client.transferFile(
        shareUrl: 'https://pan.baidu.com/s/1abc?pwd=1234',
        shareid: '777',
        shareUk: '888',
        bdstoken: 'tok123',
        randsk: 'rnd/sk',
        fsId: '111',
        fileName: 'EP01.mp4',
        cookie: 'BDCLND=rnd%2Fsk; BDUSS=u',
        accountCookie: 'BDUSS=u',
        referer: 'https://pan.baidu.com/s/1abc',
      );
      expect(path, '/vbox/EP01.mp4');
      final SpiderTransportRequest tr = transport.requests.firstWhere(
          (SpiderTransportRequest r) =>
              r.url.toString().contains('/share/transfer'));
      expect(tr.url.query.contains('sekey=rnd%2Fsk'), isTrue);
      expect(tr.body, contains('fsidlist=%5B111%5D'));
      expect(tr.body, contains('path=/vbox'));
      expect(tr.body, contains('ondup=newcopy'));
    });

    test('getDLNADlink：mediainfo 返回 dlink + PCS UA', () async {
      final BaiduPlayResult r = await client.getDLNADlink(
        filePath: '/vbox/EP01.mp4',
        cookie: 'BDUSS=u',
      );
      expect(r.url, 'https://dlna.example.com/ep01.m3u8');
      expect(r.headers['User-Agent'], BaiduIBoxClient.pcsUserAgent);
    });

    test('getLocatedownload：urls[0] 取链', () async {
      final BaiduPlayResult r = await client.getLocatedownload(
        filePath: '/vbox/EP01.mp4',
        cookie: 'BDUSS=u',
      );
      expect(r.url, 'https://cdn.example.com/ep01.mp4');
      expect(r.source, contains('locatedownload'));
    });

    test('getLocatedownload：302 跟随后的 CDN 落点直接可用', () async {
      final _FakeTransport t = _FakeTransport((SpiderTransportRequest r) =>
          SpiderTransportResponse(
            status: 200,
            headers: const <String, String>{},
            bodyBytes: utf8.encode(''),
            finalUrl: 'https://cdn2.example.com/x.mp4',
          ));
      final BaiduIBoxClient c = BaiduIBoxClient(transport: t, prefs: prefs);
      final BaiduPlayResult r = await c.getLocatedownload(
        filePath: '/vbox/EP01.mp4',
        cookie: 'BDUSS=u',
      );
      expect(r.url, 'https://cdn2.example.com/x.mp4');
    });

    test('resolvePlayURL：主路链端到端（分享 → 转存 → locatedownload）', () async {
      final BaiduPlayResult r = await client.resolvePlayURL(
        shareUrl: 'https://pan.baidu.com/s/1abc?pwd=1234',
        bduss: 'BDUSS=u',
        fsId: '111',
      );
      expect(r.url, 'https://cdn.example.com/ep01.mp4');
      expect(r.source, contains('locatedownload'));
      // 必经过转存（而非命中已存在文件）。
      expect(r.source, contains('main-transfer'));
    });
  });

  group('百度 iBox C3 WebView 回退', () {
    late PrefsManager prefs;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      prefs = PrefsManager.instance;
      await prefs.init();
      await prefs.clearAll();
    });

    test('fetchUserBdstoken：本地失败 → WebView 回退取 bdstoken', () async {
      final _FakeTransport t = _FakeTransport((SpiderTransportRequest r) =>
          _res(r.url.toString().contains('/disk/main')
              ? '<html></html>'
              : '{}'));
      final _FakeWebViewBridge web = _FakeWebViewBridge(
        html: '<script>bdstoken="webtok"</script>',
      );
      final BaiduIBoxClient c =
          BaiduIBoxClient(transport: t, prefs: prefs, webView: web);
      expect(await c.fetchUserBdstoken(cookie: 'BDUSS=u'), 'webtok');
      expect(web.loaded.any((String u) => u.contains('/disk/main')), isTrue);
    });

    test('findExistingVboxPath：本地 errno!=0 → WebView 回退列目录', () async {
      final _FakeTransport t =
          _FakeTransport((SpiderTransportRequest r) => _res('{"errno":-6}'));
      final _FakeWebViewBridge web = _FakeWebViewBridge(
        html: '<html></html>',
        xhr: <String, String>{
          '/api/list':
              '{"errno":0,"data":{"list":[{"server_filename":"EP01.mp4","path":"/vbox/EP01.mp4"}]}}',
        },
      );
      final BaiduIBoxClient c =
          BaiduIBoxClient(transport: t, prefs: prefs, webView: web);
      expect(
        await c.findExistingVboxPath(fileName: 'EP01.mp4', cookie: 'BDUSS=u'),
        '/vbox/EP01.mp4',
      );
      expect(web.requested.any((String u) => u.contains('/api/list')), isTrue);
    });

    test('桥不可用 → 保持失败即抛（不改变原语义）', () async {
      final _FakeTransport t = _FakeTransport(
          (SpiderTransportRequest r) => _res('{"errno":-6}'));
      final BaiduIBoxClient c = BaiduIBoxClient(transport: t, prefs: prefs);
      expect(
        await c.findExistingVboxPath(fileName: 'EP01.mp4', cookie: 'BDUSS=u'),
        isNull,
      );
    });
  });
}