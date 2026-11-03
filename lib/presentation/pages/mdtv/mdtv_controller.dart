/// 麻豆平台（MDTV）控制器（对齐 iOS `MDTVService`（ObservableObject 单例））。
///
/// 职责：密钥/IV/模式候选索引 + `PrefsManager` 持久化 + 加密请求/解密响应 +
/// 暴力密钥探测 + 业务方法（Tab 配置 / 分类 / 视频列表 / 标签 / 搜索 /
/// 详情 / 播放地址）。
///
/// 协议（对齐 iOS）：请求 `{"post-data": base64(加密参数)}`，携带
/// `suffix: JGDZMX` 头；响应 `{"data": base64(加密数据)}`，解密校验 JSON。
/// 解密失败时按 `mode(CFB→CBC→ECB) × key × IV` 暴力探测，命中后持久化索引。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/network/http_client.dart';
import '../../../core/utils/logger.dart';
import '../../../data/datasources/local/prefs_manager.dart';
import '../../../domain/entities/mdtv/mdtv.dart';

/// MDTV 业务异常（对齐 iOS `MDTVError.errorDescription`）。
class MdtvException implements Exception {
  /// 构造。
  const MdtvException(this.message);

  /// 面向用户的可读描述。
  final String message;

  @override
  String toString() => message;
}

/// 麻豆平台控制器。
class MdtvController extends ChangeNotifier {
  /// 构造（[client] 便于单测注入；[baseUrl] 覆盖默认 API 域名）。
  MdtvController({HttpClient? client, String? baseUrl})
      : _client = client ?? HttpClient(),
        _customBaseUrl = baseUrl;

  final HttpClient _client;
  final PrefsManager _prefs = PrefsManager.instance;
  final String? _customBaseUrl;

  // ── 契约键 ─────────────────────────────────────────────
  static const String _homeTabsKey = 'mdtv_home_tabs';
  static const String _ivIdxKey = 'mdtv_iv_idx';
  static const String _keyIdxKey = 'mdtv_key_idx';
  static const String _keyVerifiedKey = 'mdtv_key_verified';
  static const String _modeIdxKey = 'mdtv_mode_idx';

  // ── 常量（对齐 iOS） ───────────────────────────────────
  static const String platformSuffix = 'JGDZMX';
  static const String fallbackBaseUrl = 'https://api.nzp1ve.com';
  static const String imageCdn = 'https://vvbacksixiuw.n123dx.xyz';
  static const String userAgent = 'Dart/3.4 (dart:io)';
  static const List<String> defaultTabs = <String>['推荐', '分类', '标签'];

  // ── 状态 ──────────────────────────────────────────────
  List<String> _homeTabs = List<String>.of(defaultTabs);
  bool _isKeyFound = false;
  int _keyIdx = 0;
  int _ivIdx = 0;
  int _modeIdx = 0;
  bool _initialized = false;

  bool get isInitialized => _initialized;

  bool get isKeyFound => _isKeyFound;

  List<String> get homeTabs => List<String>.unmodifiable(_homeTabs);

  String get baseUrl => _customBaseUrl ?? fallbackBaseUrl;

  String get _keyHex => MdtvCrypto.keyCandidates[_safe(_keyIdx, MdtvCrypto.keyCandidates)];

  String get _ivHex => MdtvCrypto.ivCandidates[_safe(_ivIdx, MdtvCrypto.ivCandidates)];

  MdtvEncryptMode get _mode =>
      MdtvCrypto.modeCandidates[_safe(_modeIdx, MdtvCrypto.modeCandidates)];

  static int _safe(int idx, List<Object?> list) =>
      idx < 0 ? 0 : (idx >= list.length ? list.length - 1 : idx);

  // ── 初始化 / 重置 ──────────────────────────────────────

  /// 启动时加载持久化状态（页面 onAppear 前调用一次）。
  Future<void> init() async {
    _keyIdx = await _prefs.getInt(_keyIdxKey);
    _ivIdx = await _prefs.getInt(_ivIdxKey);
    _modeIdx = await _prefs.getInt(_modeIdxKey);
    final bool verified = await _prefs.getBool(_keyVerifiedKey);
    _isKeyFound = (_keyIdx > 0 || _modeIdx > 0) && verified;

    final List<dynamic> tabs = await _prefs.getJsonList(_homeTabsKey);
    final List<String> loaded = tabs.whereType<String>().toList();
    _homeTabs = loaded.isEmpty ? List<String>.of(defaultTabs) : loaded;
    _initialized = true;
    notifyListeners();
  }

  /// 重置密钥配置（重新自动探测）。
  Future<void> resetKeyConfig() async {
    _keyIdx = 0;
    _ivIdx = 0;
    _modeIdx = 0;
    _isKeyFound = false;
    await _prefs.remove(_keyIdxKey);
    await _prefs.remove(_ivIdxKey);
    await _prefs.remove(_modeIdxKey);
    await _prefs.remove(_keyVerifiedKey);
    notifyListeners();
  }

  /// 重置首页 Tab（恢复默认）。
  Future<void> resetTabs() async {
    _homeTabs = List<String>.of(defaultTabs);
    await _prefs.remove(_homeTabsKey);
    notifyListeners();
  }

  // ── 业务方法 ──────────────────────────────────────────

  /// 获取首页 Tab 配置（远程优先，失败回退本地默认）。
  Future<List<String>> fetchTabConfig() async {
    try {
      final Object? dec = await _roundTrip('/app/mdtv/home_tabs');
      final List<String> tabs = _extractStringList(dec);
      if (tabs.isNotEmpty) {
        _homeTabs = tabs;
        await _saveTabs();
        notifyListeners();
      }
    } catch (e) {
      AppLog.warn('mdtv', '远程 Tab 配置获取失败', error: e);
    }
    return _homeTabs;
  }

  /// 获取分类/频道列表。
  Future<List<MdtvCategory>> fetchCategories() async {
    final Object? dec = await _roundTrip('/video/channel');
    return _unwrapList(dec)
        .whereType<Map>()
        .map(_asStringMap)
        .map(MdtvCategory.fromJson)
        .toList(growable: false);
  }

  /// 获取视频列表（[categoryId] 为空表示全部）。
  Future<List<MdtvVideoItem>> fetchVideos({
    String? categoryId,
    int page = 1,
    int limit = 20,
  }) async {
    final Map<String, Object?> params = <String, Object?>{
      'page': page,
      'limit': limit,
      if (categoryId != null) 'cid': categoryId,
    };
    final Object? dec = await _roundTrip('/video/listcache', params);
    return _unwrapList(dec)
        .whereType<Map>()
        .map(_asStringMap)
        .map(MdtvVideoItem.fromJson)
        .toList(growable: false);
  }

  /// 获取标签列表。
  Future<List<MdtvTag>> fetchTags() async {
    final Object? dec = await _roundTrip('/video/tags');
    return _unwrapList(dec)
        .whereType<Map>()
        .map(_asStringMap)
        .map(MdtvTag.fromJson)
        .toList(growable: false);
  }

  /// 搜索视频。
  Future<List<MdtvVideoItem>> searchVideos(String keyword, {int page = 1}) async {
    final Object? dec = await _roundTrip(
      '/app/mdtv/search',
      <String, Object?>{'keyword': keyword, 'page': page},
    );
    return _unwrapList(dec)
        .whereType<Map>()
        .map(_asStringMap)
        .map(MdtvVideoItem.fromJson)
        .toList(growable: false);
  }

  /// 获取视频详情。
  Future<MdtvVideoDetail?> fetchVideoDetail(String videoId) async {
    final Object? dec = await _roundTrip(
      '/video/detail',
      <String, Object?>{'vid': videoId},
    );
    final Map<String, dynamic>? map = _unwrapMap(dec);
    return map == null ? null : MdtvVideoDetail.fromJson(map);
  }

  /// 获取播放地址（多线路时取首线路）。
  Future<String?> fetchPlayURL(String videoId) async {
    final Object? dec = await _roundTrip(
      '/video/play',
      <String, Object?>{'vid': videoId},
    );
    final Map<String, dynamic>? map = _unwrapMap(dec);
    if (map == null) return null;
    final String? direct = map['playUrl']?.toString().trim();
    if (direct != null && direct.isNotEmpty) return direct;
    final List<Object?> urls = map['playUrls'] is List
        ? (map['playUrls'] as List).cast<Object?>()
        : const <Object?>[];
    for (final Object? u in urls) {
      if (u is Map) {
        final String? url = u['url']?.toString().trim();
        if (url != null && url.isNotEmpty) return url;
      }
    }
    return null;
  }

  /// 拼接完整图片 URL。
  String imageURL(String path) {
    final String trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    return imageCdn + (trimmed.startsWith('/') ? trimmed : '/$trimmed');
  }

  // ── 请求 / 解密核心 ───────────────────────────────────

  /// 加密参数 → 请求 → 解密响应（返回解密后的 JSON 对象）。
  Future<Object?> _roundTrip(
    String path, [
    Map<String, Object?> parameters = const <String, Object?>{},
  ]) async {
    final String encrypted = _encryptParameters(parameters);
    final HttpClientResponse resp;
    try {
      resp = await _client.postJson(
        Uri.parse(baseUrl + path),
        json: <String, Object?>{'post-data': encrypted},
        headers: const <String, String>{
          'user-agent': userAgent,
          'suffix': platformSuffix,
        },
      );
    } catch (e) {
      AppLog.warn('mdtv', '请求失败: $path', error: e);
      throw const MdtvException('网络请求失败');
    }
    if (!resp.isOk) {
      throw MdtvException('网络请求失败（HTTP ${resp.statusCode}）');
    }
    final Map<String, dynamic>? json = _tryDecodeJson(resp.text) is Map<String, dynamic>
        ? (_tryDecodeJson(resp.text) as Map<String, dynamic>)
        : null;
    if (json == null) {
      throw const MdtvException('响应格式错误');
    }
    final String? encryptedData = json['data']?.toString();
    if (encryptedData == null || encryptedData.isEmpty) {
      throw const MdtvException('响应格式错误');
    }
    final Object? decrypted = await _decryptOrBruteForce(encryptedData);
    if (decrypted == null) {
      throw const MdtvException('响应解密失败（密钥可能不正确）');
    }
    return decrypted;
  }

  String _encryptParameters(Map<String, Object?> parameters) {
    final List<int> plain = utf8.encode(jsonEncode(parameters));
    final String? direct =
        _encryptToBase64(_keyHex, _ivHex, _mode, plain);
    if (direct != null) return direct;

    // 兜底：当前候选（首轮 index 0 可能为短 key / 不支持模式）不可用时，
    // 退到首个「可用」候选，确保请求发出以触发暴力探测（iOS 后续会保存正确配置）。
    final String ivHex = MdtvCrypto.ivCandidates.first;
    for (final MdtvEncryptMode mode in MdtvCrypto.modeCandidates) {
      for (final String keyHex in MdtvCrypto.keyCandidates) {
        final String? enc = _encryptToBase64(keyHex, ivHex, mode, plain);
        if (enc != null) return enc;
      }
    }
    throw const MdtvException('请求加密失败');
  }

  String? _encryptToBase64(
    String keyHex,
    String ivHex,
    MdtvEncryptMode mode,
    List<int> plain,
  ) {
    final List<int>? key = MdtvCrypto.hexToBytes(keyHex);
    final List<int>? iv = MdtvCrypto.hexToBytes(ivHex);
    if (key == null || iv == null) return null;
    final List<int>? enc = _encryptRaw(mode, key, iv, plain);
    if (enc == null) return null;
    return base64Encode(enc);
  }

  Future<Object?> _decryptOrBruteForce(String encryptedData) async {
    final Object? direct = _decryptResponse(encryptedData);
    if (direct != null) return direct;
    return bruteForceDecrypt(encryptedData);
  }

  Object? _decryptResponse(String base64Str) {
    final List<int>? data = _tryBase64Decode(base64Str);
    if (data == null) return null;
    final List<int>? key = MdtvCrypto.hexToBytes(_keyHex);
    final List<int>? iv = MdtvCrypto.hexToBytes(_ivHex);
    if (key == null || iv == null) return null;
    return _decryptToJson(_mode, key, iv, data);
  }

  /// 暴力探测（对齐 iOS `bruteForceDecrypt`）：CFB/CBC/ECB × key × IV。
  Future<Object?> bruteForceDecrypt(String base64Str) async {
    final List<int>? data = _tryBase64Decode(base64Str);
    if (data == null) return null;

    for (int modeIdx = 0;
        modeIdx < MdtvCrypto.modeCandidates.length;
        modeIdx++) {
      final MdtvEncryptMode mode = MdtvCrypto.modeCandidates[modeIdx];
      // CTR/OFB 不参与解密探测（对齐 iOS `default: continue`）。
      if (mode == MdtvEncryptMode.ctr || mode == MdtvEncryptMode.ofb) continue;

      for (int keyIdx = 0;
          keyIdx < MdtvCrypto.keyCandidates.length;
          keyIdx++) {
        for (int ivIdx = 0;
            ivIdx < MdtvCrypto.ivCandidates.length;
            ivIdx++) {
          final List<int>? key =
              MdtvCrypto.hexToBytes(MdtvCrypto.keyCandidates[keyIdx]);
          final List<int>? iv =
              MdtvCrypto.hexToBytes(MdtvCrypto.ivCandidates[ivIdx]);
          if (key == null || iv == null) continue;
          final Object? json = _decryptToJson(mode, key, iv, data);
          if (json is Map &&
              (json.containsKey('code') || json.containsKey('data'))) {
            _keyIdx = keyIdx;
            _ivIdx = ivIdx;
            _modeIdx = modeIdx;
            await _saveCryptoConfig();
            _isKeyFound = true;
            notifyListeners();
            return json;
          }
        }
      }
    }
    return null;
  }

  Object? _decryptToJson(
    MdtvEncryptMode mode,
    List<int> key,
    List<int> iv,
    List<int> data,
  ) {
    final List<int>? dec = _decryptRaw(mode, key, iv, data);
    if (dec == null) return null;
    return _tryDecodeJson(utf8.decode(dec, allowMalformed: true));
  }

  static List<int>? _encryptRaw(
    MdtvEncryptMode mode,
    List<int> key,
    List<int> iv,
    List<int> data,
  ) {
    switch (mode) {
      case MdtvEncryptMode.cbc:
        return MdtvAes.cbcEncrypt(key, iv, data);
      case MdtvEncryptMode.cfb:
        return MdtvAes.cfbEncrypt(key, iv, data);
      case MdtvEncryptMode.ecb:
        return MdtvAes.ecbEncrypt(key, data);
      // 对齐 iOS `encryptRequest`：CTR/OFB 不加密请求。
      case MdtvEncryptMode.ctr:
      case MdtvEncryptMode.ofb:
        return null;
    }
  }

  static List<int>? _decryptRaw(
    MdtvEncryptMode mode,
    List<int> key,
    List<int> iv,
    List<int> data,
  ) {
    switch (mode) {
      case MdtvEncryptMode.cbc:
        return MdtvAes.cbcDecrypt(key, iv, data);
      case MdtvEncryptMode.cfb:
        return MdtvAes.cfbDecrypt(key, iv, data);
      case MdtvEncryptMode.ctr:
        return MdtvAes.ctrDecrypt(key, iv, data);
      case MdtvEncryptMode.ofb:
        return MdtvAes.ofbDecrypt(key, iv, data);
      case MdtvEncryptMode.ecb:
        return MdtvAes.ecbDecrypt(key, data);
    }
  }

  // ── JSON 工具 ─────────────────────────────────────────

  static Object? _tryDecodeJson(String text) {
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  static List<int>? _tryBase64Decode(String s) {
    try {
      return base64Decode(s);
    } catch (_) {
      return null;
    }
  }

  static List<Object?> _unwrapList(Object? json) {
    if (json is List) return json.cast<Object?>();
    if (json is Map) {
      for (final String key in const <String>['data', 'list', 'result']) {
        final Object? v = json[key];
        if (v is List) return v.cast<Object?>();
        if (v is Map) {
          for (final String inner in const <String>['list', 'data', 'items', 'result']) {
            final Object? iv = v[inner];
            if (iv is List) return iv.cast<Object?>();
          }
        }
      }
    }
    return const <Object?>[];
  }

  static Map<String, dynamic>? _unwrapMap(Object? json) {
    if (json is! Map) return null;
    for (final String key in const <String>['data', 'detail', 'info', 'result']) {
      final Object? v = json[key];
      if (v is Map) return _asStringMap(v);
    }
    return _asStringMap(json);
  }

  static Map<String, dynamic> _asStringMap(Map m) =>
      m.map((dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v));

  static List<String> _extractStringList(Object? json) => _unwrapList(json)
      .map((Object? e) => e?.toString().trim() ?? '')
      .where((String s) => s.isNotEmpty)
      .toList(growable: false);

  // ── 持久化 ────────────────────────────────────────────

  Future<void> _saveTabs() async =>
      await _prefs.setJsonList(_homeTabsKey, _homeTabs);

  Future<void> _saveCryptoConfig() async {
    await _prefs.set(_keyIdxKey, _keyIdx);
    await _prefs.set(_ivIdxKey, _ivIdx);
    await _prefs.set(_modeIdxKey, _modeIdx);
    await _prefs.set(_keyVerifiedKey, true);
  }
}