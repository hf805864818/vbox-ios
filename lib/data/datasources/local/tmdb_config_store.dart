/// 数据层：TMDB 配置存储（批次 G · G-06）。
///
/// 唯一真相源：iOS `vbox/App/AppSettings.swift` L53-L101、L159-L162
///   · 契约键四枚（`prefs_keys_v1.json` → `_group_tmdb` × 3 + `_group_appSettings` × 1）：
///     `app_enable_tmdb`（bool）/ `app_tmdb_proxy_url`（string）/
///     `app_tmdb_use_token`（bool）/ `app_tmdb_proxy_token`（string，**sensitive**）；
///   · `enableTMDB` / `tmdbProxyURL` / `tmdbUseToken` / `tmdbProxyToken` 的
///     `@Published` `didSet` 即时落盘语义 → 此处 setter 即时 `_save`。
///
/// 差异登记：
///   · iOS 敏感键 `app_tmdb_proxy_token` 落 `UserDefaults`（历史遗留）；Flutter 端
///     由 [PrefsManager] 按契约 `sensitive: true` 自动路由到安全存储（首次读取
///     回退明文并迁移，见 P.16 / A1），存储位置差异不影响读写语义；
///   · iOS `load()` 在 `init` 同步执行一次；Flutter 为异步 `load()`，以 `_loaded`
///     守卫保证「启动恢复一次」语义。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'prefs_manager.dart';

/// TMDB 配置存储（可监听，UI 直接 `ListenableBuilder` 消费）。
class TmdbConfigStore extends ChangeNotifier {
  /// 构造（[prefs] 可注入；为 null 时降级为内存态，便于单测 / 未初始化兜底）。
  TmdbConfigStore({PrefsManager? prefs}) : _prefs = prefs;

  /// 契约键：是否启用 TMDB（`app_enable_tmdb`，默认 false）。
  static const String enableKey = 'app_enable_tmdb';

  /// 契约键：TMDB 代理地址（`app_tmdb_proxy_url`，默认空）。
  static const String proxyUrlKey = 'app_tmdb_proxy_url';

  /// 契约键：代理是否需要 Token（`app_tmdb_use_token`，默认 false）。
  static const String useTokenKey = 'app_tmdb_use_token';

  /// 契约键：代理 Token（`app_tmdb_proxy_token`，**敏感键**，默认空）。
  static const String proxyTokenKey = 'app_tmdb_proxy_token';

  /// 全局共享实例（应用装配时调用 [load]；页面默认消费）。
  static final TmdbConfigStore shared = TmdbConfigStore();

  final PrefsManager? _prefs;

  bool _loaded = false;
  bool _enabled = false;
  String _proxyUrl = '';
  bool _useToken = false;
  String _proxyToken = '';

  /// 是否启用 TMDB 封面与演职人员加载（对齐 iOS `enableTMDB`）。
  bool get enabled => _enabled;

  /// 代理地址（空串 = 未配置，对齐 iOS `tmdbProxyURL`）。
  String get proxyUrl => _proxyUrl;

  /// 代理是否需要 Token（对齐 iOS `tmdbUseToken`）。
  bool get useToken => _useToken;

  /// 代理 Token（对齐 iOS `tmdbProxyToken`）。
  String get proxyToken => _proxyToken;

  /// 代理地址是否已配置（trim 非空）。
  ///
  /// 对齐 iOS `proxiedURL`：`proxyBaseURL` 为空时拼出的地址无效（`?url=...`），
  /// 故 TMDB 请求以「已启用 + 代理非空」为前置。
  bool get hasProxy => _proxyUrl.trim().isNotEmpty;

  /// 是否具备发起 TMDB 请求的条件（已启用且代理非空）。
  bool get isReady => _enabled && hasProxy;

  /// 从契约键恢复（App 启动时调用；`_loaded` 守卫保证只恢复一次）。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final PrefsManager? prefs = _p;
    if (prefs == null) return;
    try {
      _enabled = await prefs.getBool(enableKey);
      _proxyUrl = await prefs.getString(proxyUrlKey);
      _useToken = await prefs.getBool(useTokenKey);
      _proxyToken = await prefs.getString(proxyTokenKey);
    } catch (e) {
      // 历史 / 跨端脏数据 → 保留默认态，不打断加载。
    }
    notifyListeners();
  }

  /// 切换启用态并落盘（对齐 iOS `enableTMDB` 的 `didSet`）。
  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    unawaited(_save());
  }

  /// 更新代理地址并落盘。
  void setProxyUrl(String value) {
    if (_proxyUrl == value) return;
    _proxyUrl = value;
    notifyListeners();
    unawaited(_save());
  }

  /// 切换 Token 开关并落盘。
  void setUseToken(bool value) {
    if (_useToken == value) return;
    _useToken = value;
    notifyListeners();
    unawaited(_save());
  }

  /// 更新代理 Token 并落盘（敏感键走安全存储）。
  void setProxyToken(String value) {
    if (_proxyToken == value) return;
    _proxyToken = value;
    notifyListeners();
    unawaited(_save());
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

  Future<void> _save() async {
    final PrefsManager? prefs = _p;
    if (prefs == null) return;
    try {
      await prefs.set(enableKey, _enabled);
      await prefs.set(proxyUrlKey, _proxyUrl);
      await prefs.set(useTokenKey, _useToken);
      await prefs.set(proxyTokenKey, _proxyToken);
    } catch (e) {
      // 落盘失败不阻断 UI（下次变更重试）。
    }
  }
}