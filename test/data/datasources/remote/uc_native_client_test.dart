import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/datasources/remote/uc_native_client.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';

/// 假传输（离线；按 URL path 路由 JSON 响应）。
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

SpiderTransportResponse _json(String body) => SpiderTransportResponse(
      status: 200,
      headers: const <String, String>{},
      bodyBytes: utf8.encode(body),
    );

/// UC 默认响应链（vbox 已存在 → token → 选集 → save → v2/play/download）。
SpiderTransportResponse _routeUc(
  SpiderTransportRequest r, {
  bool failPlay = false,
}) {
  final String url = r.url.toString();
  if (url.contains('/1/clouddrive/file/sort')) {
    if (url.contains('pdir_fid=vf')) {
      return _json('{"code":0,"data":{"list":[]}}');
    }
    return _json(
      '{"code":0,"data":{"list":[{"fid":"vf","file_name":"vbox","dir":true}]}}',
    );
  }
  if (url.contains('/1/clouddrive/share/sharepage/token')) {
    return _json('{"code":0,"data":{"stoken":"st1"}}');
  }
  if (url.contains('/1/clouddrive/share/sharepage/detail')) {
    return _json(
      '{"code":0,"data":{"list":[{"fid":"u1","file_name":"EP01.mp4",'
      '"share_fid_token":"tk1","dir":false,"file":true,"file_type":1}]}}',
    );
  }
  if (url.contains('/1/clouddrive/share/sharepage/save')) {
    return _json('{"code":0,"data":{"file_ids":["saved1"]}}');
  }
  if (url.contains('/1/clouddrive/file/v2/play')) {
    if (failPlay) return _json('{"code":500,"message":"转码失败"}');
    return _json(
      '{"code":0,"data":{"video_list":[{"accessable":true,'
      '"video_info":{"resolution":"high","url":"https://uc/trans.m3u8"}}]}}',
    );
  }
  if (url.contains('/1/clouddrive/file/download')) {
    return _json(
      '{"code":0,"data":[{"download_url":'
      '"https://dl-c-uc.example/x.mp4?sp=100&x-oss-traffic-limit=1024"}]}',
    );
  }
  return _json('{"code":0,"data":{}}');
}

UcNativeClient _client(SpiderHttpTransport transport) => UcNativeClient(
      bridge: SpiderHttpBridge(transport: transport),
    );

void main() {
  group('UC 静态工具（对齐 iOS 同名函数）', () {
    test('extractShareInfo：/s/ + pwd', () {
      final ({String passcode, String pwdId}) r =
          UcNativeClient.extractShareInfo('https://drive.uc.cn/s/abc?pwd=1234');
      expect(r.pwdId, 'abc');
      expect(r.passcode, '1234');
    });

    test('isPlayableFileName：视频扩展名', () {
      expect(UcNativeClient.isPlayableFileName('EP01.mp4'), isTrue);
      expect(UcNativeClient.isPlayableFileName('cover.jpg'), isFalse);
    });

    test('stripCdnSpeedLimit：下载 CDN 去限速；流媒体 sp 保留', () {
      expect(
        UcNativeClient.stripCdnSpeedLimit(
          'https://dl-c-x/v.mp4?sp=100&x-oss-traffic-limit=1024',
        ),
        'https://dl-c-x/v.mp4',
      );
      expect(
        UcNativeClient.stripCdnSpeedLimit(
          'https://video-play/v.m3u8?sp=1301',
        ),
        'https://video-play/v.m3u8?sp=1301',
      );
    });
  });

  group('UC 原生链（F-P03）', () {
    test('getShareToken / getShareDetail：解析 stoken 与选集', () async {
      final UcNativeClient c =
          _client(_FakeTransport((SpiderTransportRequest r) => _routeUc(r)));
      final String st = await c.getShareToken(
        pwdId: 'abc',
        passcode: '1234',
        cookie: 'k=v',
      );
      expect(st, 'st1');
      final List<UcShareFile> files = await c.getShareDetail(
        pwdId: 'abc',
        stoken: st,
        pdirFid: '0',
        cookie: 'k=v',
      );
      expect(files.single.fid, 'u1');
      expect(files.single.fileName, 'EP01.mp4');
      expect(files.single.isDir, isFalse);
    });

    test('ensureFolder：命中已存在 vbox 目录', () async {
      final UcNativeClient c =
          _client(_FakeTransport((SpiderTransportRequest r) => _routeUc(r)));
      expect((await c.ensureFolder(cookie: 'k=v')).fid, 'vf');
    });

    test('ensureFolder：不存在 → 创建 → 重试命中', () async {
      int sortCalls = 0;
      final _FakeTransport t = _FakeTransport((SpiderTransportRequest r) {
        final String url = r.url.toString();
        if (url.contains('/1/clouddrive/file/sort')) {
          sortCalls++;
          if (sortCalls == 1) {
            return _json('{"code":0,"data":{"list":[]}}');
          }
          return _json(
            '{"code":0,"data":{"list":[{"fid":"vf","file_name":"vbox"}]}}',
          );
        }
        if (url.contains('/1/clouddrive/file')) {
          return _json('{"code":23008,"message":"已存在"}');
        }
        return _json('{"code":0,"data":{}}');
      });
      final UcNativeClient c = _client(t);
      expect((await c.ensureFolder(cookie: 'k=v')).fid, 'vf');
    });

    test('mergeSetCookie：服务端刷新值覆盖 + 忽略属性名', () {
      final String merged = UcNativeClient.mergeSetCookie(
        'a=1; b=2',
        <String>['a=9; Path=/; HttpOnly', 'c=3'],
      );
      expect(merged, contains('a=9'));
      expect(merged, contains('b=2'));
      expect(merged, contains('c=3'));
      expect(merged.contains('Path'), isFalse);
      expect(merged.contains('HttpOnly'), isFalse);
    });

    test('resolvePlayUrl：vbox 命中 → save → v2/play 取链', () async {
      final _FakeTransport t = _FakeTransport(_routeUc);
      final UcNativeClient c = _client(t);
      final UcPlayResult r = await c.resolvePlayUrl(
        shareUrl: 'https://drive.uc.cn/s/abc',
        cookie: 'k=v',
      );
      expect(r.url, 'https://uc/trans.m3u8');
      expect(r.source, 'v2-play');
      expect(r.headers['Referer'], 'https://drive.uc.cn/');
      // 必经过转存（vbox 内无同名文件）。
      expect(
        t.requests
            .any((SpiderTransportRequest x) =>
                x.url.toString().contains('/sharepage/save')),
        isTrue,
      );
    });

    test('resolvePlayUrl：v2/play 失败 → download_url 兜底', () async {
      final _FakeTransport t =
          _FakeTransport((SpiderTransportRequest r) => _routeUc(r, failPlay: true));
      final UcNativeClient c = _client(t);
      final UcPlayResult r = await c.resolvePlayUrl(
        shareUrl: 'https://drive.uc.cn/s/abc',
        cookie: 'k=v',
      );
      expect(r.url, 'https://dl-c-uc.example/x.mp4');
      expect(r.source, 'download_url');
    });

    test('未识别分享链接 → 明确报错', () async {
      final UcNativeClient c =
          _client(_FakeTransport((SpiderTransportRequest r) => _routeUc(r)));
      await expectLater(
        c.getFileList(shareUrl: '', cookie: 'k=v'),
        throwsA(isA<UcNativeException>()),
      );
    });
  });
}