/// 契约层：Preferences 键名
///
/// 唯一真相源：`contract/schema/prefs_keys_v1.json`（v1.5，98 键 + 7 敏感键）
/// 本文件是该契约的 Dart 移植，**任何修改必须同步两侧**。
///
/// 提取依据：iOS 源码 `vbox/` 中的 UserDefaults 调用（3 种写法穷举）
///  ① `defaults.xxx(forKey:"k")`  ② `let xKey = "k"`  ③ `enum XXXKeys`
///
/// v1.1 修订（2026-09-29）：移除 10 个误抓键（播放器 KVC / CA 动画 key）。
/// v1.2 修订（2026-09-29）：补齐 44 个遗漏键（云盘/福利/直播/音乐/TG/日志/推送）。
/// v1.3 修订（2026-09-30）：敏感键 5 → 7（B3 裁定，新增 baidu_local_pcs_device_id /
/// saved_drive_tokens，详见契约 notes v1.3）。
/// v1.4 修订（2026-10-01）：新增 `app_ui_form_override`（显示模式覆盖，string，
/// 默认 `auto`）—— 第 2 轮批次 A 依据 D17 契约变更门禁主动扩键（非 iOS 来源）。
///
/// ⚠️ 存储方式（storage）：
///  · userDefaults —— 走 SharedPreferences
///  · keychain     —— 走 flutter_secure_storage（Keychain 语义）
///  · credentialExtra —— 存于凭据对象的 extra 字典，非独立键
///
/// ⚠️ 安全键（sensitive）：7 个（[kSensitiveKeys]），须走安全存储
/// （其 `storage` 为 `userDefaults` 系 iOS 侧历史写法，Flutter 端读取需兼容）。
library;

/// 键值类型。
enum PrefsType {
  string, stringArray, bool, int, long, float;

  static PrefsType fromJson(String s) => switch (s) {
        'string' => PrefsType.string,
        'stringArray' => PrefsType.stringArray,
        'bool' => PrefsType.bool,
        'int' => PrefsType.int,
        'long' => PrefsType.long,
        'float' => PrefsType.float,
        _ => throw ArgumentError('未知 Prefs 类型: $s'),
      };
}

/// 键的存储方式。
enum PrefsStorage {
  /// SharedPreferences（对应 iOS UserDefaults）。
  userDefaults,

  /// flutter_secure_storage（对应 iOS Keychain）。
  keychain,

  /// 存于凭据对象的 extra 字典，非独立键。
  credentialExtra,
}

/// 键名分组（对应 JSON 契约的 21 个 `_group_*` 分组）。
enum PrefsGroup {
  /// 订阅
  subscription,

  /// Spider 解析
  spider,

  /// 远程源
  remoteSource,

  /// 播放器
  player,

  /// TMDB
  tmdb,

  /// 弹幕
  danmaku,

  /// 直播电视
  liveTv,

  /// 壹平台
  onePlatform,

  /// 夸克/PG
  quarkPg,

  /// 福利
  welfare,

  /// 调试
  debug,

  /// 遗留迁移
  legacyMigration,

  /// 日志
  log,

  /// 应用设置
  appSettings,

  /// 福利扩展
  welfareExt,

  /// 直播扩展
  liveExt,

  /// 音乐
  music,

  /// TG 搜索
  tg,

  /// 推送
  push,

  /// PG 扩展
  pgExtra,

  /// 云盘
  cloud,

}

/// JSON 分组名 ↔ 枚举 映射。
const Map<String, PrefsGroup> kGroupNameToEnum = <String, PrefsGroup>{
  '_group_subscription': PrefsGroup.subscription,
  '_group_spider': PrefsGroup.spider,
  '_group_remote_source': PrefsGroup.remoteSource,
  '_group_player': PrefsGroup.player,
  '_group_tmdb': PrefsGroup.tmdb,
  '_group_danmaku': PrefsGroup.danmaku,
  '_group_live_tv': PrefsGroup.liveTv,
  '_group_one_platform': PrefsGroup.onePlatform,
  '_group_quark_pg': PrefsGroup.quarkPg,
  '_group_welfare': PrefsGroup.welfare,
  '_group_debug': PrefsGroup.debug,
  '_group_legacy_migration': PrefsGroup.legacyMigration,
  '_group_log': PrefsGroup.log,
  '_group_app_settings': PrefsGroup.appSettings,
  '_group_welfare_ext': PrefsGroup.welfareExt,
  '_group_live_ext': PrefsGroup.liveExt,
  '_group_music': PrefsGroup.music,
  '_group_tg': PrefsGroup.tg,
  '_group_push': PrefsGroup.push,
  '_group_pg_extra': PrefsGroup.pgExtra,
  '_group_cloud': PrefsGroup.cloud,
};

/// 单个 Prefs 键的元数据。
class PrefsKey {
  const PrefsKey({
    required this.name,
    required this.group,
    required this.type,
    this.storage = PrefsStorage.userDefaults,
    this.sensitive = false,
    this.defaultValue,
    this.description = '',
  });

  final String name;
  final PrefsGroup group;
  final PrefsType type;
  final PrefsStorage storage;
  final bool sensitive;
  final Object? defaultValue;
  final String description;
}

/// 全部 Prefs 键（99 个）。
const List<PrefsKey> kAllPrefsKeys = <PrefsKey>[
  // ────────────── _group_subscription（3）──────────────
  PrefsKey(name: 'subscribed_config_urls', group: PrefsGroup.subscription, type: PrefsType.stringArray, storage: PrefsStorage.userDefaults, defaultValue: <String>[], description: '订阅源 URL 列表'),
  PrefsKey(name: 'active_subscription_index', group: PrefsGroup.subscription, type: PrefsType.int, storage: PrefsStorage.userDefaults, defaultValue: 0, description: '当前激活订阅源索引'),
  PrefsKey(name: 'cached_subscribe_config', group: PrefsGroup.subscription, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: null, description: '订阅 JSON 缓存（建议不迁移）'),
  // ────────────── _group_spider（4）──────────────
  PrefsKey(name: 'fallback_enabled', group: PrefsGroup.spider, type: PrefsType.bool, storage: PrefsStorage.userDefaults, defaultValue: true, description: '兜底源开关'),
  PrefsKey(name: 'enable_dual_mode', group: PrefsGroup.spider, type: PrefsType.bool, storage: PrefsStorage.userDefaults, defaultValue: true, description: '双模式（type=3 HTTP API 走原生链路）'),
  PrefsKey(name: 'custom_fallback_sites', group: PrefsGroup.spider, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: '[]', description: '自定义兜底源（JSON 数组字符串）'),
  PrefsKey(name: 'user_parsers', group: PrefsGroup.spider, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: '[]', description: '用户自定义解析器（JSON）'),
  // ────────────── _group_remote_source（9）──────────────
  PrefsKey(name: 'remote_default_source_enabled', group: PrefsGroup.remoteSource, type: PrefsType.bool, storage: PrefsStorage.userDefaults, defaultValue: true, description: '启用远程默认源'),
  PrefsKey(name: 'bundle_sources_enabled', group: PrefsGroup.remoteSource, type: PrefsType.bool, storage: PrefsStorage.userDefaults, defaultValue: false, description: '启用内置源（兼容模式）'),
  PrefsKey(name: 'remote_default_manifest_url', group: PrefsGroup.remoteSource, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: 'https://vbox-ai.github.io/api/sources/manifest.json', description: 'manifest 地址'),
  PrefsKey(name: 'remote_default_last_config_version', group: PrefsGroup.remoteSource, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: '', description: '上次同步的 configVersion'),
  PrefsKey(name: 'remote_default_last_sync_time', group: PrefsGroup.remoteSource, type: PrefsType.long, storage: PrefsStorage.userDefaults, defaultValue: null, description: '上次同步时间戳'),
  PrefsKey(name: 'remote_default_last_sync_error', group: PrefsGroup.remoteSource, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: null, description: '上次同步错误'),
  PrefsKey(name: 'remote_default_last_sync_app_version', group: PrefsGroup.remoteSource, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: null, description: '上次同步时的 App 版本'),
  PrefsKey(name: 'remote_node_bundle_url', group: PrefsGroup.remoteSource, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: null, description: 'Node bundle 远程地址'),
  PrefsKey(name: 'remote_node_bundle_ver', group: PrefsGroup.remoteSource, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: null, description: 'Node bundle 版本'),
  // ────────────── _group_player（4）──────────────
  PrefsKey(name: 'player_auto_play_next', group: PrefsGroup.player, type: PrefsType.bool, storage: PrefsStorage.userDefaults, defaultValue: true, description: '自动播放下一集'),
  PrefsKey(name: 'player_background_play', group: PrefsGroup.player, type: PrefsType.bool, storage: PrefsStorage.userDefaults, defaultValue: false, description: '后台播放'),
  PrefsKey(name: 'player_long_press_speed', group: PrefsGroup.player, type: PrefsType.float, storage: PrefsStorage.userDefaults, defaultValue: 2.0, description: '长按倍速'),
  PrefsKey(name: 'player_pip_enabled', group: PrefsGroup.player, type: PrefsType.bool, storage: PrefsStorage.userDefaults, defaultValue: true, description: '画中画开关'),
  // ────────────── _group_tmdb（3）──────────────
  PrefsKey(name: 'app_tmdb_proxy_url', group: PrefsGroup.tmdb, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: '', description: 'TMDB 代理地址'),
  PrefsKey(name: 'app_tmdb_proxy_token', group: PrefsGroup.tmdb, type: PrefsType.string, storage: PrefsStorage.userDefaults, sensitive: true, defaultValue: '', description: 'TMDB 代理 token'),
  PrefsKey(name: 'app_tmdb_use_token', group: PrefsGroup.tmdb, type: PrefsType.bool, storage: PrefsStorage.userDefaults, defaultValue: false, description: 'TMDB 使用 token'),
  // ────────────── _group_danmaku（2）──────────────
  PrefsKey(name: 'custom_danmaku_source_enabled', group: PrefsGroup.danmaku, type: PrefsType.bool, storage: PrefsStorage.userDefaults, defaultValue: false, description: '自定义弹幕源'),
  PrefsKey(name: 'custom_danmaku_source_url', group: PrefsGroup.danmaku, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: '', description: '弹幕源地址'),
  // ────────────── _group_live_tv（6）──────────────
  PrefsKey(name: 'live_tv_local_channels', group: PrefsGroup.liveTv, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: '[]', description: '本地直播频道（JSON）'),
  PrefsKey(name: 'mdtv_home_tabs', group: PrefsGroup.liveTv, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: '[]', description: 'MDTV 首页 Tab'),
  PrefsKey(name: 'mdtv_iv_idx', group: PrefsGroup.liveTv, type: PrefsType.int, storage: PrefsStorage.userDefaults, defaultValue: 0, description: 'MDTV IV 索引'),
  PrefsKey(name: 'mdtv_key_idx', group: PrefsGroup.liveTv, type: PrefsType.int, storage: PrefsStorage.userDefaults, defaultValue: 0, description: 'MDTV Key 索引'),
  PrefsKey(name: 'mdtv_key_verified', group: PrefsGroup.liveTv, type: PrefsType.bool, storage: PrefsStorage.userDefaults, defaultValue: false, description: 'MDTV Key 已校验'),
  PrefsKey(name: 'mdtv_mode_idx', group: PrefsGroup.liveTv, type: PrefsType.int, storage: PrefsStorage.userDefaults, defaultValue: 0, description: 'MDTV 模式索引'),
  // ────────────── _group_one_platform（5）──────────────
  PrefsKey(name: 'one_platform_iv_idx', group: PrefsGroup.onePlatform, type: PrefsType.int, storage: PrefsStorage.userDefaults, defaultValue: 0, description: 'One 平台 IV 索引'),
  PrefsKey(name: 'one_platform_key_idx', group: PrefsGroup.onePlatform, type: PrefsType.int, storage: PrefsStorage.userDefaults, defaultValue: 0, description: 'One 平台 Key 索引'),
  PrefsKey(name: 'one_platform_token', group: PrefsGroup.onePlatform, type: PrefsType.string, storage: PrefsStorage.userDefaults, sensitive: true, defaultValue: '', description: 'One 平台 token'),
  PrefsKey(name: 'one_platform_userkey', group: PrefsGroup.onePlatform, type: PrefsType.string, storage: PrefsStorage.userDefaults, sensitive: true, defaultValue: '', description: 'One 平台 userkey'),
  PrefsKey(name: 'one_platform_uuid', group: PrefsGroup.onePlatform, type: PrefsType.string, storage: PrefsStorage.userDefaults, sensitive: true, defaultValue: '', description: 'One 平台 UUID'),
  // ────────────── _group_quark_pg（10）──────────────
  PrefsKey(name: 'pg_ali_auto_cleanup', group: PrefsGroup.quarkPg, type: PrefsType.bool, storage: PrefsStorage.userDefaults, defaultValue: false, description: '自动清理'),
  PrefsKey(name: 'pg_ali_cleanup_delay', group: PrefsGroup.quarkPg, type: PrefsType.int, storage: PrefsStorage.userDefaults, defaultValue: 60, description: '清理延迟(s)'),
  PrefsKey(name: 'pg_ali_enabled', group: PrefsGroup.quarkPg, type: PrefsType.bool, storage: PrefsStorage.userDefaults, defaultValue: false, description: '启用 PG'),
  PrefsKey(name: 'pg_ali_is_vip', group: PrefsGroup.quarkPg, type: PrefsType.bool, storage: PrefsStorage.userDefaults, defaultValue: false, description: 'VIP 状态'),
  PrefsKey(name: 'pg_ali_proxy_port', group: PrefsGroup.quarkPg, type: PrefsType.int, storage: PrefsStorage.userDefaults, defaultValue: 58090, description: '代理端口'),
  PrefsKey(name: 'pg_ali_thread_limit', group: PrefsGroup.quarkPg, type: PrefsType.int, storage: PrefsStorage.userDefaults, defaultValue: 3, description: '线程上限'),
  PrefsKey(name: 'pg_ali_thread_night', group: PrefsGroup.quarkPg, type: PrefsType.int, storage: PrefsStorage.userDefaults, defaultValue: 5, description: '夜间线程'),
  PrefsKey(name: 'pg_ali_transfer_dir', group: PrefsGroup.quarkPg, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: '', description: '转存目录'),
  PrefsKey(name: 'pg_ali_vod_flags', group: PrefsGroup.quarkPg, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: '', description: 'VOD 标志'),
  PrefsKey(name: 'quark_device_id', group: PrefsGroup.quarkPg, type: PrefsType.string, storage: PrefsStorage.userDefaults, sensitive: true, defaultValue: '', description: '夸克设备 ID'),
  // ────────────── _group_welfare（2）──────────────
  PrefsKey(name: 'welfare_platform_order', group: PrefsGroup.welfare, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: '[]', description: '福利平台排序（JSON）'),
  PrefsKey(name: 'fuli_remote_platform_order_v2', group: PrefsGroup.welfare, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: '[]', description: '福利远程平台排序 v2'),
  // ────────────── _group_debug（3）──────────────
  PrefsKey(name: 'show_debug_overlay', group: PrefsGroup.debug, type: PrefsType.bool, storage: PrefsStorage.userDefaults, defaultValue: false, description: '调试浮层'),
  PrefsKey(name: 'show_search_debug', group: PrefsGroup.debug, type: PrefsType.bool, storage: PrefsStorage.userDefaults, defaultValue: false, description: '搜索调试'),
  PrefsKey(name: 'searchHistory', group: PrefsGroup.debug, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: '[]', description: '搜索历史（JSON）'),
  // ────────────── _group_legacy_migration（1）──────────────
  PrefsKey(name: 'vbox_sqlite_migration_done', group: PrefsGroup.legacyMigration, type: PrefsType.bool, storage: PrefsStorage.userDefaults, defaultValue: false, description: 'UserDefaults→SQLite 迁移标记。Flutter 首次启动必须识别，避免重复迁移'),
  // ────────────── _group_log（8）──────────────
  PrefsKey(name: 'app_skin_mode', group: PrefsGroup.log, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'AppSettings.swift:156'),
  PrefsKey(name: 'app_skin_follows_system', group: PrefsGroup.log, type: PrefsType.bool, storage: PrefsStorage.userDefaults, description: 'AppSettings.swift:158'),
  PrefsKey(name: 'app_dev_log_enabled', group: PrefsGroup.log, type: PrefsType.bool, storage: PrefsStorage.userDefaults, description: 'AppSettings.swift:166'),
  PrefsKey(name: 'app_dev_log_level', group: PrefsGroup.log, type: PrefsType.int, storage: PrefsStorage.userDefaults, description: 'AppSettings.swift:167'),
  PrefsKey(name: 'app_last_launch_version', group: PrefsGroup.log, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'AppSettings.swift:175'),
  PrefsKey(name: 'app_log_enabled', group: PrefsGroup.log, type: PrefsType.bool, storage: PrefsStorage.userDefaults, description: 'AppLogStore.swift:254'),
  PrefsKey(name: 'app_log_min_level', group: PrefsGroup.log, type: PrefsType.int, storage: PrefsStorage.userDefaults, description: 'AppLogStore.swift:255'),
  PrefsKey(name: 'app_log_crash_marker', group: PrefsGroup.log, type: PrefsType.bool, storage: PrefsStorage.userDefaults, description: 'AppLogStore.swift:259'),
  // ────────────── _group_app_settings（5）──────────────
  PrefsKey(name: 'app_enable_tmdb', group: PrefsGroup.appSettings, type: PrefsType.bool, storage: PrefsStorage.userDefaults, description: 'AppSettings.swift:159'),
  PrefsKey(name: 'app_welfare_unlocked', group: PrefsGroup.appSettings, type: PrefsType.bool, storage: PrefsStorage.userDefaults, description: 'AppSettings.swift:163'),
  PrefsKey(name: 'app_welfare_password', group: PrefsGroup.appSettings, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'AppSettings.swift:164'),
  PrefsKey(name: 'app_welfare_enabled', group: PrefsGroup.appSettings, type: PrefsType.bool, storage: PrefsStorage.userDefaults, description: 'AppSettings.swift:165'),
  PrefsKey(name: 'app_ui_form_override', group: PrefsGroup.appSettings, type: PrefsType.string, storage: PrefsStorage.userDefaults, defaultValue: 'auto', description: '显示模式覆盖 auto|portrait|landscape（默认 auto）：第 2 轮新增（D17，非 iOS 来源，方案 §3.2）'),
  // ────────────── _group_welfare_ext（6）──────────────
  PrefsKey(name: 'fuli_remote_source_enabled', group: PrefsGroup.welfareExt, type: PrefsType.bool, storage: PrefsStorage.userDefaults, description: 'WelfarePlatformConfigStore.swift:47'),
  PrefsKey(name: 'fuli_remote_source_last_success_time', group: PrefsGroup.welfareExt, type: PrefsType.long, storage: PrefsStorage.userDefaults, description: 'WelfarePlatformConfigStore.swift:49'),
  PrefsKey(name: 'fuli_remote_source_last_config_version', group: PrefsGroup.welfareExt, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'WelfarePlatformConfigStore.swift:51'),
  PrefsKey(name: 'welfare_custom_domains_v2', group: PrefsGroup.welfareExt, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'WelfareDomainStore.swift'),
  PrefsKey(name: 'welfare_proxy_enabled_platforms_v1', group: PrefsGroup.welfareExt, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'WelfareProxyStore.swift（[String: Bool] JSON 字典字符串，H-07 对齐 iOS 修正）'),
  PrefsKey(name: 'welfare_proxy_url_v1', group: PrefsGroup.welfareExt, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'WelfareProxyStore.swift'),
  // ────────────── _group_live_ext（2）──────────────
  PrefsKey(name: 'live_tv_current_source', group: PrefsGroup.liveExt, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'LiveTVService.swift'),
  PrefsKey(name: 'live_tv_custom_sources', group: PrefsGroup.liveExt, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'LiveTVService.swift'),
  // ────────────── _group_music（2）──────────────
  PrefsKey(name: 'music_queue_index', group: PrefsGroup.music, type: PrefsType.int, storage: PrefsStorage.userDefaults, description: 'AudioPlayerManager.swift'),
  PrefsKey(name: 'music_queue_items', group: PrefsGroup.music, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'AudioPlayerManager.swift'),
  // ────────────── _group_tg（3）──────────────
  PrefsKey(name: 'tg_search_channels_v1', group: PrefsGroup.tg, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'TGSearchConfigStore.swift'),
  PrefsKey(name: 'tg_search_channel_mode_v1', group: PrefsGroup.tg, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'TGSearchConfigStore.swift'),
  PrefsKey(name: 'tg_search_proxy_url_v1', group: PrefsGroup.tg, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'TGSearchConfigStore.swift'),
  // ────────────── _group_push（1）──────────────
  PrefsKey(name: 'push_play_items_v1', group: PrefsGroup.push, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'PushPlayStore.swift'),
  // ────────────── _group_pg_extra（2）──────────────
  PrefsKey(name: 'pg_source', group: PrefsGroup.pgExtra, type: PrefsType.string, storage: PrefsStorage.credentialExtra, description: 'AliyunPgConfig.swift:176（非 prefs）'),
  PrefsKey(name: 'qr_scan', group: PrefsGroup.pgExtra, type: PrefsType.string, storage: PrefsStorage.credentialExtra, description: 'AliyunPgConfig.swift:178（非 prefs）'),
  // ────────────── _group_cloud（16）──────────────
  PrefsKey(name: 'cloud_drive_credentials_v1', group: PrefsGroup.cloud, type: PrefsType.string, storage: PrefsStorage.keychain, description: 'SecureCredentialStore.swift:6（Keychain account）'),
  PrefsKey(name: 'saved_drive_tokens_v1', group: PrefsGroup.cloud, type: PrefsType.string, storage: PrefsStorage.keychain, description: 'SecureCredentialStore.swift:8（Keychain account）'),
  PrefsKey(name: 'saved_drive_tokens', group: PrefsGroup.cloud, type: PrefsType.string, storage: PrefsStorage.userDefaults, sensitive: true, description: '网盘 token 存储键（UserDefaults，区别于 Keychain account；B3 敏感键裁定）'),
  PrefsKey(name: 'cloud_drive_sort_order_v1', group: PrefsGroup.cloud, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'CloudDriveSortManager.swift'),
  PrefsKey(name: 'cloud_drive_cleanup_queue_v1', group: PrefsGroup.cloud, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'CloudDriveManager.swift'),
  PrefsKey(name: 'baidu_local_pcs_device_id', group: PrefsGroup.cloud, type: PrefsType.string, storage: PrefsStorage.userDefaults, sensitive: true, description: 'CloudDriveManager.swift:5665；百度 PCS 本地设备指纹（B3 敏感键裁定）'),
  PrefsKey(name: 'baidu_file_list_cache_v1', group: PrefsGroup.cloud, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'CloudDriveManager.swift:128'),
  PrefsKey(name: 'baidu_ibox_play_item_cache_v1', group: PrefsGroup.cloud, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'CloudDriveManager.swift:127'),
  PrefsKey(name: 'baidu_play_item_cache_v1', group: PrefsGroup.cloud, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'CloudDriveManager.swift:126'),
  PrefsKey(name: 'baidu_play_result_cache_v1', group: PrefsGroup.cloud, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'CloudDriveManager.swift:125'),
  PrefsKey(name: 'baidu_route_diagnostics_v1', group: PrefsGroup.cloud, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'CloudDriveManager.swift:132'),
  PrefsKey(name: 'baidu_share_context_cache_v1', group: PrefsGroup.cloud, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'CloudDriveManager.swift:129'),
  PrefsKey(name: 'baidu_verify_cooldown_v1', group: PrefsGroup.cloud, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'CloudDriveManager.swift:130'),
  PrefsKey(name: 'baidu_verify_cooldowns_v1', group: PrefsGroup.cloud, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'CloudDriveAuthManager.swift:79'),
  PrefsKey(name: 'quark_saved_fid_cache_v1', group: PrefsGroup.cloud, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'CloudDriveManager.swift'),
  PrefsKey(name: 'quark_vbox_folder_cache_v1', group: PrefsGroup.cloud, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'CloudDriveManager.swift'),
  PrefsKey(name: 'cloud_play_item_cache_v1', group: PrefsGroup.cloud, type: PrefsType.string, storage: PrefsStorage.userDefaults, description: 'CloudDriveManager.swift'),
];

/// 敏感键名集合（7 个，严格对应契约 `sensitiveKeys`）。
const Set<String> kSensitiveKeys = <String>{
  'app_tmdb_proxy_token',
  'one_platform_token',
  'one_platform_userkey',
  'one_platform_uuid',
  'quark_device_id',
  'baidu_local_pcs_device_id',
  'saved_drive_tokens',
};

/// 全部键名集合。
final Set<String> kAllKeyNames = <String>{
  for (final PrefsKey k in kAllPrefsKeys) k.name,
};

/// 按键名查找元数据。
PrefsKey? findPrefsKey(String name) {
  for (final PrefsKey k in kAllPrefsKeys) {
    if (k.name == name) return k;
  }
  return null;
}

/// 判断某键是否敏感。
bool isSensitiveKey(String name) => kSensitiveKeys.contains(name);

/// 按分组列出键。
List<PrefsKey> keysOfGroup(PrefsGroup group) =>
    kAllPrefsKeys.where((PrefsKey k) => k.group == group).toList();
