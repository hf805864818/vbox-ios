/// 数据层：福利平台代理配置存储（批次 H · H-07）。
///
/// 唯一真相源：iOS `vbox/Services/WelfareProxyStore.swift`
///   · 支持 URL 转发代理格式：`https://proxy.example.com/?token=xxx&url=`
///     （在代理地址末尾拼接原始 URL）；
///   · `proxyURL`（契约键 `welfare_proxy_url_v1`，string）；
///   · 各平台代理开关 `[平台名: Bool]`（契约键
///     `welfare_proxy_enabled_platforms_v1`，**JSON 字典字符串**，
///     H-07 已修正契约 type 对齐 iOS 实现）；
///   · 平台开关**仅在代理有效**（`hasValidProxy`）时生效（`isProxyEnabled` 前置守卫）；
///   · `clearProxyURL` 连带清空全部平台开关。
///
/// 差异登记：
///   · iOS 以 `JSONEncoder` 落 UserDefaults `Data`；Flutter 按契约 type=string
///     落 SharedPreferences **JSON 字符串**（跨端读取走 `jsonDecode` 兼容）；
///   · URL 编码：iOS `urlQueryAllowed`（保留部分保留字符），Flutter 用
///     [Uri.encodeComponent] 全量编码原始 URL，避免 `&`/`=` 干扰代理自身查询参数。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'prefs_manager.dart';

/// 福利平台代理配置存储（可监听，UI 直接 `ListenableBuilder` 消费）。
class WelfareProxyStore extends ChangeNotifier {
  /// 构造（[prefs] 可注入；为 null 时降级为内存态，便于单测 / 未初始化兜底）。
  WelfareProxyStore({PrefsManager? prefs}) : _prefs = prefs;

  /// 代理 URL 契约键（`prefs_keys_v1.json` → `_group_welfare_ext`）。
  static const String proxyUrlKey = 'welfare_proxy_url_v1';

  /// 平台代理开关契约键（JSON 字典字符串）。
  static const String enabledPlatformsKey = 'welfare_proxy_enabled_platforms_v1';

  /// 全局共享实例（应用装配时调用 [load]；服务层 / 设置页默认消费）。
  static final WelfareProxyStore shared = WelfareProxyStore();

  final PrefsManager? _prefs;

  String _proxyURL = '';
  Map<String, bool> _enabledPlatforms = <String, bool>{};

  /// 代理 URL（支持 URL 转发格式，如 `https://vbox.ltd/?token=xxx&url=`）。
  String get proxyURL => _proxyURL;

  /// 各平台代理开关状态（[平台名: 是否启用]，仅代理有效时生效）。
  Map<String, bool> get enabledPlatforms =>
      Map<String, bool>.unmodifiable(_enabledPlatforms);

  /// 代理 URL 是否有效（对齐 iOS `hasValidProxy`）。
  bool get hasValidProxy =>
      _proxyURL.isNotEmpty && _proxyURL.startsWith('http');

  /// 从契约键恢复（App 启动 / 设置页进入时调用）。
  Future<void> load() async {
    final PrefsManager? prefs = _p;
    if (prefs == null) return;
    try {
      _proxyURL = (await prefs.getString(proxyUrlKey)).trim();
      _enabledPlatforms = _decodeEnabledPlatforms(
        await prefs.getString(enabledPlatformsKey),
      );
    } catch (e) {
      // 历史 / 跨端脏数据 → 降级为空态，不打断加载。
      _proxyURL = '';
      _enabledPlatforms = <String, bool>{};
    }
    notifyListeners();
  }

  // ─────────────── 代理 URL 管理 ───────────────

  /// 设置代理 URL（对齐 iOS `setProxyURL`）。
  void setProxyURL(String url) {
    final String trimmed = url.trim();
    _proxyURL = trimmed;
    notifyListeners();
    unawaited(_save());
  }

  /// 清除代理 URL（连带清空所有平台开关，对齐 iOS `clearProxyURL`）。
  void clearProxyURL() {
    _proxyURL = '';
    _enabledPlatforms = <String, bool>{};
    notifyListeners();
    unawaited(_save());
  }

  // ─────────────── 平台代理开关 ───────────────

  /// 检查某个平台是否启用代理（代理无效一律 false，对齐 iOS）。
  bool isProxyEnabled(String platformName) {
    if (!hasValidProxy) return false;
    return _enabledPlatforms[platformName] ?? false;
  }

  /// 设置平台代理开关。
  void setProxyEnabled(bool enabled, String platformName) {
    _enabledPlatforms[platformName] = enabled;
    notifyListeners();
    unawaited(_save());
  }

  /// 切换平台代理开关。
  void toggleProxy(String platformName) {
    setProxyEnabled(!isProxyEnabled(platformName), platformName);
  }

  /// 当前启用代理的平台数（设置页「x/y 已开启」计数）。
  int enabledProxyCount(Iterable<String> platformNames) =>
      platformNames.where(isProxyEnabled).length;

  // ─────────────── 代理 URL 构建 ───────────────

  /// 根据原始 URL 构建代理 URL（平台启用代理且代理有效 → 代理后 URL，否则原样）。
  String proxiedURL(String originalURL, String platformName) {
    if (!isProxyEnabled(platformName) || originalURL.isEmpty) {
      return originalURL;
    }
    return buildProxiedURL(originalURL);
  }

  /// 构建代理 URL（不检查平台开关，直接使用代理；对齐 iOS `buildProxiedURL`）。
  ///
  /// URL 转发代理格式：`https://proxy.example.com/?token=xxx&url=`
  ///   · 代理地址含 `?`：末尾是 `&`/`?` 直接拼接原始 URL；否则追加 `&url=`;
  ///   · 代理地址不含 `?`：追加 `?url=`。
  String buildProxiedURL(String originalURL) {
    if (_proxyURL.isEmpty) return originalURL;
    final String encoded = Uri.encodeComponent(originalURL);
    if (_proxyURL.contains('?')) {
      if (_proxyURL.endsWith('&') || _proxyURL.endsWith('?')) {
        return _proxyURL + originalURL;
      }
      return '$_proxyURL&url=$encoded';
    }
    return '$_proxyURL?url=$encoded';
  }

  // ─────────────── 内部 ───────────────

  PrefsManager? get _p {
    final PrefsManager? injected = _prefs;
    if (injected != null) return injected;
    try {
      return PrefsManager.instance;
    } catch (_) {
      return null;
    }
  }

  /// 解析 JSON 字典字符串 → `{平台名: bool}`（空串 / 脏数据 → 空表）。
  Map<String, bool> _decodeEnabledPlatforms(String raw) {
    if (raw.isEmpty) return <String, bool>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, bool>{};
      final Map<String, bool> out = <String, bool>{};
      decoded.forEach((Object? k, Object? v) {
        if (k is String && v is bool) out[k] = v;
      });
      return out;
    } on FormatException {
      return <String, bool>{};
    }
  }

  Future<void> _save() async {
    final PrefsManager? prefs = _p;
    if (prefs == null) return;
    try {
      await prefs.set(proxyUrlKey, _proxyURL);
      await prefs.set(enabledPlatformsKey, jsonEncode(_enabledPlatforms));
    } catch (e) {
      // 落盘失败不阻断 UI（下次变更重试）。
    }
  }
}
