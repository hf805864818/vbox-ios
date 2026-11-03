/// 数据层：福利平台自定义域名存储（批次 H · H-07）。
///
/// 唯一真相源：iOS `vbox/Services/WelfareDomainStore.swift`
///   · 存储格式 `{ "平台名": ["https://新域名1", ...] }`，支持**多域名轮询**；
///   · 契约键 `welfare_custom_domains_v2`（string，**JSON 字典字符串**）；
///   · `addDomain`：trim + 去重 + 追加；`setDomains`：整体覆写；
///     `removeDomain`：删空后移除键；`clearDomains`：清空该平台。
///
/// 差异登记：同 [WelfareProxyStore] —— iOS 落 UserDefaults `Data`，Flutter 按
/// 契约 type=string 落 SharedPreferences **JSON 字符串**。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'prefs_manager.dart';

/// 福利平台自定义域名存储（可监听，UI 直接 `ListenableBuilder` 消费）。
class WelfareDomainStore extends ChangeNotifier {
  /// 构造（[prefs] 可注入；为 null 时降级为内存态，便于单测 / 未初始化兜底）。
  WelfareDomainStore({PrefsManager? prefs}) : _prefs = prefs;

  /// 契约键名（`prefs_keys_v1.json` → `_group_welfare_ext`）。
  static const String key = 'welfare_custom_domains_v2';

  /// 全局共享实例（应用装配时调用 [load]；服务层 / 设置页默认消费）。
  static final WelfareDomainStore shared = WelfareDomainStore();

  final PrefsManager? _prefs;

  Map<String, List<String>> _customDomains = <String, List<String>>{};

  /// 全部自定义域名（[平台名: 域名列表]，只读快照）。
  Map<String, List<String>> get customDomains => Map<String, List<String>>.unmodifiable(
        _customDomains.map(
          (String k, List<String> v) => MapEntry<String, List<String>>(k, List<String>.unmodifiable(v)),
        ),
      );

  /// 获取某个平台的所有自定义域名（无则空表）。
  List<String> domains(String platformName) =>
      _customDomains[platformName] ?? const <String>[];

  /// 从契约键恢复（App 启动 / 设置页进入时调用）。
  Future<void> load() async {
    final PrefsManager? prefs = _p;
    if (prefs == null) return;
    try {
      _customDomains = _decodeDomains(await prefs.getString(key));
    } catch (_) {
      // 历史 / 跨端脏数据 → 降级为空态，不打断加载。
      _customDomains = <String, List<String>>{};
    }
    notifyListeners();
  }

  // ─────────────── 增删改 ───────────────

  /// 添加一个域名到平台（trim + 去重 + 追加，对齐 iOS `addDomain`）。
  void addDomain(String platformName, String domain) {
    final String trimmed = domain.trim();
    if (trimmed.isEmpty) return;
    final List<String> list = List<String>.of(_customDomains[platformName] ?? <String>[]);
    if (!list.contains(trimmed)) {
      list.add(trimmed);
      _customDomains[platformName] = list;
      notifyListeners();
      unawaited(_save());
    }
  }

  /// 直接设置平台域名列表（trim + 过滤空串，对齐 iOS `setDomains`）。
  void setDomains(List<String> domains, String platformName) {
    final List<String> trimmed = domains
        .map((String d) => d.trim())
        .where((String d) => d.isNotEmpty)
        .toList();
    _customDomains[platformName] = trimmed;
    notifyListeners();
    unawaited(_save());
  }

  /// 删除某个平台的指定域名（删空后移除键，对齐 iOS `removeDomain`）。
  void removeDomain(String platformName, String domain) {
    final List<String>? list = _customDomains[platformName];
    if (list == null) return;
    list.remove(domain);
    if (list.isEmpty) {
      _customDomains.remove(platformName);
    } else {
      _customDomains[platformName] = list;
    }
    notifyListeners();
    unawaited(_save());
  }

  /// 清除某个平台的所有自定义域名（对齐 iOS `clearDomains`）。
  void clearDomains(String platformName) {
    if (!_customDomains.containsKey(platformName)) return;
    _customDomains.remove(platformName);
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

  /// 解析 JSON 字典字符串 → `{平台名: [域名]}`（空串 / 脏数据 → 空表）。
  Map<String, List<String>> _decodeDomains(String raw) {
    if (raw.isEmpty) return <String, List<String>>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, List<String>>{};
      final Map<String, List<String>> out = <String, List<String>>{};
      decoded.forEach((Object? k, Object? v) {
        if (k is! String) return;
        final List<String> list = <String>[];
        if (v is List) {
          for (final Object? item in v) {
            final String s = (item ?? '').toString().trim();
            if (s.isNotEmpty) list.add(s);
          }
        }
        if (list.isNotEmpty) out[k] = list;
      });
      return out;
    } on FormatException {
      return <String, List<String>>{};
    }
  }

  Future<void> _save() async {
    final PrefsManager? prefs = _p;
    if (prefs == null) return;
    try {
      await prefs.set(key, jsonEncode(_customDomains));
    } catch (_) {
      // 落盘失败不阻断 UI（下次变更重试）。
    }
  }
}
