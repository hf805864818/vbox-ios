import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/datasources/remote/aliyun_adrive_client.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';

/// 假传输：按 URL / 请求体路由阿里 ADrive 响应。
class _FakeTransport implements SpiderHttpTransport {
  _FakeTransport(this.handler);

  final SpiderTransportResponse Function(SpiderTransportRequest r) handler;
  final List<SpiderTransportRequest> requests = <SpiderTransportRequest>[];

  @override
  Future<SpiderTransportResponse> send(SpiderTransportRequest request) async {
    requests.add(request);
    return handler(request);
  }
}

SpiderTransportResponse _json(String body, {int status = 200}) =>
    SpiderTransportResponse(
      status: status,
      headers: const <String, String>{},
      bodyBytes: utf8.encode(body),
    );

Map<String, Object?> _body(SpiderTransportRequest r) {
  final String? raw = r.body;
  if (raw == null || raw.isEmpty) return <String, Object?>{};
  final Object? d = jsonDecode(raw);
  return d is Map ? d.cast<String, Object?>() : <String, Object?>{};
}

/// 阿里 PG 链默认路由（分享转码成功）。
SpiderTransportResponse _route(
  SpiderTransportRequest r, {
  bool shareTranscodeFails = false,
  bool shareDownloadFails = false,
}) {
  final String url = r.url.toString();
  final bool hasShareToken = r.headers.containsKey('x-share-token');
  if (url.contains('/v2/account/token')) {
    return _json('{"access_token":"at1","refresh_token":"rt2"}');
  }
  if (url.contains('/adrive/v2/user/get')) {
    return _json('{"default_drive_id":"drv1"}');
  }
  if (url.contains('/v2/share_link/get_share_token')) {
    return _json('{"code":"OK","share_token":"st1"}');
  }
  if (url.contains('/adrive/v3/file/list')) {
    final Map<String, Object?> body = _body(r);
    if (body['parent_file_id'] == 'root') {
      return _json(
        '{"code":"OK","items":['
        '{"file_id":"dir1","name":"Season1","type":"folder"},'
        '{"file_id":"f1","name":"EP01.mp4","type":"file","category":"video","size":10},'
        '{"file_id":"f2","name":"cover.jpg","type":"file","category":"image"}'
        ']}',
      );
    }
    return _json(
      '{"code":"OK","items":['
      '{"file_id":"f3","name":"EP02.mp4","type":"file","category":"video"}'
      ']}',
    );
  }
  if (url.contains('/file/get_video_preview_play_info')) {
    if (hasShareToken && shareTranscodeFails) {
      return _json('{"code":"Error","message":"无转码"}', status: 500);
    }
    return _json(
      '{"code":"OK","video_preview_play_info":{"live_transcoding_task_list":['
      '{"template_id":"FHD_264","url":"https://cdn.example.com/trans.m3u8"}'
      ']}}',
    );
  }
  if (url.contains('/file/get_download_url')) {
    if (url.contains('api.aliyundrive.com')) {
      // 分享直链方案A（PDS）。
      if (shareDownloadFails) return _json('{}', status: 500);
      return _json(
        '{"url":"https://cdn.example.com/raw.mp4","headers":{"X-Custom":"1"}}',
      );
    }
    // 分享直链方案B（ADrive，带 x-share-token）与个人直链共用路径。
    if (hasShareToken) {
      if (shareDownloadFails) return _json('{}', status: 500);
      return _json('{"url":"https://cdn.example.com/raw-2.mp4"}');
    }
    return _json('{"url":"https://cdn.example.com/personal.mp4"}');
  }
  if (url.contains('/adrive/v2/file/copy')) {
    return _json('{"code":"OK","file_id":"saved1"}');
  }
  return _json('{}');
}

AliyunAdriveClient _client(SpiderHttpTransport transport) =>
    AliyunAdriveClient(transport: transport);

void main() {
  group('阿里静态工具', () {
    test('parseShareId：/s/ + 丢弃查询串', () {
      expect(
        AliyunAdriveClient.parseShareId('https://www.alipan.com/s/abc123?pwd=x'),
        'abc123',
      );
      expect(AliyunAdriveClient.parseShareId(''), '');
    });

    test('isTranscodeM3u8：host 含 aliyun+video 且 path 含 /lt/ 或 /qv/', () {
      expect(
        AliyunAdriveClient.isTranscodeM3u8(
          'https://cn-hangzhou-video.aliyuncs.com/lt/abc.m3u8',
        ),
        isTrue,
      );
      expect(
        AliyunAdriveClient.isTranscodeM3u8('https://cdn.example.com/v.m3u8'),
        isFalse,
      );
    });

    test('extractDownloadInfo：url → download_url → url_list[0] + headers', () {
      final AliyunDownloadInfo a =
          AliyunAdriveClient.extractDownloadInfo(<String, Object?>{
        'url': 'https://a/1.mp4',
        'download_url': 'https://b/2.mp4',
        'headers': <String, Object?>{'X-A': '1'},
      });
      expect(a.url, 'https://a/1.mp4');
      expect(a.headers['X-A'], '1');

      final AliyunDownloadInfo b =
          AliyunAdriveClient.extractDownloadInfo(<String, Object?>{
        'url_list': <Object?>['https://c/3.mp4'],
      });
      expect(b.url, 'https://c/3.mp4');
      expect(b.headers, isEmpty);
    });

    test('extractVideoPreviewUrl：QHD→FHD→HD→SD→LD 子串匹配', () {
      final String url = AliyunAdriveClient.extractVideoPreviewUrl(
        <String, Object?>{
          'code': 'OK',
          'video_preview_play_info': <String, Object?>{
            'live_transcoding_task_list': <Object?>[
              <String, Object?>{'template_id': 'LD_264', 'url': 'https://ld'},
              <String, Object?>{'template_id': 'HD_264', 'url': 'https://hd'},
              <String, Object?>{'template_id': 'QHD_265', 'url': 'https://qhd'},
            ],
          },
        },
      );
      expect(url, 'https://qhd');
    });
  });

  group('阿里 PG 播放链（F-P09）', () {
    test('refreshAccessToken：方案A 成功且 verify 通过', () async {
      final _FakeTransport t = _FakeTransport(_route);
      final AliyunAdriveClient c = _client(t);
      final ({String accessToken, String refreshToken}) r =
          await c.refreshAccessToken(refreshToken: 'rt');
      expect(r.accessToken, 'at1');
      expect(r.refreshToken, 'rt2');
    });

    test('P2-6：方案A/B 全失败 → OpenList renewapi GET 兜底成功', () async {
      int getCalls = 0;
      final _FakeTransport t = _FakeTransport((SpiderTransportRequest r) {
        final String url = r.url.toString();
        if (url.contains('oplist.org/alicloud/renewapi')) {
          getCalls++;
          expect(r.method, 'GET');
          expect(url, contains('driver_txt=alicloud_qr'));
          expect(url, contains('refresh_ui=rt0'));
          expect(url, contains('server_use=true'));
          return _json('{"access_token":"ol-at","refresh_token":"ol-rt"}');
        }
        return _json('{}', status: 500); // 方案A/B 与 verify 全失败。
      });
      final AliyunAdriveClient c = _client(t);
      final ({String accessToken, String refreshToken}) r =
          await c.refreshAccessToken(refreshToken: 'rt0');
      expect(getCalls, 1);
      expect(r.accessToken, 'ol-at');
      expect(r.refreshToken, 'ol-rt');
    });

    test('P2-6：OpenList GET 报「已失效」→ POST 兜底成功', () async {
      final _FakeTransport t = _FakeTransport((SpiderTransportRequest r) {
        final String url = r.url.toString();
        if (url.contains('oplist.org/alicloud/renewapi')) {
          if (r.method == 'POST') {
            final String contentType = r.headers.entries
                .firstWhere(
                  (MapEntry<String, String> e) =>
                      e.key.toLowerCase() == 'content-type',
                  orElse: () => const MapEntry<String, String>('', ''),
                )
                .value;
            expect(
              contentType,
              contains('application/x-www-form-urlencoded'),
            );
            expect(r.body, contains('driver_txt=alicloud_qr'));
            return _json('{"access_token":"p-at","refresh_token":"p-rt"}');
          }
          // GET 命中 OpenList 错误格式（invalid/expired/过期 → 已失效文案）。
          return _json('{"text":"refresh token expired"}');
        }
        return _json('{}', status: 500);
      });
      final AliyunAdriveClient c = _client(t);
      final ({String accessToken, String refreshToken}) r =
          await c.refreshAccessToken(refreshToken: 'rt0');
      expect(r.accessToken, 'p-at');
      expect(r.refreshToken, 'p-rt');
    });

    test('P2-6：OpenList GET/POST 全失败 → 抛统一刷新失败文案', () async {
      final _FakeTransport t = _FakeTransport((SpiderTransportRequest r) {
        if (r.url.toString().contains('oplist.org/alicloud/renewapi')) {
          return _json('{"text":"invalid"}');
        }
        return _json('{}', status: 500);
      });
      final AliyunAdriveClient c = _client(t);
      await expectLater(
        c.refreshAccessToken(refreshToken: 'rt0'),
        throwsA(
          isA<AliyunAdriveException>().having(
            (AliyunAdriveException e) => e.message,
            'message',
            'PG Token 刷新失败：无法获取兼容分享操作的 ADrive token',
          ),
        ),
      );
    });

    test('listPlayableFiles：递归子目录 + 过滤 + 按名升序', () async {
      final AliyunAdriveClient c = _client(_FakeTransport(_route));
      final List<AliyunShareFile> files = await c.listPlayableFiles(
        shareUrl: 'https://www.alipan.com/s/abc',
        refreshToken: 'rt',
      );
      expect(files.map((AliyunShareFile f) => f.name), <String>['EP01.mp4', 'EP02.mp4']);
    });

    test('resolvePlayUrl：分享转码成功 → 转码 m3u8 且不注入头', () async {
      final AliyunAdriveClient c = _client(_FakeTransport(_route));
      final AliyunPlayResult r = await c.resolvePlayUrl(
        shareUrl: 'https://www.alipan.com/s/abc',
        refreshToken: 'rt',
      );
      expect(r.url, 'https://cdn.example.com/trans.m3u8');
      expect(r.source, 'ali-share-transcode');
      expect(r.headers, isEmpty); // 转码不注入 UA/Referer
    });

    test('resolvePlayUrl：分享转码失败 → 分享直链（注入 UA/Referer + 保留服务端头）',
        () async {
      final AliyunAdriveClient c = _client(
        _FakeTransport((SpiderTransportRequest r) =>
            _route(r, shareTranscodeFails: true)),
      );
      final AliyunPlayResult r = await c.resolvePlayUrl(
        shareUrl: 'https://www.alipan.com/s/abc',
        refreshToken: 'rt',
      );
      expect(r.url, 'https://cdn.example.com/raw.mp4');
      expect(r.source, 'ali-share-download');
      expect(r.headers['X-Custom'], '1');
      expect(r.headers['User-Agent'], AliyunAdriveClient.desktopUA);
      expect(r.headers['Referer'], 'https://api.alipan.com');
    });

    test('resolvePlayUrl：分享全失败 → 转存兜底 → 个人转码', () async {
      final AliyunAdriveClient c = _client(
        _FakeTransport((SpiderTransportRequest r) =>
            _route(r, shareTranscodeFails: true, shareDownloadFails: true)),
      );
      final AliyunPlayResult r = await c.resolvePlayUrl(
        shareUrl: 'https://www.alipan.com/s/abc',
        refreshToken: 'rt',
      );
      expect(r.source, 'ali-transfer-transcode');
      expect(r.url, 'https://cdn.example.com/trans.m3u8');
    });
  });
}