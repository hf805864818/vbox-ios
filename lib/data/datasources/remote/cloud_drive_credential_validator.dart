/// 云盘凭据真实校验器（第 4 批 F-P24）。
///
/// 唯一真相源：iOS `CloudDriveAuthManager.validateCredential(for:)`
/// （[L2389-L2423](../../../../vbox/Services/CloudDriveAuthManager.swift#L2389-L2423)）
/// 及其按盘分派的真实网络校验：
///  - **Cookie 类网盘**（115/夸克/UC/139/189/迅雷）→ [validateCookie] L3041-3074；
///  - **百度** → `baiduFetchTemplateVariables` L2933-2961（gettemplatevariable，
///    errno != 0 判失效，bdstoken/uk 任一非空判通过）；
///  - **123 云盘** → `validatePan123Credential` L2963-3039（GET → POST 重试序，
///    code Int/String 双形态判定）；
///  - **Node 托管盘**（光鸭/蜗牛/B站/夸克Node/UCNode/百度Node）→
///    `validateNodeManagedCredential` L2645-2674（本地核心字段非空即可，
///    真实有效性由 Node 侧解析链路运行时判定）；
///  - **阿里** → iOS 走 `refreshAliAccessTokenIfNeeded()`（刷新即校验）。
///
/// **与 iOS 的已知差异**（登记，不臆造）：阿里刷新在 Flutter 端授权链未含
/// 「刷新结果落库」闭环（阿里 refresh token 存在轮换语义，校验时调用刷新但不
/// 落库会导致用户凭据失效），故降级为 refreshToken / accessToken 字段校验。
///
/// 结果语义对齐 iOS `markValid` / `markInvalid`（state + statusMessage +
/// lastCheckedAt 由调用方落库）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../../domain/entities/cloud/cloud_drive.dart';
import '../local/prefs_manager.dart';

/// 校验异常（对齐 iOS `AuthError` 的两类文案来源：`notAuthorized` / `remoteError`）。
class CredentialValidationException implements Exception {
  const CredentialValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 校验结果（`valid` + 状态文案；落库语义见文件头注释）。
class CredentialValidationResult {
  const CredentialValidationResult({
    required this.valid,
    this.message,
    this.skipped = false,
  });

  final bool valid;

  /// 成功 → 「授权检测正常」（对齐 iOS `markValid` 缺省 message）；
  /// 失败 → iOS 侧 `error.localizedDescription` 同源文案。
  final String? message;

  /// P2-5：防风控冷却期内跳过远程校验（true 时调用方**不应**据此改落库
  /// 状态——结果既非「已验证有效」也非「已验证失效」）。
  final bool skipped;
}

/// 凭据校验器（纯静态依赖注入 http client，便于单测）。
class CloudDriveCredentialValidator {
  CloudDriveCredentialValidator({http.Client? client, PrefsManager? prefs})
      : _client = client ?? http.Client(),
        _prefs = prefs;

  final http.Client _client;

  /// prefs 持久化（P2-5 冷却；null → 仅进程内存冷却，测试环境友好）。
  final PrefsManager? _prefs;

  /// 通用 UA（对齐 iOS `validateCookie` L3053）。
  static const String _chromeUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';

  /// 115 等需要的完整 Chrome UA（对齐 iOS L3050）。
  static const String _chromeFullUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 校验入口（对齐 iOS `validateCredential(for:)` 的按盘分派）。
  Future<CredentialValidationResult> validate(
    CloudDriveType type,
    CloudDriveCredential credential,
  ) async {
    try {
      switch (type) {
        case CloudDriveType.ali:
          _validateAli(credential);
        case CloudDriveType.one15:
          await validateCookie(
            url: 'https://webapi.115.com/files?cid=0&limit=1',
            cookie: credential.cookie ?? '',
            referer: 'https://115.com/',
            is115: true,
          );
        case CloudDriveType.quark:
          await validateCookie(
            url:
                'https://drive-pc.quark.cn/1/clouddrive/member?pr=ucpro&fr=pc&sys=darwin&ve=3.19.0',
            cookie: credential.cookie ?? '',
            referer: 'https://pan.quark.cn/',
          );
        case CloudDriveType.uc:
          await validateCookie(
            url: 'https://pc-api.uc.cn/1/clouddrive/file/sort?pr=UCBrowser&fr=pc',
            cookie: credential.cookie ?? '',
            referer: 'https://drive.uc.cn/',
          );
        case CloudDriveType.baidu:
          // P2-5：防风控冷却（对齐 iOS `baiduIsVerifyCoolingDown` /
          // `baiduMarkVerifyCooldown`，`CloudDriveAuthManager.swift:1318-1337`，
          // prefs 键 `baidu_verify_cooldowns_v1`）：校验失败记 10 分钟冷却，
          // 冷却期内跳过远程校验，避免频繁触发百度风控。
          final String key = _baiduCooldownKey(credential.cookie ?? '');
          if (await _baiduIsVerifyCoolingDown(key)) {
            return const CredentialValidationResult(
              valid: false,
              message: '检测过于频繁，已跳过远程校验（防风控冷却中）',
              skipped: true,
            );
          }
          try {
            await validateBaiduCookie(credential.cookie ?? '');
          } on CredentialValidationException {
            await _baiduMarkVerifyCooldown(key);
            rethrow;
          }
        case CloudDriveType.pan123:
          await validatePan123(
            cookie: credential.cookie ?? '',
            token: credential.accessToken ?? '',
          );
        case CloudDriveType.pan139:
          await validateCookie(
            url: 'https://yun.139.com/',
            cookie: credential.cookie ?? '',
            referer: 'https://yun.139.com/',
          );
        case CloudDriveType.pan189:
          await validateCookie(
            url: 'https://cloud.189.cn/',
            cookie: credential.cookie ?? '',
            referer: 'https://cloud.189.cn/',
          );
        case CloudDriveType.xunlei:
          await validateCookie(
            url: 'https://pan.xunlei.com/',
            cookie: credential.cookie ?? '',
            referer: 'https://pan.xunlei.com/',
          );
        case CloudDriveType.quarkNode:
        case CloudDriveType.ucNode:
        case CloudDriveType.baiduNode:
        case CloudDriveType.guangya:
        case CloudDriveType.woniu4k:
        case CloudDriveType.bilibili:
          validateNodeManaged(type, credential);
        }
      return const CredentialValidationResult(valid: true, message: '授权检测正常');
    } on CredentialValidationException catch (e) {
      return CredentialValidationResult(valid: false, message: e.message);
    } catch (_) {
      // 网络异常等非业务失败（对齐 iOS catch 后 markInvalid(reason) 的兜底文案）。
      return const CredentialValidationResult(valid: false, message: '网络错误，请稍后重试');
    }
  }

  /// 阿里：字段校验（与 iOS 差异见文件头注释）。
  void _validateAli(CloudDriveCredential credential) {
    final bool hasSecret = (credential.refreshToken?.isNotEmpty ?? false) ||
        (credential.accessToken?.isNotEmpty ?? false);
    if (!hasSecret) {
      throw const CredentialValidationException('阿里云盘未配置 Refresh Token');
    }
  }

  /// Cookie 类校验（逐字对齐 iOS `validateCookie` L3041-3074）。
  ///
  /// - `url` 含 `/file/sort`（UC）→ POST + JSON body，其余 GET；
  /// - 115 → 完整 Chrome UA + `Origin: https://115.com`；
  /// - HTTP 401/403 / `state == false` / `code ∈ {401, 403, 40001}` → 失效。
  Future<void> validateCookie({
    required String url,
    required String cookie,
    required String referer,
    bool is115 = false,
  }) async {
    if (cookie.isEmpty) {
      throw const CredentialValidationException('Cookie 为空');
    }
    final bool isPost = url.contains('/file/sort');
    final Uri uri = Uri.parse(url);
    final Map<String, String> headers = <String, String>{
      'Cookie': cookie,
      'Referer': referer,
      'User-Agent': is115 ? _chromeFullUA : _chromeUA,
      if (is115) 'Origin': 'https://115.com',
      if (isPost) 'Content-Type': 'application/json',
    };
    final http.Response resp = isPost
        ? await _client.post(uri, headers: headers,
            body: jsonEncode(<String, Object>{
              'pdir_fid': '0', 'page': 1, 'size': 1,
            }))
        : await _client.get(uri, headers: headers);
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw CredentialValidationException('HTTP ${resp.statusCode}');
    }
    final Map<String, Object?>? json = _tryDecode(resp.body);
    if (json != null) {
      final Object? state = json['state'];
      if (state is bool && !state) {
        throw CredentialValidationException(
          (json['error'] ?? json['message'])?.toString() ?? 'Cookie 无效',
        );
      }
      final Object? code = json['code'];
      final int? codeInt = code is int ? code : int.tryParse('$code');
      if (codeInt == 401 || codeInt == 403 || codeInt == 40001) {
        throw CredentialValidationException(
          json['message']?.toString() ?? 'Cookie 无效 code=$codeInt',
        );
      }
    }
  }

  /// 百度校验（对齐 iOS `baiduFetchTemplateVariables` L2933-2961）。
  Future<void> validateBaiduCookie(String cookie) async {
    if (cookie.isEmpty) {
      throw const CredentialValidationException('百度 Cookie 为空');
    }
    final Uri uri = Uri.parse(
      'https://pan.baidu.com/api/gettemplatevariable'
      '?clienttype=0&app_id=250528&web=1'
      '&fields=${Uri.encodeComponent('["bdstoken","token","uk","username","servertime"]')}',
    );
    final http.Response resp = await _client.get(
      uri,
      headers: <String, String>{
        'Cookie': cookie,
        'User-Agent': _chromeFullUA,
        'Referer': 'https://pan.baidu.com/',
      },
    );
    final Map<String, Object?>? json = _tryDecode(resp.body);
    if (json == null) {
      throw const CredentialValidationException('百度登录态校验失败（响应非 JSON）');
    }
    final int? errno = (json['errno'] is int)
        ? json['errno'] as int
        : int.tryParse('${json['errno']}');
    if (errno != null && errno != 0) {
      throw CredentialValidationException('百度登录态异常 errno=$errno');
    }
    final Map<String, Object?> result =
        (json['result'] as Map?)?.cast<String, Object?>() ?? json;
    final bool hasIdentity =
        _nonEmptyString(result['bdstoken']) || _nonEmptyString(result['uk']);
    if (!hasIdentity) {
      throw const CredentialValidationException('百度未返回 bdstoken/uk');
    }
  }

  /// 123 云盘校验（对齐 iOS `validatePan123Credential` L2963-3039）。
  ///
  /// GET → POST 重试序；`code` 为 Int 或 String 双形态（0/200/ok 判通过，
  /// 401/403/40001 判失效）；全部尝试失败 → 带 HTTP 状态与响应前 200 字。
  Future<void> validatePan123({
    required String cookie,
    required String token,
  }) async {
    if (cookie.isEmpty && token.isEmpty) {
      throw const CredentialValidationException('123云盘 Cookie 与 Token 均为空');
    }
    const String base = 'https://www.123pan.com/api/file/list/new';
    const String query =
        'driveId=0&limit=1&next=1&orderBy=filename&orderDirection=asc'
        '&parentFileId=0&trashed=false&operateType=4';
    int lastStatus = 0;
    String lastBody = '';
    for (final String method in const <String>['GET', 'POST']) {
      final Uri uri = Uri.parse(method == 'GET' ? '$base?$query' : base);
      final Map<String, String> headers = <String, String>{
        'Referer': 'https://www.123pan.com/',
        'User-Agent': _chromeFullUA,
        if (cookie.isNotEmpty) 'Cookie': cookie,
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        if (method == 'POST') 'Content-Type': 'application/json',
      };
      final http.Response resp = method == 'POST'
          ? await _client.post(
              uri,
              headers: headers,
              body: jsonEncode(<String, Object>{
                'driveId': 0, 'limit': 1, 'next': 1, 'orderBy': 'filename',
                'orderDirection': 'asc', 'parentFileId': 0,
                'trashed': false, 'operateType': 4,
              }),
            )
          : await _client.get(uri, headers: headers);
      lastStatus = resp.statusCode;
      lastBody = resp.body;
      if (lastStatus == 401 || lastStatus == 403) continue;
      final Map<String, Object?>? json = _tryDecode(resp.body);
      if (json == null) continue;
      final Object? code = json['code'];
      final int? codeInt = code is int ? code : int.tryParse('$code');
      final String? codeStr = code?.toString().toLowerCase();
      final bool isSuccess = codeInt == 0 ||
          codeInt == 200 ||
          codeStr == '0' ||
          codeStr == '200' ||
          codeStr == 'ok';
      if (isSuccess) return;
      final Object? state = json['state'];
      final bool stateFalse = state is bool && !state;
      final bool unauthorized =
          codeInt == 401 || codeInt == 403 || codeInt == 40001;
      if (stateFalse || unauthorized) {
        final String msg = (json['error'] ?? json['message'])?.toString() ??
            '123云盘登录态无效';
        if (method != 'POST') continue;
        throw CredentialValidationException(msg);
      }
    }
    final String detail = lastStatus != 0 ? 'HTTP $lastStatus' : '无响应';
    final String preview =
        lastBody.length > 200 ? lastBody.substring(0, 200) : lastBody;
    throw CredentialValidationException('123云盘登录态校验失败 ($detail): $preview');
  }

  /// Node 托管盘本地校验（逐字对齐 iOS `validateNodeManagedCredential`
  /// L2645-2674 的分盘文案）。
  void validateNodeManaged(CloudDriveType type, CloudDriveCredential c) {
    switch (type) {
      case CloudDriveType.guangya:
        if ((c.extra['token'] ?? '').isEmpty) {
          throw const CredentialValidationException('光鸭网盘未配置 Token，请先扫码授权');
        }
      case CloudDriveType.woniu4k:
        if ((c.cookie ?? '').isEmpty) {
          throw const CredentialValidationException('蜗牛网盘未配置 Cookie，请先账号登录');
        }
      case CloudDriveType.bilibili:
        if ((c.cookie ?? '').isEmpty) {
          throw const CredentialValidationException('B站未配置 Cookie，请先扫码登录');
        }
      case CloudDriveType.ucNode:
        // Cookie 主凭据或 Node 侧回拉的 TV Token 任一非空即可（iOS L2659-2666）。
        final bool hasAny = (c.cookie ?? '').isNotEmpty ||
            (c.extra['uc_node_tv_token'] ?? '').isNotEmpty;
        if (!hasAny) {
          throw const CredentialValidationException(
              'UC网盘Node未配置 Cookie / TV Token，请先扫码登录或粘贴 Token');
        }
      case CloudDriveType.baiduNode:
        if ((c.cookie ?? '').isEmpty) {
          throw const CredentialValidationException('百度网盘Node未配置 Cookie，请先扫码登录或粘贴 Cookie');
        }
      case CloudDriveType.quarkNode:
        // iOS default 分支（L2671-2672）：夸克Node 无额外校验字段 → 直接通过。
        break;
      default:
        break;
    }
  }

  // ─────────────── P2-5 · 百度验证防风控冷却 ───────────────

  /// 冷却 prefs 键（契约 `baidu_verify_cooldowns_v1`，对齐 iOS
  /// `baiduVerifyCooldownKey`，`CloudDriveAuthManager.swift:79`）。
  static const String _baiduCooldownPrefsKey = 'baidu_verify_cooldowns_v1';

  /// 进程内冷却缓存（prefs 不可用时的回退，单测环境友好）。
  final Map<String, int> _memoryCooldowns = <String, int>{};

  /// 冷却 key：凭据稳定标识（优先 BDUSS 值——账号身份、重登 cookie 变化仍
  /// 命中；提取不到回退整段 cookie 的 MD5）。
  String _baiduCooldownKey(String cookie) {
    final RegExpMatch? m = RegExp(r'BDUSS=([^;]+)').firstMatch(cookie);
    if (m != null && m.group(1)!.isNotEmpty) return 'bduss:${m.group(1)}';
    return 'md5:${md5.convert(utf8.encode(cookie)).toString()}';
  }

  /// 读冷却缓存（JSON `{key: epochMs}`；prefs 异常回退内存缓存）。
  Future<Map<String, int>> _loadCooldowns() async {
    final PrefsManager? p = _prefs;
    if (p == null) return Map<String, int>.of(_memoryCooldowns);
    try {
      final Object? raw = await p.get(_baiduCooldownPrefsKey);
      if (raw is! String || raw.isEmpty) {
        return Map<String, int>.of(_memoryCooldowns);
      }
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return Map<String, int>.of(_memoryCooldowns);
      return decoded.map<String, int>((Object? k, Object? v) =>
          MapEntry<String, int>('$k', v is int ? v : int.tryParse('$v') ?? 0));
    } catch (_) {
      return Map<String, int>.of(_memoryCooldowns);
    }
  }

  /// 写冷却缓存（同步刷内存缓存；prefs 异常静默——冷却不阻断校验主流程）。
  Future<void> _saveCooldowns(Map<String, int> cache) async {
    _memoryCooldowns
      ..clear()
      ..addAll(cache);
    final PrefsManager? p = _prefs;
    if (p == null) return;
    try {
      await p.set(_baiduCooldownPrefsKey, jsonEncode(cache));
    } catch (_) {
      // prefs 不可用（未初始化等）→ 仅内存冷却。
    }
  }

  /// 冷却判定（对齐 iOS `baiduIsVerifyCoolingDown`：读取即清理过期项）。
  Future<bool> _baiduIsVerifyCoolingDown(String key) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final Map<String, int> cache = await _loadCooldowns();
    final Map<String, int> alive = <String, int>{
      for (final MapEntry<String, int> e in cache.entries)
        if (e.value > now) e.key: e.value,
    };
    if (alive.length != cache.length) await _saveCooldowns(alive);
    return (alive[key] ?? 0) > now;
  }

  /// 记冷却（对齐 iOS `baiduMarkVerifyCooldown`：默认 10 分钟；
  /// >60 项清理过期（对齐 iOS 缓存上限），仍超限移除最早过期项）。
  Future<void> _baiduMarkVerifyCooldown(
    String key, {
    int seconds = 10 * 60,
  }) async {
    final Map<String, int> cache = await _loadCooldowns();
    cache[key] =
        DateTime.now().millisecondsSinceEpoch + Duration(seconds: seconds).inMilliseconds;
    if (cache.length > 60) {
      final int now = DateTime.now().millisecondsSinceEpoch;
      cache.removeWhere((_, int v) => v <= now);
      while (cache.length > 60) {
        final String oldest = cache.entries
            .reduce((MapEntry<String, int> a, MapEntry<String, int> b) =>
                a.value <= b.value ? a : b)
            .key;
        cache.remove(oldest);
      }
    }
    await _saveCooldowns(cache);
  }

  Map<String, Object?>? _tryDecode(String body) {
    try {
      final Object? v = jsonDecode(body);
      return v is Map<String, Object?> ? v : null;
    } catch (_) {
      return null;
    }
  }

  bool _nonEmptyString(Object? v) => v is String && v.isNotEmpty;
}
