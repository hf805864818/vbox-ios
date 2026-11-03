/// 表现层单测：Node 常驻系统登录网关（批次 F · F-05）。
///
/// 验证 [NodeCloudDriveLoginGateway] 的 B 站扫码链：支持判定、start/poll 阶段
/// 映射、成功时回收凭据（saveProfile）、以及按方式分档的「未就绪」文案。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/cloud_drive_credential_store.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/remote/bili_auth_client.dart';
import 'package:vbox/data/datasources/remote/node_credential_sync_service.dart';
import 'package:vbox/data/datasources/remote/node_login_client.dart';
import 'package:vbox/domain/entities/cloud/bili_auth.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive_login.dart';
import 'package:vbox/domain/entities/cloud/node_login.dart';
import 'package:vbox/presentation/pages/cloud/aliyun_pg_login_gateway.dart';
import 'package:vbox/presentation/pages/cloud/login_gateway.dart';
import 'package:vbox/presentation/pages/cloud/native_cloud_drive_login_gateway.dart';
import 'package:vbox/presentation/pages/cloud/node_login_gateway.dart';

/// 假 B 站传输：按路径返回预设响应。
class _FakeBiliTransport implements BiliAuthTransport {
  _FakeBiliTransport(this.handler);

  final Map<String, dynamic> Function(String method, String path) handler;

  @override
  Future<Map<String, dynamic>> requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async =>
      handler(method, path);
}

/// 假 Node 登录传输：按 (method,path,body) 返回预设 JSON，并记录调用。
class _FakeNodeLoginTransport implements NodeLoginTransport {
  _FakeNodeLoginTransport(this.handler);

  final Map<String, dynamic> Function(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) handler;
  final List<String> calls = <String>[];

  @override
  Future<Map<String, dynamic>> requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    calls.add('$method $path');
    return handler(method, path, body);
  }
}

/// 记录调用的 Node 凭据客户端。
class _RecordingCredentialClient implements NodeCredentialApiClient {
  final List<String> calls = <String>[];

  @override
  Future<Map<String, dynamic>> requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    calls.add('$method $path');
    return <String, dynamic>{'code': 0};
  }
}

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

  NodeCloudDriveLoginGateway gatewayWith(
    Map<String, dynamic> Function(String method, String path) handler, {
    _RecordingCredentialClient? credentialClient,
    _FakeNodeLoginTransport? nodeTransport,
  }) =>
      NodeCloudDriveLoginGateway(
        biliClient: BiliAuthClient(transport: _FakeBiliTransport(handler)),
        nodeClient: NodeLoginClient(
          transport: nodeTransport ??
              _FakeNodeLoginTransport((_, __, ___) => <String, dynamic>{
                    'code': 0,
                  }),
        ),
        credentialSync: credentialClient == null
            ? null
            : NodeCredentialSyncService(
                store: store,
                client: credentialClient,
              ),
      );

  group('supports / 文案', () {
    test('B 站扫码 + Node 托管盘（F-P16）受支持', () {
      bool sup(CloudDriveType t, CloudDriveLoginMode m) =>
          NodeCloudDriveLoginGateway.supports(t, m);
      // B 站扫码（nativeQr 亦归 Node 网关）。
      expect(sup(CloudDriveType.bilibili, CloudDriveLoginMode.nodeQr), isTrue);
      expect(sup(CloudDriveType.bilibili, CloudDriveLoginMode.nativeQr), isTrue);
      // 通用扫码：115 / 夸克Node / 百度Node / UCNode。
      for (final CloudDriveType t in <CloudDriveType>[
        CloudDriveType.one15,
        CloudDriveType.quarkNode,
        CloudDriveType.baiduNode,
        CloudDriveType.ucNode,
      ]) {
        expect(sup(t, CloudDriveLoginMode.nodeQr), isTrue, reason: '$t');
      }
      // 短信：光鸭 / 139 / 迅雷。
      for (final CloudDriveType t in <CloudDriveType>[
        CloudDriveType.guangya,
        CloudDriveType.pan139,
        CloudDriveType.xunlei,
      ]) {
        expect(sup(t, CloudDriveLoginMode.nodeSms), isTrue, reason: '$t');
      }
      // 账号：123 / 189 / 蜗牛。
      for (final CloudDriveType t in <CloudDriveType>[
        CloudDriveType.pan123,
        CloudDriveType.pan189,
        CloudDriveType.woniu4k,
      ]) {
        expect(sup(t, CloudDriveLoginMode.nodeAccount), isTrue, reason: '$t');
      }
      // 未接入 / 不匹配档。
      expect(sup(CloudDriveType.bilibili, CloudDriveLoginMode.nodeSms), isFalse);
      expect(sup(CloudDriveType.ali, CloudDriveLoginMode.nativeQr), isFalse);
      expect(sup(CloudDriveType.pan123, CloudDriveLoginMode.nodeQr), isFalse);
    });

    test('不支持档：Node 方式报「未就绪」，原生方式报「未接入」', () async {
      final NodeCloudDriveLoginGateway gateway = gatewayWith((_, __) => <String, dynamic>{});
      await expectLater(
        gateway.startQrLogin(
          type: CloudDriveType.bilibili,
          mode: CloudDriveLoginMode.nodeSms,
        ),
        throwsA(
          isA<CloudDriveLoginException>().having(
            (CloudDriveLoginException e) => e.message,
            'message',
            'Node 常驻系统未就绪',
          ),
        ),
      );
      await expectLater(
        gateway.startQrLogin(
          type: CloudDriveType.ali,
          mode: CloudDriveLoginMode.nativeQr,
        ),
        throwsA(
          isA<CloudDriveLoginException>().having(
            (CloudDriveLoginException e) => e.message,
            'message',
            '原生登录链路尚未接入',
          ),
        ),
      );
    });
  });

  group('startQrLogin', () {
    test('B 站扫码返回 taskId 与二维码 data URL', () async {
      final NodeCloudDriveLoginGateway gateway = gatewayWith((_, __) =>
          <String, dynamic>{
            'code': 0,
            'taskId': 'T-1',
            'qrImage': 'data:image/png;base64,AAAA',
          });
      final CloudDriveQrTask task = await gateway.startQrLogin(
        type: CloudDriveType.bilibili,
        mode: CloudDriveLoginMode.nativeQr,
      );
      expect(task.taskId, 'T-1');
      expect(task.qrDataUrl, 'data:image/png;base64,AAAA');
    });

    test('缺图时 qrDataUrl 为空串（UI 展示占位）', () async {
      final NodeCloudDriveLoginGateway gateway = gatewayWith((_, __) =>
          <String, dynamic>{'code': 0, 'taskId': 'T-2'});
      final CloudDriveQrTask task = await gateway.startQrLogin(
        type: CloudDriveType.bilibili,
        mode: CloudDriveLoginMode.nodeQr,
      );
      expect(task.qrDataUrl, '');
    });

    test('P2-3：qrImage 缺失但 qrUrl 存在 → 标记 qr_data: 本地编码兜底', () async {
      final NodeCloudDriveLoginGateway gateway = gatewayWith((_, __) =>
          <String, dynamic>{
            'code': 0,
            'taskId': 'T-3',
            'qrUrl': 'https://passport.baidu.com/v2/api/qrcode?sign=xyz',
          });
      final CloudDriveQrTask task = await gateway.startQrLogin(
        type: CloudDriveType.bilibili,
        mode: CloudDriveLoginMode.nativeQr,
      );
      expect(task.taskId, 'T-3');
      expect(
        task.qrDataUrl,
        '${kQrDataContentPrefix}https://passport.baidu.com/v2/api/qrcode?sign=xyz',
      );
    });
  });

  group('pollQrLogin', () {
    test('成功：返回 success 并回收凭据（saveProfile → GET credentials）', () async {
      final _RecordingCredentialClient credential = _RecordingCredentialClient();
      final NodeCloudDriveLoginGateway gateway = gatewayWith(
        (_, __) => <String, dynamic>{'status': 'success', 'terminal': true},
        credentialClient: credential,
      );
      final CloudDriveLoginPhase phase = await gateway.pollQrLogin(
        type: CloudDriveType.bilibili,
        mode: CloudDriveLoginMode.nativeQr,
        taskId: 'T',
      );
      expect(phase, CloudDriveLoginPhase.success);
      expect(credential.calls, <String>['GET /website/api/credentials']);
    });

    test('已扫码 → scanned 阶段，不回收凭据', () async {
      final _RecordingCredentialClient credential = _RecordingCredentialClient();
      final NodeCloudDriveLoginGateway gateway = gatewayWith(
        (_, __) => <String, dynamic>{'status': 'waiting', 'msg': '已扫码，请确认'},
        credentialClient: credential,
      );
      final CloudDriveLoginPhase phase = await gateway.pollQrLogin(
        type: CloudDriveType.bilibili,
        mode: CloudDriveLoginMode.nativeQr,
        taskId: 'T',
      );
      expect(phase, CloudDriveLoginPhase.scanned);
      expect(credential.calls, isEmpty);
    });

    test('过期 / 失败：抛错并携带服务端 msg', () async {
      final NodeCloudDriveLoginGateway expired = gatewayWith(
        (_, __) => <String, dynamic>{'status': 'expired', 'msg': '二维码过期'},
      );
      await expectLater(
        expired.pollQrLogin(
          type: CloudDriveType.bilibili,
          mode: CloudDriveLoginMode.nativeQr,
          taskId: 'T',
        ),
        throwsA(
          isA<CloudDriveLoginException>()
              .having((CloudDriveLoginException e) => e.message, 'message', '二维码过期'),
        ),
      );

      final NodeCloudDriveLoginGateway failed = gatewayWith(
        (_, __) => <String, dynamic>{'status': 'error', 'msg': '风控'},
      );
      await expectLater(
        failed.pollQrLogin(
          type: CloudDriveType.bilibili,
          mode: CloudDriveLoginMode.nativeQr,
          taskId: 'T',
        ),
        throwsA(
          isA<CloudDriveLoginException>()
              .having((CloudDriveLoginException e) => e.message, 'message', '风控'),
        ),
      );
    });

    test('waiting 且 terminal=true（无 msg）→ 抛「扫码登录已结束」', () async {
      final NodeCloudDriveLoginGateway gateway = gatewayWith(
        (_, __) => <String, dynamic>{'status': 'waiting', 'terminal': true},
      );
      await expectLater(
        gateway.pollQrLogin(
          type: CloudDriveType.bilibili,
          mode: CloudDriveLoginMode.nativeQr,
          taskId: 'T',
        ),
        throwsA(
          isA<CloudDriveLoginException>().having(
            (CloudDriveLoginException e) => e.message,
            'message',
            '扫码登录已结束',
          ),
        ),
      );
    });
  });

  test('defaultCloudDriveLoginGateway：B 站扫码路由 Node 网关，其余回退未接入', () {
    expect(
      defaultCloudDriveLoginGateway(
        CloudDriveType.bilibili,
        CloudDriveLoginMode.nodeQr,
      ),
      isA<NodeCloudDriveLoginGateway>(),
    );
    expect(
      defaultCloudDriveLoginGateway(
        CloudDriveType.ali,
        CloudDriveLoginMode.pgQr,
      ),
      isA<AliyunPgLoginGateway>(),
    );
    expect(
      defaultCloudDriveLoginGateway(
        CloudDriveType.ali,
        CloudDriveLoginMode.nativeQr,
      ),
      isA<UnavailableCloudDriveLoginGateway>(),
    );
    // 原生扫码档（UC / 百度 / 夸克）→ 原生网关（直连官方接口，不走 Node）。
    expect(
      defaultCloudDriveLoginGateway(
        CloudDriveType.uc,
        CloudDriveLoginMode.nativeQr,
      ),
      isA<NativeCloudDriveLoginGateway>(),
    );
    expect(
      defaultCloudDriveLoginGateway(
        CloudDriveType.baidu,
        CloudDriveLoginMode.nativeQr,
      ),
      isA<NativeCloudDriveLoginGateway>(),
    );
    expect(
      defaultCloudDriveLoginGateway(
        CloudDriveType.quark,
        CloudDriveLoginMode.nativeQr,
      ),
      isA<NativeCloudDriveLoginGateway>(),
    );
    // B 站短信档不受支持 → 回退未接入。
    expect(
      defaultCloudDriveLoginGateway(
        CloudDriveType.bilibili,
        CloudDriveLoginMode.nodeSms,
      ),
      isA<UnavailableCloudDriveLoginGateway>(),
    );
  });

  test('cancelQrLogin 幂等：失败不冒泡', () async {
    final NodeCloudDriveLoginGateway gateway = gatewayWith((_, __) {
      throw const BiliAuthException('boom');
    });
    await expectLater(gateway.cancelQrLogin('T'), completes);
  });

  test('短信 / 账号入口：统一报 Node 未就绪', () async {
    final NodeCloudDriveLoginGateway gateway = gatewayWith((_, __) => <String, dynamic>{});
    await expectLater(
      gateway.sendSmsCode(type: CloudDriveType.bilibili, phone: '1'),
      throwsA(isA<CloudDriveLoginException>()),
    );
    await expectLater(
      gateway.submitSmsCode(
        type: CloudDriveType.bilibili,
        taskId: 'T',
        code: '1',
      ),
      throwsA(isA<CloudDriveLoginException>()),
    );
    await expectLater(
      gateway.submitAccountLogin(
        type: CloudDriveType.bilibili,
        mode: CloudDriveLoginMode.nodeAccount,
        account: 'a',
        password: 'p',
      ),
      throwsA(isA<CloudDriveLoginException>()),
    );
  });

  group('Node 托管盘登录（F-P16）', () {
    test('115 扫码：provider=pan115 且成功回收凭据', () async {
      final _FakeNodeLoginTransport node =
          _FakeNodeLoginTransport((String m, String p, Map<String, dynamic>? b) {
        if (p == NodeLoginPaths.qrStart) {
          return <String, dynamic>{
            'code': 0,
            'taskId': 'T1',
            'qrImage': 'data:image/png;base64,AA',
          };
        }
        if (p == NodeLoginPaths.qrPoll) {
          return <String, dynamic>{
            'code': 0,
            'status': 'success',
            'terminal': true,
          };
        }
        return <String, dynamic>{'code': 0};
      });
      final _RecordingCredentialClient cred = _RecordingCredentialClient();
      final NodeCloudDriveLoginGateway gateway = gatewayWith(
        (_, __) => <String, dynamic>{},
        nodeTransport: node,
        credentialClient: cred,
      );
      final CloudDriveQrTask task = await gateway.startQrLogin(
        type: CloudDriveType.one15,
        mode: CloudDriveLoginMode.nodeQr,
      );
      expect(task.taskId, 'T1');
      expect(task.qrDataUrl, 'data:image/png;base64,AA');
      final CloudDriveLoginPhase phase = await gateway.pollQrLogin(
        type: CloudDriveType.one15,
        mode: CloudDriveLoginMode.nodeQr,
        taskId: 'T1',
      );
      expect(phase, CloudDriveLoginPhase.success);
      expect(cred.calls, <String>['GET /website/api/credentials']);
    });

    test('通用扫码 waiting + 「已扫码」→ scanned 阶段', () async {
      final _FakeNodeLoginTransport node = _FakeNodeLoginTransport(
        (_, __, ___) => <String, dynamic>{
          'code': 0,
          'status': 'waiting',
          'msg': '已扫码，请在手机上确认',
        },
      );
      final NodeCloudDriveLoginGateway gateway =
          gatewayWith((_, __) => <String, dynamic>{}, nodeTransport: node);
      final CloudDriveLoginPhase phase = await gateway.pollQrLogin(
        type: CloudDriveType.ucNode,
        mode: CloudDriveLoginMode.nodeQr,
        taskId: 'T',
      );
      expect(phase, CloudDriveLoginPhase.scanned);
    });

    test('光鸭短信：send 返回 taskId，login 用暂存 taskId 并回收', () async {
      final _FakeNodeLoginTransport node =
          _FakeNodeLoginTransport((String m, String p, Map<String, dynamic>? b) {
        if (p == NodeLoginPaths.guangyaSmsSend) {
          return <String, dynamic>{'code': 0, 'taskId': 'G1', 'msg': '已发送'};
        }
        return <String, dynamic>{'code': 0};
      });
      final _RecordingCredentialClient cred = _RecordingCredentialClient();
      final NodeCloudDriveLoginGateway gateway = gatewayWith(
        (_, __) => <String, dynamic>{},
        nodeTransport: node,
        credentialClient: cred,
      );
      final String taskId = await gateway.sendSmsCode(
        type: CloudDriveType.guangya,
        phone: '13800000000',
      );
      expect(taskId, 'G1');
      await gateway.submitSmsCode(
        type: CloudDriveType.guangya,
        taskId: '',
        code: '1234',
      );
      expect(node.calls, contains('POST ${NodeLoginPaths.guangyaSmsLogin}'));
      expect(cred.calls, <String>['GET /website/api/credentials']);
    });

    test('139 短信：send 缓存 headers，login 走 new139 端点', () async {
      final _FakeNodeLoginTransport node =
          _FakeNodeLoginTransport((String m, String p, Map<String, dynamic>? b) {
        if (p == NodeLoginPaths.new139SmsSend) {
          return <String, dynamic>{
            'code': 0,
            'loginHeaders': <String, dynamic>{'X-A': '1'},
            'captchaUrl': 'https://c/1',
            'msg': '已发送',
          };
        }
        return <String, dynamic>{'code': 0};
      });
      final NodeCloudDriveLoginGateway gateway =
          gatewayWith((_, __) => <String, dynamic>{}, nodeTransport: node);
      await gateway.sendSmsCode(type: CloudDriveType.pan139, phone: '139');
      // 139 触发滑块 → 网关暴露 captchaUrl 供 UI 内嵌（Web-R3）。
      expect(
        gateway.pendingCaptchaUrl(CloudDriveType.pan139),
        'https://c/1',
      );
      await gateway.submitSmsCode(
        type: CloudDriveType.pan139,
        taskId: '',
        code: '0000',
      );
      expect(node.calls, contains('POST ${NodeLoginPaths.new139Login}'));
    });

    test('迅雷短信：走 thunder 端点', () async {
      final _FakeNodeLoginTransport node = _FakeNodeLoginTransport(
        (_, __, ___) => <String, dynamic>{'code': 0},
      );
      final NodeCloudDriveLoginGateway gateway =
          gatewayWith((_, __) => <String, dynamic>{}, nodeTransport: node);
      await gateway.sendSmsCode(type: CloudDriveType.xunlei, phone: '139');
      await gateway.submitSmsCode(
        type: CloudDriveType.xunlei,
        taskId: '',
        code: '9999',
      );
      expect(node.calls, contains('POST ${NodeLoginPaths.thunderSmsSend}'));
      expect(node.calls, contains('POST ${NodeLoginPaths.thunderSmsLogin}'));
    });

    test('123 账号登录并回收凭据', () async {
      final _FakeNodeLoginTransport node = _FakeNodeLoginTransport(
        (_, __, ___) => <String, dynamic>{'code': 0},
      );
      final _RecordingCredentialClient cred = _RecordingCredentialClient();
      final NodeCloudDriveLoginGateway gateway = gatewayWith(
        (_, __) => <String, dynamic>{},
        nodeTransport: node,
        credentialClient: cred,
      );
      await gateway.submitAccountLogin(
        type: CloudDriveType.pan123,
        mode: CloudDriveLoginMode.nodeAccount,
        account: 'a',
        password: 'p',
      );
      expect(node.calls, contains('PUT ${NodeLoginPaths.pan123Account}'));
      expect(cred.calls, <String>['GET /website/api/credentials']);
    });

    test('蜗牛：loadAccountCaptcha 供图 + submitAccountLogin 带 captchaCode', () async {
      final _FakeNodeLoginTransport node =
          _FakeNodeLoginTransport((String m, String p, Map<String, dynamic>? b) {
        if (p == NodeLoginPaths.woniuVerify) {
          return <String, dynamic>{
            'code': 0,
            'data': <String, dynamic>{
              'taskId': 'W1',
              'image': 'data:image/png;base64,AA',
            },
          };
        }
        return <String, dynamic>{'code': 0};
      });
      final _RecordingCredentialClient cred = _RecordingCredentialClient();
      final NodeCloudDriveLoginGateway gateway = gatewayWith(
        (_, __) => <String, dynamic>{},
        nodeTransport: node,
        credentialClient: cred,
      );
      expect(
        await gateway.loadAccountCaptcha(CloudDriveType.woniu4k),
        'data:image/png;base64,AA',
      );
      await gateway.submitAccountLogin(
        type: CloudDriveType.woniu4k,
        mode: CloudDriveLoginMode.nodeAccount,
        account: 'a',
        password: 'p',
        captchaCode: '8888',
      );
      expect(node.calls, contains('PUT ${NodeLoginPaths.woniuLogin}'));
      expect(cred.calls, <String>['GET /website/api/credentials']);
    });

    test('189 账号需二次校验 → 返回 needSms，登录未完成且不回收凭据', () async {
      final _FakeNodeLoginTransport node = _FakeNodeLoginTransport(
        (_, __, ___) =>
            <String, dynamic>{'code': 0, 'sms': true, 'msg': '需短信'},
      );
      final _RecordingCredentialClient cred = _RecordingCredentialClient();
      final NodeCloudDriveLoginGateway gateway = gatewayWith(
        (_, __) => <String, dynamic>{},
        nodeTransport: node,
        credentialClient: cred,
      );
      final CloudDriveAccountResult result = await gateway.submitAccountLogin(
        type: CloudDriveType.pan189,
        mode: CloudDriveLoginMode.nodeAccount,
        account: 'a',
        password: 'p',
      );
      expect(result.needSms, isTrue);
      expect(result.message, '需短信');
      expect(node.calls, contains('PUT ${NodeLoginPaths.pan189Account}'));
      // 二次校验阶段尚未登录成功，不回写凭据。
      expect(cred.calls, isEmpty);
    });

    test('189 短信二次校验 → 走 pan189/sms/login 并回收凭据', () async {
      final _FakeNodeLoginTransport node = _FakeNodeLoginTransport(
        (_, __, ___) => <String, dynamic>{'code': 0},
      );
      final _RecordingCredentialClient cred = _RecordingCredentialClient();
      final NodeCloudDriveLoginGateway gateway = gatewayWith(
        (_, __) => <String, dynamic>{},
        nodeTransport: node,
        credentialClient: cred,
      );
      await gateway.submitAccountSmsCode(
        type: CloudDriveType.pan189,
        code: '8888',
      );
      expect(node.calls, contains('POST ${NodeLoginPaths.pan189SmsLogin}'));
      expect(cred.calls, <String>['GET /website/api/credentials']);
    });

    test('非 189 盘不支持短信二次校验', () async {
      final NodeCloudDriveLoginGateway gateway =
          gatewayWith((_, __) => <String, dynamic>{});
      await expectLater(
        gateway.submitAccountSmsCode(type: CloudDriveType.pan123, code: '1'),
        throwsA(isA<CloudDriveLoginException>()),
      );
    });
  });
}
