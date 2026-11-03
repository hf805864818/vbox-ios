/// 数据层：源治理存储（切片源 / 自定义解析器 / 兜底开关 / 站源启停）。
///
/// 唯一真相源：iOS `SpiderManager`（`vbox/Services/SpiderManager.swift`）
///   · `fallbackEnabled`（L46-L48，键 `fallback_enabled`）；
///   · `customFallbackSites` + `saveCustomFallbackSites`（L49、L237-L262，
///     键 `custom_fallback_sites`）；
///   · `customParsers` + `saveCustomParsers`（L45、L286-L335，键 `user_parsers`）；
///   · 站源启停 `DatabaseManager.updateZhanyuanActive`（SQLite `zhanyuan.isActive`）。
///
/// 落地口径（复用既有契约键，不新增契约）：
/// - 三个开关/列表键均为 `prefs_keys_v1.json` 既有键，走 [PrefsManager]；
/// - 站源启停对齐 iOS：状态落 SQLite `zhanyuan` 表的 `isActive`，
///   由表现层在加载站源列表时按站点名过滤。
library;

import 'package:flutter/foundation.dart';

import '../../../domain/entities/source/source_governance.dart';
import '../../models/db_model.dart';
import '../../models/zhanyuan.dart';
import 'database_manager.dart';
import 'prefs_manager.dart';

/// 源治理存储（单例；`ChangeNotifier` 便于设置页即时刷新）。
class SourceGovernanceStore extends ChangeNotifier {
  SourceGovernanceStore._();

  /// 全局单例。
  static final SourceGovernanceStore instance = SourceGovernanceStore._();

  /// 契约键：兜底源开关。
  static const String fallbackEnabledKey = 'fallback_enabled';

  /// 契约键：自定义切片源（JSON 数组字符串）。
  static const String customFallbackSitesKey = 'custom_fallback_sites';

  /// 契约键：用户自定义解析器（JSON 数组字符串）。
  static const String userParsersKey = 'user_parsers';

  bool _fallbackEnabled = true;
  List<FallbackSite> _customFallbackSites = const <FallbackSite>[];
  List<ParserEntry> _userParsers = const <ParserEntry>[];
  Set<String> _disabledZhanyuanNames = <String>{};
  bool _loaded = false;

  /// 兜底切片源开关（对齐 iOS `SpiderManager.fallbackEnabled`）。
  bool get fallbackEnabled => _fallbackEnabled;

  /// 自定义切片源（对齐 iOS `customFallbackSites`）。
  List<FallbackSite> get customFallbackSites =>
      List<FallbackSite>.unmodifiable(_customFallbackSites);

  /// 自定义解析器（对齐 iOS `customParsers`，本端只含用户自定义项）。
  List<ParserEntry> get userParsers =>
      List<ParserEntry>.unmodifiable(_userParsers);

  /// 已禁用站源名集合（SQLite `zhanyuan.isActive = 0`）。
  Set<String> get disabledZhanyuanNames =>
      Set<String>.unmodifiable(_disabledZhanyuanNames);

  /// 是否已完成首次加载。
  bool get isLoaded => _loaded;

  /// 从契约键 + SQLite 恢复三组配置。
  ///
  /// 幂等；SQLite 不可用时（如纯 widget 测试）站源状态降级为空集合，不抛异常。
  Future<void> load() async {
    final PrefsManager prefs = PrefsManager.instance;
    // 契约缺省 true（`prefs_keys_v1.json` `fallback_enabled.default = true`），
    // 与 iOS `SpiderManager.init` 的 `?? true` 一致。
    final Object? raw = await prefs.get(fallbackEnabledKey);
    _fallbackEnabled = raw is bool ? raw : true;
    _customFallbackSites = _decodeCustomFallbackSites(
      await prefs.getJsonList(customFallbackSitesKey),
    );
    _userParsers = _decodeUserParsers(await prefs.getJsonList(userParsersKey));
    _disabledZhanyuanNames = await _loadDisabledZhanyuanNames();
    _loaded = true;
    notifyListeners();
  }

  /// 设置兜底切片源开关（对齐 iOS `didSet` 落 UserDefaults）。
  Future<void> setFallbackEnabled(bool value) async {
    if (_fallbackEnabled == value) return;
    _fallbackEnabled = value;
    await PrefsManager.instance.set(fallbackEnabledKey, value);
    notifyListeners();
  }

  /// 添加自定义切片源；地址重复或字段非法时返回 false（对齐 iOS 去重语义）。
  Future<bool> addCustomFallbackSite(FallbackSite site) async {
    if (!site.isValid) return false;
    if (_customFallbackSites.any((FallbackSite s) => s.api == site.api)) {
      return false;
    }
    _customFallbackSites = <FallbackSite>[..._customFallbackSites, site];
    await _persistCustomFallbackSites();
    notifyListeners();
    return true;
  }

  /// 删除自定义切片源（按 API 地址，对齐 iOS `removeCustomFallbackSite`）。
  Future<void> removeCustomFallbackSite(String api) async {
    final List<FallbackSite> next = _customFallbackSites
        .where((FallbackSite s) => s.api != api)
        .toList(growable: false);
    if (next.length == _customFallbackSites.length) return;
    _customFallbackSites = next;
    await _persistCustomFallbackSites();
    notifyListeners();
  }

  /// 添加自定义解析器；地址重复或字段非法时返回 false（对齐 iOS 去重语义）。
  Future<bool> addUserParser(ParserEntry parser) async {
    if (!parser.isValid) return false;
    if (_userParsers.any((ParserEntry p) => p.url == parser.url)) return false;
    _userParsers = <ParserEntry>[..._userParsers, parser];
    await _persistUserParsers();
    notifyListeners();
    return true;
  }

  /// 删除自定义解析器（按地址，对齐 iOS `removeCustomParser`）。
  Future<void> removeUserParser(String url) async {
    final List<ParserEntry> next = _userParsers
        .where((ParserEntry p) => p.url != url)
        .toList(growable: false);
    if (next.length == _userParsers.length) return;
    _userParsers = next;
    await _persistUserParsers();
    notifyListeners();
  }

  /// 读取全部站源（SQLite `zhanyuan` 表；不可用时降级为空列表）。
  ///
  /// SQLite 为**权威状态源**（`isActive`），订阅配置站点作为内存补齐
  /// （见 `SourceGovernanceUseCases.listZhanyuanSites`）。
  Future<List<Zhanyuan>> allZhanyuanSites() async {
    try {
      final List<Map<String, Object?>> rows = await DatabaseManager.instance
          .queryAll(Zhanyuan.table, orderBy: 'name ASC');
      return rows
          .map((Map<String, Object?> r) => Zhanyuan.fromMap(r))
          .toList(growable: false);
    } catch (_) {
      // 测试环境未初始化 SQLite：降级为空（不阻断设置页）。
      return const <Zhanyuan>[];
    }
  }

  /// 读取已启用站源（对齐 iOS `queryActiveZhanyuanSites()`）。
  Future<List<Zhanyuan>> activeZhanyuanSites() async {
    final List<Zhanyuan> all = await allZhanyuanSites();
    return all.where((Zhanyuan z) => z.isActive).toList(growable: false);
  }

  /// 设置单个站源启用状态（落 SQLite `zhanyuan.isActive`，对齐 iOS
  /// `DatabaseManager.updateZhanyuanActive`）。
  ///
  /// SQLite 不可用时（如纯 widget 测试）仅更新内存禁用集合，不抛异常。
  Future<void> setZhanyuanActive({
    required String name,
    required String searchUrl,
    required bool active,
  }) =>
      _setZhanyuanActive(
        name: name,
        searchUrl: searchUrl,
        active: active,
        notify: true,
      );

  Future<void> _setZhanyuanActive({
    required String name,
    required String searchUrl,
    required bool active,
    required bool notify,
  }) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) return;
    try {
      final int now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final DatabaseManager db = DatabaseManager.instance;
      final List<Map<String, Object?>> rows = await db.queryAll(
        Zhanyuan.table,
        where: 'name = ?',
        whereArgs: <Object?>[trimmed],
        limit: 1,
      );
      if (rows.isEmpty) {
        await db.upsert(
          Zhanyuan.table,
          <String, Object?>{
            'name': trimmed,
            'searchUrl': searchUrl,
            'searchUA': Zhanyuan.defaultUA,
            'isActive': writeBool(active),
            'updatedAt': now,
            'dyurl': '',
          },
          primaryKey: 'name',
        );
      } else {
        await db.update(
          Zhanyuan.table,
          <String, Object?>{'isActive': writeBool(active), 'updatedAt': now},
          where: 'name = ?',
          whereArgs: <Object?>[trimmed],
        );
      }
    } catch (_) {
      // 降级：仅内存态生效，保证设置页交互不崩。
    }
    if (active) {
      _disabledZhanyuanNames.remove(trimmed);
    } else {
      _disabledZhanyuanNames.add(trimmed);
    }
    if (notify) notifyListeners();
  }

  /// 批量设置站源启用状态（「全选」入口，对齐 iOS `ZhanyuanSiteManageView`）。
  ///
  /// 批量内合并为一次 [notifyListeners]（避免逐行触发整页重建）。
  Future<void> setZhanyuanActiveAll(
    List<(String name, String searchUrl)> sites,
    bool active,
  ) async {
    for (final (String name, String searchUrl) in sites) {
      await _setZhanyuanActive(
        name: name,
        searchUrl: searchUrl,
        active: active,
        notify: false,
      );
    }
    notifyListeners();
  }

  // ────────────────── 内部 ──────────────────

  List<FallbackSite> _decodeCustomFallbackSites(List<dynamic> raw) => raw
      .whereType<Map<Object?, Object?>>()
      .map((Map<Object?, Object?> m) =>
          FallbackSite.fromJson(m.cast<String, Object?>()))
      .where((FallbackSite s) => s.isValid)
      .toList(growable: false);

  List<ParserEntry> _decodeUserParsers(List<dynamic> raw) => raw
      .whereType<Map<Object?, Object?>>()
      .map((Map<Object?, Object?> m) =>
          ParserEntry.fromJson(m.cast<String, Object?>()))
      .where((ParserEntry p) => p.isValid)
      .toList(growable: false);

  Future<void> _persistCustomFallbackSites() => PrefsManager.instance.setJsonList(
        customFallbackSitesKey,
        _customFallbackSites.map((FallbackSite s) => s.toJson()).toList(),
      );

  Future<void> _persistUserParsers() => PrefsManager.instance.setJsonList(
        userParsersKey,
        _userParsers.map((ParserEntry p) => p.toJson()).toList(),
      );

  Future<Set<String>> _loadDisabledZhanyuanNames() async {
    try {
      final List<Map<String, Object?>> rows = await DatabaseManager.instance
          .queryAll(Zhanyuan.table, where: 'isActive = 0');
      return rows
          .map((Map<String, Object?> r) => (r['name'] ?? '').toString())
          .where((String n) => n.isNotEmpty)
          .toSet();
    } catch (_) {
      // 测试环境未初始化 SQLite：降级为空集合，不阻断设置页加载。
      return <String>{};
    }
  }

  /// 测试复位（仅单测使用）。
  @visibleForTesting
  void resetForTest() {
    _fallbackEnabled = true;
    _customFallbackSites = const <FallbackSite>[];
    _userParsers = const <ParserEntry>[];
    _disabledZhanyuanNames = <String>{};
    _loaded = false;
  }

  /// 测试注入（仅单测使用）。
  @visibleForTesting
  void setStateForTest({
    bool? fallbackEnabled,
    List<FallbackSite>? customFallbackSites,
    List<ParserEntry>? userParsers,
  }) {
    if (fallbackEnabled != null) _fallbackEnabled = fallbackEnabled;
    if (customFallbackSites != null) _customFallbackSites = customFallbackSites;
    if (userParsers != null) _userParsers = userParsers;
  }
}
