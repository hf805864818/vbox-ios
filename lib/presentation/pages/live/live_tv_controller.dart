/// 直播状态控制器（对齐 iOS `LiveTVService`（ObservableObject 单例））。
///
/// 职责：直播源/自定义源/本地频道持久化 + 订阅源内容拉取与解析 + 动态分类 +
/// 频道按分组合并多线路。状态经 [ChangeNotifier] 广播，供直播页 / 源选择器 /
/// 播放 sheet 订阅。
///
/// 纯解析逻辑见 [LiveTvParser]（domain，无 IO）；本控制器只负责 IO + 状态编排。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/network/http_client.dart';
import '../../../core/utils/logger.dart';
import '../../../data/datasources/local/prefs_manager.dart';
import '../../../domain/entities/live/live.dart';

/// 直播控制器。
class LiveTvController extends ChangeNotifier {
  /// 构造（[client] 便于单测注入）。
  LiveTvController({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;
  final PrefsManager _prefs = PrefsManager.instance;

  static const String _currentSourceKey = 'live_tv_current_source';
  static const String _customSourcesKey = 'live_tv_custom_sources';
  static const String _localChannelsKey = 'live_tv_local_channels';

  LiveSourceType _currentSource = LiveSourceType.defaultM3U;
  final List<LiveSourceType> _customSources = <LiveSourceType>[];
  List<SubscribeChannel> _subscribeChannels = <SubscribeChannel>[];
  List<LiveCategory> _categories = <LiveCategory>[];
  final Map<String, List<SubscribeChannel>> _localChannelsMap =
      <String, List<SubscribeChannel>>{};
  String? _lastError;
  bool _initialized = false;

  // ──────────────────────────── 状态 ────────────────────────────

  LiveSourceType get currentSource => _currentSource;

  List<LiveSourceType> get customSources => List.unmodifiable(_customSources);

  List<SubscribeChannel> get subscribeChannels =>
      List.unmodifiable(_subscribeChannels);

  List<LiveCategory> get categories => List.unmodifiable(_categories);

  Map<String, List<SubscribeChannel>> get localChannelsMap =>
      Map.unmodifiable(_localChannelsMap);

  /// 所有可用源（默认2 + 自定义）。
  List<LiveSourceType> get availableSources => <LiveSourceType>[
        LiveSourceType.defaultM3U,
        LiveSourceType.defaultIptv2,
        ..._customSources,
      ];

  /// 最近一次拉取错误（供页面展示空态/重试）。
  String? get lastError => _lastError;

  bool get isInitialized => _initialized;

  // ──────────────────────────── 初始化 ────────────────────────────

  /// 启动时加载持久化状态（App 启动调用一次）。
  Future<void> init() async {
    await _loadCustomSources();
    await _loadLocalChannels();
    await _loadCurrentSource();
    _initialized = true;
    notifyListeners();
  }

  /// 首次进入页面时确保已拉取订阅源（对齐 iOS `onAppear`）。
  Future<void> ensureLoaded() async {
    if (_categories.isNotEmpty || _subscribeChannels.isNotEmpty) return;
    final String? url = _currentSource.sourceURL;
    if (url == null) return;
    if (url.startsWith('local://')) {
      final String localName = url.substring('local://'.length);
      _subscribeChannels = List<SubscribeChannel>.of(
        _localChannelsMap[localName] ?? const <SubscribeChannel>[],
      );
      _categories = LiveTvParser.buildCategories(_subscribeChannels);
      notifyListeners();
    } else {
      await fetchSubscribeChannels(url);
    }
  }

  // ──────────────────────────── 源管理 ────────────────────────────

  /// 切换直播源。
  Future<void> switchSource(LiveSourceType source) async {
    _currentSource = source;
    _subscribeChannels = <SubscribeChannel>[];
    _categories = <LiveCategory>[];
    _lastError = null;
    await _saveCurrentSource();
    notifyListeners();

    final String? url = source.sourceURL;
    if (url == null) return;
    if (url.startsWith('local://')) {
      final String localName = url.substring('local://'.length);
      _subscribeChannels = List<SubscribeChannel>.of(
        _localChannelsMap[localName] ?? const <SubscribeChannel>[],
      );
      _categories = LiveTvParser.buildCategories(_subscribeChannels);
      notifyListeners();
    } else {
      await fetchSubscribeChannels(url);
    }
  }

  /// 添加自定义源。
  Future<void> addCustomSource(String name, String url) async {
    _customSources.add(LiveSourceType(
      kind: LiveSourceKind.custom,
      name: name,
      url: url,
    ));
    await _saveCustomSources();
    notifyListeners();
  }

  /// 删除自定义源（按下标）。
  Future<void> removeCustomSourceAt(int index) async {
    if (index < 0 || index >= _customSources.length) return;
    final LiveSourceType removed = _customSources.removeAt(index);
    await _saveCustomSources();
    if (removed.id == _currentSource.id) {
      _currentSource = LiveSourceType.defaultM3U;
      await _saveCurrentSource();
    }
    notifyListeners();
  }

  // ──────────────────────────── 本地导入 ────────────────────────────

  /// 添加本地导入频道（并自动登记为 `local://` 自定义源，去重）。
  Future<void> addLocalChannels(
    String name,
    List<SubscribeChannel> channels,
  ) async {
    _localChannelsMap[name] = channels;
    await _saveLocalChannels();
    final String localUrl = 'local://$name';
    final bool exists =
        _customSources.any((LiveSourceType s) => s.id == 'custom_${name}_$localUrl');
    if (!exists) {
      _customSources.add(LiveSourceType(
        kind: LiveSourceKind.custom,
        name: name,
        url: localUrl,
      ));
      await _saveCustomSources();
    }
    notifyListeners();
  }

  // ──────────────────────────── 频道 / 解析 ────────────────────────────

  /// 从 URL 拉取并解析订阅源（M3U/TXT 自动判定）。
  Future<void> fetchSubscribeChannels(String url) async {
    try {
      final HttpClientResponse resp = await _client.get(Uri.parse(url));
      if (!resp.isOk) {
        _lastError = '订阅源返回 HTTP ${resp.statusCode}';
        notifyListeners();
        return;
      }
      final String content = resp.text;
      final String trimmed = content.trim();
      final List<SubscribeChannel> parsed = trimmed.startsWith('#EXTM3U')
          ? LiveTvParser.parseM3U(content)
          : LiveTvParser.parseTXT(content);
      _subscribeChannels = parsed;
      _categories = LiveTvParser.buildCategories(parsed);
      _lastError = null;
      notifyListeners();
    } catch (e) {
      AppLog.warn('live_tv', '订阅源获取失败: $url', error: e);
      _lastError = '获取订阅源失败：$e';
      notifyListeners();
    }
  }

  /// 指定分组的频道（同组同名合并多线路）。
  List<LiveChannel> channelsForGroup(String groupName) =>
      LiveTvParser.channelsForGroup(_subscribeChannels, groupName);

  /// 拉取源内容（导出在线源复用）。
  Future<String?> fetchRawContent(String url) async {
    try {
      final HttpClientResponse resp = await _client.get(Uri.parse(url));
      if (!resp.isOk) return null;
      return resp.text;
    } catch (e) {
      AppLog.warn('live_tv', '拉取源内容失败: $url', error: e);
      return null;
    }
  }

  /// 将频道列表导出为 M3U 文本。
  String exportM3U(List<SubscribeChannel> channels) {
    final StringBuffer buf = StringBuffer('#EXTM3U\n');
    for (final SubscribeChannel ch in channels) {
      final String groupTag = ch.group != null ? ' group-title="${ch.group}"' : '';
      final String logoTag = ch.logo != null ? ' tvg-logo="${ch.logo}"' : '';
      buf.write('#EXTINF:-1$groupTag$logoTag,${ch.name}\n');
      buf.write('${ch.url}\n');
    }
    return buf.toString();
  }

  // ──────────────────────────── 持久化 ────────────────────────────

  Future<void> _loadCustomSources() async {
    final String raw = await _prefs.getString(_customSourcesKey);
    if (raw.isEmpty) return;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _customSources
        ..clear()
        ..addAll(decoded
            .whereType<Map>()
            .map((dynamic e) => LiveSourceType.fromDictionary(_stringMap(e)))
            .whereType<LiveSourceType>());
    } on FormatException {
      // 契约外脏数据，忽略。
    }
  }

  Future<void> _saveCustomSources() async {
    await _prefs.set(
      _customSourcesKey,
      jsonEncode(_customSources.map((e) => e.toDictionary()).toList()),
    );
  }

  Future<void> _loadCurrentSource() async {
    final String raw = await _prefs.getString(_currentSourceKey);
    if (raw.isEmpty) return;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final LiveSourceType? source =
          LiveSourceType.fromDictionary(_stringMap(decoded));
      if (source != null) _currentSource = source;
    } on FormatException {
      // 契约外脏数据，保持默认源。
    }
  }

  Future<void> _saveCurrentSource() async {
    await _prefs.set(_currentSourceKey, jsonEncode(_currentSource.toDictionary()));
  }

  Future<void> _loadLocalChannels() async {
    final String raw = await _prefs.getString(_localChannelsKey);
    if (raw.isEmpty) return;
    try {
      final Object? decoded = jsonDecode(raw);
      // 契约 defaultValue 为 '[]'（数组）；iOS 实际存 object，两者都兼容。
      if (decoded is! Map) return;
      decoded.forEach((dynamic key, dynamic value) {
        if (value is! List) return;
        _localChannelsMap[key.toString()] = value
            .whereType<Map>()
            .map((dynamic e) => SubscribeChannel.fromJson(_stringMap(e)))
            .where((SubscribeChannel c) => c.url.isNotEmpty)
            .toList(growable: false);
      });
    } on FormatException {
      // 忽略脏数据。
    }
  }

  Future<void> _saveLocalChannels() async {
    final Map<String, dynamic> out = <String, dynamic>{};
    _localChannelsMap.forEach((String name, List<SubscribeChannel> channels) {
      out[name] = channels.map((SubscribeChannel c) => c.toJson()).toList();
    });
    await _prefs.set(_localChannelsKey, jsonEncode(out));
  }

  static Map<String, String> _stringMap(Map<dynamic, dynamic> m) =>
      m.map((dynamic k, dynamic v) =>
          MapEntry<String, String>(k.toString(), v?.toString() ?? ''));
}