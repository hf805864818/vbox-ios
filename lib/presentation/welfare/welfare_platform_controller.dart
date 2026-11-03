/// 福利平台配置控制器（批次 H · H-01）。
///
/// 唯一真相源：iOS `vbox/WelfareRemote/WelfarePlatformConfigStore.swift`
///   · `bootstrap()`（L101-110）：幂等；先恢复磁盘缓存 → 后台刷新（不阻塞启动）；
///   · `refreshAsync()`（L132-158）：拉配置 → 置 `loaded` → 记成功时间 / 版本 → 落盘；
///   · `platforms(in:)`（L163-168）：按分类过滤 + `sortOrder` 升序；
///   · `switchEnabled`（L75-79）：契约键 `fuli_remote_source_enabled`，**默认开**。
///
/// 消费契约键（4 个）：
///   · `fuli_remote_source_enabled`（bool，默认 `true`）—— 远程源总开关（H-07 出 UI）；
///   · `fuli_remote_source_last_success_time`（long）—— 最后成功加载时间（Unix 秒）；
///   · `fuli_remote_source_last_config_version`（string）—— 最后已知配置版本；
///   · `remote_default_manifest_url`（string）—— manifest 地址（空则用内置默认）。
///
/// 加载状态机（对齐 iOS `WelfareConfigLoadState`）：idle → loading → loaded / failed。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/errors/failures.dart';
import '../../core/network/http_client.dart';
import '../../core/utils/logger.dart';
import '../../core/utils/result.dart';
import '../../core/utils/time_utils.dart';
import '../../data/datasources/local/prefs_manager.dart';
import '../../data/datasources/local/welfare_platform_cache.dart';
import '../../data/datasources/remote/welfare_platform_datasource.dart';
import '../../domain/entities/remote_source/remote_source.dart';
import '../../domain/entities/welfare/welfare.dart';

/// 福利平台配置加载状态（对齐 iOS `WelfareConfigLoadState`）。
enum WelfarePlatformLoadState {
  /// 未启动。
  idle,

  /// 加载中。
  loading,

  /// 加载成功（远程或缓存）。
  loaded,

  /// 加载失败。
  failed,
}

/// 福利平台配置控制器（可热切换）。
class WelfarePlatformController extends ChangeNotifier {
  /// 构造（依赖可注入，便于单测）。
  WelfarePlatformController({
    WelfarePlatformDatasource? datasource,
    WelfarePlatformCache? cache,
    PrefsManager? prefs,
    int Function()? nowSeconds,
  })  : _datasource = datasource,
        _cache = cache ?? WelfarePlatformCache(),
        _prefs = prefs,
        _nowSeconds = nowSeconds;

  /// 远程源总开关契约键。
  static const String kSwitchEnabledKey = 'fuli_remote_source_enabled';

  /// 最后成功加载时间契约键。
  static const String kLastSuccessTimeKey = 'fuli_remote_source_last_success_time';

  /// 最后已知配置版本契约键。
  static const String kLastConfigVersionKey = 'fuli_remote_source_last_config_version';

  /// manifest 地址契约键。
  static const String kManifestUrlKey = 'remote_default_manifest_url';

  /// 日志标签。
  static const String logTag = 'welfare';

  WelfarePlatformDatasource? _datasource;
  final WelfarePlatformCache _cache;
  final PrefsManager? _prefs;
  final int Function()? _nowSeconds;

  bool _bootstrapped = false;
  bool _disposed = false;

  bool _switchEnabled = true;
  WelfarePlatformLoadState _loadState = WelfarePlatformLoadState.idle;
  WelfarePlatformConfig? _config;
  String? _errorMessage;
  int _lastSuccessTimeSeconds = 0;
  String? _lastConfigVersion;

  /// 远程源总开关（契约默认开，对齐 iOS `WelfareRemoteSourceSwitch.default`）。
  bool get switchEnabled => _switchEnabled;

  /// 当前加载状态。
  WelfarePlatformLoadState get loadState => _loadState;

  /// 加载成功时的配置（否则 null）。
  WelfarePlatformConfig? get config => _config;

  /// 失败原因（`failed` 时有值）。
  String? get errorMessage => _errorMessage;

  /// 最后成功加载时间（Unix 秒；0 表示从未成功）。
  int get lastSuccessTimeSeconds => _lastSuccessTimeSeconds;

  /// 最后已知配置版本。
  String? get lastConfigVersion => _lastConfigVersion;

  /// 平台总数。
  int get totalPlatformCount => _config?.platforms.length ?? 0;

  /// 是否已有可展示数据（缓存或远程）。
  bool get hasData => _config != null;

  /// 指定分类下的平台（按 `sortOrder` 升序；无配置时为空）。
  List<WelfarePlatform> platformsIn(WelfarePlatformCategory category) =>
      _config?.platformsIn(category) ?? const <WelfarePlatform>[];

  /// 启动时调用一次（幂等）：恢复缓存 + 后台刷新。
  Future<void> bootstrap() async {
    if (_bootstrapped) return;
    _bootstrapped = true;

    await _loadSwitchEnabled();

    // ① 先恢复磁盘缓存（对齐 iOS `loadFromDiskCache`），让首帧即有数据。
    final WelfarePlatformConfig? cached = await _cache.read();
    if (cached != null) {
      _config = cached;
      _loadState = WelfarePlatformLoadState.loaded;
      _lastConfigVersion = _versionOf(cached);
      _safeNotify();
    }

    // ② 开关开启才后台刷新（对齐 iOS：关闭时不刷新，保证「关开关后不显示远程平台」）。
    if (_switchEnabled) {
      unawaited(refresh());
    }
  }

  /// 主动刷新（刷新按钮 / 解锁后调用）。
  Future<void> refresh() async {
    _loadState = WelfarePlatformLoadState.loading;
    _errorMessage = null;
    _safeNotify();

    final String manifestUrl = await _manifestUrl();
    final Result<WelfarePlatformConfig> result =
        await _ds.fetch(manifestUrl, forceRefresh: true);
    if (_disposed) return;

    final Failure? failure = result.failureOrNull;
    if (failure != null) {
      _loadState = WelfarePlatformLoadState.failed;
      _errorMessage = failure.message;
      _safeNotify();
      AppLog.warn(logTag, '福利平台配置刷新失败：${failure.message}');
      return;
    }

    final WelfarePlatformConfig config = result.valueOrNull!;
    _config = config;
    _loadState = WelfarePlatformLoadState.loaded;
    _errorMessage = null;
    _lastSuccessTimeSeconds = _now();
    _lastConfigVersion = _versionOf(config);
    _safeNotify();
    AppLog.info(
      logTag,
      '福利平台配置加载成功：${config.platforms.length} 个平台，'
      'version=${_lastConfigVersion ?? "nil"}',
    );

    await _cache.write(config);
    await _persistSuccess(_lastSuccessTimeSeconds, _lastConfigVersion);
  }

  /// 设置远程源总开关并落盘。
  Future<void> setSwitchEnabled(bool value) async {
    if (_switchEnabled == value) return;
    _switchEnabled = value;
    _safeNotify();
    await _p?.set(kSwitchEnabledKey, value);
  }

  /// 清空缓存（调试 / 「清缓存」入口）；
  /// 重置 `bootstrapped` 以允许再次 [bootstrap] 自动重载（对齐 iOS `clearAllCache`）。
  Future<void> clearCache() async {
    await _cache.clear();
    _config = null;
    _loadState = WelfarePlatformLoadState.idle;
    _errorMessage = null;
    _lastSuccessTimeSeconds = 0;
    _lastConfigVersion = null;
    _bootstrapped = false;
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // ────────────── 内部 ──────────────

  WelfarePlatformDatasource get _ds =>
      _datasource ??= WelfarePlatformDatasource(client: HttpClient());

  PrefsManager? get _p => _prefs ?? _maybePrefs();

  /// `PrefsManager.instance` 未初始化时返回 null（缓存/开关降级为内存态）。
  PrefsManager? _maybePrefs() {
    try {
      return PrefsManager.instance;
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadSwitchEnabled() async {
    final PrefsManager? prefs = _p;
    if (prefs == null) return;
    try {
      final Object? v = await prefs.get(kSwitchEnabledKey);
      _switchEnabled = v is bool ? v : true;
      _lastSuccessTimeSeconds = await prefs.getInt(kLastSuccessTimeKey);
      final Object? version = await prefs.get(kLastConfigVersionKey);
      _lastConfigVersion =
          version is String && version.isNotEmpty ? version : null;
    } catch (e) {
      AppLog.warn(logTag, '福利远程源开关读取失败，按默认开处理', error: e);
    }
  }

  Future<String> _manifestUrl() async {
    final PrefsManager? prefs = _p;
    if (prefs == null) return RemoteSourceStrategy.defaultManifestUrl;
    try {
      final String url = (await prefs.getString(kManifestUrlKey)).trim();
      return url.isEmpty ? RemoteSourceStrategy.defaultManifestUrl : url;
    } catch (_) {
      return RemoteSourceStrategy.defaultManifestUrl;
    }
  }

  Future<void> _persistSuccess(int atSeconds, String? version) async {
    final PrefsManager? prefs = _p;
    if (prefs == null) return;
    try {
      await prefs.set(kLastSuccessTimeKey, atSeconds);
      if (version != null) await prefs.set(kLastConfigVersionKey, version);
    } catch (e) {
      AppLog.warn(logTag, '福利同步状态落盘失败', error: e);
    }
  }

  String? _versionOf(WelfarePlatformConfig config) {
    final Object? v = config.meta?['version'];
    final String s = (v ?? '').toString().trim();
    return s.isEmpty ? null : s;
  }

  int _now() => _nowSeconds?.call() ?? TimeUtils.nowUnixSeconds();

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }
}