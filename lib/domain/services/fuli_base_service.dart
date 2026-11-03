/// 领域层：通用福利平台服务基类 + 注册表（批次 H · H-02 / H-03 / H-07）。
///
/// 唯一真相源：iOS `vbox/Services/FuliPlatformService.swift`
///   · `FuliPlatformService` 协议（L24-L60）：平台标识 / 域名 / 抓取契约；
///   · `FuliBaseService` 基类（L201-L236）：`@Published currentHost` /
///     `isHostReady` + 默认视频内容类型 + 图片防盗链默认值 + 抓取默认实现；
///   · H-07 域名 / 代理接线（L70-L96）：`allHosts`（自定义域名在前 + 默认域名）、
///     `isProxyEnabled`、`applyProxyIfNeeded`（平台开关开启 → 代理 URL 构建）。
///
/// 移植口径：
///   · 平台标识：`platformKey` / `platformName` / `defaultHosts`；
///   · 域名就绪：`currentHost` / `isHostReady` + `reprobe()` / `resetDomain()`；
///   · 内容类型：`contentCategory`（video / comic，决定列表点击进播放还是漫画）；
///   · 图片防盗链：`imageReferer` / `imageSSLBypass`；
///   · 抓取契约（H-03 落地）：`fetchHomeContent` / `fetchCategoryContent` /
///     `fetchDetail` / `fetchSearch` / `fetchPlayerURL` 默认实现
///     （对齐 iOS `FuliBaseService` L222-L236，子类覆写）；
///   · H-07 域名 / 代理：`allHosts` / `isProxyEnabled` / `applyProxyIfNeeded`
///     消费 [WelfareDomainStore.shared] / [WelfareProxyStore.shared]
///     （对齐 iOS `WelfareDomainStore.shared` / `WelfareProxyStore.shared`）。
library;

import '../../data/datasources/local/welfare_domain_store.dart';
import '../../data/datasources/local/welfare_proxy_store.dart';
import '../entities/welfare/fuli_models.dart';

/// 福利内容类型（对齐 iOS `FuliContentCategory`）。
enum FuliContentCategory {
  /// 视频（列表点击进播放页）。
  video,

  /// 漫画（列表点击进漫画浏览器）。
  comic,
}

/// 通用福利平台服务基类（`fuli_base` 路由的服务抽象）。
///
/// 新增 `fuli_base` 平台：继承本类实现域名探测后注册到
/// [FuliBaseServiceRegistry.shared]，路由即可按 `platformKey` 命中。
abstract class FuliBaseService {
  /// 构造。
  FuliBaseService({
    required this.platformKey,
    required this.platformName,
    required this.defaultHosts,
  });

  /// 平台唯一 key（路由注册与观看记录定位的主键）。
  final String platformKey;

  /// 平台显示名（与远程配置 `name` 一致）。
  final String platformName;

  /// 默认域名列表（按顺序回退探测）。
  final List<String> defaultHosts;

  /// 当前选中的可用域名（未就绪时为空）。
  String get currentHost;

  /// 域名是否已就绪（探测成功）。
  bool get isHostReady;

  /// 内容类型（默认视频；漫画子类覆写）。
  FuliContentCategory get contentCategory => FuliContentCategory.video;

  /// 封面图防盗链 Referer（默认 `null`，仅需要的远程源覆写）。
  String? get imageReferer => null;

  /// 封面图是否绕过 SSL（默认 `false`）。
  bool get imageSSLBypass => false;

  /// 首个默认域名（探测起点 / 兜底显示）。
  String get primaryHost =>
      defaultHosts.isEmpty ? '' : defaultHosts.first;

  /// 全部域名（自定义在前 + 默认在后，按顺序轮询；对齐 iOS `allHosts`）。
  ///
  /// 播放 / 探测时优先尝试自定义域名，再回退默认域名。
  List<String> get allHosts {
    final List<String> customs = WelfareDomainStore.shared.domains(platformName);
    return <String>[...customs, ...defaultHosts];
  }

  /// 当前平台是否启用代理（代理无效一律 false；对齐 iOS `isProxyEnabled`）。
  bool get isProxyEnabled =>
      WelfareProxyStore.shared.isProxyEnabled(platformName);

  /// 对 URL 应用代理（平台开关开启 → 代理 URL，否则原样；对齐 iOS `applyProxyIfNeeded`）。
  String applyProxyIfNeeded(String url) =>
      WelfareProxyStore.shared.proxiedURL(url, platformName);

  /// 重新探测可用域名（对齐 iOS `reprobe()`）。
  void reprobe();

  /// 清空自定义域名并重新探测（对齐 iOS `resetDomain()`）。
  void resetDomain();

  // ─────────────── 抓取契约（H-03，对齐 iOS `FuliBaseService` L222-L236）───────────────

  /// 解析首页分类 + 推荐视频（默认空结果）。
  Future<FuliHomeResult> fetchHomeContent() async => FuliHomeResult.empty;

  /// 解析分类 / 子分类视频列表（默认空结果）。
  Future<FuliCategoryResult> fetchCategoryContent({
    required FuliCategory category,
    FuliCategory? subCategory,
    required int page,
  }) async =>
      FuliCategoryResult(videos: <FuliVideo>[], page: page, hasMore: false);

  /// 解析视频详情（含剧集；默认空详情）。
  Future<FuliDetail> fetchDetail(String vodId) async => FuliDetail(
        vodId: vodId,
        vodName: '',
        vodPic: '',
        vodContent: null,
        playFrom: platformName,
        episodes: <FuliEpisode>[],
      );

  /// 搜索（默认空结果）。
  Future<FuliSearchResult> fetchSearch({
    required String keyword,
    required int page,
  }) async =>
      FuliSearchResult(videos: <FuliVideo>[], page: page, hasMore: false);

  /// 获取播放地址（默认按 URL 后缀判定 parse，对齐 iOS 基类）。
  Future<FuliPlayerResult> fetchPlayerURL(FuliEpisode episode) async {
    final String url = episode.url;
    final bool direct = url.contains('.m3u8') ||
        url.contains('.mp4') ||
        url.contains('.ts');
    return FuliPlayerResult(
      url: url,
      headers: const <String, String>{},
      parse: direct ? 0 : 1,
    );
  }
}

/// 福利平台服务注册表（`fuli_base` 路由按 `platformKey` 解析服务实例）。
///
/// 对齐 iOS `WelfarePlatformRouter.makeFuliBaseDestination`：按 `platformKey`
/// 映射到具体子类；**未注册的 key 不给兜底**，由路由给出明确「未支持」结果。
class FuliBaseServiceRegistry {
  /// 构造（可注入初始服务）。
  FuliBaseServiceRegistry([
    Iterable<FuliBaseService> initial = const <FuliBaseService>[],
  ]) {
    for (final FuliBaseService service in initial) {
      register(service);
    }
  }

  /// 全局共享实例（应用装配时注册原生平台服务）。
  static final FuliBaseServiceRegistry shared = FuliBaseServiceRegistry();

  final Map<String, FuliBaseService> _byKey = <String, FuliBaseService>{};

  /// 注册服务（`platformKey` 为空则不注册，对齐 iOS 默认 `platformKey = ""`）。
  void register(FuliBaseService service) {
    final String key = service.platformKey.trim();
    if (key.isEmpty) return;
    _byKey[key] = service;
  }

  /// 注销服务（返回是否命中）。
  bool unregister(String platformKey) => _byKey.remove(platformKey) != null;

  /// 按 `platformKey` 取服务（未注册返回 `null`）。
  FuliBaseService? serviceFor(String platformKey) => _byKey[platformKey];

  /// 已注册服务数。
  int get count => _byKey.length;

  /// 全部已注册服务。
  Iterable<FuliBaseService> get all => _byKey.values;

  /// 清空注册表（装配重置 / 测试用）。
  void clear() => _byKey.clear();
}