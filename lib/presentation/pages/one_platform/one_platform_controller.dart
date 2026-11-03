/// One 平台（YBox）控制器（对齐 iOS `OnePlatformService`（ObservableObject 单例））。
///
/// 职责：认证信息（token / user-key / uuid）+ AES 密钥/IV 候选索引持久化 +
/// 加密请求/解密响应 + 密钥暴力探测 + 设备注册（游客模式）+ 业务方法
/// （分类 / 发现 / 每日推荐 / 专辑 / 章节 / 详情 / 播放地址 / 搜索）。
///
/// 协议（对齐 iOS）：
///   · 请求体 = `base64(AES-128-CBC(jsonEncode(parameters)))`，以原始密文串作 body；
///   · 请求头 = `token / user-key / uuid / timestamp / sign / platform / app-version`；
///   · `sign = md5(timestamp + body + userKey)`；
///   · 响应 = `base64(AES-128-CBC(json))`，解密后校验 `code`（0/200 为成功）。
///
/// 数据由 [PrefsManager] 持久化：`one_platform_key_idx` / `one_platform_iv_idx`
/// （普通键）+ `one_platform_token` / `one_platform_userkey` / `one_platform_uuid`
/// （敏感键，走安全存储）。
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/network/http_client.dart';
import '../../../core/utils/logger.dart';
import '../../../data/datasources/local/prefs_manager.dart';
import '../../../data/datasources/local/welfare_domain_store.dart';
import '../../../domain/entities/one_platform/one_platform.dart';

/// One 平台业务异常（对齐 iOS `OneError`）。
class OnePlatformException implements Exception {
  /// 构造。
  const OnePlatformException(this.message);

  /// 面向用户的可读描述。
  final String message;

  @override
  String toString() => message;
}

/// 视频列表分页结果（对齐 iOS `fetchVideos` 的 `(items, hasMore)` 元组）。
class OneVideoPage {
  /// 构造。
  const OneVideoPage({required this.items, required this.hasMore});

  /// 本页条目。
  final List<OneVideoItem> items;

  /// 是否还有下一页。
  final bool hasMore;
}

/// One 平台控制器。
class OnePlatformController extends ChangeNotifier {
  /// 构造（[client] 便于单测注入；[baseUrl] 覆盖默认 API 域名）。
  OnePlatformController({HttpClient? client, String? baseUrl})
      : _client = client ?? HttpClient(),
        _customBaseUrl = baseUrl;

  final HttpClient _client;
  final PrefsManager _prefs = PrefsManager.instance;
  final String? _customBaseUrl;

  // ── 契约键 ─────────────────────────────────────────────
  static const String keyIdxKey = 'one_platform_key_idx';
  static const String ivIdxKey = 'one_platform_iv_idx';
  static const String tokenKey = 'one_platform_token';
  static const String userKeyKey = 'one_platform_userkey';
  static const String uuidKey = 'one_platform_uuid';

  // ── 常量（对齐 iOS） ───────────────────────────────────
  static const String platformName = 'One平台';
  static const String fallbackBaseUrl = 'https://api.em1oifd0.com';
  static const String imageCdn = 'https://enimg807.5pkwjhp.com';
  static const String platform = '2';
  static const String appVersion = '5.2.0';
  static const String userAgent = 'iOS';

  /// 默认分类（对齐 iOS `defaultCategories`，注册失败/接口异常时兜底）。
  static const List<OneCategory> defaultCategories = <OneCategory>[
    OneCategory(cateId: '0', name: '推荐', sortOrder: 0),
    OneCategory(cateId: '1', name: '国产', sortOrder: 1),
    OneCategory(cateId: '2', name: '日韩', sortOrder: 2),
    OneCategory(cateId: '3', name: '欧美', sortOrder: 3),
    OneCategory(cateId: '4', name: '动漫', sortOrder: 4),
    OneCategory(cateId: '5', name: '自拍', sortOrder: 5),
    OneCategory(cateId: '6', name: '综艺', sortOrder: 6),
  ];

  // ── 状态 ──────────────────────────────────────────────
  String _token = '';
  String _userKey = '';
  String _uuid = '';
  bool _isRegistered = false;
  bool _isKeyFound = false;
  int _keyIdx = 0;
  int _ivIdx = 0;
  bool _initialized = false;

  /// 认证 token。
  String get token => _token;

  /// user-key。
  String get userKey => _userKey;

  /// 设备 UUID。
  String get uuid => _uuid;

  /// 是否已完成注册（token 非空）。
  bool get isRegistered => _isRegistered;

  /// 是否已探测到正确的 AES 密钥组合。
  bool get isKeyFound => _isKeyFound;

  /// 是否已加载过持久化状态。
  bool get isInitialized => _initialized;

  /// 当前 key 索引（调试用）。
  int get keyIndex => _keyIdx;

  /// 当前 IV 索引（调试用）。
  int get ivIndex => _ivIdx;

  /// 配置是否完整（token 与 user-key 均非空，对齐 iOS `isConfigured`）。
  bool get isConfigured => _token.isNotEmpty && _userKey.isNotEmpty;

  /// API 域名（优先 `WelfareDomainStore` 自定义域名，回退内置域名）。
  String get baseUrl =>
      _customBaseUrl ?? WelfareDomainStore.shared.domains(platformName).firstOrNull ?? fallbackBaseUrl;

  String get _keyHex =>
      OnePlatformCrypto.keyCandidates[_safe(_keyIdx, OnePlatformCrypto.keyCandidates)];

  String get _ivHex =>
      OnePlatformCrypto.ivCandidates[_safe(_ivIdx, OnePlatformCrypto.ivCandidates)];

  static int _safe(int idx, List<Object?> list) =>
      idx < 0 ? 0 : (idx >= list.length ? list.length - 1 : idx);

  // ── 初始化 / 重置 ──────────────────────────────────────

  /// 启动时加载持久化状态（首次进入页面前调用一次）。
  Future<void> init() async {
    _token = await _prefs.getString(tokenKey);
    _userKey = await _prefs.getString(userKeyKey);
    _uuid = await _prefs.getString(uuidKey);
    _isRegistered = _token.isNotEmpty;

    // UUID 自动生成并永久保存（对齐 iOS init）。
    if (_uuid.isEmpty) {
      _uuid = _generateUuid();
      await _prefs.set(uuidKey, _uuid);
    }

    // 加载已保存的密钥索引（对齐 iOS `loadSavedKeyIndex`）。
    final int savedKey = await _prefs.getInt(keyIdxKey);
    final int savedIv = await _prefs.getInt(ivIdxKey);
    _keyIdx = savedKey >= 0 && savedKey < OnePlatformCrypto.keyCandidates.length
        ? savedKey
        : 0;
    _ivIdx = savedIv >= 0 && savedIv < OnePlatformCrypto.ivCandidates.length
        ? savedIv
        : 0;
    _isKeyFound = savedKey > 0 || savedIv > 0;

    _initialized = true;
    notifyListeners();
  }

  /// 重置密钥配置（重新自动探测）。
  Future<void> resetKeyConfig() async {
    _keyIdx = 0;
    _ivIdx = 0;
    _isKeyFound = false;
    await _prefs.remove(keyIdxKey);
    await _prefs.remove(ivIdxKey);
    notifyListeners();
  }

  /// 生成 32 位小写十六进制 UUID（对齐 iOS `UUID().uuidString` 去横线）。
  static String _generateUuid() {
    final Random r = Random.secure();
    return List<String>.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  // ── 加解密 / 签名 ─────────────────────────────────────

  /// 当前密钥加密（明文字符串 → Base64 密文）。
  String? encrypt(String plaintext) => OnePlatformCrypto.encryptBase64(
        plaintext,
        OnePlatformCrypto.hexToBytes(_keyHex) ?? const <int>[],
        OnePlatformCrypto.hexToBytes(_ivHex) ?? const <int>[],
      );

  /// 当前密钥解密（Base64 密文 → 明文字符串）。
  String? decrypt(String base64Str) => OnePlatformCrypto.decryptBase64(
        base64Str,
        OnePlatformCrypto.hexToBytes(_keyHex) ?? const <int>[],
        OnePlatformCrypto.hexToBytes(_ivHex) ?? const <int>[],
      );

  /// 生成 sign（`md5(timestamp + body + userKey)`，对齐 iOS `generateSign`）。
  String generateSign({
    required String body,
    required String timestamp,
    String? customUserKey,
  }) =>
      OnePlatformCrypto.md5Hex(
        utf8.encode('$timestamp$body${customUserKey ?? _userKey}'),
      );

  // ── 网络请求 ──────────────────────────────────────────

  /// 发送加密请求并返回解密后的 JSON 对象（对齐 iOS `request`）。
  Future<Map<String, dynamic>> request(
    String path, {
    Map<String, Object?> parameters = const <String, Object?>{},
    String? customToken,
    String? customUserKey,
  }) async {
    final String timestamp =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final String reqToken = customToken ?? _token;
    final String reqUserKey = customUserKey ?? _userKey;

    final String bodyString = jsonEncode(parameters);
    final String? encrypted = encrypt(bodyString);
    if (encrypted == null) {
      throw const OnePlatformException('请求加密失败');
    }
    final String sign = generateSign(
      body: bodyString,
      timestamp: timestamp,
      customUserKey: reqUserKey,
    );

    final Uri uri = Uri.parse(baseUrl + path);
    final HttpClientResponse resp;
    try {
      resp = await _client.send(
        'POST',
        uri,
        headers: <String, String>{
          'user-agent': userAgent,
          'token': reqToken,
          'user-key': reqUserKey,
          'uuid': _uuid,
          'timestamp': timestamp,
          'sign': sign,
          'platform': platform,
          'app-version': appVersion,
        },
        body: encrypted,
      );
    } catch (e) {
      AppLog.warn('one_platform', '请求失败: $path', error: e);
      throw const OnePlatformException('网络请求失败');
    }
    if (!resp.isOk) {
      throw OnePlatformException('网络请求失败（HTTP ${resp.statusCode}）');
    }

    // 响应解密（含多密钥组合探测）。
    final String? decrypted = _decryptResponse(resp.text);
    if (decrypted != null) {
      final Object? decoded = _tryDecodeJson(decrypted);
      if (decoded is Map) {
        final Map<String, dynamic> json = _asStringMap(decoded);
        final int code = _asInt(json['code'] ?? json['retcode']) ?? -1;
        if (code != 0 && code != 200) {
          final String msg = (json['message'] ?? json['msg'] ?? '未知错误').toString();
          throw OnePlatformException('业务错误（$code）：$msg');
        }
        return json;
      }
    }

    // 解密失败：尝试直接解析（可能是未加密的错误响应）。
    final Object? plain = _tryDecodeJson(resp.text);
    if (plain is Map) return _asStringMap(plain);

    throw const OnePlatformException('响应解密失败（密钥可能不正确）');
  }

  /// 响应解密：优先当前密钥，失败后遍历全部 key×iv 组合并持久化命中索引。
  String? _decryptResponse(String responseString) {
    final String trimmed = responseString.trim();
    final String? direct = decrypt(trimmed);
    if (direct != null) return direct;

    final List<int>? data = OnePlatformCrypto.tryBase64Decode(trimmed);
    if (data == null) return null;
    for (int ki = 0; ki < OnePlatformCrypto.keyCandidates.length; ki++) {
      final List<int>? key =
          OnePlatformCrypto.hexToBytes(OnePlatformCrypto.keyCandidates[ki]);
      if (key == null) continue;
      for (int ii = 0; ii < OnePlatformCrypto.ivCandidates.length; ii++) {
        if (ki == _keyIdx && ii == _ivIdx) continue; // 已经试过
        final List<int>? iv =
            OnePlatformCrypto.hexToBytes(OnePlatformCrypto.ivCandidates[ii]);
        if (iv == null) continue;
        final List<int>? dec = OnePlatformCrypto.cbcDecrypt(key, iv, data);
        if (dec == null) continue;
        final String text = utf8.decode(dec, allowMalformed: true);
        final Object? json = _tryDecodeJson(text);
        if (json is Map) {
          _keyIdx = ki;
          _ivIdx = ii;
          _isKeyFound = true;
          unawaited(_saveCryptoConfig());
          AppLog.info('one_platform', '找到正确密钥: keyIdx=$ki, ivIdx=$ii');
          return text;
        }
      }
    }
    return null;
  }

  // ── 设备注册（游客模式） ──────────────────────────────

  /// 设备注册 —— 自动获取 token 与 user-key（对齐 iOS `registerDevice`）。
  ///
  /// 遍历「注册路径候选 × 参数组合 × 密钥组合」，逐次尝试直至命中。
  Future<bool> registerDevice() async {
    const List<String> pathCandidates = <String>[
      '/v1/register/token',
      '/v1/user/device',
      '/v1/app/init',
      '/v1/user/info',
      '/v2.5/user/device',
      '/v2.5/app/init',
      '/v2.5/user/register',
      '/v2.5/index/init',
      '/v2.5/user/login',
      '/v2.5/user/visitor',
      '/v2.5/index/config',
      '/v2.5/app/config',
      '/user/api/register',
      '/user/api/login',
    ];

    final List<Map<String, Object?>> paramCombinations = <Map<String, Object?>>[
      <String, Object?>{'device_id': _uuid, 'platform': platform, 'app_version': appVersion},
      <String, Object?>{'uuid': _uuid, 'platform': platform, 'app_version': appVersion},
      <String, Object?>{'device_id': _uuid, 'platform': platform},
      <String, Object?>{'uuid': _uuid, 'platform': platform},
      <String, Object?>{'device_id': _uuid},
      <String, Object?>{'uuid': _uuid},
    ];

    final int originalKey = _keyIdx;
    final int originalIv = _ivIdx;
    int attempts = 0;

    for (final String path in pathCandidates) {
      for (final Map<String, Object?> params in paramCombinations) {
        for (int ki = 0; ki < OnePlatformCrypto.keyCandidates.length; ki++) {
          for (int ii = 0; ii < OnePlatformCrypto.ivCandidates.length; ii++) {
            for (final String userKey
                in OnePlatformCrypto.initialUserKeyCandidates) {
              attempts += 1;
              _keyIdx = ki;
              _ivIdx = ii;
              try {
                final Map<String, dynamic> json = await request(
                  path,
                  parameters: params,
                  customToken: '',
                  customUserKey: userKey,
                );
                final bool ok = await _extractRegistration(json, ki, ii);
                if (ok) {
                  AppLog.info('one_platform',
                      '注册成功: path=$path, 第 $attempts 次尝试, keyIdx=$ki, ivIdx=$ii');
                  return true;
                }
              } catch (_) {
                // 继续下一个组合。
              }
            }
          }
        }
      }
    }

    // 恢复默认密钥。
    _keyIdx = originalKey;
    _ivIdx = originalIv;
    AppLog.warn('one_platform', '所有注册路径都失败（共尝试 $attempts 种组合）');
    return false;
  }

  /// 从注册响应中提取 token/user-key（`data` 内或顶层），命中则持久化。
  Future<bool> _extractRegistration(
    Map<String, dynamic> json,
    int keyIdx,
    int ivIdx,
  ) async {
    final Object? dataObj = json['data'];
    final Map<String, dynamic>? data =
        dataObj is Map ? _asStringMap(dataObj) : null;
    final String token = (data?['token'] ?? data?['access_token'] ?? json['token'] ?? '')
        .toString();
    if (token.isEmpty) return false;
    final String respUserKey =
        (data?['user_key'] ?? data?['userkey'] ?? json['user_key'] ?? '').toString();
    _token = token;
    if (respUserKey.isNotEmpty) _userKey = respUserKey;
    _isRegistered = true;
    await _prefs.set(tokenKey, _token);
    if (respUserKey.isNotEmpty) await _prefs.set(userKeyKey, _userKey);
    await _prefs.set(keyIdxKey, keyIdx);
    await _prefs.set(ivIdxKey, ivIdx);
    notifyListeners();
    return true;
  }

  /// 确保已注册（无 token 时自动注册，对齐 iOS `ensureRegistered`）。
  Future<bool> ensureRegistered() async {
    if (_isRegistered && _token.isNotEmpty) return true;
    return registerDevice();
  }

  // ── 业务方法 ──────────────────────────────────────────

  /// 获取分类列表（失败回退 [defaultCategories]）。
  Future<List<OneCategory>> fetchCategories() async {
    if (!await ensureRegistered()) return defaultCategories;
    try {
      final Map<String, dynamic> json = await request('/v2.5/article/category');
      final Object? data = json['data'];
      if (data is List) {
        return <OneCategory>[
          for (int i = 0; i < data.length; i++)
            if (_parseCategory(data[i], i) case final OneCategory c) c,
        ];
      }
    } catch (e) {
      AppLog.warn('one_platform', 'fetchCategories error', error: e);
    }
    return defaultCategories;
  }

  /// 获取发现页/分类视频列表（对齐 iOS `fetchVideos`）。
  Future<OneVideoPage> fetchVideos({
    String categoryId = '0',
    int page = 1,
  }) async {
    if (!await ensureRegistered()) {
      return const OneVideoPage(items: <OneVideoItem>[], hasMore: false);
    }
    final String path = categoryId == '0'
        ? '/v2.5/article/discovery'
        : '/v2.5/article/list';
    try {
      final Map<String, dynamic> json = await request(
        path,
        parameters: <String, Object?>{
          'page': page,
          'cateid': categoryId,
          'pagesize': 20,
        },
      );
      final Object? data = json['data'];
      if (data is Map) {
        final Map<String, dynamic> d = _asStringMap(data);
        final Object? rows = d['rows'] ?? d['list'];
        if (rows is List) {
          final List<OneVideoItem> items = rows
              .map(_parseVideoItem)
              .whereType<OneVideoItem>()
              .toList(growable: false);
          final int total = _asInt(d['total']) ?? 0;
          final int pageCount = _asInt(d['totalpage'] ?? d['pagecount']) ?? 0;
          final bool hasMore =
              page < pageCount || (total > 0 && items.length >= 20);
          return OneVideoPage(items: items, hasMore: hasMore);
        }
      }
    } catch (e) {
      AppLog.warn('one_platform', 'fetchVideos($categoryId, page:$page) error', error: e);
    }
    return const OneVideoPage(items: <OneVideoItem>[], hasMore: false);
  }

  /// 每日推荐（对齐 iOS `fetchDailyRecommend`）。
  Future<List<OneVideoItem>> fetchDailyRecommend() async {
    if (!await ensureRegistered()) return const <OneVideoItem>[];
    try {
      final Map<String, dynamic> json = await request('/v2.5/article/day');
      final Object? data = json['data'];
      if (data is List) {
        return data
            .map(_parseVideoItem)
            .whereType<OneVideoItem>()
            .toList(growable: false);
      }
    } catch (e) {
      AppLog.warn('one_platform', 'fetchDailyRecommend error', error: e);
    }
    return const <OneVideoItem>[];
  }

  /// 视频详情（对齐 iOS `fetchVideoDetail`）。
  Future<OneVideoDetail?> fetchVideoDetail(String articleId) async {
    if (!await ensureRegistered()) return null;
    try {
      final Map<String, dynamic> json = await request(
        '/v2.5/article/detail',
        parameters: <String, Object?>{'id': articleId},
      );
      final Object? data = json['data'];
      if (data is Map) return _parseVideoDetail(_asStringMap(data));
    } catch (e) {
      AppLog.warn('one_platform', 'fetchVideoDetail($articleId) error', error: e);
    }
    return null;
  }

  /// 播放地址（对齐 iOS `fetchPlayURL`）。
  Future<String?> fetchPlayURL(String articleId) async {
    if (!await ensureRegistered()) return null;
    try {
      final Map<String, dynamic> json = await request(
        '/v2.5/article/play',
        parameters: <String, Object?>{'id': articleId},
      );
      final Object? data = json['data'];
      if (data is Map) {
        final String? url =
            (data['url'] ?? data['playurl'])?.toString().trim();
        if (url != null && url.isNotEmpty) return url;
      }
    } catch (e) {
      AppLog.warn('one_platform', 'fetchPlayURL($articleId) error', error: e);
    }
    return null;
  }

  /// 专辑列表（对齐 iOS `fetchAlbums`）。
  Future<List<OneAlbum>> fetchAlbums({int page = 1}) async {
    if (!await ensureRegistered()) return const <OneAlbum>[];
    try {
      final Map<String, dynamic> json = await request(
        '/v2.5/series/album/list',
        parameters: <String, Object?>{'page': page, 'pagesize': 20},
      );
      final Object? data = json['data'];
      if (data is Map) {
        final Object? rows = _asStringMap(data)['rows'];
        if (rows is List) {
          return rows
              .map(_parseAlbum)
              .whereType<OneAlbum>()
              .toList(growable: false);
        }
      }
    } catch (e) {
      AppLog.warn('one_platform', 'fetchAlbums error', error: e);
    }
    return const <OneAlbum>[];
  }

  /// 专辑章节（对齐 iOS `fetchChapters`）。
  Future<List<OneChapter>> fetchChapters(String albumId, {int page = 1}) async {
    if (!await ensureRegistered()) return const <OneChapter>[];
    try {
      final Map<String, dynamic> json = await request(
        '/v2.5/series/chapters',
        parameters: <String, Object?>{'id': albumId, 'page': page},
      );
      final Object? data = json['data'];
      if (data is List) {
        return <OneChapter>[
          for (int i = 0; i < data.length; i++)
            if (_parseChapter(data[i], i) case final OneChapter c) c,
        ];
      }
    } catch (e) {
      AppLog.warn('one_platform', 'fetchChapters($albumId) error', error: e);
    }
    return const <OneChapter>[];
  }

  /// 搜索（对齐 iOS `search`）。
  Future<List<OneVideoItem>> search(String keyword, {int page = 1}) async {
    try {
      final Map<String, dynamic> json = await request(
        '/v2.5/article/search',
        parameters: <String, Object?>{'keyword': keyword, 'page': page},
      );
      final Object? data = json['data'];
      if (data is Map) {
        final Object? rows = _asStringMap(data)['rows'];
        if (rows is List) {
          return rows
              .map(_parseVideoItem)
              .whereType<OneVideoItem>()
              .toList(growable: false);
        }
      }
    } catch (e) {
      AppLog.warn('one_platform', 'search($keyword) error', error: e);
    }
    return const <OneVideoItem>[];
  }

  // ── 解析器（对齐 iOS parseVideoItem / parseVideoDetail / parseAlbum）──

  OneCategory? _parseCategory(Object? raw, int index) {
    if (raw is! Map) return null;
    final Map<String, dynamic> d = _asStringMap(raw);
    final String cateId = (d['cateid'] ?? d['id'] ?? '').toString();
    final String? name = (d['name'] ?? d['catename'])?.toString();
    if (cateId.isEmpty || name == null || name.isEmpty) return null;
    return OneCategory(
      cateId: cateId,
      name: name,
      icon: d['icon']?.toString(),
      sortOrder: index,
    );
  }

  OneVideoItem? _parseVideoItem(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, dynamic> d = _asStringMap(raw);
    final String articleId = (d['id'] ?? d['articleid'] ?? '').toString();
    if (articleId.isEmpty) return null;
    return OneVideoItem(
      articleId: articleId,
      title: (d['title'] ?? d['name'] ?? '未知标题').toString(),
      cover: imageURL((d['cover'] ?? d['coverpic'] ?? d['pic'] ?? '').toString()),
      duration: (d['duration'] ?? d['timelength'] ?? '').toString(),
      views: _asInt(d['views'] ?? d['playnum'] ?? d['hits']) ?? 0,
      likes: _asInt(d['likes'] ?? d['upnum']) ?? 0,
      categoryId: (d['cateid'] ?? d['categoryid'] ?? '0').toString(),
      categoryName: (d['catename'] ?? d['category'])?.toString(),
      tags: _extractTags(d),
      rating: (d['score'] ?? d['rating'])?.toString(),
      uploadTime: (d['addtime'] ?? d['uptime'])?.toString(),
      description: (d['description'] ?? d['intro'])?.toString(),
      actorName: (d['actor'] ?? d['actorname'])?.toString(),
    );
  }

  OneVideoDetail _parseVideoDetail(Map<String, dynamic> d) {
    final String articleId = (d['id'] ?? '').toString();
    final String title = (d['title'] ?? '').toString();
    final String cover = imageURL((d['cover'] ?? '').toString());
    final String duration = (d['duration'] ?? '').toString();
    final int views = _asInt(d['views']) ?? 0;
    final int likes = _asInt(d['likes']) ?? 0;
    final String description = (d['description'] ?? d['intro'] ?? '').toString();

    final List<OnePlaySource> playUrls = <OnePlaySource>[];
    final Object? list = d['playurls'];
    if (list is List) {
      for (final Object? item in list) {
        if (item is Map) {
          final Map<String, dynamic> m = _asStringMap(item);
          final String? name = m['name']?.toString();
          final String? url = m['url']?.toString();
          if (name != null && url != null) {
            playUrls.add(OnePlaySource(name: name, url: url));
          }
        }
      }
    }
    final String? single = (d['playurl'] ?? d['url'])?.toString();
    if (single != null && single.isNotEmpty) {
      playUrls.add(OnePlaySource(name: '默认', url: single));
    }

    return OneVideoDetail(
      articleId: articleId,
      title: title,
      cover: cover,
      duration: duration,
      views: views,
      likes: likes,
      description: description,
      tags: _extractTags(d),
      actorName: d['actor']?.toString(),
      categoryName: d['catename']?.toString(),
      uploadTime: d['addtime']?.toString(),
      rating: d['score']?.toString(),
      playUrl: playUrls.isEmpty ? null : playUrls.first.url,
      playUrls: playUrls,
    );
  }

  OneAlbum? _parseAlbum(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, dynamic> d = _asStringMap(raw);
    final String albumId = (d['id'] ?? d['albumid'] ?? '').toString();
    if (albumId.isEmpty) return null;
    return OneAlbum(
      albumId: albumId,
      title: (d['title'] ?? '').toString(),
      cover: imageURL((d['cover'] ?? '').toString()),
      description: (d['description'] ?? '').toString(),
      itemCount: _asInt(d['itemcount'] ?? d['total']) ?? 0,
      rating: d['score']?.toString(),
    );
  }

  OneChapter? _parseChapter(Object? raw, int index) {
    if (raw is! Map) return null;
    final Map<String, dynamic> d = _asStringMap(raw);
    final String chapId = (d['id'] ?? d['chapterid'] ?? '').toString();
    if (chapId.isEmpty) return null;
    return OneChapter(
      chapterId: chapId,
      title: (d['title'] ?? '第${index + 1}章').toString(),
      sortOrder: index,
      isPaid: d['ispaid'] == true,
      hasRead: d['hasread'] == true,
    );
  }

  static List<String> _extractTags(Map<String, dynamic> d) {
    final Object? tags = d['tags'];
    if (tags is List) {
      return tags.map((Object? e) => e.toString()).toList(growable: false);
    }
    final Object? tag = d['tag'];
    if (tag is String && tag.isNotEmpty) return <String>[tag];
    return const <String>[];
  }

  /// 拼接完整图片 URL（相对路径补 CDN 域名）。
  String imageURL(String path) {
    final String trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    return imageCdn + (trimmed.startsWith('/') ? trimmed : '/$trimmed');
  }

  // ── 保存配置 ──────────────────────────────────────────

  /// 保存手动配置（对齐 iOS `saveToken`）。
  Future<void> saveToken({
    required String token,
    required String userKey,
    required String uuid,
  }) async {
    _token = token.trim();
    _userKey = userKey.trim();
    _uuid = uuid.trim();
    _isRegistered = _token.isNotEmpty;
    await _prefs.set(tokenKey, _token);
    await _prefs.set(userKeyKey, _userKey);
    await _prefs.set(uuidKey, _uuid);
    notifyListeners();
  }

  // ── JSON 工具 ─────────────────────────────────────────

  static Object? _tryDecodeJson(String text) {
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  static Map<String, dynamic> _asStringMap(Map<dynamic, dynamic> m) =>
      m.map((dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v));

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  Future<void> _saveCryptoConfig() async {
    await _prefs.set(keyIdxKey, _keyIdx);
    await _prefs.set(ivIdxKey, _ivIdx);
  }
}

/// 忽略返回的 Future（配合 `unawaited` 语义，避免引入 `dart:async` 依赖）。
void unawaited(Future<void> future) {}