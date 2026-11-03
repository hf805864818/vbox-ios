/// 云盘凭据校验器单测（第 4 批 F-P24）。
///
/// 对齐基准（唯一真相源）：iOS `CloudDriveAuthManager.validateCredential(for:)`
/// （`CloudDriveAuthManager.swift:2389-2423`）、`validateCookie`（L3041-3074）、
/// `baiduFetchTemplateVariables`（L2933-2961）、`validatePan123Credential`
/// （L2963-3039）、`validateNodeManagedCredential`（L2645-2674）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/remote/cloud_drive_credential_validator.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';

/// 可编排响应的假客户端（记录请求便于断言 iOS 请求形态）。
class _FakeClient extends http.BaseClient {
  _FakeClient(this.handler);

  final Future<http.Response> Function(http.BaseRequest request) handler;

  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final http.Response resp = await handler(request);
    return http.StreamedResponse(
      Stream<Uint8List>.fromIterable(<Uint8List>[
        Uint8List.fromList(utf8.encode(resp.body)),
      ]),
      resp.statusCode,
      headers: resp.headers,
    );
  }
}

CloudDriveCredential _cred(
  CloudDriveType type, {
  String? cookie,
  String? accessToken,
  String? refreshToken,
  Map<String, String> extra = const <String, String>{},
}) =>
    CloudDriveCredential(
      driveType: type.id,
      updatedAt: DateTime(2026, 1, 1),
      cookie: cookie,
      accessToken: accessToken,
      refreshToken: refreshToken,
      extra: extra,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final PrefsManager pm = PrefsManager.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
  });

  group('阿里（字段校验，与 iOS 差异已登记）', () {
    test('refreshToken / accessToken 任一非空 → 通过', () async {
      final _FakeClient client = _FakeClient((_) async {
        throw StateError('阿里不应发起网络请求');
      });
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(client: client);
      final CredentialValidationResult ok = await validator.validate(
        CloudDriveType.ali,
        _cred(CloudDriveType.ali, refreshToken: 'r'),
      );
      expect(ok.valid, isTrue);
      expect(ok.message, '授权检测正常');

      final CredentialValidationResult ok2 = await validator.validate(
        CloudDriveType.ali,
        _cred(CloudDriveType.ali, accessToken: 'a'),
      );
      expect(ok2.valid, isTrue);
    });

    test('两者皆空 → 失效且文案对齐', () async {
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(
              client: _FakeClient((_) async => throw StateError('')));
      final CredentialValidationResult result = await validator.validate(
        CloudDriveType.ali,
        _cred(CloudDriveType.ali),
      );
      expect(result.valid, isFalse);
      expect(result.message, '阿里云盘未配置 Refresh Token');
    });
  });

  group('Cookie 类网盘（对齐 iOS validateCookie）', () {
    test('空 Cookie → 直接失效', () async {
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(
        client: _FakeClient(
          (_) async => throw StateError('空 Cookie 不应发请求'),
        ),
      );
      final CredentialValidationResult result = await validator.validate(
        CloudDriveType.quark,
        _cred(CloudDriveType.quark),
      );
      expect(result.valid, isFalse);
      expect(result.message, 'Cookie 为空');
    });

    test('HTTP 401 / 403 → 失效', () async {
      for (final int status in <int>[401, 403]) {
        final _FakeClient client = _FakeClient(
          (_) async => http.Response('{}', status),
        );
        final CloudDriveCredentialValidator validator =
            CloudDriveCredentialValidator(client: client);
        final CredentialValidationResult result = await validator.validate(
          CloudDriveType.quark,
          _cred(CloudDriveType.quark, cookie: 'k=v'),
        );
        expect(result.valid, isFalse, reason: 'status=$status');
        expect(result.message, 'HTTP $status');
      }
    });

    test('state == false → 取 error / message 文案', () async {
      final _FakeClient client = _FakeClient(
        // 中文 body 必须显式 utf8（http.Response 默认 latin1 编码非 ASCII
        // 会抛 Invalid argument → 走「网络错误」兜底文案，断言失真）。
        (_) async => http.Response(
          '{"state":false,"error":"请重新登录"}',
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        ),
      );
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(client: client);
      final CredentialValidationResult result = await validator.validate(
        CloudDriveType.one15,
        _cred(CloudDriveType.one15, cookie: 'k=v'),
      );
      expect(result.valid, isFalse);
      expect(result.message, '请重新登录');
    });

    test('code ∈ {401,403,40001}（Int/String 双形态）→ 失效', () async {
      for (final String code in <String>['401', '403', '40001']) {
        final _FakeClient client = _FakeClient(
          (_) async => http.Response('{"code":"$code"}', 200),
        );
        final CloudDriveCredentialValidator validator =
            CloudDriveCredentialValidator(client: client);
        final CredentialValidationResult result = await validator.validate(
          CloudDriveType.uc,
          _cred(CloudDriveType.uc, cookie: 'k=v'),
        );
        expect(result.valid, isFalse, reason: code);
      }
      // 成功形态：code=0 整数。
      final _FakeClient ok = _FakeClient(
        (_) async => http.Response('{"code":0,"state":true}', 200),
      );
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(client: ok);
      final CredentialValidationResult good = await validator.validate(
        CloudDriveType.quark,
        _cred(CloudDriveType.quark, cookie: 'k=v'),
      );
      expect(good.valid, isTrue);
    });

    test('UC：`/file/sort` → POST + JSON body（对齐 iOS L3055-3061）', () async {
      final _FakeClient client = _FakeClient(
        (_) async => http.Response('{"state":true}', 200),
      );
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(client: client);
      await validator.validate(
        CloudDriveType.uc,
        _cred(CloudDriveType.uc, cookie: 'k=v'),
      );
      expect(client.requests.single.method, 'POST');
      final http.Request req = client.requests.single as http.Request;
      expect(req.url.host, 'pc-api.uc.cn');
      expect(req.body, contains('pdir_fid'));
      expect(req.headers['Content-Type'], 'application/json');
    });

    test('115：GET + 完整 Chrome UA + Origin（对齐 iOS L3050-3053）', () async {
      final _FakeClient client = _FakeClient(
        (_) async => http.Response('{"state":true}', 200),
      );
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(client: client);
      await validator.validate(
        CloudDriveType.one15,
        _cred(CloudDriveType.one15, cookie: 'k=v'),
      );
      final http.BaseRequest req = client.requests.single;
      expect(req.method, 'GET');
      expect(req.url.host, 'webapi.115.com');
      expect(req.headers['Origin'], 'https://115.com');
      expect(req.headers['User-Agent'], contains('Chrome/120'));
    });
  });

  group('百度（对齐 iOS baiduFetchTemplateVariables）', () {
    test('errno != 0 → 失效', () async {
      final _FakeClient client = _FakeClient(
        (_) async => http.Response('{"errno":-6}', 200),
      );
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(client: client);
      final CredentialValidationResult result = await validator.validate(
        CloudDriveType.baidu,
        _cred(CloudDriveType.baidu, cookie: 'BDUSS=b; STOKEN=s'),
      );
      expect(result.valid, isFalse);
      expect(result.message, '百度登录态异常 errno=-6');
    });

    test('errno == 0 但 bdstoken/uk 皆空 → 失效', () async {
      final _FakeClient client = _FakeClient(
        (_) async => http.Response(
            '{"errno":0,"result":{"bdstoken":"","uk":""}}', 200),
      );
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(client: client);
      final CredentialValidationResult result = await validator.validate(
        CloudDriveType.baidu,
        _cred(CloudDriveType.baidu, cookie: 'BDUSS=b; STOKEN=s'),
      );
      expect(result.valid, isFalse);
      expect(result.message, '百度未返回 bdstoken/uk');
    });

    test('返回 bdstoken → 通过', () async {
      final _FakeClient client = _FakeClient(
        (_) async => http.Response(
            '{"errno":0,"result":{"bdstoken":"tok","uk":"1"}}', 200),
      );
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(client: client);
      final CredentialValidationResult result = await validator.validate(
        CloudDriveType.baidu,
        _cred(CloudDriveType.baidu, cookie: 'BDUSS=b; STOKEN=s'),
      );
      expect(result.valid, isTrue);
      expect(result.message, '授权检测正常');
    });

    test('响应非 JSON → 失效', () async {
      final _FakeClient client = _FakeClient(
        (_) async => http.Response('<html>login</html>', 200),
      );
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(client: client);
      final CredentialValidationResult result = await validator.validate(
        CloudDriveType.baidu,
        _cred(CloudDriveType.baidu, cookie: 'BDUSS=b; STOKEN=s'),
      );
      expect(result.valid, isFalse);
      expect(result.message, '百度登录态校验失败（响应非 JSON）');
    });

    test('P2-5：校验失败记 10 分钟冷却，冷却内跳过远程校验', () async {
      int calls = 0;
      final _FakeClient client = _FakeClient((http.BaseRequest request) async {
        calls++;
        return http.Response('{"errno":-6,"errmsg":"acct_err"}', 200);
      });
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(client: client, prefs: pm);
      final CloudDriveCredential cred =
          _cred(CloudDriveType.baidu, cookie: 'BDUSS=abc; STOKEN=st1');

      // 首次：远程校验失败 → 记冷却。
      final CredentialValidationResult first =
          await validator.validate(CloudDriveType.baidu, cred);
      expect(first.valid, isFalse);
      expect(first.skipped, isFalse);
      expect(calls, 1);

      // 冷却期内：直接 skipped，不再发远程请求。
      final CredentialValidationResult second =
          await validator.validate(CloudDriveType.baidu, cred);
      expect(second.skipped, isTrue);
      expect(second.valid, isFalse);
      expect(second.message, contains('冷却'));
      expect(calls, 1);
      // 冷却已持久化到 prefs（契约键 baidu_verify_cooldowns_v1）。
      final Object? raw = await pm.get('baidu_verify_cooldowns_v1');
      expect(raw, isA<String>());
      expect(raw as String, contains('bduss:abc'));
    });

    test('P2-5：冷却 key 优先 BDUSS（同账号新 Cookie 命中，异账号不受影响）', () async {
      final _FakeClient client = _FakeClient(
        (_) async => http.Response('{"errno":-6,"errmsg":"acct_err"}', 200),
      );
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(client: client, prefs: pm);
      await validator.validate(
        CloudDriveType.baidu,
        _cred(CloudDriveType.baidu, cookie: 'BDUSS=same; STOKEN=old'),
      );
      // 同 BDUSS、不同 STOKEN → 仍命中冷却。
      final CredentialValidationResult hit = await validator.validate(
        CloudDriveType.baidu,
        _cred(CloudDriveType.baidu, cookie: 'BDUSS=same; STOKEN=new'),
      );
      expect(hit.skipped, isTrue);
      // 不同 BDUSS → 正常发起远程校验（失败但不 skipped）。
      final CredentialValidationResult miss = await validator.validate(
        CloudDriveType.baidu,
        _cred(CloudDriveType.baidu, cookie: 'BDUSS=other; STOKEN=x'),
      );
      expect(miss.skipped, isFalse);
      expect(miss.valid, isFalse);
    });
  });

  group('123云盘（对齐 iOS validatePan123Credential）', () {
    test('Cookie 与 Token 均空 → 失效', () async {
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(
        client: _FakeClient((_) async => throw StateError('')),
      );
      final CredentialValidationResult result = await validator.validate(
        CloudDriveType.pan123,
        _cred(CloudDriveType.pan123),
      );
      expect(result.valid, isFalse);
      expect(result.message, '123云盘 Cookie 与 Token 均为空');
    });

    test('GET code=0 → 直接通过（不发 POST）', () async {
      final _FakeClient client = _FakeClient(
        (_) async => http.Response('{"code":0}', 200),
      );
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(client: client);
      final CredentialValidationResult result = await validator.validate(
        CloudDriveType.pan123,
        _cred(CloudDriveType.pan123, cookie: 'k=v'),
      );
      expect(result.valid, isTrue);
      expect(client.requests.single.method, 'GET');
    });

    test('GET 401 → POST 重试；POST code="200"（String）→ 通过', () async {
      final _FakeClient client = _FakeClient((http.BaseRequest req) async {
        if (req.method == 'GET') return http.Response('', 401);
        return http.Response('{"code":"200"}', 200);
      });
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(client: client);
      final CredentialValidationResult result = await validator.validate(
        CloudDriveType.pan123,
        _cred(CloudDriveType.pan123, accessToken: 'tok'),
      );
      expect(result.valid, isTrue);
      expect(client.requests.map((http.BaseRequest r) => r.method).toList(),
          <String>['GET', 'POST']);
    });

    test('全链失败 → 带 HTTP 状态的兜底文案', () async {
      final _FakeClient client = _FakeClient(
        (_) async => http.Response('server down', 500),
      );
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(client: client);
      final CredentialValidationResult result = await validator.validate(
        CloudDriveType.pan123,
        _cred(CloudDriveType.pan123, cookie: 'k=v'),
      );
      expect(result.valid, isFalse);
      expect(result.message, contains('HTTP 500'));
    });
  });

  group('Node 托管盘（对齐 iOS validateNodeManagedCredential 文案）', () {
    test('缺失核心字段 → 分盘文案失效', () async {
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(
        client: _FakeClient((_) async => throw StateError('Node 托管盘不应发请求')),
      );

      final Map<CloudDriveType, (CloudDriveCredential, String)> cases =
          <CloudDriveType, (CloudDriveCredential, String)>{
        CloudDriveType.guangya: (
          _cred(CloudDriveType.guangya),
          '光鸭网盘未配置 Token，请先扫码授权',
        ),
        CloudDriveType.woniu4k: (
          _cred(CloudDriveType.woniu4k),
          '蜗牛网盘未配置 Cookie，请先账号登录',
        ),
        CloudDriveType.bilibili: (
          _cred(CloudDriveType.bilibili),
          'B站未配置 Cookie，请先扫码登录',
        ),
        CloudDriveType.ucNode: (
          _cred(CloudDriveType.ucNode),
          'UC网盘Node未配置 Cookie / TV Token，请先扫码登录或粘贴 Token',
        ),
        CloudDriveType.baiduNode: (
          _cred(CloudDriveType.baiduNode),
          '百度网盘Node未配置 Cookie，请先扫码登录或粘贴 Cookie',
        ),
      };
      for (final MapEntry<CloudDriveType, (CloudDriveCredential, String)> entry
          in cases.entries) {
        final CredentialValidationResult result = await validator.validate(
          entry.key,
          entry.value.$1,
        );
        expect(result.valid, isFalse, reason: entry.key.id);
        expect(result.message, entry.value.$2, reason: entry.key.id);
      }
    });

    test('核心字段齐备 → 通过（光鸭看 extra["token"]）', () async {
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(
        client: _FakeClient((_) async => throw StateError('')),
      );
      final CredentialValidationResult result = await validator.validate(
        CloudDriveType.guangya,
        _cred(CloudDriveType.guangya, extra: <String, String>{'token': 't'}),
      );
      expect(result.valid, isTrue);
    });

    test('UC Node：TV Token 兜底（对齐 iOS L2659-2666）', () async {
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(
        client: _FakeClient((_) async => throw StateError('')),
      );
      final CredentialValidationResult result = await validator.validate(
        CloudDriveType.ucNode,
        _cred(CloudDriveType.ucNode,
            extra: <String, String>{'uc_node_tv_token': 'tv'}),
      );
      expect(result.valid, isTrue);
    });

    test('夸克 Node：iOS default 分支直接通过', () async {
      final CloudDriveCredentialValidator validator =
          CloudDriveCredentialValidator(
        client: _FakeClient((_) async => throw StateError('')),
      );
      final CredentialValidationResult result = await validator.validate(
        CloudDriveType.quarkNode,
        _cred(CloudDriveType.quarkNode),
      );
      expect(result.valid, isTrue);
    });
  });

  test('网络异常 → 兜底文案「网络错误，请稍后重试」', () async {
    final _FakeClient client = _FakeClient(
      (_) async => throw http.ClientException('boom'),
    );
    final CloudDriveCredentialValidator validator =
        CloudDriveCredentialValidator(client: client);
    final CredentialValidationResult result = await validator.validate(
      CloudDriveType.pan139,
      _cred(CloudDriveType.pan139, cookie: 'k=v'),
    );
    expect(result.valid, isFalse);
    expect(result.message, '网络错误，请稍后重试');
  });
}
