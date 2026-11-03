/// 领域层：福利专区专用远程 Spider 服务（批次 H · H-03）。
///
/// 唯一真相源：iOS `vbox/WelfareRemote/WelfareSpiderService.swift`
///   · `LoadState`（L14-L32）：idle / loading / loaded / failed + `title`；
///   · init（L38-L43）：构造时从缓存恢复 `loaded` 态；
///   · `currentDomain`（L45-L50）：优先自定义域名（H-07），否则 `primaryHost`；
///   · `scriptPreview`（L52-L58）：脚本文本前 28 行；
///   · `localScriptPath`（L60-L63）：本地缓存文件名；
///   · `reload()`（L65-L79）：置 loading → 下载 → loaded / failed。
///
/// 差异登记：
///   · 以 [ChangeNotifier] 表达 iOS 的 `@Published` 状态（与
///     [WelfarePlatformController] 一致），UI 用 `ListenableBuilder` 监听；
///   · `currentDomain` 暂直接返回 [WelfarePlatform.primaryHost]（自定义域名
///     存储归 H-07 批次）。
library;

import 'package:flutter/foundation.dart';

import '../../data/datasources/welfare/welfare_spider_loader.dart';
import '../entities/welfare/welfare.dart';

/// 福利 Spider 脚本加载状态（对齐 iOS `LoadState`，assoc value 拆分为字段）。
enum WelfareSpiderLoadState {
  /// 未加载。
  idle,

  /// 加载中。
  loading,

  /// 已加载（脚本可用）。
  loaded,

  /// 加载失败。
  failed;

  /// 状态标题（对齐 iOS `LoadState.title`）。
  String get title => switch (this) {
        WelfareSpiderLoadState.idle => '未加载',
        WelfareSpiderLoadState.loading => '正在加载脚本',
        WelfareSpiderLoadState.loaded => '脚本已缓存',
        WelfareSpiderLoadState.failed => '脚本加载失败',
      };
}

/// 福利专区专用远程 Spider 服务（脚本状态机）。
class WelfareSpiderService extends ChangeNotifier {
  /// 构造（[loader] 可注入，便于单测）。
  WelfareSpiderService({
    required this.platform,
    WelfareSpiderLoader? loader,
  })  : _loader = loader ?? WelfareSpiderLoader() {
    // 对齐 iOS init：先恢复缓存态（有缓存直接进 loaded）。
    final WelfareSpiderScript? cached = _loader.cachedScript(platform);
    if (cached != null) {
      _script = cached;
      _state = WelfareSpiderLoadState.loaded;
    }
  }

  /// 触发加载的平台元数据。
  final WelfarePlatform platform;

  final WelfareSpiderLoader _loader;

  WelfareSpiderLoadState _state = WelfareSpiderLoadState.idle;
  WelfareSpiderScript? _script;
  String? _errorMessage;

  /// 当前加载状态。
  WelfareSpiderLoadState get state => _state;

  /// 已加载脚本（loaded 时有值）。
  WelfareSpiderScript? get script => _script;

  /// 失败原因（failed 时有值）。
  String? get errorMessage => _errorMessage;

  /// 当前生效域名（对齐 iOS `currentDomain`；自定义域名归 H-07，暂用首个默认域）。
  String get currentDomain => platform.primaryHost;

  /// 脚本文本预览（前 28 行；未加载返回 `null`）。
  String? get scriptPreview => _script?.preview;

  /// 本地缓存文件名（未加载返回 `null`）。
  String? get localScriptPath => _script?.localScriptPath;

  /// 重新加载脚本（下载 + 缓存，成功置 loaded / 失败置 failed）。
  Future<void> reload() async {
    _state = WelfareSpiderLoadState.loading;
    _errorMessage = null;
    _safeNotify();

    try {
      final WelfareSpiderScript script = await _loader.loadScript(platform);
      _script = script;
      _state = WelfareSpiderLoadState.loaded;
      _errorMessage = null;
    } catch (e) {
      _script = null;
      _state = WelfareSpiderLoadState.failed;
      _errorMessage = _describe(e);
    }
    _safeNotify();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  String _describe(Object error) {
    if (error is WelfareSpiderLoaderError) {
      return error.messageOf();
    }
    return error.toString();
  }
}
