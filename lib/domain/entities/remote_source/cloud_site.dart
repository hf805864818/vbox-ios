/// 领域层：网盘站点配置（对齐 iOS `SpiderManager.CloudSiteConfig` / `CloudSiteType`）。
///
/// 数据来源：远程默认源 `cloudSources.cloudSites`（即 `cloud_sources.json`），
/// 字段名与该文件一致；契约 `contract/schema/manifest_v1.json` §`$defs.cloudSite`。
library;

import '../spider/site_config.dart';
import '../spider/spider_models.dart';

/// 网盘站点类型（对齐 iOS `SpiderManager.CloudSiteType`）。
enum CloudSiteType {
  /// CMS V10 系（`?wd=` 搜索页 + 详情页链接）。
  cms,

  /// 论坛型（搜索结果内即网盘链接，或主题列表二级解析）。
  forum,

  /// SPA 型（JSON 搜索接口）。
  spa,

  /// WordPress 型（`?s=` 搜索页）。
  wordpress,

  /// DedeCMS 型（`/plus/search.php?keyword=`）。
  dedecms,

  /// binhd.com 型（Django HTML 站 + 复制链接 API）。
  binhd;

  /// 解析类型字符串。
  ///
  /// 未知/缺省回退 [CloudSiteType.cms]：iOS 用 `Codable` 枚举会因未知值**整个
  /// JSON 解码失败**（所有网盘站丢失），此处按单站回退，避免远端新增类型连带丢源。
  static CloudSiteType fromName(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'forum':
        return CloudSiteType.forum;
      case 'spa':
        return CloudSiteType.spa;
      case 'wordpress':
        return CloudSiteType.wordpress;
      case 'dedecms':
        return CloudSiteType.dedecms;
      case 'binhd':
        return CloudSiteType.binhd;
      case 'cms':
      default:
        return CloudSiteType.cms;
    }
  }
}

/// 网盘站点配置（对齐 iOS `SpiderManager.CloudSiteConfig`）。
class CloudSiteConfig {
  /// 构造。
  const CloudSiteConfig({
    required this.name,
    required this.type,
    required this.searchurl,
    required this.detailBase,
    this.ua,
    this.detailPattern,
    this.extraPanHosts = const <String>[],
    this.extraPanNames = const <String, String>{},
    this.searchurls = const <String>[],
    this.threadPattern,
    this.threadURL,
    this.apiSearch,
    this.resultField,
    this.titleField,
    this.urlField,
    this.urlTemplate,
  });

  /// 由 JSON 构造（字段名同 `cloud_sources.json`）。
  factory CloudSiteConfig.fromJson(Map<String, Object?> j) => CloudSiteConfig(
        name: asLooseStringRequired(j['name']),
        type: CloudSiteType.fromName(asLooseString(j['type'])),
        searchurl: asLooseStringRequired(j['searchurl']),
        detailBase: asLooseStringRequired(j['detailBase']),
        ua: asLooseString(j['ua']),
        detailPattern: asLooseString(j['detailPattern']),
        extraPanHosts: _stringList(j['extraPanHosts']),
        extraPanNames: _stringMap(j['extraPanNames']),
        searchurls: _stringList(j['searchurls']),
        threadPattern: asLooseString(j['threadPattern']),
        threadURL: asLooseString(j['threadURL']),
        apiSearch: asLooseString(j['apiSearch']),
        resultField: asLooseString(j['resultField']),
        titleField: asLooseString(j['titleField']),
        urlField: asLooseString(j['urlField']),
        urlTemplate: asLooseString(j['urlTemplate']),
      );

  /// 站点显示名（同时用于结果来源标注）。
  final String name;

  /// 站点类型。
  final CloudSiteType type;

  /// 搜索 URL 前缀；含 `{kw}` 时替换占位符，否则直接拼接关键词。
  final String searchurl;

  /// 详情页域名基准：相对路径按此补成绝对地址。
  final String detailBase;

  /// `pc` 表示使用桌面 UA（对齐 iOS `site.ua == "pc"`）。
  final String? ua;

  /// 自定义详情页链接正则（仅 cms 生效，覆盖默认正则）。
  final String? detailPattern;

  /// 追加的网盘域名白名单（所有类型生效）。
  final List<String> extraPanHosts;

  /// 追加的网盘域名 → 显示名映射。
  final Map<String, String> extraPanNames;

  /// 备用搜索 URL（仅 cms 生效，主 URL 无结果时轮询）。
  final List<String> searchurls;

  /// 论坛型：主题链接正则（各捕获组以 `-` 拼接为 id）。
  final String? threadPattern;

  /// 论坛型：主题 URL 模板（`{id}` 占位）。
  final String? threadURL;

  /// SPA 型：JSON 搜索接口模板（`{kw}` 占位）。
  final String? apiSearch;

  /// SPA 型：结果数组路径（点分，如 `data.merged_by_type`）。
  final String? resultField;

  /// SPA 型：标题字段名（缺省 `title`）。
  final String? titleField;

  /// SPA 型：链接字段名（缺省 `url`）。
  final String? urlField;

  /// SPA 型：详情页 URL 模板（`{id}` 占位）。
  final String? urlTemplate;

  /// 是否使用 PC UA。
  bool get usesPcUserAgent => (ua ?? '').toLowerCase() == 'pc';

  /// 拼接搜索 URL：`{kw}` 占位优先，否则前缀拼接（对齐 iOS cms/dede/wordpress）。
  String searchUrlFor(String encodedKeyword) => searchurl.contains('{kw}')
      ? searchurl.replaceAll('{kw}', encodedKeyword)
      : searchurl + encodedKeyword;

  /// 合成用于「切换源」列表 / 站点解析的 [SiteConfig]。
  ///
  /// 对齐 iOS `fetchAllSourceDisplayItems()`：网盘源 `id = "cloud_<name>"`、
  /// `siteKey = name`，归属 `.cloudCMS` 等分类；仅 `cms` 型带 API 基地址
  /// （`<detailBase>/api.php/provide/vod`，用于 `ac=home` 首页），其余类型无 API。
  /// Flutter 以 `key = "cloud_<name>"`、`group = "cloud"` 承载同一语义。
  SiteConfig toSiteConfig() => SiteConfig(
        key: '$cloudSiteKeyPrefix$name',
        name: name,
        type: 0,
        api: type == CloudSiteType.cms
            ? '$detailBase/api.php/provide/vod'
            : null,
        group: cloudSiteGroup,
      );
}

/// 网盘源合成 key 前缀（对齐 iOS `SourceDisplayItem.id = "cloud_<name>"`）。
const String cloudSiteKeyPrefix = 'cloud_';

/// 网盘源分组标记（对齐 iOS `SourceCategory.cloud*`）。
const String cloudSiteGroup = 'cloud';

List<String> _stringList(Object? v) => v is List
    ? v
        .map((Object? e) => '$e')
        .where((String s) => s.isNotEmpty)
        .toList(growable: false)
    : const <String>[];

Map<String, String> _stringMap(Object? v) => v is Map
    ? v.map((Object? k, Object? val) => MapEntry('$k', '$val'))
    : const <String, String>{};