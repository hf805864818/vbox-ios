/// 数据层：备份管理器（AES-256-GCM + PBKDF2-HMAC-SHA256）。
///
/// 唯一真相源：`contract/docs/backup_v1.md`（备份格式规范 v1.0）
/// 逆向来源：iOS `vbox/Services/BackupManager.swift`（831 行）
///
/// ⚠️ 必须与 iOS 端产生**字节级兼容**的备份文件（双向互通）。
///
/// 加密参数（不得改动，否则不兼容）：
/// - PBKDF2-HMAC-SHA256，迭代 **100,000**
/// - salt **16 字节**，IV **12 字节**，密钥 **32 字节（AES-256）**
/// - AES-GCM，tag **16 字节**，**无 AAD**
/// - 口令 **UTF-8** 编码（字节长度，非字符长度）
/// - Base64 **标准**（非 URL-safe）
/// - **不压缩**（源码未使用 gzip/zlib）
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 备份错误类型（对齐 iOS `BackupError`）。
sealed class BackupException implements Exception {
  const BackupException(this.message);
  final String message;
  @override
  String toString() => 'BackupException: $message';
}

/// 口令错误（AES-GCM tag 校验不通过）。
class WrongPasswordException extends BackupException {
  const WrongPasswordException()
      : super('口令错误，无法解密这份备份');
}

/// 备份文件 schemaVersion 高于当前 App 支持版本。
class SchemaTooNewException extends BackupException {
  SchemaTooNewException(int fileVersion)
      : super('备份文件格式版本 v$fileVersion 高于当前 App 支持的 '
            'v${BackupManager.supportedSchemaVersion}，请先升级 App 再还原');
}

/// 空口令。
class EmptyPasswordException extends BackupException {
  const EmptyPasswordException() : super('口令不能为空');
}

/// 格式非法。
class InvalidFormatException extends BackupException {
  const InvalidFormatException(super.message);
}

/// 加密失败。
class CryptoFailedException extends BackupException {
  const CryptoFailedException(super.message);
}

/// 备份类目（9 个，对齐 iOS `BackupCategory`）。
enum BackupCategory {
  watchHistory,
  favorites,
  downloads,
  subscriptions,
  siteConfigs,
  personalSettings,
  remoteSources,
  searchHistory,
  cloudCredentials;

  /// 是否敏感（仅网盘凭据）。
  bool get isSensitive => this == BackupCategory.cloudCredentials;

  /// 默认是否勾选（敏感的默认不勾选）。
  bool get defaultOn => !isSensitive;

  /// 中文名（对齐契约 §3）。
  String get label => switch (this) {
        BackupCategory.watchHistory => '观看记录',
        BackupCategory.favorites => '我的收藏',
        BackupCategory.downloads => '下载记录',
        BackupCategory.subscriptions => '订阅源',
        BackupCategory.siteConfigs => '站点配置',
        BackupCategory.personalSettings => '个人设置',
        BackupCategory.remoteSources => '远程源配置',
        BackupCategory.searchHistory => '搜索历史',
        BackupCategory.cloudCredentials => '网盘凭据',
      };

  /// 副标题（对齐契约 §3）。
  String get subtitle => switch (this) {
        BackupCategory.watchHistory => '播放历史与观看进度',
        BackupCategory.favorites => '收藏的剧集列表',
        BackupCategory.downloads => '下载列表与进度（不含本地文件）',
        BackupCategory.subscriptions => '订阅的源地址列表',
        BackupCategory.siteConfigs => '站点、解析设置等配置',
        BackupCategory.personalSettings => '用户名、头像、外观、TMDB 等',
        BackupCategory.remoteSources => '远程源缓存配置',
        BackupCategory.searchHistory => '搜索关键词记录',
        BackupCategory.cloudCredentials => '网盘授权令牌',
      };
}

/// 冲突策略（对齐契约 §8 / iOS `ConflictStrategy`）。
enum ConflictStrategy {
  /// 保留本机现有数据，把备份内容合并进来。
  merge,

  /// 先清空本机对应类目，再完整写入备份内容。
  overwrite;

  /// 中文名（UI 用）。
  String get label => switch (this) {
        ConflictStrategy.merge => '合并',
        ConflictStrategy.overwrite => '覆盖',
      };

  static ConflictStrategy fromName(String? v) => switch (v) {
        'overwrite' => ConflictStrategy.overwrite,
        _ => ConflictStrategy.merge,
      };
}

/// 备份元数据（对齐 iOS `BackupMeta`）。
class BackupMeta {
  const BackupMeta({
    required this.appName,
    required this.appVersion,
    required this.createdAt,
    required this.account,
    required this.username,
    required this.device,
  });

  final String appName;
  final String appVersion;

  /// Unix 秒级时间戳。
  final int createdAt;
  final String account;
  final String username;
  final String device;

  Map<String, Object?> toJson() => <String, Object?>{
        'appName': appName,
        'appVersion': appVersion,
        'createdAt': createdAt,
        'account': account,
        'username': username,
        'device': device,
      };

  factory BackupMeta.fromJson(Map<String, Object?> j) => BackupMeta(
        appName: j['appName'] as String? ?? '',
        appVersion: j['appVersion'] as String? ?? '',
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        account: j['account'] as String? ?? '',
        username: j['username'] as String? ?? '',
        device: j['device'] as String? ?? '',
      );
}

/// 备份文件信封（对齐 iOS `BackupFileEnvelope`）。
class BackupEnvelope {
  const BackupEnvelope({
    this.schemaVersion = BackupManager.supportedSchemaVersion,
    required this.meta,
    required this.encrypted,
    this.cipher,
    this.kdf,
    this.salt,
    this.iv,
    this.authTag,
    required this.payload,
  });

  final int schemaVersion;
  final BackupMeta meta;
  final bool encrypted;

  /// 加密时固定为 `"AES-256-GCM"`。
  final String? cipher;

  /// 加密时固定为 `"PBKDF2-HMAC-SHA256"`。
  final String? kdf;
  final String? salt;
  final String? iv;
  final String? authTag;

  /// base64(密文) 或 base64(明文)。
  final String payload;

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'meta': meta.toJson(),
        'encrypted': encrypted,
        if (cipher != null) 'cipher': cipher,
        if (kdf != null) 'kdf': kdf,
        if (salt != null) 'salt': salt,
        if (iv != null) 'iv': iv,
        if (authTag != null) 'authTag': authTag,
        'payload': payload,
      };

  factory BackupEnvelope.fromJson(Map<String, Object?> j) => BackupEnvelope(
        schemaVersion: (j['schemaVersion'] as num?)?.toInt() ?? 1,
        meta: BackupMeta.fromJson(
            (j['meta'] as Map?)?.cast<String, Object?>() ?? <String, Object?>{}),
        encrypted: j['encrypted'] as bool? ?? false,
        cipher: j['cipher'] as String?,
        kdf: j['kdf'] as String?,
        salt: j['salt'] as String?,
        iv: j['iv'] as String?,
        authTag: j['authTag'] as String?,
        payload: j['payload'] as String? ?? '',
      );
}

class BackupManager {
  BackupManager._();

  static final BackupManager instance = BackupManager._();

  /// 当前支持的备份 schemaVersion（对齐 iOS `supportedSchemaVersion`）。
  static const int supportedSchemaVersion = 1;

  /// PBKDF2 迭代次数（对齐 iOS，**不得改动**）。
  static const int pbkdf2Iterations = 100000;

  /// salt 长度（字节）。
  static const int saltLength = 16;

  /// IV 长度（字节）。
  static const int ivLength = 12;

  /// AES 密钥长度（字节，256 bit）。
  static const int keyLength = 32;

  /// GCM tag 长度（字节，CryptoKit 默认）。
  static const int tagLength = 16;

  /// cipher 字面值（**必须精确匹配**）。
  static const String cipherName = 'AES-256-GCM';

  /// kdf 字面值（**必须精确匹配**）。
  static const String kdfName = 'PBKDF2-HMAC-SHA256';

  final AesGcm _aes = AesGcm.with256bits();

  /// 派生 AES-256 密钥。
  Future<SecretKey> _deriveKey(String password, List<int> salt) async {
    if (password.isEmpty) throw const EmptyPasswordException();
    final Pbkdf2 pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: pbkdf2Iterations,
      bits: keyLength * 8,
    );
    return pbkdf2.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
  }

  /// 加密：明文 JSON 字符串 → 加密信封。
  ///
  /// [plaintextJson]：待加密的 JSON 字符串
  /// [password]：口令（可为空 → 走未加密模式）
  Future<BackupEnvelope> encrypt({
    required String plaintextJson,
    required BackupMeta meta,
    String? password,
  }) async {
    final List<int> plainBytes = utf8.encode(plaintextJson);

    // 无口令 → 未加密模式
    if (password == null || password.isEmpty) {
      return BackupEnvelope(
        meta: meta,
        encrypted: false,
        payload: base64.encode(plainBytes),
      );
    }

    final List<int> salt = _randomBytes(saltLength);
    final List<int> iv = _randomBytes(ivLength);
    final SecretKey key = await _deriveKey(password, salt);

    final SecretBox box = await _aes.encrypt(
      plainBytes,
      secretKey: key,
      nonce: iv,
    );

    return BackupEnvelope(
      meta: meta,
      encrypted: true,
      cipher: cipherName,
      kdf: kdfName,
      salt: base64.encode(salt),
      iv: base64.encode(iv),
      authTag: base64.encode(box.mac.bytes),
      payload: base64.encode(box.cipherText),
    );
  }

  /// 解密：加密信封 → 明文 JSON 字符串。
  Future<String> decrypt({
    required BackupEnvelope envelope,
    String? password,
  }) async {
    // 版本检查
    if (envelope.schemaVersion > supportedSchemaVersion) {
      throw SchemaTooNewException(envelope.schemaVersion);
    }

    // 未加密模式
    if (!envelope.encrypted) {
      return utf8.decode(base64.decode(envelope.payload));
    }

    if (password == null || password.isEmpty) {
      throw const EmptyPasswordException();
    }
    final String? saltB64 = envelope.salt;
    final String? ivB64 = envelope.iv;
    final String? tagB64 = envelope.authTag;
    if (saltB64 == null || ivB64 == null || tagB64 == null) {
      throw const InvalidFormatException('加密备份缺少 salt/iv/authTag');
    }

    final List<int> salt = base64.decode(saltB64);
    final List<int> iv = base64.decode(ivB64);
    final List<int> tag = base64.decode(tagB64);
    final List<int> cipherText = base64.decode(envelope.payload);

    final SecretKey key = await _deriveKey(password, salt);
    final SecretBox box = SecretBox(cipherText, nonce: iv, mac: Mac(tag));

    try {
      final List<int> clear = await _aes.decrypt(box, secretKey: key);
      return utf8.decode(clear);
    } on SecretBoxAuthenticationError {
      throw const WrongPasswordException();
    }
  }

  /// 编码为备份文件字符串（JSON）。
  String encode(BackupEnvelope envelope) => jsonEncode(envelope.toJson());

  /// 解析备份文件字符串。
  BackupEnvelope decode(String content) {
    try {
      final Object? decoded = jsonDecode(content);
      if (decoded is! Map) {
        throw const InvalidFormatException('备份文件顶层不是 JSON 对象');
      }
      return BackupEnvelope.fromJson(decoded.cast<String, Object?>());
    } on FormatException catch (e) {
      throw InvalidFormatException('备份文件 JSON 解析失败: ${e.message}');
    }
  }

  List<int> _randomBytes(int n) {
    final Uint8List out = Uint8List(n);
    final Random rnd = Random.secure();
    for (int i = 0; i < n; i++) {
      out[i] = rnd.nextInt(256);
    }
    return out;
  }
}
