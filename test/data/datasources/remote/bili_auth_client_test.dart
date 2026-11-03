/// 数据层单测：B 站扫码登录客户端（批次 F · F-05）。
///
/// 用假传输 [BiliAuthTransport] 驱动 start / poll / cancel / cookie 全链，
/// 覆盖成功、业务错误与容错分支。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/data/datasources/remote/bili_auth_client.dart';
import 'package:vbox/domain/entities/cloud/bili_auth.dart';

/// 记录调用并返回预设响应的假传输。
class _FakeTransport implements BiliAuthTransport {
  _FakeTransport(this.handler);

  final Map<String, dynamic> Function(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) handler;

  final List<({String method, String path, Map<String, dynamic>? body})> calls =
      <({String method, String path, Map<String, dynamic>? body})>[];

  @override
  Future<Map<String, dynamic>> requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    calls.add((method: method, path: path, body: body));
    return handler(method, path, body);
  }
}

void main() {
  group('startQrLogin', () {
    test('成功：解析 taskId / qrUrl / qrImage，方法为 POST start 路径', () async {
      final _FakeTransport transport = _FakeTransport((_, __, ___) =>
          <String, dynamic>{
            'code': 0,
            'taskId': 'T-1',
            'qrUrl': 'https://bili/qr',
            'qrImage': 'data:image/png;base64,AAAA',
            'msg': 'ok',
          });
      final BiliQrStart start =
          await BiliAuthClient(transport: transport).startQrLogin();

      expect(start.taskId, 'T-1');
      expect(start.qrUrl, 'https://bili/qr');
      expect(start.qrDataUrl, 'data:image/png;base64,AAAA');
      expect(transport.calls.single.method, 'POST');
      expect(transport.calls.single.path, BiliAuthPaths.start);
    });

    test('code 为字符串 "0" 亦视为成功（线格式宽容）', () async {
      final _FakeTransport transport = _FakeTransport((_, __, ___) =>
          <String, dynamic>{'code': '0', 'taskId': 'T-2'});
      final BiliQrStart start =
          await BiliAuthClient(transport: transport).startQrLogin();
      expect(start.taskId, 'T-2');
    });

    test('业务错误码：抛错并携带服务端 msg', () async {
      final _FakeTransport transport = _FakeTransport((_, __, ___) =>
          <String, dynamic>{'code': 400, 'msg': '风控拦截'});
      await expectLater(
        BiliAuthClient(transport: transport).startQrLogin(),
        throwsA(
          isA<BiliAuthException>()
              .having((BiliAuthException e) => e.message, 'message', '风控拦截'),
        ),
      );
    });

    test('code=0 但 taskId 缺失：抛格式异常', () async {
      final _FakeTransport transport =
          _FakeTransport((_, __, ___) => <String, dynamic>{'code': 0});
      await expectLater(
        BiliAuthClient(transport: transport).startQrLogin(),
        throwsA(
          isA<BiliAuthException>().having(
            (BiliAuthException e) => e.message,
            'message',
            '二维码数据格式异常',
          ),
        ),
      );
    });
  });

  group('pollQrLogin', () {
    test('等待档：body 携带 provider=bili 与 taskId', () async {
      final _FakeTransport transport = _FakeTransport((_, __, ___) =>
          <String, dynamic>{'status': 'waiting', 'msg': ''});
      final BiliPollResult result =
          await BiliAuthClient(transport: transport).pollQrLogin('T-9');

      expect(result.status, BiliAuthStatus.waiting);
      expect(result.terminal, isFalse);
      expect(transport.calls.single.method, 'POST');
      expect(transport.calls.single.path, BiliAuthPaths.poll);
      expect(transport.calls.single.body, <String, dynamic>{
        'provider': 'bili',
        'taskId': 'T-9',
      });
    });

    test('waiting + 「已扫码」文案 → scanned', () async {
      final _FakeTransport transport = _FakeTransport((_, __, ___) =>
          <String, dynamic>{'status': 'waiting', 'msg': '已扫码，请在手机确认'});
      final BiliPollResult result =
          await BiliAuthClient(transport: transport).pollQrLogin('T');
      expect(result.status, BiliAuthStatus.scanned);
    });

    test('成功档：terminal 透传', () async {
      final _FakeTransport transport = _FakeTransport((_, __, ___) =>
          <String, dynamic>{'status': 'success', 'terminal': true});
      final BiliPollResult result =
          await BiliAuthClient(transport: transport).pollQrLogin('T');
      expect(result.status, BiliAuthStatus.success);
      expect(result.terminal, isTrue);
    });
  });

  test('cancelQrLogin：失败不冒泡（幂等容错）', () async {
    final _FakeTransport transport = _FakeTransport((_, __, ___) {
      throw const BiliAuthException('boom');
    });
    await expectLater(
      BiliAuthClient(transport: transport).cancelQrLogin('T'),
      completes,
    );
    expect(transport.calls.single.path, BiliAuthPaths.cancel);
  });

  test('saveCookie / clearCookie：PUT / DELETE 到 cookie 路径', () async {
    final _FakeTransport transport =
        _FakeTransport((_, __, ___) => <String, dynamic>{'code': 0});
    final BiliAuthClient client = BiliAuthClient(transport: transport);

    await client.saveCookie('SESSDATA=1');
    await client.clearCookie();

    expect(transport.calls[0].method, 'PUT');
    expect(transport.calls[0].path, BiliAuthPaths.cookie);
    expect(transport.calls[0].body, <String, dynamic>{'cookie': 'SESSDATA=1'});
    expect(transport.calls[1].method, 'DELETE');
    expect(transport.calls[1].path, BiliAuthPaths.cookie);
  });

  test('缺省「未接入」传输：报 Node 未就绪', () async {
    await expectLater(
      const UnavailableBiliAuthTransport().requestJson('POST', '/x'),
      throwsA(
        isA<BiliAuthException>().having(
          (BiliAuthException e) => e.message,
          'message',
          'Node 常驻系统未就绪',
        ),
      ),
    );
  });
}
