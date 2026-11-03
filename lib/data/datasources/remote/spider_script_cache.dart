/// 数据层：蜘蛛脚本本地缓存（对齐 iOS `RemoteSourceConfigManager` 的 `js_cache`）。
///
/// 唯一真相源：iOS `vbox/Services/RemoteSourceConfigManager.swift`
///   - `downloadAndCacheSpiderJS(baseURL:sites:)`（L464-541）：同步完成后，遍历
///     蜘蛛站点把主脚本 / `ext` 批量下载到 `remote_sources/js_cache/<key>.js`，
///     并清理已不在配置中的过期文件；
///   - `downloadJSFile(key:urlString:)`（L668-691）：内容 > 50 字符且含脚本关键字
///     （`function `/`var `/`let `/`const `/`def `/`import `/`class Spider`）才落盘；
///   - `cachedSpiderJSContent(forKey:)`（L701-707）：运行时 cache-first 读取。
///
/// 端差异（Flutter 侧）：
///   - 落盘目录用 [StoragePaths.spiderDir]（iOS 为 `Documents/remote_sources/js_cache`）；
///   - 下载通道以 [SpiderScriptFetch] 注入（装配层接远程源专用、带 ghfast→gh-proxy→直连
///     代理降级链的 [HttpClient]），与 iOS `fetchData` 同一可达性语义。
///
/// 约束：失败**绝不抛错**——缓存缺失时由调用方回退在线 `loadScriptFromURL`，
/// 与 iOS cache-first → fallback 网络一致。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/storage/storage_paths.dart';
import '../../../domain/entities/spider/site_config.dart';

/// 脚本下载通道：返回脚本文本（UTF-8），失败返回 null（由实现内置代理降级链）。
typedef SpiderScriptFetch = Future<String?> Function(Uri url);

/// 单轮脚本缓存同步报告（供日志与测试断言）。
class SpiderScriptSyncReport {
  /// 构造。
  const SpiderScriptSyncReport({
    this.attempted = 0,
    this.synced = const <String>[],
    this.failed = const <String>[],
    this.cleaned = const <String>[],
  });

  /// 计划下载的条目数（主脚本 + ext）。
  final int attempted;

  /// 落盘成功的缓存 key。
  final List<String> synced;

  /// 失败的缓存 key。
  final List<String> failed;

  /// 清理掉的过期缓存 key。
  final List<String> cleaned;

  /// 是否全部成功（无 failed）。
  bool get ok => failed.isEmpty;
}

/// 蜘蛛脚本本地缓存（对齐 iOS `js_cache`）。
class SpiderScriptCache {
  /// 构造。
  ///
  /// [fetch] 下载通道；未注入时同步空转（不联网），仅保留 [read] 能力。
  /// [dirPath] 缓存目录；缺省 [StoragePaths.spiderDir]。
  /// [logger] 日志出口（缺省 `debugPrint`）。
  SpiderScriptCache({
    SpiderScriptFetch? fetch,
    String Function()? dirPath,
    void Function(String message)? logger,
  })  : _fetch = fetch,
        _dirPath = dirPath,
        _log = logger ?? debugPrint;

  final SpiderScriptFetch? _fetch;
  final String Function()? _dirPath;
  final void Function(String message) _log;

  /// 内容有效下限（对齐 iOS `jsCode.count > 50`）。
  static const int _minLength = 50;

  /// 缓存目录（未注入时取 [StoragePaths.spiderDir]）。
  String get _dir => _dirPath?.call() ?? StoragePaths.spiderDir;

  /// 读取缓存脚本内容（对齐 iOS `cachedSpiderJSContent(forKey:)`）。
  ///
  /// 命中 `<key>.js` 且内容 > [_minLength] 时返回文本，否则 null（调用方回退网络）。
  String? read(String key) {
    final String k = key.trim();
    if (k.isEmpty) return null;
    try {
      final File f = File(_filePath(k));
      if (!f.existsSync()) return null;
      final String code = f.readAsStringSync();
      return code.length > _minLength ? code : null;
    } catch (_) {
      return null;
    }
  }

  /// 是否已缓存该站点脚本。
  bool contains(String key) => read(key) != null;

  /// 批量下载并缓存蜘蛛脚本（对齐 iOS `downloadAndCacheSpiderJS`）。
  ///
  /// [sites] 为**蜘蛛源**站点原始 JSON（对齐 iOS `allSources.spiderSources?.sites`）；
  /// [baseURL] 为 all_sources.json 所在目录（相对脚本路径的 base，可为空串）。
  /// Node 托管源跳过（对齐 iOS `isNodeManagedSite`）。
  Future<SpiderScriptSyncReport> syncSites({
    required List<Map<String, Object?>> sites,
    required String baseURL,
  }) async {
    final SpiderScriptFetch? fetch = _fetch;
    if (fetch == null) return const SpiderScriptSyncReport();

    // ① 收集待下载目标（key / url 对；ext 记为 `<key>_ext`）。
    final List<_ScriptTarget> targets = <_ScriptTarget>[];
    for (final Map<String, Object?> raw in sites) {
      final SiteConfig site = SiteConfig.fromJson(raw);
      if (site.isNodeSite) {
        _log('[RemoteSource] ⏭️ Node 托管蜘蛛跳过缓存: ${site.name} (${site.key})');
        continue;
      }
      final String api = (site.api ?? '').trim();
      if (api.isEmpty) continue;
      final String key = site.key.isEmpty ? site.name : site.key;
      if (key.isEmpty) continue;

      final String? mainUrl = _resolveScriptUrl(api, baseURL);
      if (mainUrl == null) continue;
      targets.add(_ScriptTarget(key, mainUrl));

      final String ext = (site.ext ?? '').trim();
      if (ext.isNotEmpty) {
        final String? extUrl = _resolveExtUrl(ext, baseURL);
        if (extUrl != null) targets.add(_ScriptTarget('${key}_ext', extUrl));
      }
    }

    if (targets.isEmpty) {
      _log('[RemoteSource] 没有需要缓存的 JS 蜘蛛引擎');
      _cleanup(const <String>{});
      return const SpiderScriptSyncReport();
    }

    _log('[RemoteSource] 开始缓存 JS 蜘蛛引擎，站点数: ${sites.length}');
    final List<String> synced = <String>[];
    final List<String> failed = <String>[];
    await Future.wait(<Future<void>>[
      for (final _ScriptTarget t in targets)
        () async {
          final bool ok = await _download(t.key, t.url);
          if (ok) {
            synced.add(t.key);
          } else {
            failed.add(t.key);
          }
        }(),
    ]);

    // ③ 清理过期缓存（不在当前配置中的文件）。
    final List<String> cleaned = _cleanup(synced.toSet());
    _log('[RemoteSource] JS 蜘蛛引擎缓存完成，有效缓存: ${synced.length} 个'
        '${failed.isEmpty ? '' : '，失败: ${failed.length} 个'}');
    return SpiderScriptSyncReport(
      attempted: targets.length,
      synced: synced,
      failed: failed,
      cleaned: cleaned,
    );
  }

  /// 单条下载（对齐 iOS `downloadJSFile`：内容校验 + 原子写入）。
  Future<bool> _download(String key, String urlString) async {
    final Uri? uri = Uri.tryParse(urlString);
    if (uri == null || uri.host.isEmpty) return false;
    try {
      final String? code = await _fetch!(uri);
      if (code == null || code.length <= _minLength || !_looksLikeScript(code)) {
        _log('[RemoteSource] ⚠️ JS 文件内容无效: $key');
        return false;
      }
      final Directory dir = Directory(_dir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final File dest = File(_filePath(key));
      final File tmp = File('${dest.path}.tmp');
      await tmp.writeAsString(code, flush: true);
      await tmp.rename(dest.path);
      _log('[RemoteSource] ✅ JS 缓存成功: $key (${code.length} bytes)');
      return true;
    } catch (e) {
      _log('[RemoteSource] ❌ JS 缓存失败: $key - $e');
      return false;
    }
  }

  /// 清理过期缓存（对齐 iOS `cleanupExpiredJSCache`），返回清理的 key。
  List<String> _cleanup(Set<String> validKeys) {
    final List<String> cleaned = <String>[];
    try {
      final Directory dir = Directory(_dir);
      if (!dir.existsSync()) return cleaned;
      for (final FileSystemEntity e in dir.listSync()) {
        if (e is! File) continue;
        final String name = e.uri.pathSegments.last;
        if (!name.endsWith('.js')) continue;
        final String base = name.substring(0, name.length - 3);
        if (!validKeys.contains(base)) {
          try {
            e.deleteSync();
            cleaned.add(base);
            _log('[RemoteSource] 🗑️ 清理过期 JS 缓存: $base');
          } catch (_) {}
        }
      }
    } catch (_) {}
    return cleaned;
  }

  /// 解析主脚本地址（**逐字对齐 iOS `resolveSpiderURL`**，SpiderManager.swift L1338-L1352）。
  ///
  /// 条件与 iOS 完全一致：`./` 前缀，或「非 http 且以 `.js` / `.py` 结尾」。
  ///
  /// ★ `.py` 必须在此命中（本轮修复）：iOS 端注释明确记录过同一处 bug ——
  ///   「旧实现仅 .js 走缓存，.py 直接跳过导致 py 源不显示」。Flutter 端此前
  ///   仍只认 `.js`，于是裸相对路径的 py 主脚本**永不落盘** → 运行时 cache miss，
  ///   只能回退联网 + 依赖订阅源基址；基址为空（本地/内置源清单）或离线即
  ///   「暂无数据」。这正是「只有后缀 py 的源加载不出分类数据」的直接原因。
  static String? _resolveScriptUrl(String api, String baseURL) {
    final bool isHttp = api.startsWith('http://') || api.startsWith('https://');
    if (api.startsWith('./') ||
        (!isHttp && (api.endsWith('.js') || api.endsWith('.py')))) {
      final String clean = api.startsWith('./') ? api.substring(2) : api;
      if (baseURL.isEmpty) return null;
      return '$baseURL/$clean';
    }
    if (isHttp) return api;
    return null;
  }

  /// 解析 ext 地址（对齐 iOS ext 缓存分支：绝对 URL / `./x.js` / `x.js`）。
  static String? _resolveExtUrl(String ext, String baseURL) {
    if (ext.startsWith('http://') || ext.startsWith('https://')) return ext;
    if (ext.startsWith('./') || ext.endsWith('.js')) {
      final String clean = ext.startsWith('./') ? ext.substring(2) : ext;
      if (baseURL.isEmpty) return null;
      return '$baseURL/$clean';
    }
    return null;
  }

  /// 脚本内容启发式判定（对齐 iOS `downloadJSFile` 的 JS / Python 关键字集合）。
  static bool _looksLikeScript(String code) =>
      code.contains('function ') ||
      code.contains('var ') ||
      code.contains('let ') ||
      code.contains('const ') ||
      code.contains('def ') ||
      code.contains('import ') ||
      code.contains('class Spider');

  /// 缓存文件绝对路径（文件名统一 `<key>.js`，对齐 iOS）。
  String _filePath(String key) {
    final String dir = _dir;
    return dir.endsWith('/') ? '$dir$key.js' : '$dir/$key.js';
  }
}

/// 待下载脚本目标。
class _ScriptTarget {
  const _ScriptTarget(this.key, this.url);

  final String key;
  final String url;
}
