/// 数据层：CMS V10 接口模型与纯解析函数。
///
/// 逆向来源：iOS `vbox/Services/CMSV10Helper.swift` + `RemoteCMSV10Service.swift`
/// + `SpiderManager.fetchSingleSourceCategoryContent` 接口形态（苹果 CMS V10）：
/// - 分类：`?ac=list`
/// - 首页：`?ac=home`（class + list 一次返回，对齐 iOS `fetchAPIHomeData`）
/// - 分类列表：`?ac=list&pg=N&t=<type_id>`（对齐 iOS L2102）
/// - 搜索：`?ac=detail&wd=<关键词>&pg=N`（对齐 iOS `RemoteCMSV10Service` L150）
/// - 详情：`?ac=detail&ids=<vod_id>`
library;

import '../../../core/utils/json_utils.dart';

/// 分类。
class CmsV10Category {
  /// 构造。
  const CmsV10Category({
    required this.typeId,
    required this.typeName,
    this.typePid = 0,
  });

  /// 分类 ID。
  final String typeId;

  /// 分类名。
  final String typeName;

  /// 父分类 ID。
  final int typePid;

  /// 从 JSON 构造。
  factory CmsV10Category.fromJson(Map<String, Object?> j) => CmsV10Category(
        typeId: JsonUtils.pickStringOr(j, 'type_id', ''),
        typeName: JsonUtils.pickStringOr(j, 'type_name', ''),
        typePid: JsonUtils.pickInt(j, 'type_pid'),
      );

  @override
  String toString() => 'CmsV10Category($typeName/$typeId)';
}

/// 列表项 / 详情基础信息。
class CmsV10Video {
  /// 构造。
  const CmsV10Video({
    required this.vodId,
    required this.name,
    this.pic = '',
    this.remarks = '',
    this.year = '',
    this.area = '',
    this.typeName = '',
    this.playUrl = '',
  });

  /// 影片 ID。
  final String vodId;

  /// 名称。
  final String name;

  /// 封面（已归一为绝对地址）。
  final String pic;

  /// 备注（如「更新至 12 集」）。
  final String remarks;

  /// 年份。
  final String year;

  /// 地区。
  final String area;

  /// 分类名。
  final String typeName;

  /// 原始播放地址串（详情接口返回；格式见 [parseCmsPlayUrl]）。
  final String playUrl;

  /// 从 JSON 构造（封面按站点 host 归一）。
  factory CmsV10Video.fromJson(Map<String, Object?> j, String host) => CmsV10Video(
        vodId: JsonUtils.pickStringOr(j, 'vod_id', ''),
        name: JsonUtils.pickStringOr(j, 'vod_name', ''),
        pic: normalizeCmsPic(JsonUtils.pickStringOr(j, 'vod_pic', ''), host),
        remarks: JsonUtils.pickStringOr(j, 'vod_remarks', ''),
        year: JsonUtils.pickStringOr(j, 'vod_year', ''),
        area: JsonUtils.pickStringOr(j, 'vod_area', ''),
        typeName: JsonUtils.pickStringOr(j, 'type_name', ''),
        playUrl: JsonUtils.pickStringOr(j, 'vod_play_url', ''),
      );

  @override
  String toString() => 'CmsV10Video($name/$vodId)';
}

/// 剧集。
class CmsV10Episode {
  /// 构造。
  const CmsV10Episode({required this.name, required this.url});

  /// 集名（缺失时按序号生成）。
  final String name;

  /// 播放地址（已归一为绝对地址）。
  final String url;

  @override
  String toString() => 'CmsV10Episode($name → $url)';
}

/// 分页视频列表（对齐 iOS `_hasMore`：pagecount/limit 推算分页终止）。
class CmsV10VideoPage {
  /// 构造。
  const CmsV10VideoPage({
    required this.items,
    this.pagecount,
    this.limit,
    this.total,
  });

  /// 当前页条目。
  final List<CmsV10Video> items;

  /// 总页数（接口未给时 null，调用方退回「空页终止」）。
  final int? pagecount;

  /// 每页条数。
  final int? limit;

  /// 总条数。
  final int? total;

  /// 是否还有下一页（对齐 iOS `RemoteCMSV10Service._hasMore`：以 pagecount
  /// 为准；接口未给 pagecount 时 null → 调用方以「本页非空」近似）。
  bool? hasMore(int page) {
    final int? pc = pagecount;
    if (pc == null || pc < 1) return null;
    return page < pc;
  }
}

/// 首页合并结果（`?ac=home`：class 分类 + list 推荐一次返回，
/// 对齐 iOS `SpiderManager.fetchAPIHomeData`）。
class CmsV10HomeBundle {
  /// 构造。
  const CmsV10HomeBundle({required this.classes, required this.videos});

  /// 分类。
  final List<CmsV10Category> classes;

  /// 推荐列表。
  final List<CmsV10Video> videos;

  /// 是否可用（分类或列表任一非空）。
  bool get isUsable => classes.isNotEmpty || videos.isNotEmpty;
}

/// 详情。
class CmsV10Detail {
  /// 构造。
  const CmsV10Detail({
    required this.video,
    this.episodes = const <CmsV10Episode>[],
    this.content = '',
    this.score = '',
    this.actors = '',
    this.director = '',
  });

  /// 基础信息。
  final CmsV10Video video;

  /// 剧集列表。
  final List<CmsV10Episode> episodes;

  /// 剧情简介（可能含 HTML）。
  final String content;

  /// 评分。
  final String score;

  /// 主演。
  final String actors;

  /// 导演。
  final String director;

  /// 从 JSON 构造。
  factory CmsV10Detail.fromJson(Map<String, Object?> j, String host) => CmsV10Detail(
        video: CmsV10Video.fromJson(j, host),
        episodes: parseCmsPlayUrl(JsonUtils.pickStringOr(j, 'vod_play_url', ''), host),
        content: JsonUtils.pickStringOr(j, 'vod_content', ''),
        score: JsonUtils.pickStringOr(j, 'vod_score', ''),
        actors: JsonUtils.pickStringOr(j, 'vod_actor', ''),
        director: JsonUtils.pickStringOr(j, 'vod_director', ''),
      );

  /// 是否可直接播放。
  bool get isPlayable => episodes.isNotEmpty;

  @override
  String toString() => 'CmsV10Detail(${video.name}, ${episodes.length} 集)';
}

// ─────────────────────────────────────────────────────────
// 纯解析函数（无 IO，可单测）
// ─────────────────────────────────────────────────────────

/// 播放地址归一（对齐 iOS `CMSV10Helper.normalizeUrl`）。
///
/// 规则：
/// - 已含 `http://` / `https://` → 原样；
/// - `//host/x` → 补 `https:`；
/// - `/path` → 拼站点 host；
/// - 其他 → 补 `https://` 前缀。
///
/// ⚠️ 与 iOS 的差异：iOS 对 `/path` 直接拼 `https://`（会得到 `https:///path`），
/// 此处改为拼站点 host（更正确，属**有意的行为改进**，已在方案文档登记）。
String normalizeCmsUrl(String url, String host) {
  final String u = url.trim();
  if (u.isEmpty) return '';
  if (u.startsWith('http://') || u.startsWith('https://')) return u;
  if (u.startsWith('//')) return 'https:$u';
  if (u.startsWith('/')) return host.isEmpty ? u : 'https://$host$u';
  if (u.contains('://')) return u;
  return 'https://$u';
}

/// 封面归一（对齐 iOS `CMSV10Helper.normalizePic`）。
String normalizeCmsPic(String pic, String host) => normalizeCmsUrl(pic, host);

/// 解析 `vod_play_url` 为剧集列表。
///
/// 契约格式：`名称$地址#名称$地址#…`（苹果 CMS V10 标准）。
/// - 无 `$` 时按序号生成集名；
/// - 空地址条目跳过；
/// - 地址按 [host] 归一。
List<CmsV10Episode> parseCmsPlayUrl(String raw, String host) {
  final String s = raw.trim();
  if (s.isEmpty) return const <CmsV10Episode>[];
  final List<CmsV10Episode> out = <CmsV10Episode>[];
  final List<String> segments = s.split('#');
  for (int i = 0; i < segments.length; i++) {
    final String seg = segments[i].trim();
    if (seg.isEmpty) continue;
    final int sep = seg.indexOf(r'$');
    final String name = sep >= 0 ? seg.substring(0, sep).trim() : '第${i + 1}集';
    final String rawUrl = sep >= 0 ? seg.substring(sep + 1).trim() : seg;
    final String url = normalizeCmsUrl(rawUrl, host);
    if (url.isEmpty) continue;
    out.add(CmsV10Episode(name: name.isEmpty ? '第${i + 1}集' : name, url: url));
  }
  return out;
}

// HTML 兜底解析（对齐 iOS `fetchCloudCategoryHTML` / `fetchHTMLHomeFallback`
// 的通用 detailPattern 路径，SpiderManager.swift L2164-L2206）。

/// 常见 macCMS 详情页链接（大小写不敏感）：
/// `/index.php/vod/detail/id/<id>.html`、`/voddetail/<id>.html`、
/// `/vod/detail/id/<id>.html`、`/detail/id/<id>.html`。
final RegExp cmsDetailHrefPattern = RegExp(
  r'(?:/index\.php/vod/detail/id/|/voddetail/|/vod/detail/id/|/detail/id/)(\d+)\.html',
  caseSensitive: false,
);

/// 锚点提取（href + 内部 HTML）。
final RegExp _cmsAnchorPattern = RegExp(
  r'''<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>''',
  caseSensitive: false,
  dotAll: true,
);

final RegExp _cmsImgAltPattern = RegExp(
  r'''<img\b[^>]*alt\s*=\s*["']([^"']{1,120})["']''',
  caseSensitive: false,
);

final RegExp _cmsImgSrcPattern = RegExp(
  r'''src\s*=\s*["']([^"']+\.(?:jpg|jpeg|png|webp)[^"']*)["']''',
  caseSensitive: false,
);

/// 从 HTML 提取 CMS 详情页条目（JSON 接口失败时的兜底，对齐 iOS 通用
/// 正则语义）：id 取详情路径数字，名称优先锚点文本、其次 `img alt`，
/// 封面取锚点内首图。按 `id+名称` 去重保序。
List<CmsV10Video> parseCmsDetailLinks(String html, String host) {
  final String src = html.trim();
  if (src.isEmpty) return const <CmsV10Video>[];
  final Map<String, CmsV10Video> out = <String, CmsV10Video>{};
  for (final RegExpMatch m in _cmsAnchorPattern.allMatches(src)) {
    final String href = (m.group(1) ?? '').trim();
    final RegExpMatch? idMatch = cmsDetailHrefPattern.firstMatch(href);
    if (idMatch == null) continue;
    final String id = idMatch.group(1)!;
    final String inner = m.group(2) ?? '';
    String name = inner.replaceAll(RegExp(r'<[^>]*>'), ' ').trim();
    name = name.replaceAll(RegExp(r'\s+'), ' ');
    if (name.length > 60 || name.isEmpty) {
      name = _cmsImgAltPattern.firstMatch(inner)?.group(1)?.trim() ?? '';
    }
    final String pic =
        _cmsImgSrcPattern.firstMatch(inner)?.group(1)?.trim() ?? '';
    final String key = '${id}_$name';
    if (out.containsKey(key)) continue;
    out[key] = CmsV10Video(
      vodId: id,
      name: name.isEmpty ? 'ID $id' : name,
      pic: normalizeCmsPic(pic, host),
    );
  }
  return out.values.toList(growable: false);
}
