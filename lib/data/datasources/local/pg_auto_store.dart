/// 数据层：PG 自动化配置持久化（批次 F · F-09）。
///
/// 对齐 iOS `AliyunPgConfig`（`vbox/Services/AliyunPgConfig.swift`）：
/// 9 个 `pg_ali_*` 键全部 `UserDefaults.standard`（契约 `storage: userdefaults`），
/// Flutter 端经 [PrefsManager] 读写 `SharedPreferences`，键名 / 类型与契约
/// `prefs_keys_v1.json`（`_group_quark_pg`）1:1 对应。
library;

import '../../../domain/entities/cloud/pg_auto.dart';
import 'prefs_manager.dart';

/// PG 自动化配置存储。
class PgAutoStore {
  /// 构造（注入契约偏好管理器）。
  PgAutoStore(this._prefs);

  final PrefsManager _prefs;

  /// 契约键名（`prefs_keys_v1.json` → `_group_quark_pg`）。
  static const String enabledKey = 'pg_ali_enabled';
  static const String isVipKey = 'pg_ali_is_vip';
  static const String threadLimitKey = 'pg_ali_thread_limit';
  static const String threadNightKey = 'pg_ali_thread_night';
  static const String vodFlagsKey = 'pg_ali_vod_flags';
  static const String transferDirKey = 'pg_ali_transfer_dir';
  static const String autoCleanupKey = 'pg_ali_auto_cleanup';
  static const String cleanupDelayKey = 'pg_ali_cleanup_delay';
  static const String proxyPortKey = 'pg_ali_proxy_port';

  /// 全部契约键（`reset` 用；顺序与契约一致）。
  static const List<String> allKeys = <String>[
    autoCleanupKey,
    cleanupDelayKey,
    enabledKey,
    isVipKey,
    proxyPortKey,
    threadLimitKey,
    threadNightKey,
    transferDirKey,
    vodFlagsKey,
  ];

  /// 读取配置（缺键回退契约缺省值）。
  Future<PgAutoConfig> load() async {
    return PgAutoConfig(
      enabled: await _prefs.getBool(enabledKey),
      isVip: await _prefs.getBool(isVipKey),
      threadLimit: await _prefs.getInt(threadLimitKey),
      threadNight: await _prefs.getInt(threadNightKey),
      vodFlags: await _prefs.getString(vodFlagsKey),
      transferDir: await _prefs.getString(transferDirKey),
      autoCleanup: await _prefs.getBool(autoCleanupKey),
      cleanupDelaySeconds: await _prefs.getInt(cleanupDelayKey),
      proxyPort: await _prefs.getInt(proxyPortKey),
    );
  }

  /// 全量写入。
  Future<void> save(PgAutoConfig config) async {
    await _prefs.set(enabledKey, config.enabled);
    await _prefs.set(isVipKey, config.isVip);
    await _prefs.set(threadLimitKey, config.threadLimit);
    await _prefs.set(threadNightKey, config.threadNight);
    await _prefs.set(vodFlagsKey, config.vodFlags);
    await _prefs.set(transferDirKey, config.transferDir);
    await _prefs.set(autoCleanupKey, config.autoCleanup);
    await _prefs.set(cleanupDelayKey, config.cleanupDelaySeconds);
    await _prefs.set(proxyPortKey, config.proxyPort);
  }

  /// 恢复缺省（移除 9 个契约键，读取时回归契约缺省值）。
  Future<void> reset() async {
    for (final String key in allKeys) {
      await _prefs.remove(key);
    }
  }
}
