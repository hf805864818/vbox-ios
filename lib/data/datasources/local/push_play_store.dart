/// 数据层：推送播放存储（批次 G · G-03）。
///
/// 唯一真相源：iOS `vbox/Services/PushPlayStore.swift`
///   · 契约键 `push_play_items_v1`（string）：JSON 数组字符串（对齐 iOS
///     `UserDefaults.standard.data(forKey:)` 的 JSON 编码内容，Flutter 按契约
///     type=string 落 SharedPreferences）；
///   · `addItem`：URL 去重 → 插入**列表头部**（最新在前）；
///   · `updateItem`：写入解析后的剧集列表；
///   · `removeItem` / `removeAll`：删除单条 / 清空；
///   · `detectType`：自动识别链接类型（网盘域名清单 → 直链扩展名 → 网页解析）。
///
/// 差异登记：
///   · iOS 落 `UserDefaults` `Data`；Flutter 按契约 type=string 存 JSON 字符串
///     （跨端读取走 `jsonDecode` 兼容，同 H-07 `WelfareProxyStore` 口径）；
///   · iOS `createdAt` 由 `JSONEncoder` 默认编码为 `timeIntervalSinceReferenceDate`
///     数字；Flutter 落 ISO8601 字符串并在解码侧兼容两种形态（见实体 `_parseDate`）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../domain/entities/push/push_play.dart';
import 'prefs_manager.dart';

/// 推送播放存储（可监听，UI 直接 `ListenableBuilder` 消费）。
class PushPlayStore extends ChangeNotifier {
  /// 构造（[prefs] 可注入；为 null 时降级为内存态，便于单测 / 未初始化兜底）。
  PushPlayStore({PrefsManager? prefs}) : _prefs = prefs;

  /// 契约键（`prefs_keys_v1.json` → `_group_push`）。
  static const String itemsKey = 'push_play_items_v1';

  /// 全局共享实例（应用装配时调用 [load]；页面默认消费）。
  static final PushPlayStore shared = PushPlayStore();

  final PrefsManager? _prefs;

  List<PushPlayItem> _items = const <PushPlayItem>[];

  /// 全部推送链接（最新在前）。
  List<PushPlayItem> get items => List<PushPlayItem>.unmodifiable(_items);

  /// 从契约键恢复（App 启动 / 页面进入时调用）。
  ///
  /// 内存态优先：已有数据（预填 / 已恢复）时跳过，避免覆盖内存预填
  /// （对齐 iOS 启动恢复一次、此后以内存态为准的语义）。
  Future<void> load() async {
    if (_items.isNotEmpty) return;
    final PrefsManager? prefs = _p;
    if (prefs == null) return;
    try {
      _items = PushPlayItem.decodeItems(await prefs.getString(itemsKey));
    } catch (e) {
      // 历史 / 跨端脏数据 → 降级为空态，不打断加载。
      _items = const <PushPlayItem>[];
    }
    notifyListeners();
  }

  // ─────────────── CRUD（对齐 iOS `PushPlayStore`）───────────────

  /// 添加链接（对齐 iOS `addItem`：trim → 空 URL 忽略 → 空标题默认名 →
  /// 按 url 去重 → 插入头部 → 落盘）。
  void addItem({required String title, required String url, required PushPlayLinkType type}) {
    final String trimmedURL = url.trim();
    final String trimmedTitle = title.trim();
    if (trimmedURL.isEmpty) return;

    final String finalTitle = trimmedTitle.isEmpty
        ? defaultTitle(trimmedURL, type: type)
        : trimmedTitle;
    final PushPlayItem item = PushPlayItem(
      title: finalTitle,
      url: trimmedURL,
      type: type,
      createdAt: DateTime.now(),
    );

    // 避免重复（对齐 iOS：同 url 直接忽略）。
    if (!_items.any((PushPlayItem e) => e.url == trimmedURL)) {
      _items = <PushPlayItem>[item, ..._items];
      notifyListeners();
      unawaited(_save());
    }
  }

  /// 写入解析后的剧集列表（对齐 iOS `updateItem(_:withEpisodes:)`）。
  void updateItem(PushPlayItem item, List<PushPlayEpisode> episodes) {
    final int index = _items.indexWhere((PushPlayItem e) => e.id == item.id);
    if (index < 0) return;
    final List<PushPlayItem> next = List<PushPlayItem>.of(_items);
    next[index] = PushPlayItem(
      title: item.title,
      url: item.url,
      type: item.type,
      createdAt: item.createdAt,
      episodes: episodes,
    );
    _items = next;
    notifyListeners();
    unawaited(_save());
  }

  /// 删除单条（对齐 iOS `removeItem`）。
  void removeItem(PushPlayItem item) {
    final List<PushPlayItem> next =
        _items.where((PushPlayItem e) => e.id != item.id).toList();
    if (next.length == _items.length) return;
    _items = next;
    notifyListeners();
    unawaited(_save());
  }

  /// 清空全部（对齐 iOS `removeAll`）。
  void removeAll() {
    if (_items.isEmpty) return;
    _items = const <PushPlayItem>[];
    notifyListeners();
    unawaited(_save());
  }

  // ─────────────── 类型识别（对齐 iOS `PushPlayStore.detectType(for:)`）───────────────

  /// 自动识别链接类型。
  static PushPlayLinkType detectType(String url) {
    final String lower = url.toLowerCase();

    // 网盘链接识别（域名清单与 iOS `cloudPatterns` 一致）。
    const List<String> cloudPatterns = <String>[
      'alipan.com', 'aliyundrive.com', 'aliyun.com',
      'pan.quark.cn', 'quark.cn',
      'pan.baidu.com', 'yun.baidu.com', 'baidu.com',
      '115.com', '115cdn.com',
      'drive.uc.cn', 'uc.cn',
      'www.123pan.com', '123pan.com',
      'caiyun.139.com', '139.com',
      'cloud.189.cn', '189.cn',
    ];
    if (cloudPatterns.any((String p) => lower.contains(p))) {
      return PushPlayLinkType.cloud;
    }

    // 直链识别（视频扩展名）。
    if (lower.contains('.m3u8') ||
        lower.contains('.mp4') ||
        lower.contains('.flv') ||
        lower.contains('.ts') ||
        lower.contains('.mkv') ||
        lower.contains('.avi')) {
      return PushPlayLinkType.direct;
    }

    // 默认网页解析。
    return PushPlayLinkType.web;
  }

  // ─────────────── 内部 ───────────────

  /// 空标题默认名（对齐 iOS `defaultTitle(for:type:)`）。
  static String defaultTitle(String url, {required PushPlayLinkType type}) {
    final Uri? uri = Uri.tryParse(url);
    switch (type) {
      case PushPlayLinkType.cloud:
        return uri?.host.isNotEmpty ?? false ? '网盘 - ${uri!.host}' : '网盘资源';
      case PushPlayLinkType.direct:
        return '直链视频';
      case PushPlayLinkType.web:
        return uri?.host.isNotEmpty ?? false ? '网页 - ${uri!.host}' : '网页资源';
    }
  }

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
      await prefs.set(itemsKey, PushPlayItem.encodeItems(_items));
    } catch (e) {
      // 落盘失败不阻断 UI（下次变更重试）。
    }
  }
}
