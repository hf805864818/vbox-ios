/// 领域层：内容浏览用例（首页 / 分类 / 搜索，单源解析）。
///
/// 链路：站点（allSources 按 key 解析）→ 模式判定 → 引擎/API → 内容结果。
/// 对齐契约 §1.1（引擎选择规则）+ §3（返回结构）+ iOS `SpiderRepository` /
/// `CMSV10Helper`。
///
/// 模式分支（对齐 `DetailPlaybackUseCases`，同源解析口径）：
/// - apiEndpoint / zhanyuan → CMS V10（`?ac=list` / `?ac=videolist`）；
/// - node / jsSpider / pythonSpider → Spider 引擎 `homeContent` / `categoryContent` /
///   `searchContent`；
/// - jsSpider 由 QuickJS 顶替（G-03-B 决策：JSC 为 iOS 原生保留）。
library;

import '../../core/errors/failures.dart';
import '../../core/utils/logger.dart';
import '../../core/utils/result.dart';
import '../../data/datasources/local/tg_search_config_store.dart';
import '../../data/datasources/remote/all_sources_datasource.dart';
import '../../data/datasources/remote/cms_v10_datasource.dart';
import '../../data/datasources/remote/cms_v10_models.dart';
import '../../data/datasources/remote/spider_script_cache.dart';
import '../../platform/runtime/quickjs_ffi.dart';
import '../../platform/spider/node_http_client.dart';
import '../../platform/spider/spider_engine_factory.dart';
import '../entities/remote_source/remote_source.dart';
import '../entities/spider/spider.dart';
import 'music_source_filter.dart';

/// TG 搜索蜘蛛站点 key（对齐 iOS `SpiderManager.swift` L1394 的注入判定）。
const String _tgSearchSiteKey = 'js_TG搜索';

/// 内容浏览用例。
class ContentBrowseUseCases {
  /// 构造。
  ///
  /// [loadAllSources] 注入站点聚合加载（清单 → allSources URL → 拉取解析），
  /// 便于表现层组装缓存/TTL 逻辑；引擎相关依赖均可注入（测试用 fake）。
  /// [waitNodeReady] Node 常驻就绪等待（对齐 iOS
  /// `fetchSingleSourceCategoryContent` 的 `waitForNodeReadyIfNeeded`，
  /// SpiderManager.swift L2136）：node 承载的蜘蛛源调用前等待宿主就绪。
  ContentBrowseUseCases({
    required this.loadAllSources,
    SpiderEngineFactory engineFactory = const SpiderEngineFactory(),
    CmsV10Datasource? cmsDatasource,
    QuickJsNativeBridge? quickJsBridge,
    NodeHttpClient? nodeClient,
    this.scriptBaseUrl,
    SpiderScriptCache? spiderScriptCache,
    Future<void> Function()? waitNodeReady,
  })  : _engineFactory = engineFactory,
        _cmsDatasource = cmsDatasource,
        _quickJsBridge = quickJsBridge,
        _nodeClient = nodeClient,
        _scriptCache = spiderScriptCache,
        _waitNodeReady = waitNodeReady;

  /// 站点聚合加载器。
  final Future<Result<AllSourcesContainer>> Function() loadAllSources;

  /// 脚本相对路径基址（`allSources` 清单 URL），对齐 iOS `subBaseURL`。
  ///
  /// 站源 `api` 为 `./x.js` / `x.js` / `x.py` 等相对路径时，以其为 base 解析；
  /// 表现层注入（清单刷新后更新），缺省退回绝对 URL 场景（仅 http(s) 可用）。
  final String? Function()? scriptBaseUrl;

  /// Node 常驻就绪等待（可空：测试/无 Node 场景直接跳过）。
  final Future<void> Function()? _waitNodeReady;

  final SpiderEngineFactory _engineFactory;
  final CmsV10Datasource? _cmsDatasource;
  final QuickJsNativeBridge? _quickJsBridge;
  final NodeHttpClient? _nodeClient;

  /// JS/Python 蜘蛛脚本本地缓存（对齐 iOS `cachedSpiderJSContent(forKey:)`：
  /// 远程同步已把脚本落盘，运行时 cache-first 读取，避免每次冷启动重拉脚本）。
  final SpiderScriptCache? _scriptCache;

  /// 蜘蛛引擎缓存（对齐 iOS `SpiderManager` 引擎/脚本复用：同一站点首次
  /// 下载解析脚本后复用，翻页/切分类不再重复拉脚本）。key = 站点 key。
  final Map<String, SpiderEngine> _engineCache = <String, SpiderEngine>{};

  /// 列出全部可浏览站点（源切换 UI）。
  Future<Result<List<SiteConfig>>> listSites() async {
    final Result<AllSourcesContainer> sourcesResult = await loadAllSources();
    final Failure? failure = sourcesResult.failureOrNull;
    if (failure != null) return Err<List<SiteConfig>>(failure);
    final AllSourcesContainer? container = sourcesResult.valueOrNull;
    if (container == null) {
      return const Err<List<SiteConfig>>(UnknownFailure('站点聚合为空'));
    }
    // 对齐 iOS `fetchAllSourceDisplayItems()`：视频「切换源」列表 =
    // **网盘源 + API 源 + JS/Python 蜘蛛 + 站源**（见 [_unifiedSites]），
    // 音乐源不进该列表，也不参与后续按列表展开的搜索/首页通路。
    final List<SiteConfig> sites = _unifiedSites(container);
    if (sites.isEmpty) {
      return const Err<List<SiteConfig>>(UnknownFailure('无可用站点'));
    }
    return Success<List<SiteConfig>>(sites);
  }

  /// 合成视频「切换源」清单（对齐 iOS `fetchAllSourceDisplayItems()`）。
  ///
  /// 组成：`container.sites`（apiSources + spiderSources）+ `cloudSites`
  /// （网盘源 → [CloudSiteConfig.toSiteConfig]，key `cloud_<name>`）；按 key
  /// 去重（api/spider 优先），音乐源按 [isMusicSite] 过滤。
  ///
  /// 网盘源追加在末尾（保留既有站点默认选中位），仅参与列表展示与网盘搜索，
  /// 不进入 [searchContent] 逐源循环（网盘搜索走 `CloudSearchUseCases`）。
  List<SiteConfig> _unifiedSites(AllSourcesContainer container) {
    final List<SiteConfig> out = <SiteConfig>[];
    final Set<String> seen = <String>{};
    void add(SiteConfig s) {
      if (s.key.isEmpty) return;
      if (isMusicSite(s)) return;
      if (!seen.add(s.key)) return;
      out.add(s);
    }

    for (final Map<String, Object?> raw in container.sites) {
      add(SiteConfig.fromJson(raw));
    }
    for (final CloudSiteConfig c in container.cloudSites) {
      add(c.toSiteConfig());
    }
    return out;
  }

  /// 首页内容（单源）。
  Future<Result<HomeContentResult>> homeContent(String siteKey) async {
    final _ResolvedSite? resolved = await _resolve(siteKey);
    if (resolved == null) {
      return const Err<HomeContentResult>(ValidationFailure('站点 key 为空'));
    }
    if (resolved.error != null) return Err<HomeContentResult>(resolved.error!);

    final SiteConfig site = resolved.site!;
    switch (site.resolveSiteMode()) {
      case SiteMode.apiEndpoint:
      case SiteMode.zhanyuan:
        return _cmsHome(site);
      case SiteMode.node:
      case SiteMode.jsSpider:
      case SiteMode.pythonSpider:
        return _spiderHome(site);
      case SiteMode.unsupported:
        AppLog.error(
          'spider',
          '站点「${site.name}」(${site.key}) 模式不支持（type=${site.type}，'
          'api=${site.api}）→ 首页无数据',
        );
        return Err<HomeContentResult>(
          UnsupportedFailure('站点「${site.name}」模式不支持'),
        );
    }
  }

  /// 分类内容（单源，分页）。
  ///
  /// [filters] 筛选参数（key：`class`/`area`/`year`，对齐 iOS
  /// `buildFilterQuery`——CMS 源拼 URL 参数；蜘蛛源不传，对齐 iOS extend='{}'）。
  Future<Result<CategoryContentResult>> categoryContent(
    String siteKey, {
    String? tid,
    int page = 1,
    Map<String, String>? filters,
  }) async {
    final _ResolvedSite? resolved = await _resolve(siteKey);
    if (resolved == null) {
      return const Err<CategoryContentResult>(ValidationFailure('站点 key 为空'));
    }
    if (resolved.error != null) {
      return Err<CategoryContentResult>(resolved.error!);
    }

    final SiteConfig site = resolved.site!;
    switch (site.resolveSiteMode()) {
      case SiteMode.apiEndpoint:
      case SiteMode.zhanyuan:
        return _cmsCategory(site, tid, page, filters);
      case SiteMode.node:
      case SiteMode.jsSpider:
      case SiteMode.pythonSpider:
        return _spiderCategory(site, tid, page);
      case SiteMode.unsupported:
        AppLog.error(
          'spider',
          '站点「${site.name}」(${site.key}) 模式不支持（type=${site.type}，'
          'api=${site.api}）→ 分类内容无数据',
        );
        return Err<CategoryContentResult>(
          UnsupportedFailure('站点「${site.name}」模式不支持'),
        );
    }
  }

  /// 分类列表（源分类胶囊）。
  Future<Result<List<VodCategory>>> categories(String siteKey) async {
    final _ResolvedSite? resolved = await _resolve(siteKey);
    if (resolved == null) {
      return const Err<List<VodCategory>>(ValidationFailure('站点 key 为空'));
    }
    if (resolved.error != null) {
      return Err<List<VodCategory>>(resolved.error!);
    }

    final SiteConfig site = resolved.site!;
    switch (site.resolveSiteMode()) {
      case SiteMode.apiEndpoint:
      case SiteMode.zhanyuan:
        return _cmsCategories(site);
      case SiteMode.node:
      case SiteMode.jsSpider:
      case SiteMode.pythonSpider:
        return _spiderCategories(site);
      case SiteMode.unsupported:
        AppLog.error(
          'spider',
          '站点「${site.name}」(${site.key}) 模式不支持（type=${site.type}，'
          'api=${site.api}）→ 分类列表为空',
        );
        return Err<List<VodCategory>>(
          UnsupportedFailure('站点「${site.name}」模式不支持'),
        );
    }
  }

  /// 搜索内容（单源，分页）。
  Future<Result<SearchContentResult>> searchContent(
    String siteKey,
    String keyword, {
    int page = 1,
  }) async {
    if (keyword.trim().isEmpty) {
      return const Err<SearchContentResult>(ValidationFailure('搜索关键词为空'));
    }
    final _ResolvedSite? resolved = await _resolve(siteKey);
    if (resolved == null) {
      return const Err<SearchContentResult>(ValidationFailure('站点 key 为空'));
    }
    if (resolved.error != null) {
      return Err<SearchContentResult>(resolved.error!);
    }

    final SiteConfig site = resolved.site!;
    switch (site.resolveSiteMode()) {
      case SiteMode.apiEndpoint:
      case SiteMode.zhanyuan:
        return _cmsSearch(site, keyword, page);
      case SiteMode.node:
      case SiteMode.jsSpider:
      case SiteMode.pythonSpider:
        return _spiderSearch(site, keyword, page);
      case SiteMode.unsupported:
        AppLog.error(
          'spider',
          '站点「${site.name}」(${site.key}) 模式不支持（type=${site.type}，'
          'api=${site.api}）→ 搜索无数据',
        );
        return Err<SearchContentResult>(
          UnsupportedFailure('站点「${site.name}」模式不支持'),
        );
    }
  }

  // ─────────────── 内部：站点解析 ───────────────

  Future<_ResolvedSite?> _resolve(String siteKey) async {
    final String key = siteKey.trim();
    if (key.isEmpty) return null;

    final Result<AllSourcesContainer> sourcesResult = await loadAllSources();
    final Failure? sourcesFailure = sourcesResult.failureOrNull;
    if (sourcesFailure != null) {
      // ★ 诊断日志：此前该早退路径**完全静默**——源清单拉取失败（网络/解析）
      //   时日志页一片空白，无法区分「清单失败」与「站点未找到」。
      AppLog.error(
        'spider',
        '站点解析失败：加载源清单出错 — ${sourcesFailure.message}',
        error: sourcesFailure,
      );
      return _ResolvedSite.error(sourcesFailure);
    }
    final AllSourcesContainer? container = sourcesResult.valueOrNull;
    SiteConfig? site = container == null
        ? null
        : AllSourcesDatasource.findSite(container, key);
    if (site == null && container != null) {
      // 网盘源合成 key（`cloud_<name>`）：切换源列表选中后需能解析首页/分类，
      // 对齐 iOS `fetchAllSourceDisplayItems()` 把网盘源并入统一源列表的语义。
      for (final CloudSiteConfig c in container.cloudSites) {
        final SiteConfig s = c.toSiteConfig();
        if (s.key == key) {
          site = s;
          break;
        }
      }
    }
    if (site == null) {
      AppLog.error('spider', '站点解析失败：未找到站点 key=$key（源清单已加载）');
      return _ResolvedSite.error(ValidationFailure('未找到站点：$key'));
    }
    return _ResolvedSite(site);
  }

  // ─────────────── 内部：CMS V10 路径 ───────────────

  /// 首页合并结果 → [HomeContentResult]。
  HomeContentResult _homeFromBundle(CmsV10HomeBundle bundle) {
    final List<VodCategory> classes = bundle.classes
        .map((CmsV10Category c) =>
            VodCategory(typeId: c.typeId, typeName: c.typeName))
        .toList(growable: false);
    final List<VodItem> list =
        bundle.videos.map(_toVodItem).toList(growable: false);
    return HomeContentResult(
      classes: classes.isEmpty ? null : classes,
      list: list,
    );
  }

  /// 网盘组源条目标记（对齐 iOS `fetchSingleSourceCategoryContent`
  /// L2142-L2146：cloudCMS 组源强制 `vodRemarks = "☁️" + 源名`，详情页据此
  /// 走网盘版式）。
  List<VodItem> _applyCloudRemarks(List<VodItem> list, SiteConfig site) {
    if (site.group != cloudSiteGroup) return list;
    final String remark = '☁️${site.name}';
    return list
        .map((VodItem v) => VodItem(
              vodId: v.vodId,
              vodName: v.vodName,
              vodPic: v.vodPic,
              vodRemarks: remark,
              vodYear: v.vodYear,
              vodArea: v.vodArea,
              vodDirector: v.vodDirector,
              vodActor: v.vodActor,
              vodContent: v.vodContent,
              vodPlayFrom: v.vodPlayFrom,
              vodPlayUrl: v.vodPlayUrl,
              customHeaders: v.customHeaders,
              engineKey: v.engineKey,
              metaDuration: v.metaDuration,
              albumName: v.albumName,
              availQualities: v.availQualities,
              musicPlatform: v.musicPlatform,
              lxMusicInfo: v.lxMusicInfo,
              musicEntryType: v.musicEntryType,
            ))
        .toList(growable: false);
  }

  Future<Result<HomeContentResult>> _cmsHome(SiteConfig site) async {
    final CmsV10Datasource? cms = _cmsDatasource;
    if (cms == null) {
      return const Err<HomeContentResult>(
        UnsupportedFailure('API/站源站点需要注入 CMS 数据源'),
      );
    }
    final String? base = site.api;
    if (base == null || base.trim().isEmpty) {
      return Err<HomeContentResult>(ValidationFailure('站点「${site.name}」缺少 API 地址'));
    }

    // 三级降级（对齐 iOS `fetchAPIHomeData`，SpiderManager.swift L5234-L5249）：
    // ① `ac=home` 一次拿分类 + 推荐；
    // ② `ac=list` 分类 + `ac=list&pg=1` 列表（分两次请求）；
    // ③ HTML 首页兜底（通用详情正则提取）。
    final Result<CmsV10HomeBundle> bundle = await cms.fetchHomeBundle(base);
    final CmsV10HomeBundle? b = bundle.valueOrNull;
    if (b != null && b.videos.isNotEmpty) {
      return Success<HomeContentResult>(_homeFromBundle(b));
    }

    // 分类为尽力而为（失败不阻断首页列表）；列表为必需。
    // 二者无数据依赖 → 并发（对齐 iOS fetchAPIHomeData 二级降级同时发出
    // 分类与列表请求的体感；串行会让失效站点切源时间翻倍）。
    final (Result<List<CmsV10Category>> catResult, Result<CmsV10VideoPage> listResult) =
        await (
          cms.fetchCategories(base),
          cms.fetchVideosPaged(base),
        ).wait;
    final Failure? listFailure = listResult.failureOrNull;
    if (listFailure != null) {
      // ③ HTML 首页兜底（iOS 同语义：JSON 全失败 → HTML 解析）。
      final Result<List<CmsV10Video>> html = await cms.fetchHomeFromHtml(base);
      final List<CmsV10Video>? items = html.valueOrNull;
      if (items != null && items.isNotEmpty) {
        final HomeContentResult h = HomeContentResult(
          classes: (catResult.valueOrNull ?? const <CmsV10Category>[])
              .map((CmsV10Category c) =>
                  VodCategory(typeId: c.typeId, typeName: c.typeName))
              .toList(growable: false),
          list: items.map(_toVodItem).toList(growable: false),
        );
        return Success<HomeContentResult>(h);
      }
      return Err<HomeContentResult>(listFailure);
    }

    // 可增长列表（下方可能追加 ac=home 的分类）。
    final List<VodCategory> classes = (catResult.valueOrNull ?? const <CmsV10Category>[])
        .map((CmsV10Category c) =>
            VodCategory(typeId: c.typeId, typeName: c.typeName))
        .toList();
    final List<VodItem> list =
        listResult.valueOrNull!.items.map(_toVodItem).toList(growable: false);
    // ac=home 只有分类没列表时沿用其分类（免重复请求）。
    if (classes.isEmpty && b != null && b.classes.isNotEmpty) {
      classes.addAll(b.classes.map((CmsV10Category c) =>
          VodCategory(typeId: c.typeId, typeName: c.typeName)));
    }
    return Success<HomeContentResult>(
      HomeContentResult(classes: classes.isEmpty ? null : classes, list: list),
    );
  }

  Future<Result<List<VodCategory>>> _cmsCategories(SiteConfig site) async {
    final CmsV10Datasource? cms = _cmsDatasource;
    if (cms == null) {
      return const Err<List<VodCategory>>(
        UnsupportedFailure('API/站源站点需要注入 CMS 数据源'),
      );
    }
    final String? base = site.api;
    if (base == null || base.trim().isEmpty) {
      return Err<List<VodCategory>>(ValidationFailure('站点「${site.name}」缺少 API 地址'));
    }
    final Result<List<CmsV10Category>> r = await cms.fetchCategories(base);
    final Failure? failure = r.failureOrNull;
    if (failure != null) return Err<List<VodCategory>>(failure);
    return Success<List<VodCategory>>(
      r.valueOrNull!
          .map((CmsV10Category c) =>
              VodCategory(typeId: c.typeId, typeName: c.typeName))
          .toList(growable: false),
    );
  }

  Future<Result<CategoryContentResult>> _cmsCategory(
    SiteConfig site,
    String? tid,
    int page,
    Map<String, String>? filters,
  ) async {
    final CmsV10Datasource? cms = _cmsDatasource;
    if (cms == null) {
      return const Err<CategoryContentResult>(
        UnsupportedFailure('API/站源站点需要注入 CMS 数据源'),
      );
    }
    final String? base = site.api;
    if (base == null || base.trim().isEmpty) {
      return Err<CategoryContentResult>(ValidationFailure('站点「${site.name}」缺少 API 地址'));
    }
    final String? typeParam = (tid == null || tid.trim().isEmpty) ? null : tid.trim();
    final Result<CmsV10VideoPage> r = await cms.fetchVideosPaged(
      base,
      typeId: typeParam,
      page: page,
      filters: filters,
    );
    final Failure? failure = r.failureOrNull;
    if (failure != null) return Err<CategoryContentResult>(failure);

    final CmsV10VideoPage paged = r.valueOrNull!;
    List<CmsV10Video> items = paged.items;
    // 子分类聚合（对齐 iOS `RemoteCMSV10Service` 父分类空 → 聚合子分类）：
    // 父分类（type_pid 关系）无数据时，取其子分类各首页合并（上限 8 个防爆炸）。
    if (items.isEmpty && typeParam != null && page == 1 && filters == null) {
      final List<CmsV10Video> merged = await _mergeChildCategories(cms, base, typeParam);
      if (merged.isNotEmpty) items = merged;
    }
    return Success<CategoryContentResult>(
      CategoryContentResult(
        page: page,
        pagecount: paged.pagecount,
        limit: paged.limit,
        total: paged.total,
        list: _applyCloudRemarks(
          items.map(_toVodItem).toList(growable: false),
          site,
        ),
      ),
    );
  }

  /// 子分类聚合：`type_pid == 父分类 id` 的子分类逐个取首页合并。
  Future<List<CmsV10Video>> _mergeChildCategories(
    CmsV10Datasource cms,
    String base,
    String parentId,
  ) async {
    final int? pid = int.tryParse(parentId);
    if (pid == null) return const <CmsV10Video>[];
    final Result<List<CmsV10Category>> cats = await cms.fetchCategories(base);
    final List<CmsV10Category>? all = cats.valueOrNull;
    if (all == null) return const <CmsV10Video>[];
    final List<CmsV10Category> children = all
        .where((CmsV10Category c) => c.typePid == pid)
        .take(8)
        .toList(growable: false);
    if (children.isEmpty) return const <CmsV10Video>[];
    final List<CmsV10Video> merged = <CmsV10Video>[];
    final Set<String> seen = <String>{};
    for (final CmsV10Category child in children) {
      final Result<CmsV10VideoPage> p = await cms.fetchVideosPaged(
        base,
        typeId: child.typeId,
      );
      final CmsV10VideoPage? page = p.valueOrNull;
      if (page == null) continue;
      for (final CmsV10Video v in page.items) {
        if (seen.add(v.vodId)) merged.add(v);
      }
    }
    return merged;
  }

  Future<Result<SearchContentResult>> _cmsSearch(
    SiteConfig site,
    String keyword,
    int page,
  ) async {
    final CmsV10Datasource? cms = _cmsDatasource;
    if (cms == null) {
      return const Err<SearchContentResult>(
        UnsupportedFailure('API/站源站点需要注入 CMS 数据源'),
      );
    }
    final String? base = site.api;
    if (base == null || base.trim().isEmpty) {
      return Err<SearchContentResult>(ValidationFailure('站点「${site.name}」缺少 API 地址'));
    }
    // 对齐 iOS：搜索走 ac=detail&wd（RemoteCMSV10Service.fetchSearchVideos）。
    final Result<List<CmsV10Video>> r =
        await cms.fetchSearchVideos(base, keyword: keyword.trim(), page: page);
    final Failure? failure = r.failureOrNull;
    if (failure != null) return Err<SearchContentResult>(failure);
    return Success<SearchContentResult>(
      SearchContentResult(
        page: page,
        list: r.valueOrNull!.map(_toVodItem).toList(growable: false),
      ),
    );
  }

  /// CMS 视频 → Spider `VodItem`（供内容浏览统一复用）。
  VodItem _toVodItem(CmsV10Video v) => VodItem(
        vodId: v.vodId,
        vodName: v.name,
        vodPic: v.pic,
        vodRemarks: v.remarks.isEmpty ? null : v.remarks,
        vodYear: v.year.isEmpty ? null : v.year,
        vodArea: v.area.isEmpty ? null : v.area,
      );

  // ─────────────── 内部：Spider 引擎路径 ───────────────

  /// 蜘蛛调用通用骨架（引擎缓存复用：缓存命中直接用，未命中创建并缓存；
  /// 调用失败时剔除缓存重建，下次请求自愈）。
  Future<Result<T>> _runSpider<T>(
    SiteConfig site,
    Future<T> Function(SpiderEngine engine) call,
  ) async {
    final SpiderEngineType engineType = _effectiveEngineType(site);
    SpiderEngine? engine = _engineCache[site.key];
    if (engine != null && engine.engineType != engineType) {
      // 站点引擎类型变更（远端清单刷新）：剔除旧实例。
      await engine.dispose();
      engine = null;
    }
    try {
      if (engine == null) {
        engine = _engineFactory.create(
          engineType,
          siteKey: site.key,
          baseUrl: site.api,
          nodeClient: _nodeClient,
          quickJsBridge: _quickJsBridge,
          // ★ 引擎日志接入 AppLog（对齐 iOS：`SpiderManager` L1473-L1475 给
          //   `PythonSpiderEngine.onLog` 挂了 `AppLogStore.shared.info(.spider, …)`）。
          //   此前 Flutter 端未挂 onLog，Python 桥的脚本 traceback、桥异常、
          //   节点降级事件全部丢弃 → 日志页看不到任何蜘蛛侧内容（诊断盲区）。
          onLog: (String message) => AppLog.info('spider', '[${site.key}] $message'),
        );
        _engineCache[site.key] = engine;
      }
      await _prepareEngine(engine, site);
      return Success<T>(await call(engine));
    } catch (e) {
      // 失败即弃（引擎状态不可信）：剔除缓存，下次请求重建。
      final Failure failure = _asFailure(e);
      // ★ 显式补蜘蛛失败日志（对齐 iOS `SpiderManager` 每个阶段都写 AppLogStore）：
      //   `_asFailure` 直接 `const SpiderFailure(...)`，而全仓错误日志的唯一汇聚点
      //   是 `Failure.from`（failures.dart L34-L41）——不经它就没有任何日志，
      //   这正是「切源失败时日志页一片空白」的根因。此处显式补一条 error 级日志。
      AppLog.error(
        'spider',
        '站点「${site.name}」(${site.key}) ${engineType.name} 调用失败：${failure.message}',
        error: e,
      );
      final SpiderEngine? broken = _engineCache.remove(site.key);
      if (broken != null) {
        await broken.dispose();
      }
      return Err<T>(failure);
    }
  }

  Future<Result<HomeContentResult>> _spiderHome(SiteConfig site) =>
      _runSpider<HomeContentResult>(
          site, (SpiderEngine engine) => engine.callHomeContent());

  Future<Result<List<VodCategory>>> _spiderCategories(SiteConfig site) =>
      _runSpider<List<VodCategory>>(site, (SpiderEngine engine) async {
        final HomeContentResult home = await engine.callHomeContent();
        return home.classes ?? const <VodCategory>[];
      });

  Future<Result<CategoryContentResult>> _spiderCategory(
    SiteConfig site,
    String? tid,
    int page,
  ) =>
      _runSpider<CategoryContentResult>(
        site,
        (SpiderEngine engine) =>
            engine.callCategoryContent(tid ?? '', page, '{}'),
      );

  Future<Result<SearchContentResult>> _spiderSearch(
    SiteConfig site,
    String keyword,
    int page,
  ) =>
      _runSpider<SearchContentResult>(
        site,
        (SpiderEngine engine) =>
            engine.callSearchContent(keyword.trim(), page),
      );

  Future<void> _prepareEngine(SpiderEngine engine, SiteConfig site) async {
    // 引擎缓存复用：脚本已加载（isSpiderReady）则跳过重载（对齐 iOS
    // `SpiderManager` 引擎/脚本缓存——翻页/切分类不再重复下载解析脚本）。
    if (engine.isSpiderReady) return;

    // Node 承载源：等常驻宿主就绪（对齐 iOS `waitForNodeReadyIfNeeded`，
    // SpiderManager.swift L2136），未就绪先调会拿到空数据/连接拒绝。
    if (engine.engineType == SpiderEngineType.node) {
      await _waitNodeReady?.call();
    }

    // 用「有效引擎类型」（jsSpider → QuickJS 顶替 JSC）判定脚本加载分支：
    // `site.resolveEngineType()` 对 jsSpider 返回 javaScriptCore，直接比对
    // quickJS/python 会漏掉 JS 站点 → 脚本不下载、__JS_SPIDER__ 未注册而失败
    // （对齐 detail_playback_usecases 传入 effective 引擎类型的口径）。
    final SpiderEngineType engineType = _effectiveEngineType(site);
    if (engineType == SpiderEngineType.quickJS ||
        engineType == SpiderEngineType.python) {
      final String key = site.key.isEmpty ? site.name : site.key;

      // ★ cache-first（对齐 iOS `loadSingleRemoteSpider` / `loadSinglePythonSpider`）：
      //   远程源同步已把脚本落盘到本地（`downloadAndCacheSpiderJS`），此处优先读本地；
      //   命中即离线加载，未命中才回退网络下载。这是「切源/翻分类必须有网且易失败」
      //   的根因修复：iOS 端同样先读 `cachedSpiderJSContent(forKey:)`。
      final String? cachedScript = _scriptCache?.read(key);
      if (cachedScript != null) {
        // ★ 诊断日志（对齐 iOS `loadSinglePythonSpider` 的「📁 从本地缓存加载」）。
        AppLog.info(
          'spider',
          '站点「${site.name}」($key) 脚本命中本地缓存（${cachedScript.length} 字符）',
        );
        await engine.loadScript(cachedScript);
      } else {
        final String? api = site.api;
        if (api == null || api.trim().isEmpty) {
          throw const ValidationFailure('蜘蛛脚本地址为空');
        }
        final String trimmed = api.trim();
        final bool isUrl =
            trimmed.startsWith('http://') || trimmed.startsWith('https://');
        if (!isUrl) {
          // 相对路径脚本（`./x.js` / `x.js` / `x.py`）：以 allSources 清单 URL 为
          // base 解析绝对地址，对齐 iOS `SpiderManager` 订阅源 subBaseURL 分支
          // （`URL(string:).deletingLastPathComponent().appendingPathComponent(api)`）。
          final String resolvedUrl = _resolveScriptUrl(trimmed, site);
          AppLog.info(
            'spider',
            '站点「${site.name}」($key) 缓存缺失，按订阅源基址解析相对路径：'
            '「$trimmed」→ $resolvedUrl',
          );
          await engine.loadScriptFromURL(resolvedUrl);
        } else {
          // G-04：TG 搜索蜘蛛注入用户配置——对齐 iOS `SpiderManager` L1391-L1400
          // 在主脚本前 prepend `var __TG_CONFIG__ = {...};` 的语义；Flutter 以
          // `loadLibrary`（不检查注册）先建立全局变量，再加载主脚本。
          if (site.key == _tgSearchSiteKey &&
              engineType == SpiderEngineType.quickJS) {
            final String configJs = TGSearchConfigStore.shared.generateConfigJs();
            if (configJs.isNotEmpty) {
              await engine.loadLibrary(configJs);
            }
          }
          AppLog.info(
            'spider',
            '站点「${site.name}」($key) 缓存缺失，从绝对地址下载脚本：$trimmed',
          );
          await engine.loadScriptFromURL(trimmed);
        }
      }

      // ★ ext 脚本（对齐 iOS `loadSpiderExt`）：此前 Flutter 端**完全未加载 ext**，
      //   依赖 ext 补充 `__JS_SPIDER__` / 请求函数的蜘蛛源注册或请求必然失败
      //   → 分类数据恒为空。ext 加载失败不影响主框架（iOS 同语义）。
      try {
        await _loadSpiderExt(engine, site, key);
      } catch (e) {
        // 对齐 iOS：ext 失败不阻断主框架，但**必须留日志**（iOS 打印
        // 「远程蜘蛛 ext 加载失败: …」）。此前此处静默吞异常 → 类似
        // 「ext 把 Python 主脚本顶掉」这类事故在日志里完全不可见。
        AppLog.warn('spider', '站点「${site.name}」($key) ext 加载失败（不阻断主框架）：$e');
      }
    }
    await engine.registerSpider();
    if (!engine.isSpiderReady) {
      throw const SpiderFailure('蜘蛛注册失败（未找到 __JS_SPIDER__）');
    }
    // ★ 就绪日志（对齐 iOS 各加载分支的「✅ 加载成功」轨迹）。
    AppLog.info(
      'spider',
      '站点「${site.name}」(${site.key}) 引擎已就绪：${engine.engineType.name}',
    );
  }

  /// 加载蜘蛛 ext（对齐 iOS `loadSpiderExt`，SpiderManager.swift L1507-L1557）：
  /// 本地缓存 → 绝对 URL → 相对路径（`./x.js` / `x.js`）→ 内联 JS。
  Future<void> _loadSpiderExt(
    SpiderEngine engine,
    SiteConfig site,
    String key,
  ) async {
    final String ext = (site.ext ?? '').trim();
    if (ext.isEmpty) return;

    // ① polyfill：优先本地缓存（同步时按 `<key>_ext` 落盘）。
    final String? cachedExt = _scriptCache?.read('${key}_ext');
    if (cachedExt != null) {
      await engine.loadLibrary(cachedExt);
      return;
    }

    // ② 绝对 URL → ③ 相对路径 → ④ 内联 JS。
    if (ext.startsWith('http://') || ext.startsWith('https://')) {
      await engine.loadScriptFromURL(ext);
      return;
    }
    // ★ ext 只认「`./` 前缀」与「`.js` 结尾」——**逐字对齐 iOS**
    //   （SpiderManager.swift L1531：`extTrimmed.hasPrefix("./") || extTrimmed.hasSuffix(".js")`）。
    //   此前 Flutter 端多认了一个 `.py`，后果严重：Python 引擎的
    //   `loadScriptFromURL` 内部会 shutdown + 重新 launch（见 python_bridge_engine.dart
    //   L74-L107），等于把刚加载好的 py 主蜘蛛**顶替成 ext 内容**；而随后
    //   `registerSpider()` 对 Python 引擎是无条件置就绪 → 引擎「假就绪」，
    //   取分类时脚本里已无 `Spider` 类 → 分类胶囊与数据全空。故与 iOS 一致地排除 `.py`。
    if (ext.startsWith('./') || ext.endsWith('.js')) {
      await engine.loadScriptFromURL(_resolveScriptUrl(ext, site));
      return;
    }
    if (ext.contains('function ') ||
        ext.contains('var ') ||
        ext.contains('let ') ||
        ext.contains('const ')) {
      await engine.loadLibrary(ext);
    }
  }

  /// 解析脚本地址：绝对 http(s) 直接用；相对路径以 [scriptBaseUrl] 为 base。
  String _resolveScriptUrl(String api, SiteConfig site) {
    final String? base = scriptBaseUrl?.call();
    if (base == null || base.trim().isEmpty) {
      throw UnsupportedFailure(
        '本地插件脚本「${site.name}」缺少订阅源基址，无法解析相对路径「$api」',
      );
    }
    final Uri? baseUri = Uri.tryParse(base.trim());
    if (baseUri == null || baseUri.host.isEmpty) {
      throw UnsupportedFailure(
        '本地插件脚本「${site.name}」订阅源基址非法：$base',
      );
    }
    return baseUri.resolve(api).toString();
  }

  SpiderEngineType _effectiveEngineType(SiteConfig site) {
    final SpiderEngineType? resolved = site.resolveEngineType();
    if (resolved == null) {
      throw SpiderException(
        SpiderErrorCode.unimplemented,
        '站点「${site.name}」无法解析引擎类型',
      );
    }
    return resolved == SpiderEngineType.javaScriptCore
        ? SpiderEngineType.quickJS
        : resolved;
  }

  Failure _asFailure(Object e) {
    if (e is SpiderException) {
      return SpiderFailure(e.message, cause: e);
    }
    return Failure.from(e);
  }
}

/// 站点解析结果（区分「key 为空」与「已解析/解析失败」）。
class _ResolvedSite {
  _ResolvedSite(this.site) : error = null;
  const _ResolvedSite.error(Failure this.error) : site = null;

  final SiteConfig? site;
  final Failure? error;
}