/// 数据层：lx-music 桥接插件远程缓存（ND-03 · 对齐 iOS P1-A6）。
///
/// 唯一真相源：iOS `vbox/Services/RemoteSourceConfigManager.swift`
///   - `downloadAndCacheLXPlugins(sites:baseURL:)`（L553-589）：过滤
///     `engineType == "lxMusic"` 的站点，按 `pluginPath` 并发同步插件；
///   - `syncLXPlugin(key:site:pluginPath:base:dir:)`（L591-646）：文件名取
///     `pluginPath` 末段（须 `.js`）→ version 标记一致跳过 → 相对 `baseURL`
///     （或绝对 URL）下载 → 内容 > 100 字节 → `md5` 下发则强校验 →
///     原子写入 + 写 version 标记；失败仅记日志、保留旧版。
///
/// 约束（对齐 iOS）：失败**绝不抛错**、绝不阻塞远程源同步主链路 —— lx 插件
/// 不可用时由 Node 侧 lx-bridge 温和降级，不影响视频 / 网盘 / kstore 音乐源。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

/// 插件下载通道（测试注入；生产由装配层接远程源专用 [HttpClient] 通道，
/// 与 iOS `fetchData` 同一放宽 TLS 语义）。
typedef LxPluginFetch = Future<List<int>> Function(Uri url);

/// 单个 lx 插件同步结果。
enum LxPluginSyncState {
  /// 下载并写入成功。
  synced,

  /// version 标记一致，已是最新（未发起下载）。
  skipped,

  /// 同步失败（内容过短 / md5 不匹配 / 下载异常 / 路径异常）。
  failed,
}

/// 一轮同步报告（供日志与测试断言）。
class LxPluginSyncReport {
  const LxPluginSyncReport({
    this.lxSiteCount = 0,
    this.synced = const <String>[],
    this.skipped = const <String>[],
    this.failed = const <String>[],
  });

  /// `engineType == "lxMusic"` 且 `pluginPath` 非空的站点数。
  final int lxSiteCount;

  /// 同步成功的站点 key（对齐 iOS `synced` 汇总日志）。
  final List<String> synced;

  /// 版本一致跳过的站点 key。
  final List<String> skipped;

  /// 失败的站点 key。
  final List<String> failed;

  /// 是否全部成功（无 failed）。
  bool get ok => failed.isEmpty;
}

/// lx-music 桥接插件同步器。
class LxPluginSyncer {
  /// 构造。
  ///
  /// [fetch] 下载通道；未注入时同步直接空转（不联网）。
  /// [pluginsDirPath] lx 插件目录（装配层接 `NodeRuntimeManager.instance.
  /// lxPluginsDirPath`，即 `<runtimeDir>/plugins/lx`）；未注入时视为运行环境
  /// 未就绪，同步空转。
  /// [logger] 日志出口（缺省 `debugPrint`）。
  LxPluginSyncer({
    LxPluginFetch? fetch,
    String? Function()? pluginsDirPath,
    void Function(String message)? logger,
  })  : _fetch = fetch,
        _pluginsDirPath = pluginsDirPath,
        _log = logger ?? debugPrint;

  final LxPluginFetch? _fetch;
  final String? Function()? _pluginsDirPath;
  final void Function(String message) _log;

  /// 同步所有 lx 插件（对齐 iOS `downloadAndCacheLXPlugins`）。
  ///
  /// [sites] 传 6 合 1 聚合站点（api + spider 均可，lx 站点按
  /// `engineType == "lxMusic"` 过滤；api 站点无该 engineType，语义与 iOS
  /// 只传 spiderSites 等价）；[baseURL] 为 all_sources.json 同目录
  /// （对齐 iOS `deletingLastPathComponent`，可为空串表示相对路径不可用）。
  Future<LxPluginSyncReport> syncSites({
    required List<Map<String, Object?>> sites,
    required String baseURL,
  }) async {
    final LxPluginFetch? fetch = _fetch;
    final String? dirPath = _pluginsDirPath?.call();
    if (fetch == null || dirPath == null || dirPath.isEmpty) {
      return const LxPluginSyncReport();
    }

    final List<Map<String, Object?>> lxSites = sites
        .where((Map<String, Object?> j) =>
            (j['engineType'] ?? '').toString() == 'lxMusic' &&
            (j['pluginPath'] ?? '').toString().isNotEmpty)
        .toList(growable: false);
    if (lxSites.isEmpty) {
      _log('[RemoteSource] 无 lx-music 插件站点，跳过插件缓存');
      return const LxPluginSyncReport();
    }

    final Directory dir = Directory(dirPath);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    _log('[RemoteSource] 开始缓存 lx-music 插件，站点数: ${lxSites.length}');
    final List<String> synced = <String>[];
    final List<String> skipped = <String>[];
    final List<String> failed = <String>[];

    await Future.wait(<Future<void>>[
      for (final Map<String, Object?> site in lxSites)
        () async {
          final String key = (site['key'] ?? '').toString().isNotEmpty
              ? (site['key'] ?? '').toString()
              : (site['name'] ?? '').toString();
          final LxPluginSyncState state = await _syncOne(
            site: site,
            baseURL: baseURL,
            dir: dir,
          );
          switch (state) {
            case LxPluginSyncState.synced:
              synced.add(key);
            case LxPluginSyncState.skipped:
              skipped.add(key);
            case LxPluginSyncState.failed:
              failed.add(key);
          }
        }(),
    ]);

    _log('[RemoteSource] lx 插件缓存完成，同步: '
        '${synced.isEmpty ? "无" : synced.join(", ")}');
    return LxPluginSyncReport(
      lxSiteCount: lxSites.length,
      synced: synced,
      skipped: skipped,
      failed: failed,
    );
  }

  /// 同步单个插件（对齐 iOS `syncLXPlugin` 全语义，失败返回
  /// [LxPluginSyncState.failed] 而不抛错）。
  Future<LxPluginSyncState> _syncOne({
    required Map<String, Object?> site,
    required String baseURL,
    required Directory dir,
  }) async {
    final String pluginPath = (site['pluginPath'] ?? '').toString();
    final String version = (site['version'] ?? '').toString();
    final String expectedMd5 = (site['md5'] ?? '').toString();

    // 文件名取 pluginPath 末段（daxe.js / nianxin.js，对应 lx-bridge 插件 key）。
    final Uri? parsed = Uri.tryParse(pluginPath);
    final String fileName = (parsed != null && parsed.pathSegments.isNotEmpty)
        ? parsed.pathSegments.last
        : pluginPath.split('/').last;
    if (!fileName.endsWith('.js')) {
      _log('[RemoteSource] ⚠️ lx 插件路径异常，跳过: $pluginPath');
      return LxPluginSyncState.failed;
    }

    final File dest = File(_join(dir.path, fileName));
    final File versionFile = File(_join(dir.path, '$fileName.version'));

    // 版本标记一致 → 已是最新，跳过下载。
    if (version.isNotEmpty && versionFile.existsSync()) {
      final String cachedv =
          versionFile.readAsStringSync().trim();
      if (cachedv == version) {
        _log('[RemoteSource] ⏭️ lx 插件版本一致，跳过: $fileName (v$version)');
        return LxPluginSyncState.skipped;
      }
    }

    // 解析下载 URL：绝对 http(s) 直接用；否则相对 baseURL（对齐 iOS
    // appendingPathComponent + 去 "./" 前缀）。
    final Uri? url;
    if (pluginPath.startsWith('http://') ||
        pluginPath.startsWith('https://')) {
      url = Uri.tryParse(pluginPath);
    } else {
      final String clean = pluginPath.startsWith('./')
          ? pluginPath.substring(2)
          : pluginPath;
      url = baseURL.isEmpty
          ? null
          : Uri.tryParse('$baseURL/$clean');
    }
    if (url == null) return LxPluginSyncState.failed;

    try {
      final List<int> data = await _fetch!(url);
      if (data.length <= 100) {
        _log('[RemoteSource] ⚠️ lx 插件内容过短，丢弃: $fileName');
        return LxPluginSyncState.failed;
      }
      // md5 完整性校验（清单下发则强校验；未下发不强校验）。
      if (expectedMd5.isNotEmpty) {
        final String actual = crypto.md5.convert(data).toString();
        if (actual.toLowerCase() != expectedMd5.toLowerCase()) {
          _log('[RemoteSource] ❌ lx 插件 md5 不匹配，丢弃: $fileName '
              '期望=$expectedMd5 实际=$actual');
          return LxPluginSyncState.failed;
        }
      }
      // 原子写入（临时文件 + rename；失败保留旧版）。
      final File tmp = File('${dest.path}.tmp');
      await tmp.writeAsBytes(data, flush: true);
      await tmp.rename(dest.path);
      if (version.isNotEmpty) {
        await versionFile.writeAsString(version, flush: true);
      }
      _log('[RemoteSource] ✅ lx 插件已同步: $fileName '
          '(${data.length} 字节${version.isNotEmpty ? ", v$version" : ""})');
      return LxPluginSyncState.synced;
    } catch (e) {
      _log('[RemoteSource] ⚠️ lx 插件下载失败，保留旧版: $fileName: $e');
      return LxPluginSyncState.failed;
    }
  }

  /// POSIX 拼接（目录路径 + 文件名；文件名已过滤无分隔符风险）。
  static String _join(String dir, String name) =>
      dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  /// 供测试读取落盘结果（utf8 文本视图）。
  static String readText(File f) => utf8.decode(f.readAsBytesSync());
}
