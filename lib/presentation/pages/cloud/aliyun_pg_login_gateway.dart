/// 网盘登录网关 · PG 阿里云盘扫码实现（批次 F · F-04/C-盘1）。
///
/// 承接 F-02 定义的 [CloudDriveLoginGateway] 接缝，串联已交付的
/// [ExtscreenApiClient]（extscreen 链路）：
/// `makeCrypto → getQrcode → queryQrcodeStatus（控制器逐次轮询）
///  → getRefreshToken → refresh → 落库 `cloud_drive_credentials_v1``。
///
/// 对齐 iOS `AliyunPgAuthManager.startQrLogin` 的完整链路。
///
/// 二维码形态：extscreen 返回的是**授权链接**（非图片），故按
/// [kQrDataContentPrefix] 约定放入 `qrDataUrl`，由表现层本地编码二维码（C-盘3）。
library;

import '../../../data/datasources/local/cloud_drive_credential_store.dart';
import '../../../data/datasources/local/prefs_manager.dart';
import '../../../data/datasources/remote/aliyun_extscreen_client.dart';
import '../../../domain/entities/cloud/aliyun_extscreen.dart';
import '../../../domain/entities/cloud/cloud_drive.dart';
import '../../../domain/entities/cloud/cloud_drive_login.dart';
import '../../../domain/entities/cloud/pg_auto.dart';
import 'login_gateway.dart';

/// PG 阿里云盘扫码登录网关。
class AliyunPgLoginGateway implements CloudDriveLoginGateway {
  /// 构造（[client] / [credentialStore] 供测试注入）。
  AliyunPgLoginGateway({
    ExtscreenApiClient? client,
    CloudDriveCredentialStore? credentialStore,
  })  : _client = client ?? ExtscreenApiClient(),
        _store = credentialStore ??
            CloudDriveCredentialStore(PrefsManager.instance);

  final ExtscreenApiClient _client;
  final CloudDriveCredentialStore _store;

  /// 进行中的扫码任务：`sid → crypto`（authCode 换 token 需复用同一加密器）。
  final Map<String, ExtscreenCrypto> _cryptos = <String, ExtscreenCrypto>{};

  /// 该网关是否覆盖给定网盘 / 方式（仅阿里云盘 PG 扫码档）。
  static bool supports(CloudDriveType type, CloudDriveLoginMode mode) =>
      type == CloudDriveType.ali && mode == CloudDriveLoginMode.pgQr;

  @override
  Future<CloudDriveQrTask> startQrLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    String? providerOverride,
  }) async {
    if (!supports(type, mode)) {
      throw const CloudDriveLoginException('PG 扫码登录仅支持阿里云盘');
    }
    try {
      final ExtscreenCrypto crypto = await _client.makeCrypto();
      final ({String qrLink, String sid}) qr = await _client.getQrcode(crypto);
      _cryptos[qr.sid] = crypto;
      return (
        taskId: qr.sid,
        qrDataUrl: '$kQrDataContentPrefix${qr.qrLink}',
      );
    } on ExtscreenException catch (e) {
      throw CloudDriveLoginException(e.message);
    } catch (e) {
      throw CloudDriveLoginException('$e');
    }
  }

  @override
  Future<CloudDriveLoginPhase> pollQrLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    required String taskId,
    String? providerOverride,
  }) async {
    if (!supports(type, mode)) {
      throw const CloudDriveLoginException('PG 扫码登录仅支持阿里云盘');
    }
    final ExtscreenCrypto? crypto = _cryptos[taskId];
    if (crypto == null) {
      throw const CloudDriveLoginException('扫码任务已失效，请重新生成二维码');
    }

    final ({String status, String? authCode}) st;
    try {
      st = await _client.queryQrcodeStatus(sid: taskId);
    } on ExtscreenException catch (e) {
      throw CloudDriveLoginException(e.message);
    }

    switch (st.status) {
      case 'Scaned':
        return CloudDriveLoginPhase.scanned;
      case 'Expired':
        _cryptos.remove(taskId);
        throw const CloudDriveLoginException('二维码已过期，请重试');
      case 'LoginSuccess':
        final String? authCode = st.authCode;
        if (authCode == null) {
          throw const CloudDriveLoginException('authCode 换取 token 失败');
        }
        try {
          final String refreshToken = await _client.getRefreshToken(
            authCode: authCode,
            crypto: crypto,
          );
          final ExtscreenToken token = await _client.refresh(
            refreshToken: refreshToken,
            crypto: crypto,
          );
          await _persist(refreshToken, token);
          _cryptos.remove(taskId);
          return CloudDriveLoginPhase.success;
        } on ExtscreenException catch (e) {
          throw CloudDriveLoginException(e.message);
        }
      default:
        // New / 未知档 → 仍等待扫码。
        return CloudDriveLoginPhase.waitingScan;
    }
  }

  /// 凭据落库（`cloud_drive_credentials_v1`）；失败不阻断「登录成功」展示。
  ///
  /// P2-2：落库时打上 `pg_source=qr_scan` 标记（对齐 iOS
  /// `AliyunPgAuthManager.savePgCredential` + `AliyunPgConfig.pgSourceKey/
  /// pgSourceValue`，`AliyunPgConfig.swift:176-178`），使 PG 凭据来源可追溯
  /// （刷新分层 `PgCredentialMark.isPgCredential` 依赖该标记）。
  Future<void> _persist(String refreshToken, ExtscreenToken token) async {
    try {
      final DateTime now = DateTime.now();
      final int? expiresIn = token.expiresIn;
      await _store.save(CloudDriveCredential(
        driveType: CloudDriveType.ali.id,
        authType: CloudDriveAuthType.oauth,
        accessToken: token.accessToken,
        refreshToken: token.refreshToken ?? refreshToken,
        expiresAt:
            expiresIn == null ? null : now.add(Duration(seconds: expiresIn)),
        state: CloudDriveAuthState.valid,
        updatedAt: now,
        extra: PgCredentialMark.mark(const <String, String>{}),
      ));
    } catch (_) {
      // 凭据回收失败不影响登录态（对齐 iOS 网关容错）。
    }
  }

  @override
  Future<void> cancelQrLogin(String taskId) async {
    _cryptos.remove(taskId);
  }

  @override
  Future<String> sendSmsCode({
    required CloudDriveType type,
    required String phone,
  }) async =>
      throw const CloudDriveLoginException('PG 扫码登录仅支持扫码档');

  @override
  Future<void> submitSmsCode({
    required CloudDriveType type,
    required String taskId,
    required String code,
  }) async =>
      throw const CloudDriveLoginException('PG 扫码登录仅支持扫码档');

  @override
  Future<CloudDriveAccountResult> submitAccountLogin({
    required CloudDriveType type,
    required CloudDriveLoginMode mode,
    required String account,
    required String password,
    String captchaCode = '',
  }) async =>
      throw const CloudDriveLoginException('PG 扫码登录仅支持扫码档');

  @override
  Future<void> submitAccountSmsCode({
    required CloudDriveType type,
    required String code,
  }) async =>
      throw const CloudDriveLoginException('PG 扫码登录仅支持扫码档');

  @override
  String? pendingCaptchaUrl(CloudDriveType type) => null;

  @override
  Future<String?> loadAccountCaptcha(CloudDriveType type) async => null;
}