/// 数据层：网盘授权凭据存储（批次 F · F-03）。
///
/// 对齐 iOS `SecureCredentialStore`（`vbox/Services/SecureCredentialStore.swift`）：
/// - 凭据字典 → Keychain 账号 **`cloud_drive_credentials_v1`**
///   （契约 `storage: keychain`，序列化形态 `{ "<driveType>": <credential> }` JSON）
/// - 明文 Token 键 **`saved_drive_tokens_v1`**（契约 keychain）与遗留键
///   **`saved_drive_tokens`**（契约 sensitive，iOS 侧为 UserDefaults 遗留）
///
/// 本类只做「领域对象 ↔ JSON ↔ [PrefsManager]」的编解码；
/// **安全存储路由由 [PrefsManager] 按契约 `storage`/`sensitive` 判定**，
/// 故凭据绝不会落明文 SharedPreferences（由 `prefs_manager_test` 逐键锁定）。
library;

import 'dart:convert';

import '../../../domain/entities/cloud/cloud_drive.dart';
import 'prefs_manager.dart';

/// 网盘凭据存储。
class CloudDriveCredentialStore {
  /// 构造（注入契约偏好管理器）。
  CloudDriveCredentialStore(this._prefs);

  final PrefsManager _prefs;

  /// 凭据字典键（契约 `storage: keychain`）。
  static const String storageKey = 'cloud_drive_credentials_v1';

  /// 明文 Token 存储键（契约 `storage: keychain`）。
  static const String savedTokensV1Key = 'saved_drive_tokens_v1';

  /// 遗留 Token 键（契约 `sensitive`，iOS 侧为 UserDefaults 遗留）。
  static const String savedTokensKey = 'saved_drive_tokens';

  /// 读取全部凭据（`driveType` → 凭据）。
  Future<Map<String, CloudDriveCredential>> loadAll() async {
    final Object? raw = await _prefs.get(storageKey);
    if (raw is! String || raw.isEmpty) {
      return <String, CloudDriveCredential>{};
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return <String, CloudDriveCredential>{};
    }
    if (decoded is! Map) return <String, CloudDriveCredential>{};

    final Map<String, CloudDriveCredential> out =
        <String, CloudDriveCredential>{};
    for (final MapEntry<Object?, Object?> entry in decoded.entries) {
      final Object? value = entry.value;
      if (entry.key == null || value is! Map) continue;
      final Map<String, dynamic> map = <String, dynamic>{
        for (final MapEntry<Object?, Object?> f in value.entries)
          f.key.toString(): f.value,
      };
      final CloudDriveCredential credential = CloudDriveCredential.fromJson(map);
      if (credential.driveType.isNotEmpty) {
        out[entry.key.toString()] = credential;
      }
    }
    return out;
  }

  /// 读取单个网盘凭据（不存在返回 null）。
  Future<CloudDriveCredential?> credential(CloudDriveType type) async =>
      (await loadAll())[type.id];

  /// 写入单个网盘凭据（覆盖）。
  Future<void> save(CloudDriveCredential credential) async {
    final Map<String, CloudDriveCredential> all = await loadAll();
    all[credential.driveType] = credential;
    await saveAll(all);
  }

  /// 全量写入（覆盖）。
  Future<void> saveAll(Map<String, CloudDriveCredential> credentials) async {
    final Map<String, dynamic> payload = <String, dynamic>{
      for (final MapEntry<String, CloudDriveCredential> e
          in credentials.entries)
        e.key: e.value.toJson(),
    };
    await _prefs.set(storageKey, jsonEncode(payload));
  }

  /// 删除某网盘凭据。
  Future<void> remove(CloudDriveType type) async {
    final Map<String, CloudDriveCredential> all = await loadAll();
    if (all.remove(type.id) != null) {
      await saveAll(all);
    }
  }

  /// 清空全部凭据（谨慎：授权中心「全部登出」用）。
  Future<void> clear() async => _prefs.remove(storageKey);

  /// 是否已持有可用密钥（授权中心「已获取」判定）。
  Future<bool> hasCredentials(CloudDriveType type) async =>
      (await credential(type))?.hasSecret ?? false;

  // ─────────────────────────────────────────────────────────
  // 手动 Token 向量（对齐 iOS `CloudDriveManager.savedTokens`）
  // ─────────────────────────────────────────────────────────

  /// 读取手动 Token 向量（对齐 iOS `CloudDriveManager.loadTokens`）。
  ///
  /// 优先 Keychain 账号 `saved_drive_tokens_v1`；为空时回退遗留键
  /// `saved_drive_tokens`（对齐 iOS 从 UserDefaults 的一次性迁移读取，不回写）。
  Future<List<DriveToken>> loadTokens() async {
    final List<DriveToken>? v1 = _decodeTokens(await _prefs.get(savedTokensV1Key));
    if (v1 != null) return v1;
    return _decodeTokens(await _prefs.get(savedTokensKey)) ??
        const <DriveToken>[];
  }

  /// 写入手动 Token 向量（对齐 iOS `CloudDriveManager.saveTokens`）。
  Future<void> saveTokens(List<DriveToken> tokens) => _prefs.set(
        savedTokensV1Key,
        jsonEncode(<dynamic>[
          for (final DriveToken token in tokens) token.toJson(),
        ]),
      );

  /// 新增 / 覆盖手动 Token（对齐 iOS `CloudDriveManager.addToken`：
  /// 先移除同盘同名项，再追加）。
  Future<void> addToken(DriveToken token) async {
    final List<DriveToken> tokens = List<DriveToken>.of(await loadTokens())
      ..removeWhere((DriveToken t) =>
          t.type == token.type && t.name == token.name)
      ..add(token);
    await saveTokens(tokens);
  }

  /// 取指定网盘的 Token 向量（对齐 iOS `CloudDriveManager.tokens(for:)`）。
  ///
  /// = 手动 Token 向量（百度仅保留 PCS / 账号 Web 形态）
  ///   + 授权中心主密钥（对齐 `bestTokenValue`；非百度插入队首，百度追加队尾）。
  Future<List<DriveToken>> tokensFor(CloudDriveType type) async {
    List<DriveToken> tokens = (await loadTokens())
        .where((DriveToken t) => t.type == type.id)
        .toList();
    if (type == CloudDriveType.baidu) {
      tokens = tokens
          .where((DriveToken t) =>
              isBaiduPcsToken(t) || isBaiduAccountWebToken(t))
          .toList();
    }
    final CloudDriveCredential? account = await credential(type);
    final String? value = _bestTokenValue(type, account);
    if (value != null && !tokens.any((DriveToken t) => t.value == value)) {
      final bool named = account?.userName?.isNotEmpty ?? false;
      final DriveToken authToken = DriveToken(
        type: type.id,
        name: named ? account!.userName! : '授权中心',
        value: value,
      );
      // 百度 Worker 链路优先保持旧手动 Token 顺序，授权中心仅作兜底（队尾）。
      if (type == CloudDriveType.baidu) {
        tokens.add(authToken);
      } else {
        tokens.insert(0, authToken);
      }
    }
    return tokens;
  }

  /// 百度双 Token 配对（对齐 iOS `CloudDriveManager.baiduTokenPair()`）。
  ///
  /// Web Cookie 必须为账号形态（BDUSS + STOKEN），否则返回 null；
  /// PCS Cookie 仅取授权中心 `extra["pcs_cookie"]` 的最新值（不回退手动向量）。
  Future<BaiduTokenPair?> baiduTokenPair() async {
    final List<DriveToken> list = await tokensFor(CloudDriveType.baidu);
    if (list.isEmpty) return null;

    final CloudDriveCredential? account =
        await credential(CloudDriveType.baidu);
    final String? cookie = account?.cookie;
    DriveToken? web;
    if (isBaiduAccountWebCookie(cookie)) {
      final bool named = account?.userName?.isNotEmpty ?? false;
      web = DriveToken(
        type: CloudDriveType.baidu.id,
        name: named ? account!.userName! : '授权中心',
        value: cookie!,
      );
    } else {
      for (final DriveToken token in list) {
        if (isBaiduAccountWebToken(token)) {
          web = token;
          break;
        }
      }
    }
    if (web == null) return null;

    final String? pcsValue = account?.extra['pcs_cookie'];
    final DriveToken? pcs =
        (pcsValue != null && isBaiduPcsCookie(pcsValue))
            ? DriveToken(
                type: CloudDriveType.baidu.id,
                name: '授权中心-PCS',
                value: pcsValue,
              )
            : null;
    return BaiduTokenPair(web: web, pcs: pcs);
  }

  /// 授权中心主密钥（对齐 iOS `CloudDriveAuthManager.bestTokenValue(for:)`：
  /// 百度必须为账号 Web 形态，否则视为无值）。
  static String? _bestTokenValue(
    CloudDriveType type,
    CloudDriveCredential? credential,
  ) {
    final String? value = credential?.primarySecret;
    if (value == null) return null;
    if (type == CloudDriveType.baidu && !isBaiduAccountWebCookie(value)) {
      return null;
    }
    return value;
  }

  /// JSON 数组字符串 → Token 向量（非法 / 非数组返回 null）。
  static List<DriveToken>? _decodeTokens(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! List) return null;
    return <DriveToken>[
      for (final Object? item in decoded)
        if (item is Map)
          DriveToken.fromJson(<String, dynamic>{
            for (final MapEntry<Object?, Object?> e in item.entries)
              e.key.toString(): e.value,
          }),
    ];
  }
}
