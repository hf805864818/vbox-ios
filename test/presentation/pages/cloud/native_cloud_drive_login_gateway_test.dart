/// 表现层单测：原生扫码登录网关（批次 F · F-05 余项）。
///
/// 用假 [SpiderHttpTransport] 离线验证 UC / 百度 / 夸克三条原生扫码链的
/// start → poll → 落库时序（对齐 iOS `NativeCloudQRLoginView`）。
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/cloud_drive_credential_store.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive_login.dart';
import 'package:vbox/platform/spider/spider_http_bridge.dart';
import 'package:vbox/presentation/pages/cloud/login_gateway.dart';
import 'package:vbox/presentation/pages/cloud/native_cloud_drive_login_gateway.dart';

/// 假传输：按请求 URL 路由预设响应。
class _FakeTransport implements SpiderHttpTransport {
  _FakeTransport(this.handler);

  final SpiderTransportResponse Function(SpiderTransportRequest request) handler;

  @override
  Future<SpiderTransportResponse> send(SpiderTransportRequest request) async =>
      handler(request);
}

SpiderTransportResponse _json(String body) => SpiderTransportResponse(
      status: 200,
      headers: const <String, String>{},
      bodyBytes: utf8.encode(body),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PrefsManager pm;
  late CloudDriveCredentialStore store;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    pm = PrefsManager.instance;
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
    store = CloudDriveCredentialStore(pm);
  });

  NativeCloudDriveLoginGateway gatewayWith(
    SpiderTransportResponse Function(SpiderTransportRequest request) handler,
  ) =>
      NativeCloudDriveLoginGateway(
        bridge: SpiderHttpBridge(transport: _FakeTransport(handler)),
        credentialStore: store,
      );

  group('supports', () {
    test('仅覆盖 UC / 百度 / 夸克 / 天翼189 + nativeQr', () {
      for (final CloudDriveType t in <CloudDriveType>[
        CloudDriveType.uc,
        CloudDriveType.baidu,
        CloudDriveType.quark,
        CloudDriveType.pan189, // P2-1
      ]) {
        expect(
          NativeCloudDriveLoginGateway.supports(t, CloudDriveLoginMode.nativeQr),
          isTrue,
          reason: '$t',
        );
        expect(
          NativeCloudDriveLoginGateway.supports(t, CloudDriveLoginMode.nodeQr),
          isFalse,
          reason: '$t',
        );
      }
      expect(
        NativeCloudDriveLoginGateway.supports(
          CloudDriveType.ali,
          CloudDriveLoginMode.nativeQr,
        ),
        isFalse,
      );
    });
  });

  test('UC 扫码：token → service_ticket → 落 __pus Cookie', () async {
    final NativeCloudDriveLoginGateway gateway = gatewayWith(
      (SpiderTransportRequest r) {
        final String url = r.url.toString();
        if (url.contains('getTokenForQrcodeLogin')) {
          return _json('{"token":"T1"}');
        }
        if (url.contains('getServiceTicketByQrcodeToken')) {
          return _json('{"data":{"members":{"service_ticket":"ST1"}}}');
        }
        if (url.contains('drive.uc.cn/account/mobileinfo')) {
          return _json('{"data":{"__pus":"pus1","kps":"kps1","uid":"uid1"}}');
        }
        return _json('{}');
      },
    );

    final CloudDriveQrTask task = await gateway.startQrLogin(
      type: CloudDriveType.uc,
      mode: CloudDriveLoginMode.nativeQr,
    );
    expect(task.qrDataUrl, startsWith(kQrDataContentPrefix));

    final CloudDriveLoginPhase phase = await gateway.pollQrLogin(
      type: CloudDriveType.uc,
      mode: CloudDriveLoginMode.nativeQr,
      taskId: task.taskId,
    );
    expect(phase, CloudDriveLoginPhase.success);

    final CloudDriveCredential? cred =
        await store.credential(CloudDriveType.uc);
    expect(cred, isNotNull);
    expect(cred!.cookie, contains('__pus=pus1'));
  });

  test('百度扫码：图片 URL 直出 → 逐跳收集 BDUSS/STOKEN', () async {
    final NativeCloudDriveLoginGateway gateway = gatewayWith(
      (SpiderTransportRequest r) {
        final String url = r.url.toString();
        if (url.contains('getqrcode')) {
          return _json(
            '{"sign":"SIG","imgurl":"https://passport.baidu.com/x.png",'
            '"channel_id":"CID"}',
          );
        }
        if (url.contains('channel/unicast')) {
          return _json(
            '{"errno":0,"channel_v":'
            '"{\\"status\\":2,\\"v\\":\\"https://passport.baidu.com/?bduss=BD1\\"}"}',
          );
        }
        if (url.contains('qrbdusslogin')) {
          return SpiderTransportResponse(
            status: 302,
            headers: const <String, String>{
              'location': 'https://passport.baidu.com/login/final',
              'set-cookie': 'BDUSS=b1; Path=/',
            },
            bodyBytes: utf8.encode(''),
          );
        }
        if (url.contains('/login/final')) {
          return SpiderTransportResponse(
            status: 200,
            headers: const <String, String>{'set-cookie': 'STOKEN=s1; Path=/'},
            bodyBytes: utf8.encode('{}'),
          );
        }
        return _json('{}');
      },
    );

    final CloudDriveQrTask task = await gateway.startQrLogin(
      type: CloudDriveType.baidu,
      mode: CloudDriveLoginMode.nativeQr,
    );
    // 百度返回图片直链（非 data URL / qr_data: 文本）。
    expect(task.qrDataUrl, 'https://passport.baidu.com/x.png');

    final CloudDriveLoginPhase phase = await gateway.pollQrLogin(
      type: CloudDriveType.baidu,
      mode: CloudDriveLoginMode.nativeQr,
      taskId: task.taskId,
    );
    expect(phase, CloudDriveLoginPhase.success);

    final CloudDriveCredential? cred =
        await store.credential(CloudDriveType.baidu);
    expect(cred, isNotNull);
    expect(cred!.cookie, contains('BDUSS=b1'));
    expect(cred.cookie, contains('STOKEN=s1'));
  });

  test('夸克扫码：token → service_ticket → 落 __kps/__pus/__uid Cookie', () async {
    final NativeCloudDriveLoginGateway gateway = gatewayWith(
      (SpiderTransportRequest r) {
        final String url = r.url.toString();
        if (url.contains('getTokenForQrcodeLogin')) {
          return _json(
            '{"status":2000000,"data":{"members":{"token":"QT"}}}',
          );
        }
        if (url.contains('getServiceTicketByQrcodeToken')) {
          return _json(
            '{"status":2000000,"data":{"members":{"service_ticket":"QST"}}}',
          );
        }
        if (url.contains('pan.quark.cn/account/info')) {
          return SpiderTransportResponse(
            status: 200,
            headers: const <String, String>{
              'set-cookie': '__kps=k1; __pus=p1; __uid=u1',
            },
            bodyBytes: utf8.encode('{"data":{"nickname":"nick"}}'),
          );
        }
        return _json('{}');
      },
    );

    final CloudDriveQrTask task = await gateway.startQrLogin(
      type: CloudDriveType.quark,
      mode: CloudDriveLoginMode.nativeQr,
    );
    expect(task.qrDataUrl, startsWith(kQrDataContentPrefix));

    final CloudDriveLoginPhase phase = await gateway.pollQrLogin(
      type: CloudDriveType.quark,
      mode: CloudDriveLoginMode.nativeQr,
      taskId: task.taskId,
    );
    expect(phase, CloudDriveLoginPhase.success);

    final CloudDriveCredential? cred =
        await store.credential(CloudDriveType.quark);
    expect(cred, isNotNull);
    expect(cred!.cookie, contains('__kps=k1'));
  });

  test('夸克扫码交换：跨 302 重定向逐跳收集 Cookie（对齐 iOS 三联兜底）', () async {
    final NativeCloudDriveLoginGateway gateway = gatewayWith(
      (SpiderTransportRequest r) {
        final String url = r.url.toString();
        if (url.contains('getTokenForQrcodeLogin')) {
          return _json(
            '{"status":2000000,"data":{"members":{"token":"QT2"}}}',
          );
        }
        if (url.contains('getServiceTicketByQrcodeToken')) {
          return _json(
            '{"status":2000000,"data":{"members":{"service_ticket":"QST2"}}}',
          );
        }
        if (url.contains('pan.quark.cn/account/info')) {
          // 302 → 重定向跳上带 __kps，最终 200 响应带 __pus/__uid。
          return const SpiderTransportResponse(
            status: 302,
            headers: <String, String>{
              'location': 'https://pan.quark.cn/account/finish',
              'set-cookie': '__kps=k2; Path=/',
            },
            setCookies: <String>['__kps=k2; Path=/'],
            bodyBytes: <int>[],
          );
        }
        if (url.contains('pan.quark.cn/account/finish')) {
          return const SpiderTransportResponse(
            status: 200,
            headers: <String, String>{'set-cookie': '__pus=p2; __uid=u2'},
            setCookies: <String>['__pus=p2', '__uid=u2'],
            bodyBytes: <int>[],
          );
        }
        return _json('{}');
      },
    );

    final CloudDriveQrTask task = await gateway.startQrLogin(
      type: CloudDriveType.quark,
      mode: CloudDriveLoginMode.nativeQr,
    );
    await gateway.pollQrLogin(
      type: CloudDriveType.quark,
      mode: CloudDriveLoginMode.nativeQr,
      taskId: task.taskId,
    );

    final CloudDriveCredential? cred =
        await store.credential(CloudDriveType.quark);
    expect(cred, isNotNull);
    expect(cred!.cookie, contains('__kps=k2'));
    expect(cred.cookie, contains('__pus=p2'));
    expect(cred.cookie, contains('__uid=u2'));
  });

  test('未覆盖网盘：即时报「原生扫码尚未接入」', () async {
    final NativeCloudDriveLoginGateway gateway = gatewayWith((_) => _json('{}'));
    await expectLater(
      gateway.startQrLogin(
        type: CloudDriveType.ali,
        mode: CloudDriveLoginMode.nativeQr,
      ),
      throwsA(isA<CloudDriveLoginException>()),
    );
  });

  test('P2-1 天翼189 扫码：uuid/ticket → 状态机 → loginUrl 逐跳收 Cookie', () async {
    int pollCount = 0;
    final NativeCloudDriveLoginGateway gateway = gatewayWith(
      (SpiderTransportRequest r) {
        final String url = r.url.toString();
        if (url.contains('getQRCodeInfo.action')) {
          return _json('{"resCode":0,"data":{"uuid":"U1","ticket":"TK1"}}');
        }
        if (url.contains('queryQRCodeStatus.action')) {
          // 状态机推进：0=待扫 → 1=已扫 → 2=成功(loginUrl)。
          pollCount++;
          if (pollCount == 1) return _json('{"resCode":0,"data":{"status":0}}');
          if (pollCount == 2) return _json('{"resCode":0,"data":{"status":1}}');
          return _json(
            '{"resCode":0,"data":{"status":2,'
            '"loginUrl":"https://cloud.189.cn/loginsucc?token=abc"}}',
          );
        }
        if (url.contains('loginsucc')) {
          // 302 → 逐跳收集（对齐 iOS session cookie jar 语义）。
          return const SpiderTransportResponse(
            status: 302,
            headers: <String, String>{
              'location': 'https://cloud.189.cn/finish',
              'set-cookie': 'ssotoken=st1; Path=/',
            },
            bodyBytes: <int>[],
          );
        }
        if (url.contains('finish')) {
          return const SpiderTransportResponse(
            status: 200,
            headers: <String, String>{
              'set-cookie': 'usersession=us1; Path=/',
            },
            bodyBytes: <int>[],
          );
        }
        return _json('{}');
      },
    );

    final CloudDriveQrTask task = await gateway.startQrLogin(
      type: CloudDriveType.pan189,
      mode: CloudDriveLoginMode.nativeQr,
    );
    expect(
      task.qrDataUrl,
      '${kQrDataContentPrefix}https://cloud.189.cn/qrlogin?uuid=U1',
    );

    expect(
      await gateway.pollQrLogin(
        type: CloudDriveType.pan189,
        mode: CloudDriveLoginMode.nativeQr,
        taskId: task.taskId,
      ),
      CloudDriveLoginPhase.waitingScan,
    );
    expect(
      await gateway.pollQrLogin(
        type: CloudDriveType.pan189,
        mode: CloudDriveLoginMode.nativeQr,
        taskId: task.taskId,
      ),
      CloudDriveLoginPhase.scanned,
    );
    expect(
      await gateway.pollQrLogin(
        type: CloudDriveType.pan189,
        mode: CloudDriveLoginMode.nativeQr,
        taskId: task.taskId,
      ),
      CloudDriveLoginPhase.success,
    );

    final CloudDriveCredential? cred =
        await store.credential(CloudDriveType.pan189);
    expect(cred, isNotNull);
    expect(cred!.cookie, contains('ssotoken=st1'));
    expect(cred.cookie, contains('usersession=us1'));
    expect(cred.statusMessage, '扫码授权成功');
  });

  test('P2-1 天翼189 过期：status=-1 → 抛「二维码已过期」并销毁任务', () async {
    final NativeCloudDriveLoginGateway gateway = gatewayWith(
      (SpiderTransportRequest r) {
        final String url = r.url.toString();
        if (url.contains('getQRCodeInfo.action')) {
          return _json('{"resCode":0,"data":{"uuid":"U2","ticket":"TK2"}}');
        }
        if (url.contains('queryQRCodeStatus.action')) {
          return _json('{"resCode":0,"data":{"status":-1}}');
        }
        return _json('{}');
      },
    );
    final CloudDriveQrTask task = await gateway.startQrLogin(
      type: CloudDriveType.pan189,
      mode: CloudDriveLoginMode.nativeQr,
    );
    await expectLater(
      gateway.pollQrLogin(
        type: CloudDriveType.pan189,
        mode: CloudDriveLoginMode.nativeQr,
        taskId: task.taskId,
      ),
      throwsA(
        isA<CloudDriveLoginException>()
            .having((CloudDriveLoginException e) => e.message, 'message', '二维码已过期，请重试'),
      ),
    );
    // 任务已销毁 → 再次轮询报「任务已失效」。
    await expectLater(
      gateway.pollQrLogin(
        type: CloudDriveType.pan189,
        mode: CloudDriveLoginMode.nativeQr,
        taskId: task.taskId,
      ),
      throwsA(isA<CloudDriveLoginException>()),
    );
  });
}
