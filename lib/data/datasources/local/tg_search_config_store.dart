/// 数据层：TG 搜索配置存储（批次 G · G-04）。
///
/// 唯一真相源：iOS `vbox/Services/TGSearchConfigStore.swift`
///   · 契约键三枚（`prefs_keys_v1.json` → `_group_tg`）：
///     `tg_search_proxy_url_v1` / `tg_search_channel_mode_v1` /
///     `tg_search_channels_v1`（string，存 JSON 数组字符串）；
///   · `addChannel`（L90-L96）—— trim → 空 ID 忽略 → 空名称回退 ID；
///   · `removeChannels` / `moveChannel`（L98-L104）—— 删除 / 排序；
///   · `hasValidProxy`（L84-L87）—— trim 非空且以 `http` 开头；
///   · `generateConfigJS`（L109-L132）—— 生成注入蜘蛛脚本的 `__TG_CONFIG__`。
///
/// 差异登记：
///   · iOS 落 `UserDefaults` `Data`（`JSONEncoder` 二进制）；Flutter 按契约
///     type=string 存 JSON 数组字符串（跨端读取走 `jsonDecode` 兼容，同
///     G-03 `PushPlayStore` 口径）；
///   · iOS `load()` 在 `init` 中同步执行一次；Flutter 为异步 `load()`，
///     以 `_loaded` 守卫保证「启动恢复一次」语义（此后以内存态为准）。
///
/// `__TG_CONFIG__` 注入点：`lib/domain/usecases/content_browse_usecases.dart`
/// `_prepareEngine`（站点 key 为 `js_TG搜索` 时先加载配置库；对齐 iOS
/// `SpiderManager.swift` L1391-L1400 的 prepend 语义）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../domain/entities/tg/tg_channel.dart';
import 'prefs_manager.dart';

/// TG 搜索配置存储（可监听，UI 直接 `ListenableBuilder` 消费）。
class TGSearchConfigStore extends ChangeNotifier {
  /// 构造（[prefs] 可注入；为 null 时降级为内存态，便于单测 / 未初始化兜底）。
  TGSearchConfigStore({PrefsManager? prefs}) : _prefs = prefs;

  /// 契约键：代理地址（`prefs_keys_v1.json` → `_group_tg`）。
  static const String proxyUrlKey = 'tg_search_proxy_url_v1';

  /// 契约键：频道来源模式。
  static const String channelModeKey = 'tg_search_channel_mode_v1';

  /// 契约键：自定义频道列表（JSON 数组字符串）。
  static const String channelsKey = 'tg_search_channels_v1';

  /// 全局共享实例（应用装配时调用 [load]；页面默认消费）。
  static final TGSearchConfigStore shared = TGSearchConfigStore();

  final PrefsManager? _prefs;

  bool _loaded = false;
  String _proxyUrl = '';
  TGChannelMode _channelMode = TGChannelMode.remoteDefault;
  List<TGChannel> _channels = const <TGChannel>[];

  /// 代理地址（空串 = 未配置）。
  String get proxyUrl => _proxyUrl;

  /// 频道来源模式。
  TGChannelMode get channelMode => _channelMode;

  /// 自定义频道列表（对齐 iOS 顺序即用户排序结果）。
  List<TGChannel> get channels => List<TGChannel>.unmodifiable(_channels);

  /// 代理地址是否有效（对齐 iOS `hasValidProxy`：trim 非空且以 `http` 开头）。
  bool get hasValidProxy {
    final String trimmed = _proxyUrl.trim();
    return trimmed.isNotEmpty && trimmed.startsWith('http');
  }

  /// 从契约键恢复（App 启动时调用；`_loaded` 守卫保证只恢复一次）。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final PrefsManager? prefs = _p;
    if (prefs == null) return;
    try {
      _proxyUrl = await prefs.getString(proxyUrlKey);
      _channelMode = TGChannelMode.fromRaw(await prefs.getString(channelModeKey));
      _channels = TGChannel.decodeChannels(await prefs.getString(channelsKey));
    } catch (e) {
      // 历史 / 跨端脏数据 → 保留默认态，不打断加载。
    }
    notifyListeners();
  }

  // ─────────────── 配置项（对齐 iOS @Published 属性）───────────────

  /// 更新代理地址并落盘（对齐 iOS `proxyURL` 的 `didSet` 即时保存语义）。
  void setProxyUrl(String value) {
    if (_proxyUrl == value) return;
    _proxyUrl = value;
    notifyListeners();
    unawaited(_save());
  }

  /// 切换频道来源模式并落盘。
  void setChannelMode(TGChannelMode value) {
    if (_channelMode == value) return;
    _channelMode = value;
    notifyListeners();
    unawaited(_save());
  }

  // ─────────────── 频道管理（对齐 iOS `addChannel` / `remove` / `move`）───────────────

  /// 添加频道（对齐 iOS `addChannel`：trim → 空 ID 忽略 → 空名称回退 ID → 追加尾部）。
  void addChannel({required String name, required String channelId}) {
    final String trimmedId = channelId.trim();
    if (trimmedId.isEmpty) return;
    final String trimmedName = name.trim();
    final TGChannel channel = TGChannel(
      name: trimmedName.isEmpty ? trimmedId : trimmedName,
      channelId: trimmedId,
    );
    _channels = <TGChannel>[..._channels, channel];
    notifyListeners();
    unawaited(_save());
  }

  /// 删除指定下标的频道（越界忽略）。
  void removeChannelAt(int index) {
    if (index < 0 || index >= _channels.length) return;
    final List<TGChannel> next = List<TGChannel>.of(_channels)..removeAt(index);
    _channels = next;
    notifyListeners();
    unawaited(_save());
  }

  /// 批量删除（对齐 iOS `removeChannels(at offsets:)`；跳过越界下标）。
  void removeChannels(Iterable<int> indexes) {
    final Set<int> valid = indexes
        .where((int i) => i >= 0 && i < _channels.length)
        .toSet();
    if (valid.isEmpty) return;
    final List<TGChannel> next = <TGChannel>[];
    for (int i = 0; i < _channels.length; i++) {
      if (!valid.contains(i)) next.add(_channels[i]);
    }
    _channels = next;
    notifyListeners();
    unawaited(_save());
  }

  /// 移动频道（对齐 iOS `moveChannel(from:to:)`）。
  ///
  /// [to] 采用**移除后插入**语义（即目标绝对位置），与
  /// `ReorderableListView.onReorderItem` 的 `newIndex` 口径一致（该回调已自动
  /// 处理移除项的下移偏移，直接透传即可）。
  void moveChannel({required int from, required int to}) {
    if (from < 0 || from >= _channels.length) return;
    final int target = to.clamp(0, _channels.length - 1);
    if (from == target) return;
    final List<TGChannel> next = List<TGChannel>.of(_channels);
    final TGChannel moved = next.removeAt(from);
    next.insert(target, moved);
    _channels = next;
    notifyListeners();
    unawaited(_save());
  }

  /// 当前频道 ID 集合（快捷添加按钮据此置灰）。
  Set<String> get channelIds =>
      _channels.map((TGChannel c) => c.channelId).toSet();

  /// 是否已添加该频道 ID。
  bool containsChannel(String channelId) =>
      _channels.any((TGChannel c) => c.channelId == channelId);

  // ─────────────── 配置注入（对齐 iOS `generateConfigJS`）───────────────

  /// 生成注入蜘蛛脚本的配置 JS（全局变量 `__TG_CONFIG__`）。
  ///
  /// 结构对齐 iOS L109-L132：`proxyUrl` / `channelMode` / `channels[{name,id}]`
  /// —— 注意注入侧频道键名为 `id`（供 JS 蜘蛛读取 `ch.id`），与持久化侧
  /// `channelId` 不同。
  String generateConfigJs() {
    final Map<String, Object?> config = <String, Object?>{
      'proxyUrl': _proxyUrl.trim(),
      'channelMode': _channelMode.rawValue,
      'channels': _channels
          .map((TGChannel c) => <String, String>{
                'name': c.name,
                'id': c.channelId,
              })
          .toList(),
    };
    return 'var __TG_CONFIG__ = ${jsonEncode(config)};';
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
      await prefs.set(proxyUrlKey, _proxyUrl);
      await prefs.set(channelModeKey, _channelMode.rawValue);
      await prefs.set(channelsKey, TGChannel.encodeChannels(_channels));
    } catch (e) {
      // 落盘失败不阻断 UI（下次变更重试）。
    }
  }
}