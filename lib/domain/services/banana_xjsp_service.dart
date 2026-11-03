/// 领域层：香蕉秀 XJSP 福利平台服务（UI-C1a，原生专用页）。
///
/// 唯一真相源：iOS `vbox/Services/YBoxService2.swift`（香蕉秀段 L270-L559）
///   · API 网关（L141）：固定 `https://zfvwi8.ipajx0.cc`（抓包还原，不做导航页探测）；
///   · 请求头（L177-L180）：`x-version: 5.2.0` / `x-channel: xj2` /
///     `x-cookie-auth: <32 位 hex>`；UA 为 `Dart/3.4 (dart:io)`（L158）；
///   · 响应格式（L283）：`{"retcode":0,"errmsg":"…","data":{…}}`，gzip 压缩；
///   · 端点：
///       `GET /vod/listing-0-0-0-0-0-0-0-0-0-1`           → `data.categories`（11 类）
///       `GET /vod/listing-{cateId}-0×8-{page}`           → `data.vodrows`（16 条/页）
///       `GET /special/listing-0-0-{page}`                → `data.rows` + `data.actorrows`
///       `GET /special/detail/{spId}-{page}`              → `data.vodrows`
///       `GET /minivod/reqlist?page={page}`               → `data.rows`（10 条/页）
///       `GET /vod/reqplay/{vodId}`                       → `data.httpurl`（长视频）
///       `GET /minivod/reqplay/{vodId}`                   → `data.httpurl`（短视频）
///   · 兜底分类（L307-L319）：接口失败时回退 9 个硬编码分类；
///   · 播放地址（L447-L489）：取 `httpurl`，回退 `httpurls[0].httpurl`；
///     `retcode == 5`（VIP）→ 由 `preview_url` 重建完整 m3u8（L493-L538）；
///     统一 HTTP → HTTPS 升级（L484-L489）；
///   · 详情：iOS 无「详情接口」——`YBoxBananaPlayerView` 直接用列表页带入的
///     封面/标题 + `reqplay` 单地址播放（L1071-L1209）。
///
/// 页面侧：`vbox/Views/WelfareSubViews.swift` `YBoxXjspMainView`（L16-L56，
/// 「首页 / 短视频 / 演员」三 Tab）。
///
/// 移植口径与差异登记（如实）：
///   · **域名就绪**：iOS 网关写死、无探测；Flutter 接入统一福利域名体系
///     （`allHosts` = 自定义域名 + 默认网关），覆写 [probeHosts] 以
///     `GET /vod/listing-0…-1` 的 `retcode == 0` 判定可达 —— 这样 W-福6 的
///     「自定义域名 / 代理变更即生效」对本平台同样成立（超集，不改变默认行为）；
///   · **`vodId` 约定**：短视频以 `mini:` 前缀标记（`miniVodPrefix`），
///     决定走 `/minivod/reqplay`；长视频为裸 `vodId` 走 `/vod/reqplay`。
///     这是把 iOS「长短视频两个 Tab 各持一张播放路径」收敛为统一
///     `FuliEpisode` 契约的适配（有意的接口适配）；
///   · **VIP 回退所需的 `preview_url`**：iOS 在列表页持有（同视图内传递）；
///     Flutter 播放链路跨页（列表 → 播放中转页），故在解析列表时按
///     `vodId` 记入服务侧 [previewUrls] 缓存，`reqplay` 返回 `retcode == 5`
///     时按同一算法重建完整 m3u8；
///   · **详情**：返回单集占位（`正片`），播放地址在 [fetchPlayerURL] 内
///     按 `vodId` 现取（对齐 iOS `loadPlayURL`）；
///   · 抓取契约：`fetchHomeContent` 只回分类（视频网格由
///     [fetchCategoryContent] 独立分页，与每日大乱斗同口径）；
///   · 未移植：iOS `BananaVideoFilter` 的 8 维筛选（页面亦未暴露，全 0）。
library;

import 'dart:async';
import 'dart:convert';

import '../../platform/spider/spider_http_bridge.dart';
import '../entities/welfare/banana_mini_video.dart';
import '../entities/welfare/fuli_models.dart';
import 'native_fuli_services.dart';

/// 香蕉秀专题 / 演员条目（对齐 iOS `YBoxBananaSpecial`）。
class BananaXjspSpecial {
  /// 构造。
  const BananaXjspSpecial({
    required this.spId,
    required this.name,
    required this.cover,
    required this.itemCount,
  });

  /// 专题 / 演员 ID。
  final String spId;

  /// 名称。
  final String name;

  /// 封面。
  final String cover;

  /// 作品数（角标「N部」）。
  final int itemCount;
}

/// 香蕉秀 XJSP 福利平台服务（`ybox_xiangjiao`，`ybox_special` 专用页驱动）。
class BananaXjspFuliService extends ProbedFuliService {
  /// 构造（[bridge] 供测试注入假传输）。
  BananaXjspFuliService({super.bridge})
      : super(
          platformKey: 'ybox_xiangjiao',
          platformName: '香蕉秀',
          // iOS 写死网关（`YBoxService2.apiGateway`）；置于默认域名末位，
          // 自定义域名（W-福6）优先。
          defaultHosts: const <String>['https://zfvwi8.ipajx0.cc'],
        );

  /// 短视频 `vodId` 前缀（决定 `/minivod/reqplay` 端点）。
  static const String miniVodPrefix = 'mini:';

  /// 平台显示名（对齐 iOS `YBoxPlatform2.name`，播放页备注 `[福利]香蕉秀`）。
  String get siteName => platformName;

  /// 设备 UA（对齐 iOS `YBoxService2.session` 的 `Dart/3.4 (dart:io)`）。
  static const String _ua = 'Dart/3.4 (dart:io)';

  /// API 版本头（对齐 iOS L177）。
  static const String _apiVersion = '5.2.0';

  /// 渠道头（对齐 iOS L178）。
  static const String _apiChannel = 'xj2';

  /// 认证 token（32 位 hex；对齐 iOS `cookieAuth` L144-L152 的算法）。
  static final String _cookieAuth = _buildCookieAuth();

  /// 分类拉取路径（兼作域名探测探针）。
  static const String _categoryPath = '/vod/listing-0-0-0-0-0-0-0-0-0-1';

  /// 实例缓存（对齐 iOS `YBoxService2.shared`；应用内单例）。
  static final Map<String, BananaXjspFuliService> _cache =
      <String, BananaXjspFuliService>{};

  /// 取（或创建）共享实例。
  static BananaXjspFuliService serviceFor({SpiderHttpBridge? bridge}) =>
      _cache.putIfAbsent(
        'ybox_xiangjiao',
        () => BananaXjspFuliService(bridge: bridge),
      );

  /// 清空实例缓存（装配重置 / 测试隔离用）。
  static void clearCache() => _cache.clear();

  /// `vodId` → `preview_url`（VIP `retcode == 5` 时重建完整 m3u8 用）。
  final Map<String, String> previewUrls = <String, String>{};

  // ─────────────── 域名就绪 ───────────────

  String _probedHost = '';
  bool _ready = false;

  @override
  String get currentHost => _probedHost.isEmpty ? primaryHost : _probedHost;

  @override
  bool get isHostReady => _ready;

  /// 逐个候选域名探测（以分类接口 `retcode == 0` 判定可达）。
  @override
  Future<void> probeHosts() async {
    for (final String host in allHosts) {
      final String base = _stripSlash(host.trim());
      if (base.isEmpty) continue;
      _probedHost = base;
      final Map<String, Object?>? json = await _getJson(_categoryPath);
      if (_intOf(json?['retcode']) == 0) {
        _ready = true;
        return;
      }
    }
    _probedHost = '';
    _ready = false;
  }

  @override
  void reprobe() {
    _probedHost = '';
    _ready = false;
    unawaited(probeHosts());
  }

  @override
  void resetDomain() {
    _probedHost = '';
    _ready = false;
    super.resetDomain();
  }

  /// 确保域名已探测。
  Future<void> ensureHostReady() async {
    if (isHostReady) return;
    await probeHosts();
  }

  // ─────────────── 抓取契约 ───────────────

  /// 首页：分类导航（对齐 iOS `fetchBananaCategories`；接口失败回退硬编码
  /// 分类）。推荐视频由 [fetchCategoryContent] 独立分页，与每日大乱斗同口径。
  @override
  Future<FuliHomeResult> fetchHomeContent() async {
    await ensureHostReady();
    final List<FuliCategory> categories = await fetchCategories();
    return FuliHomeResult(
      categories: categories,
      videos: const <FuliVideo>[],
    );
  }

  /// 分类视频列表（分页；对齐 iOS `fetchBananaVideos`，16 条/页）。
  @override
  Future<FuliCategoryResult> fetchCategoryContent({
    required FuliCategory category,
    FuliCategory? subCategory,
    required int page,
  }) async {
    await ensureHostReady();
    final String cateId = (subCategory ?? category).typeId;
    final List<FuliVideo> videos = await fetchVideos(cateId: cateId, page: page);
    return FuliCategoryResult(
      videos: videos,
      page: page,
      // 对齐 iOS `hasMore = result.count >= 16`。
      hasMore: videos.length >= 16,
    );
  }

  /// 详情：iOS 无详情接口 → 单集占位，播放地址在 [fetchPlayerURL] 现取。
  @override
  Future<FuliDetail> fetchDetail(String vodId) async => FuliDetail(
        vodId: vodId,
        vodName: '',
        vodPic: '',
        vodContent: null,
        playFrom: platformName,
        episodes: <FuliEpisode>[
          FuliEpisode(name: '正片', url: vodId),
        ],
      );

  /// 播放地址（对齐 iOS `fetchBananaPlayURL`：`httpurl` → `httpurls[0]`，
  /// `retcode == 5` 走 `preview_url` 重建；统一 HTTP → HTTPS）。
  @override
  Future<FuliPlayerResult> fetchPlayerURL(FuliEpisode episode) async {
    final String vodId = episode.url;
    final String? url = await fetchPlayUrl(vodId);
    if (url == null) {
      return const FuliPlayerResult(
        url: '',
        headers: <String, String>{},
        parse: 0,
      );
    }
    return FuliPlayerResult(
      url: url,
      // 短视频 CDN 校验 Referer/UA（对齐 iOS `startPlayer` L733-L740）；
      // 长视频对齐 iOS `YBoxBananaPlayerView` → `VodItem`（不额外注入头）。
      headers: vodId.startsWith(miniVodPrefix)
          ? <String, String>{'Referer': '$currentHost/', 'User-Agent': _ua}
          : const <String, String>{},
      parse: 0,
    );
  }

  // ─────────────── 香蕉秀 API ───────────────

  /// 分类导航（接口失败 / 为空 → 回退硬编码分类）。
  Future<List<FuliCategory>> fetchCategories() async {
    await ensureHostReady();
    final Map<String, Object?>? json = await _getJson(_categoryPath);
    final Object? data = json?['data'];
    if (data is Map<String, Object?>) {
      final Object? cats = data['categories'];
      if (cats is List) {
        final List<FuliCategory> parsed = cats
            .whereType<Map<String, Object?>>()
            .map(_parseCategory)
            .whereType<FuliCategory>()
            .toList(growable: false);
        if (parsed.isNotEmpty) return parsed;
      }
    }
    return defaultCategories;
  }

  /// 分类视频列表（`GET /vod/listing-{cateId}-0×8-{page}`）。
  Future<List<FuliVideo>> fetchVideos({
    required String cateId,
    required int page,
  }) async {
    await ensureHostReady();
    final Map<String, Object?>? json = await _getJson(
      '/vod/listing-$cateId-0-0-0-0-0-0-0-0-$page',
    );
    return _rowsOf(json, 'vodrows').map(_parseVideo).toList(growable: false);
  }

  /// 短视频列表（`GET /minivod/reqlist?page={page}`，10 条/页）。
  ///
  /// 返回对齐 iOS `YBoxBananaMiniVideo` 的 [BananaMiniVideo]（含作者昵称 / 头像）；
  /// 播放端点由调用方以 [miniVodPrefix] 前缀在 `vodId` 上补足。
  Future<List<BananaMiniVideo>> fetchMiniVideos({required int page}) async {
    await ensureHostReady();
    final Map<String, Object?>? json = await _getJson(
      '/minivod/reqlist',
      query: <String, String>{'page': '$page'},
    );
    return _rowsOf(json, 'rows')
        .map(_parseMiniVideo)
        .whereType<BananaMiniVideo>()
        .toList(growable: false);
  }

  /// 演员 / 专题导航（`data.actorrows`，全量导航；对齐 iOS 演员 Tab）。
  Future<List<BananaXjspSpecial>> fetchActors({required int page}) async {
    await ensureHostReady();
    final Map<String, Object?>? json = await _getJson(
      '/special/listing-0-0-$page',
    );
    return _rowsOf(json, 'actorrows')
        .map(_parseSpecial)
        .whereType<BananaXjspSpecial>()
        .toList(growable: false);
  }

  /// 专题 / 演员内视频列表（`GET /special/detail/{spId}-{page}`）。
  Future<List<FuliVideo>> fetchSpecialVideos({
    required String spId,
    required int page,
  }) async {
    await ensureHostReady();
    final Map<String, Object?>? json = await _getJson(
      '/special/detail/$spId-$page',
    );
    return _rowsOf(json, 'vodrows').map(_parseVideo).toList(growable: false);
  }

  /// 播放地址（`mini:` 前缀 → `/minivod/reqplay`，否则 `/vod/reqplay`）。
  ///
  /// 取 `data.httpurl`，回退 `data.httpurls[0].httpurl`；`retcode == 5` 时
  /// 用 [previewUrls] 中的 `preview_url` 重建完整 m3u8；统一升级 HTTPS。
  Future<String?> fetchPlayUrl(String vodId) async {
    final bool mini = vodId.startsWith(miniVodPrefix);
    final String id = mini
        ? vodId.substring(miniVodPrefix.length)
        : vodId;
    if (id.isEmpty) return null;
    await ensureHostReady();

    final String path =
        mini ? '/minivod/reqplay/$id' : '/vod/reqplay/$id';
    final Map<String, Object?>? json = await _getJson(path);
    final int retcode = _intOf(json?['retcode']) ?? -1;

    if (retcode != 0) {
      // VIP（retcode == 5）→ 由 preview_url 重建完整 m3u8。
      final String? preview = previewUrls[id];
      if (retcode == 5 && preview != null && preview.isNotEmpty) {
        final String? rebuilt = await rebuildFullM3U8(preview);
        if (rebuilt != null) return rebuilt;
      }
      return null;
    }

    final Object? data = json?['data'];
    if (data is! Map<String, Object?>) return null;
    final Object? direct = data['httpurl'];
    if (direct is String && direct.isNotEmpty) return sanitizePlayUrl(direct);

    final Object? list = data['httpurls'];
    if (list is List) {
      for (final Object? item in list) {
        if (item is Map<String, Object?>) {
          final Object? url = item['httpurl'];
          if (url is String && url.isNotEmpty) return sanitizePlayUrl(url);
        }
      }
    }
    return null;
  }

  /// HTTP → HTTPS 升级（对齐 iOS `sanitizePlayURL` L484-L489）。
  String sanitizePlayUrl(String raw) => raw.startsWith('http://')
      ? raw.replaceFirst('http://', 'https://')
      : raw;

  /// 由预览 m3u8 重建完整 m3u8（对齐 iOS `rebuildFullM3U8` L493-L538）。
  ///
  /// 算法：预览 m3u8 → 取 `URI="…"` 的 KEY host + 首个 `https://…ts` 的目录 →
  /// `https://{keyHost}{tsDir}/index.m3u8`。
  Future<String?> rebuildFullM3U8(String previewUrl) async {
    try {
      final SpiderHttpResult res = await bridge.request(
        previewUrl,
        options: const SpiderHttpOptions(timeout: Duration(seconds: 20)),
      );
      if (!res.ok) return null;
      final String text = res.content;

      final RegExpMatch? keyMatch =
          RegExp('URI="([^"]+)"').firstMatch(text);
      final RegExpMatch? tsMatch =
          RegExp(r'^https://[^\s]+\.ts', multiLine: true).firstMatch(text);
      if (keyMatch == null || tsMatch == null) return null;

      final String key = keyMatch.group(1) ?? '';
      final String ts = tsMatch.group(0) ?? '';
      final Uri? keyUri = Uri.tryParse(key);
      final Uri? tsUri = Uri.tryParse(ts);
      if (tsUri == null) return null;

      // KEY 为相对路径时回落预览地址的 host（对齐 iOS L523-L529）。
      final String keyHost = (keyUri != null && keyUri.hasScheme
              ? keyUri.host
              : null) ??
          Uri.tryParse(previewUrl)?.host ??
          '';
      if (keyHost.isEmpty) return null;

      final String tsPath = tsUri.path;
      final int slash = tsPath.lastIndexOf('/');
      final String tsDir = slash <= 0 ? '' : tsPath.substring(0, slash);
      return 'https://$keyHost$tsDir/index.m3u8';
    } catch (_) {
      return null;
    }
  }

  // ─────────────── 解析工具 ───────────────

  /// 兜底分类（对齐 iOS `defaultCategories` L307-L319）。
  static const List<FuliCategory> defaultCategories = <FuliCategory>[
    FuliCategory(typeId: '0', typeName: '推荐'),
    FuliCategory(typeId: '9', typeName: '国产精品'),
    FuliCategory(typeId: '7', typeName: '辣妹大奶'),
    FuliCategory(typeId: '8', typeName: '日本无码'),
    FuliCategory(typeId: '6', typeName: '情欲女同'),
    FuliCategory(typeId: '3', typeName: '日韩专区'),
    FuliCategory(typeId: '16', typeName: '香蕉原创'),
    FuliCategory(typeId: '17', typeName: '中文字幕'),
    FuliCategory(typeId: '10', typeName: '动漫专区'),
  ];

  /// `data.<key>` 数组（缺失返回空表）。
  List<Map<String, Object?>> _rowsOf(
    Map<String, Object?>? json,
    String key,
  ) {
    final Object? data = json?['data'];
    if (data is! Map<String, Object?>) return const <Map<String, Object?>>[];
    final Object? rows = data[key];
    if (rows is! List) return const <Map<String, Object?>>[];
    return rows.whereType<Map<String, Object?>>().toList(growable: false);
  }

  /// 分类条目（`cateid` + `catename`；缺字段返回 `null`）。
  FuliCategory? _parseCategory(Map<String, Object?> cat) {
    final String? cateId = _strOf(cat['cateid']);
    final String? name = _strOf(cat['catename']);
    if (cateId == null || name == null) return null;
    final Object? subs = cat['subcates'];
    if (subs is List && subs.isNotEmpty) {
      final List<FuliCategory> subCategories = subs
          .whereType<Map<String, Object?>>()
          .map(_parseCategory)
          .whereType<FuliCategory>()
          .toList(growable: false);
      if (subCategories.isNotEmpty) {
        return FuliCategory(
          typeId: cateId,
          typeName: name,
          subCategories: subCategories,
        );
      }
    }
    return FuliCategory(typeId: cateId, typeName: name);
  }

  /// 长视频条目（对齐 iOS `parseVideo` L542-L559）。
  FuliVideo _parseVideo(Map<String, Object?> row) {
    final String vodId =
        _strOf(row['vodid']) ?? _intOf(row['vodid'])?.toString() ?? '';
    final String? preview = _strOf(row['preview_url']);
    if (preview != null && preview.isNotEmpty && vodId.isNotEmpty) {
      previewUrls[vodId] = preview;
    }
    return FuliVideo(
      vodId: vodId,
      vodName: _strOf(row['title']) ?? '',
      vodPic: _strOf(row['coverpic']) ?? '',
      duration: _strOf(row['duration']),
      score: _strOf(row['scorenum']),
      areaName: _strOf(row['areaname']),
    );
  }

  /// 短视频条目（对齐 iOS `fetchBananaMiniVideos` L420-L436）。
  ///
  /// `vodrow` 内嵌视频体、`user` 内嵌作者（字段名 `user` 而非 `userinfo`）。
  /// 返回裸 `vodId`（端点由 [miniVodPrefix] 前缀在播放链路补足）。
  BananaMiniVideo? _parseMiniVideo(Map<String, Object?> row) {
    final Object? vodRaw = row['vodrow'];
    final Map<String, Object?> vod =
        vodRaw is Map<String, Object?> ? vodRaw : row;
    final Object? userRaw = row['user'];
    final Map<String, Object?> user =
        userRaw is Map<String, Object?> ? userRaw : const <String, Object?>{};

    final String vodId =
        _strOf(vod['vodid']) ?? _intOf(vod['vodid'])?.toString() ?? '';
    if (vodId.isEmpty) return null;
    final String? preview = _strOf(vod['preview_url']);
    if (preview != null && preview.isNotEmpty) previewUrls[vodId] = preview;

    return BananaMiniVideo(
      vodId: vodId,
      title: _strOf(vod['title']) ?? _strOf(vod['vodname']) ?? '',
      cover: _strOf(vod['coverpic']) ?? _strOf(vod['vodpic']) ?? '',
      videoUrl: _strOf(vod['play_url']) ?? _strOf(vod['vodPlayUrl']),
      duration: _strOf(vod['duration']),
      userName: _strOf(user['nickname']) ?? _strOf(user['name']) ?? '',
      userAvatar: _strOf(user['avatar']) ?? _strOf(user['headimg']) ?? '',
    );
  }

  /// 专题 / 演员条目（对齐 iOS `parseSpecial` L358-L375）。
  BananaXjspSpecial? _parseSpecial(Map<String, Object?> sp) {
    final String? spId = _strOf(sp['spid']) ?? _strOf(sp['id']);
    final String? name = _strOf(sp['spname']) ?? _strOf(sp['title']);
    if (spId == null || name == null) return null;
    return BananaXjspSpecial(
      spId: spId,
      name: name,
      cover: _strOf(sp['coverpic']) ?? _strOf(sp['spcover']) ?? '',
      itemCount: _intOf(sp['itemcount']) ?? 0,
    );
  }

  /// 分类接口拉取（含站点请求头；[query] 非空时拼接查询串）。
  Future<Map<String, Object?>?> _getJson(
    String path, {
    Map<String, String>? query,
  }) async {
    final String base = _stripSlash(currentHost);
    if (base.isEmpty) return null;
    Uri uri = Uri.parse('$base$path');
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: query);
    }
    final String target =
        isProxyEnabled ? applyProxyIfNeeded(uri.toString()) : uri.toString();
    try {
      final SpiderHttpResult res = await bridge.request(
        target,
        options: SpiderHttpOptions(
          timeout: const Duration(seconds: 20),
          headers: <String, String>{
            'User-Agent': _ua,
            'x-version': _apiVersion,
            'x-channel': _apiChannel,
            'x-cookie-auth': _cookieAuth,
          },
        ),
      );
      if (!res.ok) return null;
      final Object? decoded = jsonDecode(res.content);
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// 32 位 hex 设备 token（对齐 iOS `cookieAuth` L144-L152：设备标识 hex + 固定
  /// 补位，取前 32 位）。
  static String _buildCookieAuth() {
    const String seed = 'vbox.flutter.client';
    final String hash = seed.codeUnits
        .map((int c) => c.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hash}a1b2c3d4e5f60708'.substring(0, 32);
  }

  static String _stripSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  static String? _strOf(Object? value) {
    if (value is String && value.isNotEmpty) return value;
    return null;
  }

  static int? _intOf(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
