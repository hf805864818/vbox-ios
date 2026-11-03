/// 应用根组件。
///
/// 职责：
/// - 初始化依赖（StoragePaths / PrefsManager / DatabaseManager）
/// - 组装数据层仓储实现 → 注入领域层用例
/// - 形态判定（竖屏 / 横屏 + 输入模态）→ 选择对应 UI 布局
/// - 全局 Provider 注入
///
/// 唯一真相源：方案 §2.4（目录结构落地快照见附录 B）
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'core/constants/app_constants.dart';
import 'core/errors/failures.dart';
import 'core/network/http_client.dart';
import 'core/storage/storage_paths.dart';
import 'core/utils/logger.dart';
import 'core/utils/result.dart';
import 'data/datasources/local/database_manager.dart';
import 'data/datasources/local/log_file_sink.dart';
import 'data/datasources/local/prefs_manager.dart';
import 'data/datasources/local/push_play_store.dart';
import 'data/datasources/local/source_governance_store.dart';
import 'data/datasources/local/subscribe_config_store.dart';
import 'data/datasources/local/tg_search_config_store.dart';
import 'data/datasources/local/tmdb_config_store.dart';
import 'data/datasources/local/welfare_domain_store.dart';
import 'data/datasources/local/welfare_proxy_store.dart';
import 'data/datasources/remote/remote.dart';
import 'data/models/zhanyuan.dart';
import 'data/repositories/repositories.dart';
import 'domain/entities/remote_source/remote_source.dart';
import 'domain/entities/spider/spider.dart';
import 'domain/entities/subscribe/subscribe.dart';
import 'domain/services/native_fuli_services.dart';
import 'domain/usecases/usecases.dart';
import 'platform/download/download.dart';
import 'platform/node/node_runtime_manager.dart';
import 'platform/player/music_player.dart';
import 'platform/player/web_page_sniffer.dart';
import 'platform/runtime/runtime.dart';
import 'platform/spider/spider.dart';
import 'platform/system/system.dart';
import 'platform/webview/in_app_webview_bridge.dart';
import 'presentation/profile/session_controller.dart';
import 'presentation/shell/home_shell_page.dart';
import 'presentation/shell/startup_gate.dart';
import 'presentation/shell/startup_orchestrator.dart';
import 'presentation/theme/theme.dart';
import 'presentation/ui_mode/ui_mode_resolver.dart';
import 'presentation/welfare/welfare_controller.dart';
import 'presentation/welfare/welfare_platform_controller.dart';
import 'presentation/widgets/brand/vbox_splash_view.dart';

class VBoxApp extends StatefulWidget {
  const VBoxApp({super.key});

  @override
  State<VBoxApp> createState() => _VBoxAppState();
}

class _VBoxAppState extends State<VBoxApp> with WidgetsBindingObserver {
  /// 日志标签。
  static const String _logTag = 'app';

  bool _initialized = false;
  Object? _initError;

  /// 日志落盘 sink（A3；启动成功后常驻）。
  LogFileSink? _logSink;

  // 用例层实例（数据层仓储在此完成组装）
  late final FavoriteUseCases _favoriteUseCases;
  late final HistoryUseCases _historyUseCases;
  late final SubscriptionUseCases _subscriptionUseCases;
  late final RemoteSourceUseCases _remoteSourceUseCases;

  /// 远程源配置管理器（B-01/B-02/B-03 编排器；对齐 iOS `RemoteSourceConfigManager`）。
  ///
  /// 承载「启动自动同步（版本探测 → 按需全量）+ `loadState` 状态源」，
  /// 供首页胶囊（[RemoteSourceStatusBar]）与设置页订阅。
  late final RemoteSourceConfigManager _remoteSourceConfigManager;
  late final DetailPlaybackUseCases _detailPlaybackUseCases;
  late final ContentBrowseUseCases _contentBrowseUseCases;
  late final SearchHistoryUseCases _searchHistoryUseCases;
  late final AllSourcesDatasource _allSourcesDatasource;
  late final CmsV10Datasource _cmsDatasource;

  /// JS/Python 蜘蛛脚本本地缓存（远程同步落盘 + 运行时 cache-first 读取）。
  late final SpiderScriptCache _spiderScriptCache;

  /// 豆瓣浏览用例（A9：首页默认内容）。
  late final DoubanUseCases _doubanUseCases;

  /// TMDB 用例（G-06：详情页封面 / 演职增强；消费 `app_tmdb_*` 四契约键）。
  late final TmdbUseCases _tmdbUseCases;

  /// 皮肤控制器（A-03：消费 `app_skin_mode` / `app_skin_follows_system`）。
  late final VboxSkinController _skinController;

  /// 形态控制器（A-05：消费 `app_ui_form_override` + 平台通道三重判定）。
  late final UiFormController _uiFormController;

  /// 福利门控控制器（A8：消费 `app_welfare_enabled` / `app_welfare_unlocked`
  /// / `app_welfare_password`；控制底栏「福利」Tab 显隐）。
  late final WelfareController _welfareController;

  /// 福利平台配置控制器（H-01：消费 `fuli_remote_source_*` + `remote_default_manifest_url`；
  /// 福利页进入时 `bootstrap()` 恢复缓存并后台刷新）。
  late final WelfarePlatformController _welfarePlatformController;

  /// 本地账号会话控制器（I-02：SQLite `settings` 表的 `account` / `username`
  /// / `isLoggedIn` / `avatar_image`；纯本地账号，无服务端）。
  late final SessionController _sessionController;

  /// 下载管理器（G-02：全局下载队列 / 进度 / 管理浮层；消费 `download` 表）。
  late final DownloadManager _downloadManager;

  /// Node 就绪订阅（ND-01：就绪后触发本机凭据自动推送，NC-清5）。
  StreamSubscription<NodeRuntimeStatus>? _nodeStatusSub;

  /// allSources 清单 URL（S-设1：脚本相对路径解析 base，对齐 iOS `subBaseURL`）。
  String? _allSourcesUrl;

  /// 占源（自建源）并列搜索用例（S-设2：来源 = 激活订阅配置的 type==2 站点）。
  late final ZhanyuanSearchUseCases _zhanyuanSearchUseCases;

  /// 腾讯视频原生蜘蛛（S-设3：搜索附加结果源 + 详情原生解析，
  /// 对齐 iOS `TencentVideoNativeSpider.shared.search/detail`）。
  late final TencentVideoNativeSpider _tencentSpider;

  /// 源治理用例（Wave D · O-源1/2/3：兜底切片源搜索 / 自定义解析器 / 站源启停）。
  late final SourceGovernanceUseCases _sourceGovernanceUseCases;

  /// 网盘源搜索用例（对齐 iOS `SpiderManager.cloudSearch`：与 api/spider 同级
  /// 的独立源类别，`cloudSources.cloudSites` 并发抓取，命中即回调）。
  late final CloudSearchUseCases _cloudSearchUseCases;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 应用引擎即将销毁（窗口关闭 / 退出）：主动停止 Node 常驻子进程，
    // 释放 58080 端口（配合 Windows Job Object 兜底崩溃路径）。
    if (state == AppLifecycleState.detached) {
      unawaited(_stopNodeRuntime());
    }
  }

  /// 停止 Node 常驻系统（优雅退出路径；失败仅记日志不阻断退出）。
  Future<void> _stopNodeRuntime() async {
    try {
      await NodeRuntimeManager.instance.stop();
    } catch (e) {
      AppLog.warn(_logTag, '退出时停止 Node 常驻失败：$e');
    }
  }

  /// 站点聚合加载（清单刷新 → allSources URL → 拉取解析）。
  Future<Result<AllSourcesContainer>> _loadAllSources() async {
    final Result<RemoteManifest> manifestResult =
        await _remoteSourceUseCases.refresh();
    final Failure? failure = manifestResult.failureOrNull;
    // 刷新失败 → 回退缓存清单（对齐 iOS `loadCachedManifestState` 兜底）：
    // 离线/弱网下仍能按缓存的 all_sources.json 本地加载站点列表与分类资源，
    // 而不是整条链路直接失败（此前 refresh 失败即无站点）。
    RemoteManifest? manifest = manifestResult.valueOrNull;
    manifest ??= (await _remoteSourceUseCases.cached()).valueOrNull;
    if (manifest == null) {
      return Err<AllSourcesContainer>(
        failure ?? const UnknownFailure('清单加载失败'),
      );
    }

    final String? url = manifest.files[RemoteManifest.keyAllSources];
    if (url == null || url.isEmpty) {
      return const Err<AllSourcesContainer>(
        ValidationFailure('清单缺少 allSources 文件条目'),
      );
    }
    _allSourcesUrl = url;
    final Result<AllSourcesContainer> fetched =
        await _allSourcesDatasource.fetch(url);
    final AllSourcesContainer? container = fetched.valueOrNull;
    if (container == null) return fetched;
    // S-设2 前置：订阅源站点并入站点宇宙（对齐 iOS `allSites`
    // = 远程源 + 激活订阅站点），使占源（type=2，key `zhan_N`）可被解析/搜索。
    return Success<AllSourcesContainer>(_mergeSubscriptionSites(container));
  }

  /// 把激活订阅配置的站点并入 [base]（按 key 去重；type==3 归 spider，其余归 api）。
  AllSourcesContainer _mergeSubscriptionSites(AllSourcesContainer base) {
    final SubscribeConfig? config = SubscribeConfigStore.shared.config;
    if (config == null || config.sites.isEmpty) return base;
    final Set<String> existing = base.sites
        .map((Map<String, Object?> s) => (s['key'] ?? '').toString())
        .where((String k) => k.isNotEmpty)
        .toSet();
    final List<Map<String, Object?>> extraApi = <Map<String, Object?>>[];
    final List<Map<String, Object?>> extraSpider = <Map<String, Object?>>[];
    for (final SiteConfig site in config.sites) {
      if (site.key.isEmpty || existing.contains(site.key)) continue;
      existing.add(site.key);
      (site.type == 3 ? extraSpider : extraApi).add(site.toJson());
    }
    if (extraApi.isEmpty && extraSpider.isEmpty) return base;

    Map<String, Object?>? withSites(
      Map<String, Object?>? src,
      List<Map<String, Object?>> extra,
    ) {
      if (extra.isEmpty) return src;
      final Map<String, Object?> merged = <String, Object?>{...?src};
      final Object? rawSites = merged['sites'];
      merged['sites'] = <Object?>[
        ...(rawSites is List ? rawSites : const <Object?>[]),
        ...extra,
      ];
      return merged;
    }

    return AllSourcesContainer(
      apiSources: withSites(base.apiSources, extraApi),
      cloudSources: base.cloudSources,
      spiderSources: withSites(base.spiderSources, extraSpider),
      domainOverrides: base.domainOverrides,
      parsers: base.parsers,
      disabledSources: base.disabledSources,
      welfarePlatforms: base.welfarePlatforms,
    );
  }

  /// 占源站点加载器（S-设2）：激活订阅配置中的 `type == 2` 站点 → [Zhanyuan]。
  Future<List<Zhanyuan>> _loadZhanyuanSites() async {
    final SubscribeConfig? config = SubscribeConfigStore.shared.config;
    if (config == null) return const <Zhanyuan>[];
    final List<Zhanyuan> out = <Zhanyuan>[];
    for (final SiteConfig site in config.sites) {
      final Zhanyuan? z = zhanyuanFromSiteConfig(site);
      if (z != null) out.add(z);
    }
    return out;
  }

  /// 初始化日志：按契约键配置闸门（`app_log_enabled` / `app_log_min_level`）
  /// 并启动落盘 sink（A3）。
  Future<void> _startLogging() async {
    final PrefsManager prefs = PrefsManager.instance;
    AppLog.configure(
      enabled: await prefs.getBool('app_log_enabled'),
      minLevel: LogLevel.fromValue(await prefs.getInt('app_log_min_level')),
    );
    _logSink = LogFileSink()..start();
  }

  /// 初始化依赖。
  Future<void> _bootstrap() async {
    try {
      // ① 目录布局（核心层纯 Dart，根目录由平台层注入）
      final Directory root = await getApplicationSupportDirectory();
      StoragePaths.configure(root.path);
      await StoragePaths.ensureLayout();

      // ② 存储层
      await PrefsManager.instance.init();
      await DatabaseManager.instance.database; // 触发建库/迁移

      // ②' 皮肤（A-03：读契约键 → 主题工厂据此构建四皮肤）
      _skinController = VboxSkinController();
      await _skinController.load(PrefsManager.instance);

      // ②'' 形态（A-05：读契约键 `app_ui_form_override` → 用户显示模式覆盖；
      //      平台通道三重判定 TV / 触屏；桌面端走编译期常量兜底，不触碰通道）
      _uiFormController = UiFormController();
      final UiFormOverride formOverride = UiFormOverride.fromId(
        await PrefsManager.instance.uiFormOverride(),
      );
      await _uiFormController.resolveWithBridge(
        MethodChannelSystemBridge(),
        override: formOverride,
      );

      // ②''' 福利门控（A8：读契约键 `app_welfare_*` → 底栏「福利」Tab 显隐）
      _welfareController = WelfareController();
      await _welfareController.load(PrefsManager.instance);

      // ②'''' 本地账号会话（I-02：读 SQLite `settings` 表 → 个人中心登录态）
      _sessionController = SessionController();
      await _sessionController.load();

      // ②''''' 福利平台配置（H-01：消费 `fuli_remote_source_*` +
      //        `remote_default_manifest_url`；福利页进入时 bootstrap() 恢复缓存并后台刷新）
      _welfarePlatformController = WelfarePlatformController();

      // ②'''''' 福利代理 / 自定义域名（H-07：预加载共享实例，
      //        服务层 `allHosts` / `applyProxyIfNeeded` 与设置页即时消费）
      await WelfareProxyStore.shared.load();
      await WelfareDomainStore.shared.load();
      // Fuli-S1：注册原生福利平台服务（对齐 iOS makeFuliBaseDestination 的 key）。
      registerNativeFuliServices();

      // ②''''''' 下载管理器（G-02：全局单例；存储走 `download` 表，目录走
      //        `StoragePaths.downloadDir`，依赖已在 ①/② 就绪）。
      //        地址解析链：直链直接命中；网盘记录（sourceType=='cloud'，入队时
      //        不解析——分享链定位 token 有时效性）委托 [CloudDownloadUrlResolver]
      //        在执行时取链，对齐 iOS `DownloadManager.resolveCloudDriveURL`
      //        （DownloadManager.swift L183-L188 / L238-L256）。
      _downloadManager = DownloadManager(
        urlResolver: DefaultDownloadUrlResolver(
          delegate: CloudDownloadUrlResolver(),
        ),
      );

      // ②'''''''' 推送播放（G-03：启动恢复 `push_play_items_v1` 契约键；
      //        与页面自调 `load()` 幂等，保证数据在进入页面前置就绪）
      await PushPlayStore.shared.load();

      // ②''''''''''' TG 搜索配置（G-04：启动恢复 `tg_search_*` 三契约键——
      //         代理地址 / 频道来源 / 自定义频道，供设置页与蜘蛛注入消费）
      await TGSearchConfigStore.shared.load();

      // ②''''''''''' 订阅配置（G-07：启动恢复 `subscribed_config_urls` /
      //         `active_subscription_index` / `cached_subscribe_config` 三契约键）
      await SubscribeConfigStore.shared.load();

      // S-设2/S-设3：占源并列搜索（来源=激活订阅配置的 type==2 站点）
      // + 腾讯视频原生蜘蛛（搜索附加结果源 + 详情原生解析）。
      _zhanyuanSearchUseCases =
          ZhanyuanSearchUseCases(loadSites: _loadZhanyuanSites);
      _tencentSpider = TencentVideoNativeSpider();

      // ②'''''''''''' TMDB 配置（G-06：启动恢复 `app_enable_tmdb` /
      //         `app_tmdb_proxy_url` / `app_tmdb_use_token` / `app_tmdb_proxy_token`
      //         四契约键；敏感 Token 键经 PrefsManager 路由安全存储）
      await TmdbConfigStore.shared.load();

      // ③ 日志（闸门 + 落盘）
      await _startLogging();
      AppLog.info(_logTag, '启动 v${AppInfo.version}+${AppInfo.buildNumber}');

      // ④ 数据层仓储 → 领域层用例
      // A2：网络可达性探针（平台层实现），注入全部 HTTP 客户端做离线短路。
      final ConnectivityNetworkInfo networkInfo = ConnectivityNetworkInfo();
      _favoriteUseCases = FavoriteUseCases(FavoriteRepositoryImpl());
      _historyUseCases = HistoryUseCases(HistoryRepositoryImpl());
      _searchHistoryUseCases = SearchHistoryUseCases(SearchHistoryRepositoryImpl());
      _subscriptionUseCases = SubscriptionUseCases(SubscriptionRepositoryImpl());
      // 远程源通道（清单 / 版本探测 / 6 合 1 聚合）：仅此通道放宽 TLS 校验。
      // 理由见 [HttpClient.allowBadCertificate]：Dart 走内置根证书链且不补齐
      // 中间证书，而 iOS `NSURLSession` 走系统信任库会自动补链 —— 同一地址在
      // iOS 可达、桌面端却报 `unable to get local issuer certificate`（用户实测）。
      // 该开关对齐的是 iOS 的**可达性**而非其实现，不作为全局缺省。
      // 超时 / 重试对齐 iOS `fetchData`（RemoteSourceConfigManager.swift L755）：
      // 单请求 15s、**不做单点重试**（代理降级链本身就是重试），否则坏网络下
      // 「同步中」胶囊会因 30s×3 次重试×多候选而挂起 10 分钟以上才到终态。
      final HttpClient remoteSourceClient = HttpClient(
        networkInfo: networkInfo,
        allowBadCertificate: true,
        maxRetries: 0,
        receiveTimeout: const Duration(seconds: 15),
      );
      final RemoteManifestDatasource remoteManifestDatasource =
          RemoteManifestDatasource(client: remoteSourceClient);
      _remoteSourceUseCases = RemoteSourceUseCases(
        RemoteSourceRepositoryImpl(datasource: remoteManifestDatasource),
      );
      _allSourcesDatasource = AllSourcesDatasource(client: remoteSourceClient);
      // JS/Python 蜘蛛脚本本地缓存（对齐 iOS `downloadAndCacheSpiderJS` +
      // `cachedSpiderJSContent`）：同步时批量落盘、运行时 cache-first 读取。
      // 下载通道复用远程源专用 client（放宽 TLS + GitHub 代理降级链）。
      _spiderScriptCache = SpiderScriptCache(
        fetch: (Uri url) async {
          for (final String candidate
              in RemoteSourceStrategy.candidates(url.toString())) {
            try {
              final HttpClientResponse res =
                  await remoteSourceClient.get(Uri.parse(candidate));
              if (res.isOk && res.text.isNotEmpty) return res.text;
            } catch (_) {
              continue;
            }
          }
          return null;
        },
      );
      // 远程源编排器（对齐 iOS `RemoteSourceConfigManager.shared`）：启动时
      // 按官方状态机（开关 → 空地址 → 首同步 / App 升级 / force → 版本探测 →
      // 降级 TTL）决定是否全量拉取，并把 `loadState` 暴露给首页胶囊与设置页。
      _remoteSourceConfigManager = RemoteSourceConfigManager(
        manifestDatasource: remoteManifestDatasource,
        allSourcesDatasource: _allSourcesDatasource,
        repository:
            RemoteSourceRepositoryImpl(datasource: remoteManifestDatasource),
        probeClient: remoteSourceClient,
        // ND-03：lx 插件远程缓存（对齐 iOS P1-A6）——复用远程源专用通道
        // （放宽 TLS，与 all_sources 同源可达），落盘 Node lx 插件目录。
        lxPluginSyncer: LxPluginSyncer(
          fetch: (Uri url) async =>
              (await remoteSourceClient.get(url)).rawBytes,
          pluginsDirPath: () => NodeRuntimeManager.instance.lxPluginsDirPath,
        ),
        // JS/Python 蜘蛛脚本本地缓存（对齐 iOS `syncNow` 步骤 4）：
        // 同步完成后批量下载脚本到本地，运行时 cache-first 读取。
        spiderScriptCache: _spiderScriptCache,
      );
      // 注册全局单例（对齐 iOS `RemoteSourceConfigManager.shared`）：首页胶囊
      // 与设置页经 `shared` 订阅 `loadState` / 触发手动刷新，无需 Provider 传递。
      RemoteSourceConfigManager.install(_remoteSourceConfigManager);
      // CMS 链路专用 client（对齐 iOS `tryFetchJSON`/`fetchSingleSourceCategoryContent`
      // 的请求形态，SpiderManager.swift L2105-L2107）：UA 极简 `Mozilla/5.0`
      // （网盘类 CMS 按 UA 差别响应，Chrome 移动 UA 会得错误页）、超时 10s、
      // 单次请求不重试（iOS URLSession 同语义）。
      _cmsDatasource = CmsV10Datasource(
        client: HttpClient(
          networkInfo: networkInfo,
          userAgent: 'Mozilla/5.0',
          receiveTimeout: const Duration(seconds: 10),
          maxRetries: 0,
        ),
      );
      // Wave D：源治理（兜底开关 / 自定义切片源 / 自定义解析器 / 站源启停）；
      // 复用契约键 `fallback_enabled` / `custom_fallback_sites` / `user_parsers`，
      // 不新增契约；存储为 `ChangeNotifier` 单例（设置页即时刷新）。
      final HttpClient governanceClient = HttpClient(networkInfo: networkInfo);
      _sourceGovernanceUseCases = SourceGovernanceUseCases(
        loadAllSources: _loadAllSources,
        loadAllZhanyuanSites: _loadZhanyuanSites,
        cmsDatasource: _cmsDatasource,
        httpClient: governanceClient,
      );
      await SourceGovernanceStore.instance.load();
      _detailPlaybackUseCases = DetailPlaybackUseCases(
        loadAllSources: _loadAllSources,
        cmsDatasource: _cmsDatasource,
        scriptBaseUrl: () => _allSourcesUrl,
        // 脚本 cache-first：详情/播放链路与首页/分类链路共用同一缓存实例，
        // 对齐 iOS 端 `SpiderManager.loadSingleRemoteSpider` 的 cache-first + ext。
        spiderScriptCache: _spiderScriptCache,
        tencentSpider: _tencentSpider,
        // O-源2：非直链播放地址在返回前尝试解析器（远程默认 + 自定义）。
        customParser: _sourceGovernanceUseCases.resolveWithParsers,
        // O-源2+：内置网页嗅探兜底（对齐 iOS「网页播放 URL → WebView 嗅探
        // 提取直链」）：自定义解析器未命中时，静态抓页 / WebView 渲染提取
        // 真实 m3u8/mp4 直链再起播（修复网页 URL 直喂内核报容器不支持）。
        webPageSniffer:
            WebPageSniffer(webview: InAppWebViewBridge()).extractMediaUrl,
        // O-源3：兜底切片源合成 key 的站点回退解析。
        fallbackSiteResolver: _sourceGovernanceUseCases.findFallbackSite,
        // 网盘详情页解析（对齐 iOS `resolveCloudPlay` 的 `URLSession.shared`：
        // 系统默认信任链、`timeoutInterval = 10`、单次请求不重试）。
        cloudHttpClient: HttpClient(
          networkInfo: networkInfo,
          maxRetries: 0,
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      _contentBrowseUseCases = ContentBrowseUseCases(
        loadAllSources: _loadAllSources,
        cmsDatasource: _cmsDatasource,
        scriptBaseUrl: () => _allSourcesUrl,
        // 脚本 cache-first：与同步落盘共用同一缓存实例。
        spiderScriptCache: _spiderScriptCache,
        // Node 承载源调用前等常驻宿主就绪（对齐 iOS
        // `waitForNodeReadyIfNeeded`，SpiderManager.swift L2136）：
        // 轮询 NodeRuntimeManager 就绪位，上限 5s；node-failed 立即放行
        //（超时放行由调用侧失败兜底）。
        waitNodeReady: () async {
          // 对齐 iOS `waitForNodeReadyIfNeeded`（SpiderManager.swift L2136）语义：
          // Node 承载源调用前等待宿主就绪；**启动失败（node-failed）立即返回**
          // ——iOS 进程内引擎秒级就绪，宿主已明确失败时继续轮询只会让每次
          // 切源都白等（原 100×200ms=20s 无差别等待是「切源没反应」主因之一）。
          // 上限 50×100ms=5s：覆盖本机正常启动耗时；崩溃自愈由
          // NodeRuntimeManager 崩溃重启 + statusStream 驱动，下次请求自然恢复。
          const Duration step = Duration(milliseconds: 100);
          for (int i = 0; i < 50; i++) {
            final NodeRuntimeStatus phase = NodeRuntimeManager.instance.status;
            if (phase == NodeRuntimeStatus.failed) return;
            if (NodeRuntimeManager.instance.isSystemReady) return;
            await Future<void>.delayed(step);
          }
        },
      );
      // S-设4：网盘源搜索（对齐 iOS `SpiderManager.cloudSearch`，搜索页并发并入）。
      _cloudSearchUseCases = CloudSearchUseCases(
        client: HttpClient(networkInfo: networkInfo),
        loadAllSources: _loadAllSources,
      );
      // A9：首页默认内容 = 豆瓣推荐。
      _doubanUseCases = DoubanUseCases();
      // G-06：TMDB 详情增强（默认消费共享配置实例）。
      _tmdbUseCases = TmdbUseCases();

      AppLog.info(_logTag, '初始化完成');
      if (mounted) {
        setState(() => _initialized = true);
      }
    } catch (e) {
      AppLog.error(_logTag, '初始化失败', error: e);
      if (mounted) {
        setState(() => _initError = e);
      }
    }
  }

  /// 启动编排（批次 L · L-壳2）。
  ///
  /// 顺序对齐 iOS 冷启动：**会话恢复 → 远程源同步 → 引擎就绪**；
  /// 由 [StartupOrchestrator] 逐步收敛，**单步失败降级不阻断**（仅记日志），
  /// 编排结束后照常进入首页（启动页门控在 [StartupGate]）。
  Future<void> _runStartup() async {
    const StartupOrchestrator orchestrator = StartupOrchestrator(logTag: _logTag);
    await orchestrator.run(<StartupTask>[
      // ① 会话恢复：音乐播放队列存档（对齐 iOS `AudioPlayerManager.restoreQueue`）。
      StartupTask('会话恢复', () async {
        await MusicPlayerController.instance.restore();
      }),
      // ② 远程源同步：走配置管理器状态机（对齐 iOS `SpiderManager.initialize`
      //    调用的 `RemoteSourceConfigManager.shared.syncIfNeeded()`）——开关 / 空地址
      //    门控 → 首同步 / App 升级 / force → 版本探测（未变不进全量）→ 降级 TTL。
      //    失败由编排器收敛（胶囊显示失败态），不阻断启动。
      StartupTask('远程源同步', () async {
        final RemoteSourceSyncResult result =
            await _remoteSourceConfigManager.syncIfNeeded();
        if (result.action == RemoteSourceSyncAction.syncFailed ||
            result.action == RemoteSourceSyncAction.incompatibleMinAppVersion) {
          throw StateError(result.error ?? '远程源同步失败');
        }
      }),
      // ③ 引擎就绪：D6 JS 引擎探测（JSC 主 / QuickJS 降级位，降级可观测）。
      StartupTask('引擎就绪', () async {
        final bool jsc = DartFfiJsCoreBridge().isAvailable;
        final bool quickjs = DartFfiQuickJsBridge().isAvailable;
        AppLog.info(
          _logTag,
          'JS 引擎就绪：JSC=${jsc ? '可用' : '不可用'}，QuickJS=${quickjs ? '可用' : '不可用'}',
        );
        if (!jsc && !quickjs) {
          throw StateError('JS 引擎均不可用（libvbox_jsc / libvbox_quickjs 均缺失）');
        }
      }),
      // ④ Node 常驻系统（L-05-3 · ND-01）：拉起 Node 宿主（Android 走 nodejs-mobile
      //    进程内引擎，桌面走 node 子进程），**不阻塞首屏**（对齐 iOS 在后台 Task 拉起）。
      //    就绪后经 statusStream 触发本机凭据自动推送（NC-清5 / iOS `handleNodeStatus`）。
      //    失败降级为 `node-failed`（Node 站点暂不可用），不阻断启动。
      StartupTask('Node 常驻系统', () async {
        final NodeRuntimeManager node = NodeRuntimeManager.instance;
        _nodeStatusSub ??= node.statusStream.listen((NodeRuntimeStatus status) {
          if (status != NodeRuntimeStatus.ready) return;
          unawaited(
            NodeCredentialSyncService(client: LocalNodeCredentialApiClient())
                .onNodeReady()
                .catchError((Object e) {
              AppLog.warn(_logTag, 'Node 就绪凭据自动推送失败：$e');
              return null;
            }),
          );
        });
        // ND-02：先本地内置资源启动，再按缓存的远端地址做可选增量刷新
        //    （对齐 iOS `VBoxApp.init` 读取 `cachedNodeBundleRefreshURL()` /
        //    `cachedNodeBundleVersionURL()` 后传入 `start(...)`；未下发 → null 回退本地）。
        String? bundleRefreshUrl;
        String? bundleVersionUrl;
        try {
          bundleRefreshUrl =
              await RemoteSourceConfigManager.cachedNodeBundleRefreshUrl();
          bundleVersionUrl =
              await RemoteSourceConfigManager.cachedNodeBundleVersionUrl();
        } on Object catch (e) {
          AppLog.warn(_logTag, '读取 Node bundle 远端地址失败（回退本地资源）：$e');
        }
        unawaited(
          node.start(
            bundleRefreshUrl: bundleRefreshUrl,
            bundleVersionUrl: bundleVersionUrl,
          ).catchError((Object e) {
            AppLog.warn(_logTag, 'Node 常驻系统启动失败（降级）：$e');
          }),
        );
      }),
    ]);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 兜底：dispose 时也尝试停止 Node 常驻（正常退出路径）。
    unawaited(_stopNodeRuntime());
    unawaited(_logSink?.stop());
    unawaited(_nodeStatusSub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('初始化失败：$_initError'),
            ),
          ),
        ),
      );
    }
    if (!_initialized) {
      // L-壳1：依赖加载期铺品牌渐变底色（对齐 iOS 原生启动图角色），杜绝冷启动白屏；
      // 初始化完成后由 [StartupGate] 叠加动画闪屏接续（同色，过渡无跳色）。
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: VboxSplashBackdrop(),
      );
    }

    return MultiProvider(
      providers: [
        ChangeNotifierProvider<UiFormController>.value(value: _uiFormController),
        ChangeNotifierProvider<VboxSkinController>.value(value: _skinController),
        ChangeNotifierProvider<WelfareController>.value(value: _welfareController),
        ChangeNotifierProvider<WelfarePlatformController>.value(
          value: _welfarePlatformController,
        ),
        ChangeNotifierProvider<SessionController>.value(value: _sessionController),
        ChangeNotifierProvider<DownloadManager>.value(value: _downloadManager),
        ChangeNotifierProvider<PushPlayStore>.value(value: PushPlayStore.shared),
        ChangeNotifierProvider<TGSearchConfigStore>.value(
          value: TGSearchConfigStore.shared,
        ),
        ChangeNotifierProvider<SubscribeConfigStore>.value(
          value: SubscribeConfigStore.shared,
        ),
        ChangeNotifierProvider<TmdbConfigStore>.value(
          value: TmdbConfigStore.shared,
        ),
        // Wave D：源治理（设置页切片资源分区即时刷新）。
        ChangeNotifierProvider<SourceGovernanceStore>.value(
          value: SourceGovernanceStore.instance,
        ),
        Provider<FavoriteUseCases>.value(value: _favoriteUseCases),
        Provider<HistoryUseCases>.value(value: _historyUseCases),
        Provider<SubscriptionUseCases>.value(value: _subscriptionUseCases),
        Provider<RemoteSourceUseCases>.value(value: _remoteSourceUseCases),
        Provider<DetailPlaybackUseCases>.value(value: _detailPlaybackUseCases),
        Provider<ContentBrowseUseCases>.value(value: _contentBrowseUseCases),
        Provider<SearchHistoryUseCases>.value(value: _searchHistoryUseCases),
        Provider<ZhanyuanSearchUseCases>.value(value: _zhanyuanSearchUseCases),
        // Wave D：源治理用例（搜索页兜底源搜索 / 设置页站源与切片源管理）。
        Provider<SourceGovernanceUseCases>.value(
          value: _sourceGovernanceUseCases,
        ),
        Provider<TencentVideoNativeSpider>.value(value: _tencentSpider),
        // S-设4：网盘源搜索（搜索页与 api/spider/站源并列并发）。
        Provider<CloudSearchUseCases>.value(value: _cloudSearchUseCases),
        Provider<DoubanUseCases>.value(value: _doubanUseCases),
        Provider<TmdbUseCases>.value(value: _tmdbUseCases),
      ],
      child: _RootRouter(onStartup: _runStartup),
    );
  }
}

/// 应用根路由。
///
/// A-08「页面树收敛」后：**单一页树** [HomeShellPage]（内部按 `UiForm` 产出双排布），
/// 本路由只负责主题装配；形态判定（竖/横 + 输入模态）下移到页树内部。
class _RootRouter extends StatelessWidget {
  const _RootRouter({required this.onStartup});

  /// 启动编排回调（L-壳2；由 [StartupGate] 挂载后触发一次）。
  final Future<void> Function() onStartup;

  @override
  Widget build(BuildContext context) {
    final VboxSkinController skin = context.watch<VboxSkinController>();
    // A-03：皮肤 → 主题。`themeMode` 由 iOS 等价口径 `preferredColorScheme` 决定：
    //   非 null → 强制该亮/暗；null → 跟随系统（themeMode.system）。
    final Brightness? forced =
        VboxTheme.preferredBrightness(skin.skin, skin.followsSystem);
    final ThemeMode themeMode = switch (forced) {
      Brightness.light => ThemeMode.light,
      Brightness.dark => ThemeMode.dark,
      null => ThemeMode.system,
    };
    return MaterialApp(
      title: 'vbox',
      theme: VboxTheme.build(skin: skin.skin, brightness: Brightness.light),
      darkTheme: VboxTheme.build(skin: skin.skin, brightness: Brightness.dark),
      themeMode: themeMode,
      // A5：全端统一 iOS 回弹滚动（BouncingScrollPhysics + 无辉光过卷）。
      scrollBehavior: const VboxScrollBehavior(),
      // L-壳1/L-壳2：品牌闪屏门控包裹首页外壳（3.5s 最短展示 + 数据就绪 + 10s 兜底）。
      home: StartupGate(
        onStartup: onStartup,
        child: const HomeShellPage(),
      ),
    );
  }
}