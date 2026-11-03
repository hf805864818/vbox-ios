/// 领域层：通用福利 Python Spider 服务（批次 H · H-03）。
///
/// 唯一真相源：iOS `vbox/WelfareRemote/WelfarePythonSpiderService.swift`
///   · 设计目标（L7-L12）：新增 Python 福利平台只需远程源配置 + 上传 .py 脚本，
///     复用福利内容框架，不影响普通蜘蛛 / 网盘 / 其他福利平台；
///   · `service(for:)`（L47-L55）：按 `platformKey` 实例缓存；
///   · `ensureEngine()`（L155-L190）：下载脚本 → 创建引擎 → 注册；
///   · `buildInjectDict()`（L199-L219）：注入自定义域名 / 代理上下文；
///   · 抓取契约（L223-L423）：home / category / detail / search / player，
///     漫画类型详情额外加载图片列表（`manga://` 协议）；
///   · `playFromFromEpisode`（L437-L453）：从剧集名提取线路名。
///
/// 移植口径与差异登记：
///   · Python 执行走 Flutter 既有 **Python 桥引擎**（[PythonBridgeEngine]：
///     常驻子进程 + JSON over stdio），而非 iOS 内嵌解释器；
///   · iOS 经 `injectDict` 注入 `_vbox_effective_hosts` / `_vbox_proxy_*`
///     上下文，Flutter 桥未暴露该机制 → 域名选取走 [FuliBaseService.allHosts]
///     （H-07：自定义在前 + 默认在后），代理注入差异登记；
///   · `homeVideoContent` 兜底（iOS L236-L248）依赖引擎扩展能力，Flutter
///     引擎层未暴露 → 仅走 `homeContent`（差异登记）；
///   · 漫画图片加载（iOS `loadComicImages` L321-L371 并发组）Flutter 顺序执行。
library;

import 'dart:async';

import '../../data/datasources/local/welfare_domain_store.dart';
import '../../data/datasources/welfare/welfare_spider_loader.dart';
import '../../platform/spider/python_bridge_engine.dart';
import '../entities/spider/spider_engine.dart';
import '../entities/spider/spider_models.dart';
import '../entities/welfare/welfare.dart';
import 'fuli_base_service.dart';
import 'welfare_result_mapper.dart';

/// 通用福利 Python Spider 服务（远程 .py 脚本驱动福利平台）。
class WelfarePythonSpiderService extends FuliBaseService {
  /// 构造（依赖可注入，便于单测）。
  ///
  /// [loader] 负责脚本下载 / 缓存（缺省真实加载器）；
  /// [engineProvider] 返回 Python 引擎（缺省 [PythonBridgeEngine]；
  /// 测试注入 fake [SpiderEngine]）。
  WelfarePythonSpiderService({
    required WelfarePlatform platform,
    WelfareSpiderLoader? loader,
    SpiderEngine Function()? engineProvider,
    void Function(String)? logSink,
  })  : _platform = platform,
        _loader = loader ?? WelfareSpiderLoader(),
        _log = logSink ?? print,
        super(
          platformKey: platform.platformKey,
          platformName: platform.name,
          defaultHosts: platform.defaultHosts,
        ) {
    _engineProvider = engineProvider ?? PythonBridgeEngine.new;
  }

  /// 按 `platformKey` 的实例缓存（对齐 iOS `NSCache` 语义）。
  static final Map<String, WelfarePythonSpiderService> _cache =
      <String, WelfarePythonSpiderService>{};

  /// 按平台取（或创建）服务实例（对齐 iOS `service(for:)`）。
  static WelfarePythonSpiderService serviceFor(
    WelfarePlatform platform, {
    WelfareSpiderLoader? loader,
    SpiderEngine Function()? engineProvider,
    void Function(String)? logSink,
  }) =>
      _cache.putIfAbsent(
        platform.platformKey,
        () => WelfarePythonSpiderService(
          platform: platform,
          loader: loader,
          engineProvider: engineProvider,
          logSink: logSink,
        ),
      );

  /// 清空实例缓存（装配重置 / 测试隔离用）。
  static void clearCache() => _cache.clear();

  final WelfarePlatform _platform;
  final WelfareSpiderLoader _loader;
  final void Function(String) _log;

  late final SpiderEngine Function() _engineProvider;

  final WelfareResultMapper _mapper = const WelfareResultMapper();

  SpiderEngine? _engine;
  String? _initError;
  Future<void>? _initFuture;

  /// 最近一次详情页返回的 `vod_play_from`（供 playerContent 的 flag 参数用）。
  String _lastPlayFrom = '';

  /// 是否处于引擎就绪状态。
  bool get isEngineReady => _engine != null;

  /// 引擎初始化失败原因（失败后有值）。
  String? get engineInitError => _initError;

  /// 统一日志（对齐 iOS `pyLog` L37-L41）。
  void pyLog(String msg) => _log('[WelfarePy:${_platform.platformKey}] $msg');

  // ─────────────── FuliBaseService 附加属性（对齐 iOS L107-L122）───────────────

  /// 内容类型：从平台分类读取（直播走视频播放链路，对齐 iOS）。
  @override
  FuliContentCategory get contentCategory => switch (_platform.category) {
        WelfarePlatformCategory.comic => FuliContentCategory.comic,
        WelfarePlatformCategory.video ||
        WelfarePlatformCategory.live =>
          FuliContentCategory.video,
      };

  // ─────────────── 引擎初始化（对齐 iOS `ensureEngine` L155-L190）───────────────

  /// 确保引擎已初始化（幂等；失败记 [engineInitError]，不抛给调用方）。
  Future<void> ensureEngine() async {
    if (_engine != null || _initError != null) return;
    _initFuture ??= _doInit();
    await _initFuture;
  }

  Future<void> _doInit() async {
    try {
      final WelfareSpiderScript script = await _loader.loadScript(_platform);
      final SpiderEngine engine = _engineProvider();
      await engine.loadScript(script.content);
      await engine.registerSpider();
      _engine = engine;
      _initError = null;
      pyLog('✅ 引擎初始化成功');
    } catch (e) {
      _initError = e.toString();
      pyLog('❌ 引擎初始化失败: $e');
    }
  }

  // ─────────────── FuliBaseService 实现（对齐 iOS L223-L423）───────────────

  @override
  String get currentHost =>
      _engine != null && allHosts.isNotEmpty ? allHosts.first : '';

  @override
  bool get isHostReady => _engine != null;

  /// 重新探测域名（重建引擎 + 一次首页调用验证，对齐 iOS `reprobe` L129-L144）。
  @override
  void reprobe() {
    _engine = null;
    _initError = null;
    _initFuture = null;
    unawaited(_reprobeAsync());
  }

  Future<void> _reprobeAsync() async {
    await ensureEngine();
    if (_engine == null) return;
    final FuliHomeResult result = await fetchHomeContent();
    _log('[WelfarePy:${_platform.platformKey}] 域名探测: '
        '${result.videos.isNotEmpty || result.categories.isNotEmpty ? '可用' : '不可用'}');
  }

  /// 重置域名（对齐 iOS `resetDomain`：清空自定义域名后重新探测）。
  @override
  void resetDomain() {
    WelfareDomainStore.shared.clearDomains(platformName);
    reprobe();
  }

  @override
  Future<FuliHomeResult> fetchHomeContent() async {
    await ensureEngine();
    final SpiderEngine? engine = _engine;
    if (engine == null) return FuliHomeResult.empty;
    try {
      final HomeContentResult result = await engine.callHomeContent();
      return _mapper.mapHome(result);
    } catch (e) {
      pyLog('❌ fetchHomeContent: $e');
      return FuliHomeResult.empty;
    }
  }

  @override
  Future<FuliCategoryResult> fetchCategoryContent({
    required FuliCategory category,
    FuliCategory? subCategory,
    required int page,
  }) async {
    await ensureEngine();
    final SpiderEngine? engine = _engine;
    if (engine == null) {
      return FuliCategoryResult(videos: const <FuliVideo>[], page: page, hasMore: false);
    }
    final String tid = subCategory?.typeId ?? category.typeId;
    try {
      final CategoryContentResult result =
          await engine.callCategoryContent(tid, page, '{}');
      return _mapper.mapCategory(result);
    } catch (e) {
      pyLog('❌ fetchCategoryContent: $e');
      return FuliCategoryResult(videos: const <FuliVideo>[], page: page, hasMore: false);
    }
  }

  @override
  Future<FuliDetail> fetchDetail(String vodId) async {
    await ensureEngine();
    final SpiderEngine? engine = _engine;
    if (engine == null) return _emptyDetail(vodId);
    try {
      final DetailContentResult result = await engine.callDetailContent(vodId);
      final FuliDetail detail = _mapper.mapDetail(result);
      // 记录 playFrom，供 playerContent 的 flag 参数使用（对齐 iOS L294）。
      _lastPlayFrom = detail.playFrom;

      // 漫画类型：调用 playerContent 获取 manga:// 图片列表（对齐 iOS L296-L307）。
      if (contentCategory == FuliContentCategory.comic) {
        final List<FuliEpisode> withImages =
            await _loadComicImages(episodes: detail.episodes);
        return FuliDetail(
          vodId: detail.vodId,
          vodName: detail.vodName,
          vodPic: detail.vodPic,
          vodContent: detail.vodContent,
          playFrom: detail.playFrom,
          episodes: withImages,
        );
      }

      return detail;
    } catch (e) {
      pyLog('❌ fetchDetail: $e');
      return _emptyDetail(vodId);
    }
  }

  /// 加载漫画图片列表（对齐 iOS `loadComicImages` L321-L371）。
  ///
  /// 快速路径：URL 已是 `manga://` / `pics://` 协议直接解析；
  /// 慢速路径：调用 playerContent 获取协议 URL。
  Future<List<FuliEpisode>> _loadComicImages({
    required List<FuliEpisode> episodes,
  }) async {
    final SpiderEngine? engine = _engine;
    if (engine == null) return episodes;

    final List<FuliEpisode> out = <FuliEpisode>[];
    for (final FuliEpisode ep in episodes) {
      // 快速路径。
      if (_mapper.isMangaProtocol(ep.url)) {
        final List<String> images = _mapper.parseMangaURL(ep.url);
        if (images.isNotEmpty) {
          out.add(FuliEpisode(name: ep.name, url: ep.url, images: images));
          continue;
        }
        out.add(ep);
        continue;
      }

      // 慢速路径。
      try {
        final PlayerContentResult pc = await engine.callPlayerContent(
          '',
          _playFromFromEpisode(ep),
          ep.url,
        );
        final String playerURL = (pc.playUrl != null && pc.playUrl!.isNotEmpty)
            ? pc.playUrl!
            : (pc.url ?? '');
        final List<String> images = _mapper.parseMangaURL(playerURL);
        if (images.isNotEmpty) {
          out.add(FuliEpisode(name: ep.name, url: ep.url, images: images));
          continue;
        }
      } catch (e) {
        pyLog('❌ loadComicImages[${ep.name}]: $e');
      }
      out.add(ep);
    }
    return out;
  }

  @override
  Future<FuliSearchResult> fetchSearch({
    required String keyword,
    required int page,
  }) async {
    await ensureEngine();
    final SpiderEngine? engine = _engine;
    if (engine == null) {
      return FuliSearchResult(videos: const <FuliVideo>[], page: page, hasMore: false);
    }
    try {
      final SearchContentResult result = await engine.callSearchContent(keyword, page);
      return _mapper.mapSearch(result);
    } catch (e) {
      pyLog('❌ fetchSearch: $e');
      return FuliSearchResult(videos: const <FuliVideo>[], page: page, hasMore: false);
    }
  }

  @override
  Future<FuliPlayerResult> fetchPlayerURL(FuliEpisode episode) async {
    await ensureEngine();

    // 对齐 iOS L389-L419：Python 蜘蛛就绪时优先调用 playerContent。
    final SpiderEngine? engine = _engine;
    if (engine != null && engine.isSpiderReady) {
      try {
        final PlayerContentResult result = await engine.callPlayerContent(
          '',
          _playFromFromEpisode(episode),
          episode.url,
        );
        final FuliPlayerResult mapped = _mapper.mapPlayer(result);
        if (mapped.url.isNotEmpty) {
          final Map<String, String> playerHeaders =
              <String, String>{...mapped.headers};
          playerHeaders['User-Agent'] ??=
              'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36';
          return FuliPlayerResult(
            url: mapped.url,
            headers: playerHeaders,
            parse: mapped.parse,
          );
        }
      } catch (e) {
        pyLog('❌ fetchPlayerURL: $e');
      }
    }

    // 兜底：使用基类默认实现（按 URL 后缀判断 parse）。
    return super.fetchPlayerURL(episode);
  }

  // ─────────────── 小工具（对齐 iOS L425-L453）───────────────

  FuliDetail _emptyDetail(String vodId) => FuliDetail(
        vodId: vodId,
        vodName: '',
        vodPic: '',
        vodContent: null,
        playFrom: platformName,
        episodes: const <FuliEpisode>[],
      );

  /// 从剧集名提取线路名（对齐 iOS `playFromFromEpisode` L437-L453）。
  String _playFromFromEpisode(FuliEpisode episode) {
    final String name = episode.name;
    // 多线路场景：名称形如「[线路名] 第X集」。
    if (name.startsWith('[')) {
      final int end = name.indexOf(']');
      if (end > 1) return name.substring(1, end);
    }
    // 单线路场景：取详情页 `vod_play_from` 第一个值。
    if (_lastPlayFrom.isNotEmpty) {
      final String firstLine = _lastPlayFrom.split(r'$$$').first;
      if (firstLine.isNotEmpty) return firstLine;
    }
    return platformName;
  }
}
