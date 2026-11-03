/// 数据层单测：夸克原生分享链客户端（F-P01，对齐 iOS `CloudDriveManager` 夸克分支）。
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/remote/quark_native_client.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';

/// 假传输：按 URL 片段路由响应，并记录请求。
class _FakeTransport implements SpiderHttpTransport {
  _FakeTransport(this.router);

  final ({String body, int status}) Function(String url, String body) router;
  final List<String> urls = <String>[];
  final List<String> bodies = <String>[];

  @override
  Future<SpiderTransportResponse> send(SpiderTransportRequest request) async {
    final String url = request.url.toString();
    final String body = request.body ?? '';
    urls.add(url);
    bodies.add(body);
    final ({String body, int status}) r = router(url, body);
    return SpiderTransportResponse(
      status: r.status,
      headers: const <String, String>{'content-type': 'application/json'},
      bodyBytes: utf8.encode(r.body),
    );
  }
}

QuarkNativeClient _client(_FakeTransport t) =>
    QuarkNativeClient(bridge: SpiderHttpBridge(transport: t));

({String body, int status}) _json(Object o, [int status = 200]) =>
    (body: jsonEncode(o), status: status);

void main() {
  test('extractShareInfo：/s/<id> + pwd 参数', () {
    final ({String pwdId, String passcode}) a = QuarkNativeClient.extractShareInfo(
      'https://pan.quark.cn/s/abc123?pwd=xyz',
    );
    expect(a.pwdId, 'abc123');
    expect(a.passcode, 'xyz');

    final ({String pwdId, String passcode}) b =
        QuarkNativeClient.extractShareInfo('https://pan.quark.cn/s/only');
    expect(b.pwdId, 'only');
    expect(b.passcode, '');
  });

  test('strictQueryEncode：保留 unreserved，编码 + / =', () {
    expect(QuarkNativeClient.strictQueryEncode('a-b._~'), 'a-b._~');
    expect(QuarkNativeClient.strictQueryEncode('a+b/c='), 'a%2Bb%2Fc%3D');
  });

  test('isPlayableFileName：白名单扩展名', () {
    expect(QuarkNativeClient.isPlayableFileName('EP01.MP4'), isTrue);
    expect(QuarkNativeClient.isPlayableFileName('cover.jpg'), isFalse);
  });

  test('getFileList：token → detail（stoken 严格编码）→ 可播放文件', () async {
    final _FakeTransport t = _FakeTransport((String url, String _) {
      if (url.contains('/share/sharepage/token')) {
        return _json(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{'stoken': 'S+T/K='},
        });
      }
      if (url.contains('/share/sharepage/detail')) {
        return _json(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{
            'list': <Object?>[
              <String, Object?>{
                'fid': 'f1',
                'file_name': 'EP01.mp4',
                'dir': false,
                'share_fid_token': 'tk1',
              },
              <String, Object?>{
                'fid': 'f2',
                'file_name': 'cover.jpg',
                'dir': false,
              },
            ],
          },
        });
      }
      return _json(<String, Object?>{'code': 0, 'data': <String, Object?>{}});
    });

    final QuarkNativeClient c = _client(t);
    final List<QuarkShareFile> files = await c.getFileList(
      shareUrl: 'https://pan.quark.cn/s/abc123?pwd=xyz',
      cookie: 'k=v',
    );

    expect(files, hasLength(1));
    expect(files.single.fid, 'f1');
    expect(files.single.fileName, 'EP01.mp4');
    expect(files.single.shareFidToken, 'tk1');
    // stoken 严格编码（`+` → %2B、`/` → %2F、`=` → %3D）。
    final String detailUrl =
        t.urls.firstWhere((String u) => u.contains('/sharepage/detail'));
    expect(detailUrl, contains('stoken=S%2BT%2FK%3D'));
    // token 请求体带 pwd_id/passcode。
    final String tokenBody =
        t.bodies[t.urls.indexWhere((String u) => u.contains('/sharepage/token'))];
    expect(tokenBody, contains('"pwd_id":"abc123"'));
    expect(tokenBody, contains('"passcode":"xyz"'));
  });

  test('resolvePlayUrl：转存 → v2/play 取链（选低码率可用流）', () async {
    final _FakeTransport t = _FakeTransport((String url, String _) {
      if (url.contains('/share/sharepage/token')) {
        return _json(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{'stoken': 'st'},
        });
      }
      if (url.contains('/share/sharepage/detail')) {
        return _json(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{
            'list': <Object?>[
              <String, Object?>{
                'fid': 'f1',
                'file_name': 'EP01.mkv',
                'dir': false,
                'share_fid_token': 'tk1',
              },
            ],
          },
        });
      }
      if (url.contains('/share/sharepage/save')) {
        return _json(<String, Object?>{
          'status': 200,
          'code': 0,
          'data': <String, Object?>{'file_ids': <String>['newfid']},
        });
      }
      if (url.contains('/file/v2/play')) {
        return _json(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{
            'video_list': <Object?>[
              <String, Object?>{
                'accessable': true,
                'video_info': <String, Object?>{
                  'resolution': 'high',
                  'url': 'https://v/high.m3u8',
                },
              },
              <String, Object?>{
                'accessable': true,
                'video_info': <String, Object?>{
                  'resolution': 'low',
                  'url': 'https://v/low.m3u8',
                },
              },
            ],
          },
        });
      }
      return _json(<String, Object?>{'code': 0, 'data': <String, Object?>{}});
    });

    final QuarkNativeClient c = _client(t);
    final QuarkPlayResult r = await c.resolvePlayUrl(
      shareUrl: 'https://pan.quark.cn/s/abc123',
      cookie: 'k=v',
    );

    // low 优先（对齐 iOS qualityOrder 从 low 起）。
    expect(r.url, 'https://v/low.m3u8');
    expect(r.fileName, 'EP01.mkv');
  });

  test('saveShare：占位 fileId=0 → 返回 ["0"]（对齐 iOS，占位判定上移至 resolvePlayUrl）',
      () async {
    final _FakeTransport t = _FakeTransport((String url, String _) {
      if (url.contains('/share/sharepage/save')) {
        return _json(<String, Object?>{
          'status': 200,
          'code': 0,
          'data': <String, Object?>{'file_ids': <String>['0']},
        });
      }
      return _json(<String, Object?>{'code': 0, 'data': <String, Object?>{}});
    });
    final QuarkNativeClient c = _client(t);
    final List<String> ids = await c.saveShare(
      pwdId: 'p',
      stoken: 's',
      file: const QuarkShareFile(
        fid: 'f1',
        fileName: 'x.mp4',
        shareFidToken: 't1',
      ),
      cookie: 'k=v',
    );
    expect(ids, <String>['0']);
  });

  test('resolvePlayUrl：转存返回占位 fileId=0 → 抛「已失效」文案', () async {
    final _FakeTransport t = _FakeTransport((String url, String _) {
      if (url.contains('/share/sharepage/token')) {
        return _json(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{'stoken': 'st'},
        });
      }
      if (url.contains('/share/sharepage/detail')) {
        return _json(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{
            'list': <Object?>[
              <String, Object?>{
                'fid': 'f1',
                'file_name': 'EP01.mp4',
                'dir': false,
                'share_fid_token': 'tk1',
              },
            ],
          },
        });
      }
      if (url.contains('/share/sharepage/save')) {
        return _json(<String, Object?>{
          'status': 200,
          'code': 0,
          'data': <String, Object?>{'file_ids': <String>['0']},
        });
      }
      return _json(<String, Object?>{'code': 0, 'data': <String, Object?>{}});
    });

    final QuarkNativeClient c = _client(t);
    await expectLater(
      c.resolvePlayUrl(
        shareUrl: 'https://pan.quark.cn/s/abc123',
        cookie: 'k=v',
      ),
      throwsA(isA<QuarkNativeException>()),
    );
  });

  test('getShareToken：code!=0 → 抛错并带 message', () async {
    final _FakeTransport t = _FakeTransport((String _, String __) =>
        _json(<String, Object?>{'code': 41001, 'message': '分享已失效'}));
    final QuarkNativeClient c = _client(t);
    await expectLater(
      c.getShareToken(pwdId: 'p', passcode: '', cookie: ''),
      throwsA(predicate((Object e) =>
          e is QuarkNativeException && e.message.contains('分享已失效'))),
    );
  });

  test('转存 fid 缓存：二次解析跳过 save，并落契约键 quark_saved_fid_cache_v1',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final PrefsManager pm = PrefsManager.instance;
    await pm.init();
    await pm.clearAll();

    int saveCalls = 0;
    final _FakeTransport t = _FakeTransport((String url, String _) {
      if (url.contains('/share/sharepage/token')) {
        return _json(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{'stoken': 'st'},
        });
      }
      if (url.contains('/share/sharepage/detail')) {
        return _json(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{
            'list': <Object?>[
              <String, Object?>{
                'fid': 'f1',
                'file_name': 'EP01.mp4',
                'dir': false,
                'share_fid_token': 'tk1',
              },
            ],
          },
        });
      }
      if (url.contains('/share/sharepage/save')) {
        saveCalls++;
        return _json(<String, Object?>{
          'status': 200,
          'code': 0,
          'data': <String, Object?>{'file_ids': <String>['newfid']},
        });
      }
      if (url.contains('/file/v2/play')) {
        return _json(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{
            'video_list': <Object?>[
              <String, Object?>{
                'accessable': true,
                'video_info': <String, Object?>{
                  'resolution': 'low',
                  'url': 'https://v/low.m3u8',
                },
              },
            ],
          },
        });
      }
      return _json(<String, Object?>{'code': 0, 'data': <String, Object?>{}});
    });

    final QuarkNativeClient c =
        QuarkNativeClient(bridge: SpiderHttpBridge(transport: t), prefs: pm);
    await c.resolvePlayUrl(
      shareUrl: 'https://pan.quark.cn/s/abc',
      cookie: 'k=v',
    );
    await c.resolvePlayUrl(
      shareUrl: 'https://pan.quark.cn/s/abc',
      cookie: 'k=v',
    );

    expect(saveCalls, 1); // 第二次命中缓存，不再转存
    expect(await pm.getString(QuarkNativeClient.savedFidCacheKey), isNotEmpty);
  });
}