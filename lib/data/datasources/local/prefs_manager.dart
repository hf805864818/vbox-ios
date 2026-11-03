/// 数据层：偏好管理器（Preferences Manager）。
///
/// 唯一真相源：`contract/schema/prefs_keys_v1.json`（v1.5，98 键）
///
/// 设计要点：
/// - **普通键** → `SharedPreferences`（对应 iOS `UserDefaults.standard`）
/// - **安全键** → 核心层 [SecureStore] 抽象（默认实现见 [FlutterSecureStoreAdapter]），
///   判定见 [_isSecure]：
///   ① 契约敏感键（[kSensitiveKeys]，7 个，JSON `sensitive: true`）
///   ② 契约 `storage = keychain` 的键（云盘凭据）
///   ③ 契约 `storage = credential_extra` 的键（B2：PG 凭据 extra 字典字段，iOS 侧存
///      于 Keychain 凭据对象内；Flutter 端按安全键处理，避免明文落 SharedPreferences）
/// - 读取安全键时若安全存储为空，**回退读 SharedPreferences 并迁移**（A1：
///   iOS 侧敏感键曾写 UserDefaults，见方案 P.16 第 1 项），迁移后清除明文
/// - 读取时按契约 `type` 分派正确的 getter
/// - 23 个 string 键中，`custom_fallback_sites`/`user_parsers`/`live_tv_local_channels`/
///   `mdtv_home_tabs`/`welfare_platform_order`/`fuli_remote_platform_order_v2`/`searchHistory`
///   实际存 JSON 数组字符串，提供 `getJsonList`/`setJsonList` 便捷方法
/// - `vbox_sqlite_migration_done` 是**关键迁移标记**，Flutter 首次启动必须识别
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../contract/prefs_keys.dart';
import '../../../core/storage/secure_store.dart';
import 'secure_store_adapter.dart';

class PrefsManager {
  PrefsManager._();

  static final PrefsManager instance = PrefsManager._();

  SharedPreferences? _prefs;
  SecureStore? _secure;

  /// 需要按 JSON 数组字符串读写的不敏感键（契约 type=string 但语义为列表）。
  static const Set<String> jsonListKeys = <String>{
    'custom_fallback_sites',
    'user_parsers',
    'live_tv_local_channels',
    'mdtv_home_tabs',
    'welfare_platform_order',
    'fuli_remote_platform_order_v2',
    'searchHistory',
  };

  /// 初始化（App 启动时调用一次）。
  ///
  /// [secureStore] 可注入自定义实现（单测/替代后端）；缺省用
  /// [FlutterSecureStoreAdapter]（`flutter_secure_storage`）。
  Future<void> init({SecureStore? secureStore}) async {
    _prefs ??= await SharedPreferences.getInstance();
    _secure ??= secureStore ?? FlutterSecureStoreAdapter();
  }

  SharedPreferences get _p {
    final SharedPreferences? p = _prefs;
    if (p == null) {
      throw StateError('PrefsManager 未初始化：请先 await PrefsManager.instance.init()');
    }
    return p;
  }

  SecureStore get _s {
    final SecureStore? s = _secure;
    if (s == null) {
      throw StateError('PrefsManager 未初始化：请先 await PrefsManager.instance.init()');
    }
    return s;
  }

  /// 该键是否走安全存储（核心层 [SecureStore]）。
  ///
  /// 依据契约 `notes`：`sensitiveKeys` 在 Flutter 端建议迁移到安全存储
  /// （iOS 曾写入 UserDefaults，读取需兼容）；`storage = keychain` 的云盘凭据、
  /// `storage = credential_extra` 的 PG 凭据 extra 字段同理（B2 裁定）。
  static bool _isSecure(PrefsKey meta) =>
      meta.sensitive ||
      meta.storage == PrefsStorage.keychain ||
      meta.storage == PrefsStorage.credentialExtra;

  // ─────────────────────────────────────────────────────────
  // 通用读取（按契约 type 分派；无值时回退契约默认值）
  // ─────────────────────────────────────────────────────────

  /// 按键名读取任意类型值（敏感键走安全存储）。
  Future<Object?> get(String name) async {
    final PrefsKey? meta = findPrefsKey(name);
    if (meta == null) {
      throw ArgumentError('契约外键名: $name（见 prefs_keys_v1.json）');
    }
    if (_isSecure(meta)) {
      final String? v = await _s.read(name);
      if (v != null) return v;
      // A1：iOS 侧敏感键曾写 UserDefaults（Flutter 端对应 SharedPreferences）。
      // 首读回退到明文存储，命中则**迁移**进安全存储并清除明文，避免迁移丢值。
      final String? legacy = _p.getString(name);
      if (legacy != null) {
        await _s.write(name, legacy);
        await _p.remove(name);
        return legacy;
      }
      return meta.defaultValue;
    }
    try {
      return switch (meta.type) {
        PrefsType.bool => _p.getBool(name) ?? meta.defaultValue,
        PrefsType.int => _p.getInt(name) ?? meta.defaultValue,
        PrefsType.long => _p.getInt(name) ?? meta.defaultValue,
        PrefsType.float => _p.getDouble(name) ?? meta.defaultValue,
        PrefsType.string => _p.getString(name) ?? meta.defaultValue,
        PrefsType.stringArray =>
          _p.getStringList(name) ?? (meta.defaultValue as List<String>?),
      };
    } on TypeError {
      // B1：历史数据可能以与契约不符的类型落盘（如 bool 键存了 String），
      // shared_preferences 的 getter 对类型不符直接抛 TypeError，首读即崩。
      // 此处捕获并静默回退契约默认值（P.16 #2 闭环）。
      return meta.defaultValue;
    }
  }

  /// 按键名写入任意类型值（敏感键走 secure storage）。
  Future<void> set(String name, Object? value) async {
    final PrefsKey? meta = findPrefsKey(name);
    if (meta == null) {
      throw ArgumentError('契约外键名: $name（见 prefs_keys_v1.json）');
    }
    if (_isSecure(meta)) {
      if (value == null) {
        await _s.delete(name);
      } else {
        await _s.write(name, value.toString());
      }
      return;
    }
    switch (meta.type) {
      case PrefsType.bool:
        await _p.setBool(name, value as bool? ?? false);
      case PrefsType.int:
      case PrefsType.long:
        await _p.setInt(name, value as int? ?? 0);
      case PrefsType.float:
        await _p.setDouble(name, (value as num?)?.toDouble() ?? 0.0);
      case PrefsType.string:
        await _p.setString(name, value as String? ?? '');
      case PrefsType.stringArray:
        await _p.setStringList(name, (value as List<dynamic>?)?.cast<String>() ?? <String>[]);
    }
  }

  /// 删除某键。
  Future<void> remove(String name) async {
    final PrefsKey? meta = findPrefsKey(name);
    if (meta == null) return;
    if (_isSecure(meta)) {
      await _s.delete(name);
    } else {
      await _p.remove(name);
    }
  }

  /// 清空全部契约键（谨慎：含敏感键）。
  Future<void> clearAll() async {
    for (final PrefsKey k in kAllPrefsKeys) {
      await remove(k.name);
    }
  }

  // ─────────────────────────────────────────────────────────
  // 类型化便捷读写
  // ─────────────────────────────────────────────────────────

  Future<bool> getBool(String name) async => (await get(name)) as bool? ?? false;

  Future<int> getInt(String name) async => (await get(name)) as int? ?? 0;

  Future<double> getDouble(String name) async =>
      ((await get(name)) as num?)?.toDouble() ?? 0.0;

  Future<String> getString(String name) async => (await get(name)) as String? ?? '';

  Future<List<String>> getStringList(String name) async =>
      ((await get(name)) as List<String>?) ?? <String>[];

  // ─────────────────────────────────────────────────────────
  // JSON 列表便捷读（存为 JSON 数组字符串的 string 键）
  // ─────────────────────────────────────────────────────────

  Future<List<dynamic>> getJsonList(String name) async {
    final String raw = await getString(name);
    if (raw.isEmpty) return <dynamic>[];
    try {
      final Object? decoded = jsonDecode(raw);
      return decoded is List ? decoded : <dynamic>[];
    } on FormatException {
      return <dynamic>[];
    }
  }

  Future<void> setJsonList(String name, List<dynamic> value) async {
    await set(name, jsonEncode(value));
  }

  // ─────────────────────────────────────────────────────────
  // 契约语义专用方法
  // ─────────────────────────────────────────────────────────

  /// 首次启动判定（`vbox_sqlite_migration_done` 为 false 表示尚未迁移）。
  Future<bool> needSqliteMigration() async =>
      !(await getBool('vbox_sqlite_migration_done'));

  /// 标记 UserDefaults→SQLite 迁移已完成（**必须**，避免重复迁移）。
  Future<void> markSqliteMigrationDone() async =>
      set('vbox_sqlite_migration_done', true);

  /// 当前激活订阅源索引。
  Future<int> activeSubscriptionIndex() async =>
      await getInt('active_subscription_index');

  /// 订阅源 URL 列表。
  Future<List<String>> subscribedConfigUrls() async =>
      await getStringList('subscribed_config_urls');

  /// 远程 manifest 地址（可被用户覆盖）。
  Future<String> remoteManifestUrl() async =>
      await getString('remote_default_manifest_url');

  /// 显示模式覆盖档（`app_ui_form_override`，`auto|portrait|landscape`，默认 `auto`）。
  ///
  /// 批次 A · A-06：形态判定最高优先开关（方案 §3.2 ①）；
  /// 字符串→枚举解析由呈现层 `UiFormOverride.fromId` 负责（数据层不依赖呈现层）。
  Future<String> uiFormOverride() async =>
      await getString('app_ui_form_override');

  // ─────────────────────────────────────────────────────────
  // 诊断：列出全部键的当前值（敏感键脱敏）
  // ─────────────────────────────────────────────────────────

  /// 导出全部键值（敏感键以 `***` 代替），用于调试/自检。
  Future<Map<String, Object?>> dumpAll({bool maskSensitive = true}) async {
    final Map<String, Object?> out = <String, Object?>{};
    for (final PrefsKey k in kAllPrefsKeys) {
      if (_isSecure(k) && maskSensitive) {
        out[k.name] = (await _s.read(k.name)) == null ? null : '***';
      } else {
        out[k.name] = await get(k.name);
      }
    }
    return out;
  }
}
