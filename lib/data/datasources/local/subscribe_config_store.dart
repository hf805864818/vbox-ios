/// 数据层：订阅配置存储（批次 G · G-07）。
///
/// 唯一真相源：iOS `vbox/Services/SubscriptionManager.swift`（本地态部分）
///   · 契约键三枚（`prefs_keys_v1.json` → `_group_subscription`）：
///     `subscribed_config_urls`（stringArray）/ `active_subscription_index`（int）/
///     `cached_subscribe_config`（string）；
///   · `init`（L18-L23）—— 读三键 + 越界索引归 0 + 读缓存；
///   · `switchToSubscription(at:)`（L32-L40）—— 置索引 + 落盘 + 清 `config` /
///     `isLoaded` / `parses`（触发重载）；
///   · `removeURL(_:)`（L43-L59）—— 记录 `wasActive` → 移除 → 落盘 →
///     索引修正 → 若删的是激活项或已清空，则清态并删除缓存键。
///
/// 差异登记：iOS 缓存落 `UserDefaults` `Data`（`JSONEncoder` 二进制）；Flutter
/// 按契约 type=string 存 JSON 字符串（跨端读取走 `jsonDecode` 兼容，同 G-03 /
/// G-04 口径）；iOS `load()` 在 `init` 同步执行一次，Flutter 为异步 `load()`，
/// 以 `_loaded` 守卫保证「启动恢复一次」语义。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../domain/entities/subscribe/subscribe.dart';
import 'prefs_manager.dart';

/// 订阅配置存储（可监听，UI 直接 `ListenableBuilder` 消费）。
class SubscribeConfigStore extends ChangeNotifier {
  /// 构造（[prefs] 可注入；为 null 时降级为内存态，便于单测 / 未初始化兜底）。
  SubscribeConfigStore({PrefsManager? prefs}) : _prefs = prefs;

  /// 契约键：订阅源 URL 列表（stringArray）。
  static const String urlsKey = 'subscribed_config_urls';

  /// 契约键：当前激活订阅源索引（int）。
  static const String activeIndexKey = 'active_subscription_index';

  /// 契约键：订阅 JSON 缓存（string）。
  static const String cacheKey = 'cached_subscribe_config';

  /// 全局共享实例（应用装配时调用 [load]；页面默认消费）。
  static final SubscribeConfigStore shared = SubscribeConfigStore();

  final PrefsManager? _prefs;

  bool _loaded = false;
  bool _isLoading = false;
  String? _errorMessage;
  List<String> _configUrls = const <String>[];
  int _activeURLIndex = 0;
  SubscribeConfig? _config;
  bool _configLoaded = false;

  /// 订阅源 URL 列表（顺序即用户添加顺序，对齐 iOS `configURLs`）。
  List<String> get configUrls => List<String>.unmodifiable(_configUrls);

  /// 当前激活订阅源索引。
  int get activeURLIndex => _activeURLIndex;

  /// 当前激活订阅源 URL（越界 / 空列表返回 null，对齐 iOS `activeURL`）。
  String? get activeURL =>
      (_activeURLIndex >= 0 && _activeURLIndex < _configUrls.length)
          ? _configUrls[_activeURLIndex]
          : null;

  /// 已加载的订阅配置（未加载为 null）。
  SubscribeConfig? get config => _config;

  /// 配置是否已加载（对齐 iOS `isLoaded`）。
  bool get isLoaded => _configLoaded;

  /// 是否正在加载（对齐 iOS `isLoading`）。
  bool get isLoading => _isLoading;

  /// 最近一次错误消息（对齐 iOS `errorMessage`）。
  String? get errorMessage => _errorMessage;

  /// 是否已配置订阅源。
  bool get hasConfigUrls => _configUrls.isNotEmpty;

  /// 从契约键恢复（App 启动时调用；`_loaded` 守卫保证只恢复一次）。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final PrefsManager? prefs = _p;
    if (prefs == null) return;
    try {
      _configUrls = await prefs.getStringList(urlsKey);
      _activeURLIndex = await prefs.getInt(activeIndexKey);
      if (_activeURLIndex < 0 || _activeURLIndex >= _configUrls.length) {
        _activeURLIndex = 0;
      }
      final String cached = await prefs.getString(cacheKey);
      if (cached.isNotEmpty) {
        final Object? decoded = jsonDecode(cached);
        if (decoded is Map) {
          _config =
              SubscribeConfig.fromJson(decoded.cast<String, Object?>());
          _configLoaded = true;
        }
      }
    } catch (_) {
      // 历史 / 跨端脏数据 → 保留默认态，不打断加载。
    }
    notifyListeners();
  }

  /// 置加载态（供加载器驱动 UI 进度）。
  void setLoading(bool value) {
    if (_isLoading == value) return;
    _isLoading = value;
    notifyListeners();
  }

  /// 置错误态（对齐 iOS `setError`：写入消息并结束加载）。
  void setError(String message) {
    _errorMessage = message;
    _isLoading = false;
    notifyListeners();
  }

  /// 加载成功后写入配置 + 追加 URL + 落盘（对齐 iOS `loadConfig` 尾部）。
  Future<void> applyLoaded(String url, SubscribeConfig config) async {
    _config = config;
    _configLoaded = true;
    _isLoading = false;
    _errorMessage = null;
    if (!_configUrls.contains(url)) {
      _configUrls = <String>[..._configUrls, url];
    }
    notifyListeners();
    await _persistUrlsAndIndex();
    await _persistCache(config);
  }

  /// 切换到指定索引的订阅源（对齐 iOS `switchToSubscription`）。
  Future<void> switchTo(int index) async {
    if (index < 0 || index >= _configUrls.length) return;
    if (index == _activeURLIndex) return;
    _activeURLIndex = index;
    _config = null;
    _configLoaded = false;
    _errorMessage = null;
    notifyListeners();
    await _persistUrlsAndIndex();
  }

  /// 删除指定订阅源（对齐 iOS `removeURL`）。
  Future<void> removeUrl(String url) async {
    final bool wasActive = _activeURLIndex >= 0 &&
        _activeURLIndex < _configUrls.length &&
        _configUrls[_activeURLIndex] == url;
    _configUrls =
        _configUrls.where((String u) => u != url).toList(growable: false);
    if (_activeURLIndex >= _configUrls.length) {
      _activeURLIndex = _configUrls.isEmpty ? 0 : _configUrls.length - 1;
    }
    // 若删除的是当前激活源或已清空，彻底清态并删除缓存键（防重启恢复）。
    if (wasActive || _configUrls.isEmpty) {
      _config = null;
      _configLoaded = false;
      _errorMessage = null;
      await _removeCache();
    }
    notifyListeners();
    await _persistUrlsAndIndex();
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

  Future<void> _persistUrlsAndIndex() async {
    final PrefsManager? prefs = _p;
    if (prefs == null) return;
    try {
      await prefs.set(urlsKey, _configUrls);
      await prefs.set(activeIndexKey, _activeURLIndex);
    } catch (_) {
      // 落盘失败不阻断 UI（下次变更重试）。
    }
  }

  Future<void> _persistCache(SubscribeConfig config) async {
    final PrefsManager? prefs = _p;
    if (prefs == null) return;
    try {
      await prefs.set(cacheKey, jsonEncode(config.toJson()));
    } catch (_) {
      // 同上。
    }
  }

  Future<void> _removeCache() async {
    final PrefsManager? prefs = _p;
    if (prefs == null) return;
    try {
      await prefs.remove(cacheKey);
    } catch (_) {
      // 同上。
    }
  }
}