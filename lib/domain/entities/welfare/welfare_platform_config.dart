/// 领域层：福利平台配置模型（批次 H · H-01）。
///
/// 唯一真相源：`contract/schema/welfare_v1.json`
/// 逆向来源：iOS `vbox/WelfareRemote/WelfarePlatformConfig.swift`
///   · 顶层 `WelfarePlatformConfig`（含 `_meta` / `schemaVersion` / `categories`
///     / `platforms`）；
///   · 平台 `WelfarePlatform`（**29 字段实测**，其中 `platformKey` 为主键，
///     非 `key`）；
///   · 分类枚举 `RemoteWelfareCategory`（`video` / `live` / `comic`）。
///
/// 校验口径（对齐契约 `required` 与 `enum`）：
///   · 根对象必需 `schemaVersion`（整数且恒为 1）/ `categories` / `platforms`；
///   · 分类项必需 `key`（∈ `video|live|comic`）与 `name`；
///   · 平台项必需 `platformKey` / `name` / `category`（∈ 同上三值）。
///
/// 未知字段一律**透传不报错**（契约 `additionalProperties: true`），便于远程
/// 配置先行扩展；仅校验上述必需结构，避免旧客户端因新增字段而整包拒收。
library;

import 'welfare_service_type.dart';

/// 福利平台分类（对齐契约 `categories[].key` 枚举）。
enum WelfarePlatformCategory {
  /// 视频。
  video('video', '视频'),

  /// 直播。
  live('live', '直播'),

  /// 漫画。
  comic('comic', '漫画');

  const WelfarePlatformCategory(this.key, this.displayName);

  /// 分类 key（远程配置与排序持久化的主键）。
  final String key;

  /// 中文显示名。
  final String displayName;

  /// 由 key 解析分类（未知返回 `null`，由调用方按需兜底）。
  static WelfarePlatformCategory? fromKey(String key) {
    for (final WelfarePlatformCategory c in values) {
      if (c.key == key) return c;
    }
    return null;
  }
}

/// 福利平台元数据（`platforms[]` 单项）。
class WelfarePlatform {
  /// 构造。
  const WelfarePlatform({
    required this.platformKey,
    required this.name,
    required this.category,
    this.icon,
    this.desc = '',
    this.serviceType = '',
    this.scriptType,
    this.api,
    this.defaultHosts = const <String>[],
    this.sortOrder = 0,
    this.defaultProxy = false,
    this.notes,
    this.apiKind,
    this.apiPath,
    this.contentType,
    this.engine,
    this.sslBypass = false,
    this.imageSSLBypass = false,
    this.imageReferer,
    this.rootTypeId,
    this.rootTypeName,
    this.detailMode,
    this.articleListPath,
    this.articleDetailPath,
    this.headers = const <String, String>{},
    this.childDiscovery,
    this.itemPlayUrlRule,
    this.visibleInNormalSpider = false,
    this.visibleInGlobalSearch = false,
    this.visibleInHome = false,
  });

  /// 平台唯一键（不可变，排序持久化主键）。
  final String platformKey;

  /// 平台显示名（如「香蕉秀」）。
  final String name;

  /// 所属分类。
  final WelfarePlatformCategory category;

  /// SF Symbol 图标名（呈现层映射为 Material 近似图标）。
  final String? icon;

  /// 平台描述（卡片副标题）。
  final String desc;

  /// 客户端 Service 实现类型（`ybox_special` / `welfare_spider` …，路由分发用，H-02）。
  final String serviceType;

  /// 福利专区专用脚本类型（契约枚举 `python` / `javascript`，H-02 路由判定用）。
  ///
  /// 仅 `serviceType == welfare_spider` 时有业务含义：`javascript` 走 JS 引擎页，
  /// 其余走脚本状态页（对齐 iOS `makeWelfareSpiderDestination`）。
  final String? scriptType;

  /// 默认域名列表（按顺序回退探测）。
  final List<String> defaultHosts;

  /// 同分类内排序权重（升序展示）。
  final int sortOrder;

  /// 是否默认开启代理（远程配置字段）。
  final bool defaultProxy;

  /// 备注（仅说明用途）。
  final String? notes;

  /// 脚本路径（契约 `api`，如 `./sources/welfare-js/xxx.py`；仅福利 Spider 有业务含义）。
  final String? api;

  // ─────────────── CMS V10 / 图文远程源字段（UI-C1c，对齐 iOS `WelfarePlatform`）───

  /// API 形态（契约 `apiKind`，如 `mac_art_html`；决定是否走图文 HTML 模式）。
  final String? apiKind;

  /// API 路径（契约 `apiPath`，如 `/api.php/provide/vod/`；缺省用 CMS V10 默认）。
  final String? apiPath;

  /// 内容类型（契约 `contentType`，`comic` 时走套图阅读器；缺省落 `category`）。
  final String? contentType;

  /// 引擎标识（契约 `engine`，如 `python` / `spider`；仅脚本平台有业务含义）。
  final String? engine;

  /// 是否绕过 SSL 证书（站点级；用于探测与抓取，对应用户配置）。
  final bool sslBypass;

  /// 封面图是否绕过 SSL（对齐 iOS `imageSSLBypass`）。
  final bool imageSSLBypass;

  /// 封面图防盗链 Referer（对齐 iOS `imageReferer`）。
  final String? imageReferer;

  /// 根分类 ID（契约 `rootTypeId`；配置后首页只展示该根分类 + 自动发现的子分类）。
  final String? rootTypeId;

  /// 根分类显示名（契约 `rootTypeName`；缺省回落站点分类名或平台名）。
  final String? rootTypeName;

  /// 详情模式（契约 `detailMode`；`comic_images` / `article_html` 有专用语义）。
  final String? detailMode;

  /// 图文列表页路径模板（契约 `articleListPath`，含 `{typeId}` / `{pageSuffix}`）。
  final String? articleListPath;

  /// 图文详情页路径模板（契约 `articleDetailPath`，含 `{id}`）。
  final String? articleDetailPath;

  /// 站点自定义请求头（契约 `headers`；仅白名单键生效，见 `RemoteCmsV10FuliService`）。
  final Map<String, String> headers;

  /// 子分类发现模式（契约 `childDiscovery`；`type_id_1` 时按 `type_id_1` 归属筛选）。
  final String? childDiscovery;

  /// 列表项过滤规则（契约 `itemRule.vodPlayUrl`：`required` / `empty`；缺省按内容类型）。
  final String? itemPlayUrlRule;

  /// ⚠️ 三重隔离（契约强制 false）：不进入普通 Spider 链路。
  final bool visibleInNormalSpider;

  /// ⚠️ 三重隔离（契约强制 false）：不参与全局搜索。
  final bool visibleInGlobalSearch;

  /// ⚠️ 三重隔离（契约强制 false）：不在首页展示。
  final bool visibleInHome;

  /// 路由服务类型（由 [serviceType] 解析，未知回退 [WelfareServiceType.unknown]）。
  WelfareServiceType get service => WelfareServiceType.fromRaw(serviceType);

  /// 是否为福利专区 JS Spider（`welfare_spider` + `scriptType == javascript`）。
  bool get isJavaScriptSpider =>
      serviceType.trim() == WelfareServiceType.welfareSpider.raw &&
      (scriptType ?? '').trim().toLowerCase() == 'javascript';

  /// 首个默认域名（兜底显示 / 探测起点）。
  String get primaryHost => defaultHosts.isEmpty ? '' : defaultHosts.first;

  /// 拷贝并覆写部分字段（测试 / 门控补丁用）。
  WelfarePlatform copyWith({
    String? platformKey,
    String? name,
    WelfarePlatformCategory? category,
    String? icon,
    String? desc,
    String? serviceType,
    String? scriptType,
    String? api,
    List<String>? defaultHosts,
    int? sortOrder,
    bool? defaultProxy,
    String? notes,
    String? apiKind,
    String? apiPath,
    String? contentType,
    String? engine,
    bool? sslBypass,
    bool? imageSSLBypass,
    String? imageReferer,
    String? rootTypeId,
    String? rootTypeName,
    String? detailMode,
    String? articleListPath,
    String? articleDetailPath,
    Map<String, String>? headers,
    String? childDiscovery,
    String? itemPlayUrlRule,
    bool? visibleInNormalSpider,
    bool? visibleInGlobalSearch,
    bool? visibleInHome,
  }) =>
      WelfarePlatform(
        platformKey: platformKey ?? this.platformKey,
        name: name ?? this.name,
        category: category ?? this.category,
        icon: icon ?? this.icon,
        desc: desc ?? this.desc,
        serviceType: serviceType ?? this.serviceType,
        scriptType: scriptType ?? this.scriptType,
        api: api ?? this.api,
        defaultHosts: defaultHosts ?? this.defaultHosts,
        sortOrder: sortOrder ?? this.sortOrder,
        defaultProxy: defaultProxy ?? this.defaultProxy,
        notes: notes ?? this.notes,
        apiKind: apiKind ?? this.apiKind,
        apiPath: apiPath ?? this.apiPath,
        contentType: contentType ?? this.contentType,
        engine: engine ?? this.engine,
        sslBypass: sslBypass ?? this.sslBypass,
        imageSSLBypass: imageSSLBypass ?? this.imageSSLBypass,
        imageReferer: imageReferer ?? this.imageReferer,
        rootTypeId: rootTypeId ?? this.rootTypeId,
        rootTypeName: rootTypeName ?? this.rootTypeName,
        detailMode: detailMode ?? this.detailMode,
        articleListPath: articleListPath ?? this.articleListPath,
        articleDetailPath: articleDetailPath ?? this.articleDetailPath,
        headers: headers ?? this.headers,
        childDiscovery: childDiscovery ?? this.childDiscovery,
        itemPlayUrlRule: itemPlayUrlRule ?? this.itemPlayUrlRule,
        visibleInNormalSpider: visibleInNormalSpider ?? this.visibleInNormalSpider,
        visibleInGlobalSearch: visibleInGlobalSearch ?? this.visibleInGlobalSearch,
        visibleInHome: visibleInHome ?? this.visibleInHome,
      );

  /// 解析单项（缺必需字段返回 `null`）。
  static WelfarePlatform? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, Object?> j = raw.cast<String, Object?>();

    final String platformKey = (j['platformKey'] ?? '').toString().trim();
    final String name = (j['name'] ?? '').toString().trim();
    final String categoryKey = (j['category'] ?? '').toString().trim();
    if (platformKey.isEmpty || name.isEmpty) return null;
    final WelfarePlatformCategory? category =
        WelfarePlatformCategory.fromKey(categoryKey);
    if (category == null) return null;

    final Object? icon = j['icon'];
    final Object? desc = j['desc'];
    final Object? serviceType = j['serviceType'];
    final Object? scriptType = j['scriptType'];
    final Object? api = j['api'];
    final Object? notes = j['notes'];
    final Object? defaultProxy = j['defaultProxy'];
    final Object? sortOrder = j['sortOrder'];
    final Object? visibleNormal = j['visibleInNormalSpider'];
    final Object? visibleSearch = j['visibleInGlobalSearch'];
    final Object? visibleHome = j['visibleInHome'];

    // CMS V10 / 图文远程源字段（UI-C1c）。
    final String apiKindValue = _str(j['apiKind']);
    final String apiPathValue = _str(j['apiPath']);
    final String contentTypeValue = _str(j['contentType']);
    final String engineValue = _str(j['engine']);
    final String imageRefererValue = _str(j['imageReferer']);
    final String rootTypeIdValue = _str(j['rootTypeId']);
    final String rootTypeNameValue = _str(j['rootTypeName']);
    final String detailModeValue = _str(j['detailMode']);
    final String articleListPathValue = _str(j['articleListPath']);
    final String articleDetailPathValue = _str(j['articleDetailPath']);

    final Map<String, String> headers = <String, String>{};
    final Object? rawHeaders = j['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((Object? k, Object? v) {
        final String key = (k ?? '').toString().trim();
        final String value = (v ?? '').toString().trim();
        if (key.isNotEmpty && value.isNotEmpty) headers[key] = value;
      });
    }

    // `childDiscovery` 契约声明为 object，iOS 实现为 String（`type_id_1`）→ 两者兼容。
    final Object? rawChild = j['childDiscovery'];
    final String childDiscoveryValue = rawChild is Map
        ? _str(rawChild['mode'])
        : _str(rawChild);

    // `itemRule.vodPlayUrl`（`required` / `empty`）。
    final Object? rawItemRule = j['itemRule'];
    final String itemPlayUrlRuleValue =
        rawItemRule is Map ? _str(rawItemRule['vodPlayUrl']) : '';

    final List<String> hosts = <String>[];
    final Object? rawHosts = j['defaultHosts'];
    if (rawHosts is List) {
      for (final Object? h in rawHosts) {
        final String s = (h ?? '').toString().trim();
        if (s.isNotEmpty) hosts.add(s);
      }
    }

    final String scriptTypeValue = (scriptType ?? '').toString().trim();
    final String apiValue = (api ?? '').toString().trim();

    return WelfarePlatform(
      platformKey: platformKey,
      name: name,
      category: category,
      icon: icon?.toString(),
      desc: (desc ?? '').toString(),
      serviceType: (serviceType ?? '').toString(),
      scriptType: scriptTypeValue.isEmpty ? null : scriptTypeValue,
      api: apiValue.isEmpty ? null : apiValue,
      defaultHosts: hosts,
      sortOrder: sortOrder is num ? sortOrder.toInt() : 0,
      defaultProxy: defaultProxy is bool ? defaultProxy : false,
      notes: notes?.toString(),
      apiKind: apiKindValue.isEmpty ? null : apiKindValue,
      apiPath: apiPathValue.isEmpty ? null : apiPathValue,
      contentType: contentTypeValue.isEmpty ? null : contentTypeValue,
      engine: engineValue.isEmpty ? null : engineValue,
      sslBypass: j['sslBypass'] is bool ? j['sslBypass']! as bool : false,
      imageSSLBypass:
          j['imageSSLBypass'] is bool ? j['imageSSLBypass']! as bool : false,
      imageReferer: imageRefererValue.isEmpty ? null : imageRefererValue,
      rootTypeId: rootTypeIdValue.isEmpty ? null : rootTypeIdValue,
      rootTypeName: rootTypeNameValue.isEmpty ? null : rootTypeNameValue,
      detailMode: detailModeValue.isEmpty ? null : detailModeValue,
      articleListPath:
          articleListPathValue.isEmpty ? null : articleListPathValue,
      articleDetailPath:
          articleDetailPathValue.isEmpty ? null : articleDetailPathValue,
      headers: headers,
      childDiscovery: childDiscoveryValue.isEmpty ? null : childDiscoveryValue,
      itemPlayUrlRule:
          itemPlayUrlRuleValue.isEmpty ? null : itemPlayUrlRuleValue,
      visibleInNormalSpider: visibleNormal is bool ? visibleNormal : false,
      visibleInGlobalSearch: visibleSearch is bool ? visibleSearch : false,
      visibleInHome: visibleHome is bool ? visibleHome : false,
    );
  }

  /// 宽松取字符串（null → 空串；非字符串转 `toString`）。
  static String _str(Object? v) => v == null ? '' : v.toString().trim();

  /// 序列化（写入本地缓存用；仅回写本模型已知字段）。
  Map<String, Object?> toJson() => <String, Object?>{
        'platformKey': platformKey,
        'name': name,
        'category': category.key,
        if (icon != null) 'icon': icon,
        if (desc.isNotEmpty) 'desc': desc,
        if (serviceType.isNotEmpty) 'serviceType': serviceType,
        if (scriptType != null) 'scriptType': scriptType,
        if (api != null) 'api': api,
        if (defaultHosts.isNotEmpty) 'defaultHosts': defaultHosts,
        'sortOrder': sortOrder,
        'defaultProxy': defaultProxy,
        if (notes != null) 'notes': notes,
        if (apiKind != null) 'apiKind': apiKind,
        if (apiPath != null) 'apiPath': apiPath,
        if (contentType != null) 'contentType': contentType,
        if (engine != null) 'engine': engine,
        if (sslBypass) 'sslBypass': sslBypass,
        if (imageSSLBypass) 'imageSSLBypass': imageSSLBypass,
        if (imageReferer != null) 'imageReferer': imageReferer,
        if (rootTypeId != null) 'rootTypeId': rootTypeId,
        if (rootTypeName != null) 'rootTypeName': rootTypeName,
        if (detailMode != null) 'detailMode': detailMode,
        if (articleListPath != null) 'articleListPath': articleListPath,
        if (articleDetailPath != null) 'articleDetailPath': articleDetailPath,
        if (headers.isNotEmpty) 'headers': headers,
        if (childDiscovery != null) 'childDiscovery': childDiscovery,
        if (itemPlayUrlRule != null) 'itemRule': <String, Object?>{
          'vodPlayUrl': itemPlayUrlRule,
        },
        // 三重隔离显式回写（缺省 false 亦写，保证缓存重读口径一致）。
        'visibleInNormalSpider': visibleInNormalSpider,
        'visibleInGlobalSearch': visibleInGlobalSearch,
        'visibleInHome': visibleInHome,
      };
}

/// 福利分类元数据（`categories[]` 单项）。
class WelfarePlatformCategoryMeta {
  /// 构造。
  const WelfarePlatformCategoryMeta({
    required this.key,
    required this.name,
    this.icon,
  });

  /// 分类 key。
  final String key;

  /// 分类显示名。
  final String name;

  /// SF Symbol 图标名。
  final String? icon;
}

/// 福利平台完整配置（对应远端 `sources/welfare_platforms.json` 根对象）。
class WelfarePlatformConfig {
  /// 构造。
  const WelfarePlatformConfig({
    this.schemaVersion = 1,
    this.meta,
    this.categories = const <WelfarePlatformCategoryMeta>[],
    this.platforms = const <WelfarePlatform>[],
  });

  /// 契约固定值。
  static const int supportedSchemaVersion = 1;

  /// schema 版本号（契约 `const 1`）。
  final int schemaVersion;

  /// 自描述元信息（`_meta`，不参与业务逻辑）。
  final Map<String, Object?>? meta;

  /// 分类列表。
  final List<WelfarePlatformCategoryMeta> categories;

  /// 平台列表。
  final List<WelfarePlatform> platforms;

  /// 指定分类下的平台（按 `sortOrder` 升序；同权重保持原始顺序）。
  List<WelfarePlatform> platformsIn(WelfarePlatformCategory category) {
    final List<WelfarePlatform> out = platforms
        .where((WelfarePlatform p) => p.category == category)
        .toList(growable: false);
    final List<WelfarePlatform> sorted = <WelfarePlatform>[...out];
    // 稳定排序：sortOrder 相等时保留远程配置的原始次序。
    sorted.sort((WelfarePlatform a, WelfarePlatform b) =>
        a.sortOrder.compareTo(b.sortOrder));
    return sorted;
  }

  /// 宽松解析：结构不满足契约必需项时返回 `null`（不抛异常）。
  ///
  /// 对应 iOS `WelfarePlatformConfig.isValid(jsonData:)` 的解码即校验语义；
  /// 分类 / 平台**逐项**过滤 —— 单项非法只丢该项，不整包拒收（旧客户端韧性）。
  static WelfarePlatformConfig? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, Object?> j = raw.cast<String, Object?>();

    final Object? version = j['schemaVersion'];
    if (version is! num) return null;
    if (version.toInt() != supportedSchemaVersion) return null;

    final Object? rawCategories = j['categories'];
    final Object? rawPlatforms = j['platforms'];
    if (rawCategories is! List || rawPlatforms is! List) return null;

    final List<WelfarePlatformCategoryMeta> categories =
        <WelfarePlatformCategoryMeta>[];
    for (final Object? c in rawCategories) {
      if (c is! Map) continue;
      final Map<String, Object?> cj = c.cast<String, Object?>();
      final String key = (cj['key'] ?? '').toString().trim();
      final String name = (cj['name'] ?? '').toString().trim();
      if (key.isEmpty || name.isEmpty) continue;
      if (WelfarePlatformCategory.fromKey(key) == null) continue;
      final Object? icon = cj['icon'];
      categories.add(WelfarePlatformCategoryMeta(
        key: key,
        name: name,
        icon: icon?.toString(),
      ));
    }

    final List<WelfarePlatform> platforms = <WelfarePlatform>[];
    for (final Object? p in rawPlatforms) {
      final WelfarePlatform? parsed = WelfarePlatform.tryParse(p);
      if (parsed != null) platforms.add(parsed);
    }

    final Object? meta = j['_meta'];
    return WelfarePlatformConfig(
      schemaVersion: version.toInt(),
      meta: meta is Map ? meta.cast<String, Object?>() : null,
      categories: categories,
      platforms: platforms,
    );
  }

  /// 严格解析：结构非法抛 [FormatException]（供数据源在需要明确失败原因时使用）。
  factory WelfarePlatformConfig.fromJson(Object? raw) {
    final WelfarePlatformConfig? parsed = tryParse(raw);
    if (parsed == null) {
      throw const FormatException('welfare_platforms 结构非法（缺 schemaVersion/categories/platforms）');
    }
    return parsed;
  }

  /// 序列化（写入本地缓存用；`_meta` 原样回写）。
  Map<String, Object?> toJson() => <String, Object?>{
        if (meta != null) '_meta': meta,
        'schemaVersion': schemaVersion,
        'categories': categories
            .map((WelfarePlatformCategoryMeta c) => <String, Object?>{
                  'key': c.key,
                  'name': c.name,
                  if (c.icon != null) 'icon': c.icon,
                })
            .toList(growable: false),
        'platforms': platforms
            .map((WelfarePlatform p) => p.toJson())
            .toList(growable: false),
      };
}