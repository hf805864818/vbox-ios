/// 平台层：自更新器（批次 K · K-更1）。
///
/// 唯一真相源：
/// - iOS `vbox/Services/UpdateManager.swift`（检查 GitHub Releases → 版本清洗比较
///   → 三级代理降级链下载 → 分平台安装）
/// - 主方案 §S.3（自动更新设计）/ §S.4（Android 自更新）/ §S.7（版本分发渠道）
/// - 领域模型 [UpdateManifest]（本仓库 `lib/domain/entities/update/update_manifest.dart`）
///
/// 职责（对齐 iOS）：
/// 1. `check`：拉取 GitHub Releases `?per_page=1` → 归一为 [UpdateManifest] →
///    与 [AppInfo.version] 数值化比较；5 分钟内非强制检查走内存缓存短路。
/// 2. `download`：按 [RemoteSourceStrategy] 三级降级链（主代理 → 备用代理 → 直连）
///    流式下载当前平台资产 → 可选 SHA-256 校验；进度经 [ChangeNotifier] 广播。
/// 3. `install`：Android 走 [UpdateInstallBridge]（应用内安装器 + 未知来源授权引导）；
///    桌面端交给系统默认程序打开安装包，失败回退发布页。
///
/// 设计：`http.Client` / [UpdateInstallBridge] / 目录提供者 / 平台 / 本地版本全部可注入，
/// 单测不依赖真实网络、文件系统插件或原生通道。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/logger.dart';
import '../../domain/entities/remote_source/remote_strategy.dart';
import '../../domain/entities/update/update_manifest.dart';
import 'update_install_bridge.dart';

/// 更新包落盘目录提供者（默认走 `path_provider`；单测注入临时目录）。
typedef UpdateDirectoryProvider = Future<Directory> Function();

/// 下载被取消（内部信号，不外泄）。
class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}

/// 自更新器（[ChangeNotifier]；设置页 / 更新弹窗监听其状态）。
class Updater extends ChangeNotifier {
  /// 构造（依赖全可注入，便于单测）。
  Updater({
    http.Client? client,
    UpdateInstallBridge? bridge,
    this.repoOwner = defaultRepoOwner,
    this.repoName = defaultRepoName,
    this.localVersion = AppInfo.version,
    UpdatePlatform? platformOverride,
    bool? androidOverride,
    UpdateDirectoryProvider? directoryProvider,
  })  : _client = client ?? http.Client(),
        _bridge = bridge ?? MethodChannelUpdateInstallBridge(),
        _platformOverride = platformOverride,
        _isAndroid = androidOverride ?? Platform.isAndroid,
        _directoryProvider = directoryProvider ?? _defaultUpdateDir;

  /// 全局单例（设置页 / 弹窗共用同一状态）。
  static final Updater instance = Updater();

  /// 分发仓库属主（对齐 iOS `UpdateManager.repoOwner`）。
  static const String defaultRepoOwner = 'vbox-Ai';

  /// 分发仓库名（对齐 iOS `UpdateManager.repoName`）。
  static const String defaultRepoName = 'app';

  /// 日志标签。
  static const String logTag = 'update';

  /// 更新包目录名（落在应用支持目录下；Android FileProvider 白名单需一致）。
  static const String updateDirName = 'updates';

  /// 非强制检查的最小间隔（对齐 iOS `checkInterval = 300s`）。
  static const Duration checkInterval = Duration(minutes: 5);

  final http.Client _client;
  final UpdateInstallBridge _bridge;

  /// 分发仓库属主。
  final String repoOwner;

  /// 分发仓库名。
  final String repoName;

  /// 本地版本（默认 [AppInfo.version]；单测注入）。
  final String localVersion;

  final UpdatePlatform? _platformOverride;
  final bool _isAndroid;
  final UpdateDirectoryProvider _directoryProvider;

  // ─────────────── 检查状态（对齐 iOS @Published）───────────────
  bool _isChecking = false;
  bool _hasUpdate = false;
  String _latestVersion = '';
  int _latestBuild = 0;
  String? _downloadUrl;
  String? _releasePageUrl;
  List<String> _releaseNotes = const <String>[];
  String? _updateError;

  // ─────────────── 下载 / 安装状态 ───────────────
  bool _isDownloading = false;
  double _downloadProgress = 0;
  String? _downloadedPath;
  String? _downloadError;
  String? _installMessage;

  /// 是否已缩小为悬浮气泡（对齐 iOS `isMinimized`）。
  bool _isMinimized = false;

  UpdatePlatform? _platform;
  UpdateAsset? _asset;

  DateTime? _lastCheckAt;
  int _downloadToken = 0;
  bool _disposed = false;

  // ─────────────── 只读状态 ───────────────

  /// 是否正在检查。
  bool get isChecking => _isChecking;

  /// 是否有可用更新。
  bool get hasUpdate => _hasUpdate;

  /// 最新版本号（已清洗）。
  String get latestVersion => _latestVersion;

  /// 最新构建号（0 = 未知）。
  int get latestBuild => _latestBuild;

  /// 当前平台安装包下载地址（无则 null）。
  String? get downloadUrl => _downloadUrl;

  /// 分享用的下载地址（对齐 iOS `UpdateManager.shareURL`）。
  ///
  /// 与下载相同的代理顺序：主代理前缀 + 原始地址；未检查出下载地址时回退到
  /// GitHub Releases 最新 IPA 直链。分享出去后对方可快速下载安装。
  String get shareUrl {
    final String fallback =
        'https://github.com/$repoOwner/$repoName/releases/latest/download/vbox.ipa';
    final String raw = _downloadUrl ?? fallback;
    const List<ProxyHost> proxies = RemoteSourceStrategy.proxyHosts;
    if (proxies.isNotEmpty) {
      return '${proxies.first.host}/$raw';
    }
    return raw;
  }

  /// Release 页面地址（浏览器兜底）。
  String? get releasePageUrl => _releasePageUrl;

  /// 更新说明条目（已拆条去前缀）。
  List<String> get releaseNotes => _releaseNotes;

  /// 检查失败信息。
  String? get updateError => _updateError;

  /// 下载进度 0.0 ~ 1.0。
  double get downloadProgress => _downloadProgress;

  /// 是否正在下载。
  bool get isDownloading => _isDownloading;

  /// 已下载安装包路径（null = 未完成）。
  String? get downloadedPath => _downloadedPath;

  /// 是否已有可安装的安装包。
  bool get hasDownloaded => _downloadedPath != null;

  /// 下载失败信息。
  String? get downloadError => _downloadError;

  /// 安装引导信息（如「未知来源」授权提示；null = 无）。
  String? get installMessage => _installMessage;

  /// 是否已缩小为悬浮气泡。
  bool get isMinimized => _isMinimized;

  /// 当前检查命中的平台（null = 非三端 / 未检查）。
  UpdatePlatform? get platform => _platform;

  // ─────────────── 检查更新 ───────────────

  /// 检查更新（[force] = true 跳过 5 分钟内存缓存）。
  Future<void> check({bool force = false}) async {
    if (!force &&
        _lastCheckAt != null &&
        DateTime.now().difference(_lastCheckAt!) < checkInterval) {
      AppLog.debug(logTag, '距上次检查不足 5 分钟，跳过');
      return;
    }
    _lastCheckAt = DateTime.now();
    _isChecking = true;
    _updateError = null;
    _emit();

    try {
      final UpdateManifest? manifest = await _fetchManifest();
      if (manifest == null) {
        _updateError = '检查更新失败：未获取到版本信息';
      } else {
        _latestVersion = manifest.version;
        _latestBuild = manifest.build;
        _releaseNotes = manifest.notes;
        _releasePageUrl = manifest.releasePageUrl;
        _platform = _platformOverride ?? UpdatePlatform.current();
        _asset = _platform == null ? null : manifest.assetFor(_platform!);
        _downloadUrl = _asset?.url;
        _hasUpdate = manifest.isNewerThan(localVersion);
        if (_hasUpdate && _asset == null) {
          _updateError = '发现新版本，但当前平台暂无可用安装包';
        }
        AppLog.info(
          logTag,
          '检查完成：本地 $localVersion，远程 ${manifest.version}，'
          'hasUpdate=$_hasUpdate',
        );
      }
    } catch (e) {
      _updateError = '检查更新失败：$e';
      AppLog.warn(logTag, '检查更新异常', error: e);
    }

    _isChecking = false;
    _emit();
  }

  /// 拉取 GitHub Releases 最新一条并归一为 [UpdateManifest]。
  Future<UpdateManifest?> _fetchManifest() async {
    final Uri uri = Uri.parse(
      'https://api.github.com/repos/$repoOwner/$repoName/releases?per_page=1',
    );
    final http.Response res = await _client.get(uri, headers: <String, String>{
      'user-agent': 'Mozilla/5.0',
      'accept': 'application/vnd.github+json',
    }).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode}');
    }
    final Object? decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is List && decoded.isNotEmpty) {
      return UpdateManifest.fromGitHubRelease(decoded.first);
    }
    return null;
  }

  // ─────────────── 下载安装包 ───────────────

  /// 下载当前平台安装包（三级代理降级链 + 可选 SHA-256 校验）。
  Future<void> download() async {
    final UpdateAsset? asset = _asset;
    final String url = asset?.url ?? '';
    if (url.isEmpty) {
      _downloadError = '下载链接无效';
      _emit();
      return;
    }

    _isDownloading = true;
    _downloadProgress = 0;
    _downloadError = null;
    _downloadedPath = null;
    _installMessage = null;
    _emit();

    final int token = ++_downloadToken;
    final Directory dir = await _directoryProvider();
    final File dest = File(p.join(dir.path, 'vbox_update${_extensionFor(_platform)}'));
    final List<String> candidates = RemoteSourceStrategy.candidates(url);
    AppLog.info(logTag, '下载地址 ${candidates.length} 个（主代理 → 备用代理 → 直连）');

    for (final String candidate in candidates) {
      if (token != _downloadToken) return;
      try {
        await _downloadTo(Uri.parse(candidate), dest, token);
        final String expected = asset?.sha256 ?? '';
        if (expected.isNotEmpty) {
          final String actual = await _sha256File(dest);
          if (actual != expected) {
            // 坏包清除（含 .part）：避免下次「续传坏块」循环失败。
            if (await dest.exists()) await dest.delete();
            final File part = File('${dest.path}.part');
            if (await part.exists()) await part.delete();
            throw StateError('安装包 SHA-256 校验失败');
          }
        }
        _downloadProgress = 1;
        _downloadedPath = dest.path;
        _isDownloading = false;
        _emit();
        AppLog.info(logTag, '安装包下载完成：${dest.path}');
        return;
      } catch (e) {
        if (token != _downloadToken) return;
        AppLog.warn(logTag, '下载源失败：$candidate', error: e);
      }
    }

    _downloadError = '所有下载源均失败，请检查网络';
    _isDownloading = false;
    _emit();
  }

  /// 流式下载单个候选地址到 [dest]，逐块更新进度。
  ///
  /// 断点续传（本轮对齐 iOS `URLSession` 下载语义的补齐）：写入走
  /// `<dest>.part` 中转，完成后原子重命名；续传时若 `.part` 已存在则携带
  /// `Range: bytes=<len>-` 请求，响应 `206` 追加剩余字节，`200`（服务端
  /// 不支持 Range / 资源已变）则全量重写。SHA-256 校验失败清空 `.part`
  /// （防坏块循环续传）。
  Future<void> _downloadTo(Uri uri, File dest, int token) async {
    final File part = File('${dest.path}.part');
    final int resumeFrom = part.existsSync() ? part.lengthSync() : 0;

    final http.Request req = http.Request('GET', uri)
      ..headers['user-agent'] = 'Mozilla/5.0';
    if (resumeFrom > 0) {
      req.headers['range'] = 'bytes=$resumeFrom-';
    }
    final http.StreamedResponse res =
        await _client.send(req).timeout(const Duration(seconds: 30));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HttpException('HTTP ${res.statusCode}');
    }
    final bool appending =
        resumeFrom > 0 && res.statusCode == HttpStatus.partialContent;
    final int total = (res.contentLength ?? 0) + (appending ? resumeFrom : 0);
    final IOSink sink = part.openWrite(mode: appending ? FileMode.append : FileMode.write);
    int received = appending ? resumeFrom : 0;
    try {
      await for (final List<int> chunk in res.stream) {
        if (token != _downloadToken) {
          throw const _DownloadCancelled();
        }
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          _downloadProgress = received / total;
          _emit();
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    // 完成即原子替换（校验失败由调用侧清 .part，不影响下次续传重下）。
    if (dest.existsSync()) await dest.delete();
    await part.rename(dest.path);
  }

  /// 取消下载（对齐 iOS `cancelDownload`）。
  void cancelDownload() {
    _downloadToken++;
    _isDownloading = false;
    _downloadProgress = 0;
    _emit();
    AppLog.info(logTag, '用户取消下载');
  }

  // ─────────────── 安装 ───────────────

  /// 安装已下载的安装包，返回 [UpdateInstallStatus] 之一。
  Future<String> install() async {
    final String path = _downloadedPath ?? '';
    if (path.isEmpty) {
      _installMessage = '尚无已下载的安装包';
      _emit();
      return UpdateInstallStatus.failed;
    }
    _installMessage = null;
    _emit();

    if (_isAndroid) {
      final String status = await _bridge.installApk(path);
      if (status == UpdateInstallStatus.needPermission) {
        await _bridge.openInstallPermissionSettings();
        _installMessage = '请在系统设置中允许「安装未知应用」，返回后再点安装';
        _emit();
      }
      return status;
    }

    // 桌面端（Windows / macOS）：系统默认程序打开安装包，失败回退发布页。
    if (await _launchLocalFile(path)) return UpdateInstallStatus.started;
    _installMessage = '无法自动打开安装包，请在浏览器中下载安装';
    _emit();
    await openReleasePage();
    return UpdateInstallStatus.failed;
  }

  /// 用系统默认程序打开本地安装包（桌面端）。
  Future<bool> _launchLocalFile(String path) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', <String>[path]);
        return true;
      }
      if (Platform.isWindows) {
        await Process.run('cmd', <String>['/c', 'start', '', path]);
        return true;
      }
    } catch (e) {
      AppLog.warn(logTag, '系统打开安装包失败', error: e);
    }
    return false;
  }

  /// 浏览器打开 Release 页面（降级下载；对齐 iOS `openReleasePageInSafari`）。
  Future<void> openReleasePage() async {
    final String url = _releasePageUrl ?? _downloadUrl ?? '';
    if (url.isEmpty) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      AppLog.warn(logTag, '拉起浏览器失败', error: e);
    }
  }

  // ─────────────── 悬浮态 ───────────────

  /// 缩小为悬浮气泡。
  void minimize() {
    _isMinimized = true;
    _emit();
  }

  /// 从悬浮气泡恢复弹窗。
  void restore() {
    _isMinimized = false;
    _emit();
  }

  // ─────────────── 内部工具 ───────────────

  /// 安装包扩展名（按平台）。
  static String _extensionFor(UpdatePlatform? platform) => switch (platform) {
        UpdatePlatform.windows => '.exe',
        UpdatePlatform.macos => '.dmg',
        UpdatePlatform.androidArm64 ||
        UpdatePlatform.androidV7a =>
          '.apk',
        null => '.bin',
      };

  /// 计算文件 SHA-256（十六进制小写）。
  Future<String> _sha256File(File file) async {
    final Digest digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// 默认更新包目录：应用支持目录下 `updates/`。
  static Future<Directory> _defaultUpdateDir() async {
    final Directory base = await getApplicationSupportDirectory();
    final Directory dir = Directory(p.join(base.path, updateDirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 通知监听者（dispose 后静默）。
  void _emit() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _downloadToken++;
    super.dispose();
  }
}