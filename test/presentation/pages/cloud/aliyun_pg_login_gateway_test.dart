/// PG 阿里云盘扫码网关单测（P2-2）。
///
/// 验证扫码链路（makeCrypto → getQrcode → LoginSuccess → 换取 → 刷新）
/// 成功落库时写入 `pg_source=qr_scan` 标记（对齐 iOS
/// `AliyunPgAuthManager.savePgCredential` + `AliyunPgConfig.swift:176-178`），
/// 供刷新分层 `PgCredentialMark.isPgCredential` 判定 PG 凭据。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vbox/data/datasources/local/cloud_drive_credential_store.dart';
import 'package:vbox/data/datasources/local/prefs_manager.dart';
import 'package:vbox/data/datasources/remote/aliyun_extscreen_client.dart';
import 'package:vbox/domain/entities/cloud/aliyun_extscreen.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive.dart';
import 'package:vbox/domain/entities/cloud/cloud_drive_login.dart';
import 'package:vbox/domain/entities/cloud/pg_auto.dart';
import 'package:vbox/presentation/pages/cloud/aliyun_pg_login_gateway.dart';
import 'package:vbox/presentation/pages/cloud/login_gateway.dart';

/// 桩客户端：固定链路响应，记录落库输入。
class _StubClient extends ExtscreenApiClient {
  @override
  Future<ExtscreenCrypto> makeCrypto() async =>
      ExtscreenCrypto(timestamp: '1000');

  @override
  Future<({String qrLink, String sid})> getQrcode(
    ExtscreenCrypto crypto,
  ) async =>
      (qrLink: 'https://openapi.alipan.com/oauth/authorize?sid=x', sid: 'sid-1');

  @override
  Future<({String status, String? authCode})> queryQrcodeStatus({
    required String sid,
  }) async =>
      (status: 'LoginSuccess', authCode: 'ac-1');

  @override
  Future<String> getRefreshToken({
    required String authCode,
    required ExtscreenCrypto crypto,
  }) async =>
      'rt-old';

  @override
  Future<ExtscreenToken> refresh({
    required String refreshToken,
    required ExtscreenCrypto crypto,
  }) async =>
      const ExtscreenToken(
        accessToken: 'at-new',
        refreshToken: 'rt-new',
        expiresIn: 7200,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final PrefsManager pm = PrefsManager.instance;
  late CloudDriveCredentialStore store;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await pm.init();
  });

  setUp(() async {
    await pm.clearAll();
    store = CloudDriveCredentialStore(pm);
  });

  group('P2-2 PG 扫码落库打标记', () {
    test('扫码成功 → 凭据写入 pg_source=qr_scan + token 字段', () async {
      final AliyunPgLoginGateway gateway = AliyunPgLoginGateway(
        client: _StubClient(),
        credentialStore: store,
      );

      final CloudDriveQrTask task = await gateway.startQrLogin(
        type: CloudDriveType.ali,
        mode: CloudDriveLoginMode.pgQr,
      );
      expect(task.qrDataUrl, startsWith(kQrDataContentPrefix));

      final CloudDriveLoginPhase phase = await gateway.pollQrLogin(
        type: CloudDriveType.ali,
        mode: CloudDriveLoginMode.pgQr,
        taskId: task.taskId,
      );
      expect(phase, CloudDriveLoginPhase.success);

      final CloudDriveCredential? cred =
          await store.credential(CloudDriveType.ali);
      expect(cred, isNotNull);
      expect(cred!.accessToken, 'at-new');
      expect(cred.refreshToken, 'rt-new');
      expect(cred.expiresAt, isNotNull);
      // P2-2 核心：PG 来源标记（PgCredentialMark.isPgCredential 依赖）。
      expect(cred.extra[PgCredentialMark.sourceKey],
          PgCredentialMark.sourceValue);
      expect(PgCredentialMark.isPgCredential(cred.extra), isTrue);
    });

    test('非 PG 档：nativeQr 直接拒绝', () async {
      final AliyunPgLoginGateway gateway = AliyunPgLoginGateway(
        client: _StubClient(),
        credentialStore: store,
      );
      await expectLater(
        gateway.startQrLogin(
          type: CloudDriveType.ali,
          mode: CloudDriveLoginMode.nativeQr,
        ),
        throwsA(isA<CloudDriveLoginException>()),
      );
    });
  });
}
