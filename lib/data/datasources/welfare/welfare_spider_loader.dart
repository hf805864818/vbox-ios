/// 数据层：福利专区专用远程 Spider 脚本加载器（批次 H · H-03）。
///
/// 唯一真相源：iOS `vbox/WelfareRemote/WelfareSpiderLoader.swift`
///   · 设计边界（L7-L10）：只服务 `serviceType == welfare_spider`；只允许
///     `sources/welfare-js/` 下的脚本；不注册普通 SpiderManager；
///   · `loadScript(for:)`（L56-L84）：校验 → 生成远程 URL → 代理候选下载
///     → 落盘缓存；
///   · `cachedScript(for:)`（L86-L107）：按 `api` 推导缓存路径读回；
///   · `validate`（L109-L127）：serviceType / scriptType / api / 路径四重校验；
///   · `makeRemoteURL`（L137-L164）：绝对 URL 直用；`sources/` 前缀相对
///     manifest 仓库根；`welfare-js/` 前缀相对 sources 目录；
///   · `fetchData`（L166-L184）+ `proxyCandidateURLs`（L186-L202）：仅
///     GitHub 系域名套 `ghfast.top` / `gh-proxy.com` 降级链；
///   · `cacheURL`（L204-L219）：`Documents/remote_sources/welfare_spider/`
///     `{platformKey 安全化}.{ext}`，扩展名空则默认 `py`。
///
/// 差异登记：
///   · 缓存根目录改用 `StoragePaths.cacheDir/welfare_spider`（语义等价，
///     目录布局对齐 `docs/VBOX_PLAN_v6.35.md` 附录 B）；
///   · 下载失败新增 `fetchFailed` 错误（iOS 抛原始 `URLError`）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../core/network/http_client.dart';
import '../../../core/storage/storage_paths.dart';
import '../../../domain/entities/remote_source/remote_strategy.dart';
import '../../../domain/entities/welfare/welfare.dart';

/// 福利专区专用远程 Spider 脚本加载器。
class WelfareSpiderLoader {
  /// 构造（依赖可注入，便于单测）。
  ///
  /// [cacheRootProvider] 返回缓存**根目录**（Loader 在其下建 `welfare_spider`
  /// 子目录；默认取 `StoragePaths.cacheDir`）。
  /// [manifestUrlProvider] 返回 manifest 地址（用于相对脚本路径解析；
  /// 默认对齐 [RemoteSourceStrategy.defaultManifestUrl]）。
  WelfareSpiderLoader({
    HttpClient? client,
    String Function()? cacheRootProvider,
    String Function()? manifestUrlProvider,
  })  : _client = client ?? HttpClient(),
        _cacheRoot = cacheRootProvider ?? _defaultCacheRoot,
        _manifestUrl = manifestUrlProvider ?? _defaultManifestUrl;

  final HttpClient _client;
  final String Function() _cacheRoot;
  final String Function() _manifestUrl;

  /// 默认缓存根目录（`StoragePaths.cacheDir`；未配置抛 [StateError]）。
  static String _defaultCacheRoot() => StoragePaths.cacheDir;

  /// 默认 manifest 地址（对齐 iOS `RemoteSourceConfigManager.defaultManifestURL`）。
  static String _defaultManifestUrl() => RemoteSourceStrategy.defaultManifestUrl;

  /// 下载并缓存脚本（校验 → URL → 下载 → 落盘）。
  Future<WelfareSpiderScript> loadScript(WelfarePlatform platform) async {
    _validate(platform);

    final String api = platform.api!.trim();
    final Uri? remote = _makeRemoteURL(api);
    if (remote == null) {
      throw WelfareSpiderLoaderError.invalidRemoteURL;
    }

    final Uint8List bytes = await _fetchBytes(remote);
    final String content = utf8.decode(bytes, allowMalformed: true);
    if (content.trim().isEmpty) {
      throw WelfareSpiderLoaderError.emptyScript;
    }

    final String local = await _cacheURL(platform, remote);
    await File(local).writeAsBytes(bytes, flush: true);

    return WelfareSpiderScript(
      platformKey: platform.platformKey,
      remoteURL: remote,
      localURL: local,
      content: content,
      loadedAt: DateTime.now(),
    );
  }

  /// 读取本地缓存脚本（无缓存 / 内容为空返回 `null`）。
  ///
  /// 对齐 iOS `cachedScript(for:)`：**不校验**（缓存读取不做路径合法性复查，
  /// 校验职责在 `loadScript` 下载路径上）。
  WelfareSpiderScript? cachedScript(WelfarePlatform platform) {
    final String? api = platform.api;
    if (api == null) return null;
    final Uri? remote = _makeRemoteURL(api);
    if (remote == null) return null;

    final String local;
    try {
      local = _cacheURLSync(platform, remote);
    } catch (_) {
      return null;
    }

    final File file = File(local);
    if (!file.existsSync()) return null;
    final String content;
    try {
      content = utf8.decode(file.readAsBytesSync(), allowMalformed: true);
    } catch (_) {
      return null;
    }
    if (content.trim().isEmpty) return null;

    return WelfareSpiderScript(
      platformKey: platform.platformKey,
      remoteURL: remote,
      localURL: local,
      content: content,
      loadedAt: file.statSync().modified,
    );
  }

  // ────────────── 校验（对齐 iOS `validate` L109-L127）──────────────

  void _validate(WelfarePlatform platform) {
    if (!WelfareIsolationPolicy.isWelfareSpider(platform)) {
      throw WelfareSpiderLoaderError.invalidServiceType;
    }

    final String? type = platform.scriptType?.trim().toLowerCase();
    if (type != null && type != 'python' && type != 'javascript') {
      throw WelfareSpiderLoaderError.unsupportedScriptType;
    }

    final String api = platform.api?.trim() ?? '';
    if (api.isEmpty) {
      throw WelfareSpiderLoaderError.missingAPI;
    }

    if (!WelfareIsolationPolicy.isAllowedScriptPath(api)) {
      throw WelfareSpiderLoaderError.invalidScriptPath;
    }
  }

  // ────────────── 远程 URL 生成（对齐 iOS `makeRemoteURL` L137-L164）──────────────

  /// 由 `api` 生成远程脚本地址：
  ///   · 绝对 URL（含 scheme）直用；
  ///   · `sources/` 前缀 → 相对 manifest 仓库根（去两个目录段）；
  ///   · `welfare-js/` 前缀 → 相对 manifest 的 sources 目录（去一个目录段）。
  Uri? _makeRemoteURL(String api) {
    final String trimmed = api.trim();
    final Uri? absolute = Uri.tryParse(trimmed);
    if (absolute != null && absolute.scheme.isNotEmpty) return absolute;

    final Uri? manifest = Uri.tryParse(_manifestUrl());
    if (manifest == null) return null;

    final String normalized = trimmed
        .replaceAll('\\', '/')
        .replaceAll('./', '');

    if (normalized.startsWith('sources/')) {
      // 相对 manifest 仓库根：去两级（`…/api/sources/` → `…/api/` → `…/`）。
      final String sourcesDir = _dirOf(manifest);
      final String withoutTrailingSlash = sourcesDir.endsWith('/')
          ? sourcesDir.substring(0, sourcesDir.length - 1)
          : sourcesDir;
      final String repoRoot = _dirOf(Uri.parse(withoutTrailingSlash));
      return Uri.tryParse(_resolveRelative(repoRoot, normalized));
    }
    if (normalized.startsWith('welfare-js/')) {
      final String sourcesRoot = _dirOf(manifest);
      return Uri.tryParse(_resolveRelative(sourcesRoot, normalized));
    }
    return null;
  }

  /// manifest 所在目录（含尾斜杠）：`https://h/api/sources/manifest.json` →
  /// `https://h/api/sources/`（对齐 iOS `deletingLastPathComponent()` 目录语义）。
  static String _dirOf(Uri uri) {
    final String s = uri.toString();
    final int idx = s.lastIndexOf('/');
    return idx <= 0 ? s : s.substring(0, idx + 1);
  }

  /// 相对路径拼接到目录 base（base 保证尾斜杠，对齐 iOS `URL(relativeTo:)`）。
  static String _resolveRelative(String base, String relative) {
    final String b = base.endsWith('/') ? base : '$base/';
    return '$b$relative';
  }

  // ────────────── 下载（对齐 iOS `fetchData` + `proxyCandidateURLs`）──────────────

  Future<Uint8List> _fetchBytes(Uri remote) async {
    for (final Uri candidate in _proxyCandidates(remote)) {
      try {
        final HttpClientResponse resp = await _client.get(candidate);
        if (resp.isOk) return resp.rawBytes;
      } catch (_) {
        // 继续尝试下一个候选地址。
      }
    }
    throw WelfareSpiderLoaderError.fetchFailed;
  }

  /// 代理候选链（对齐 iOS `proxyCandidateURLs`）：仅 GitHub 系域名
  /// （`github.io` / `githubusercontent.com` **包含匹配**）套代理，其余直连。
  List<Uri> _proxyCandidates(Uri url) {
    final String host = url.host;
    if (!host.contains('github.io') && !host.contains('githubusercontent.com')) {
      return <Uri>[url];
    }
    final String original = url.toString();
    return <Uri>[
      Uri.parse('https://ghfast.top/$original'),
      Uri.parse('https://gh-proxy.com/$original'),
      // 2026-10 实测：ghfast / gh-proxy 已不再代理 *.github.io（403/404），
      // 追加 ghproxy.link（对 github.io 仍可用），与 RemoteSourceStrategy 对齐。
      Uri.parse('https://ghproxy.link/$original'),
      url,
    ];
  }

  // ────────────── 缓存路径（对齐 iOS `cacheURL` L204-L219）──────────────

  /// 缓存文件绝对路径（创建目录后返回）。
  Future<String> _cacheURL(WelfarePlatform platform, Uri remote) async {
    final String dir = p.join(_cacheRoot(), 'welfare_spider');
    await Directory(dir).create(recursive: true);
    return p.join(dir, _cacheFileName(platform, remote));
  }

  /// 同步版缓存路径（`cachedScript` 读取用；目录缺失时创建）。
  String _cacheURLSync(WelfarePlatform platform, Uri remote) {
    final String dir = p.join(_cacheRoot(), 'welfare_spider');
    Directory(dir).createSync(recursive: true);
    return p.join(dir, _cacheFileName(platform, remote));
  }

  String _cacheFileName(WelfarePlatform platform, Uri remote) {
    // `p.extension` 返回带点扩展名（如 `.py`），统一剥离点后再拼接。
    String ext = p.extension(remote.path);
    if (ext.isEmpty) ext = 'py';
    if (ext.startsWith('.')) ext = ext.substring(1);
    final String safeKey = platform.platformKey
        .replaceAll('/', '_')
        .replaceAll(':', '_');
    return '$safeKey.$ext';
  }
}
