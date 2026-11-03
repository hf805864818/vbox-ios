/// 数据层：豆瓣远程数据源。
///
/// 逆向来源：iOS `vbox/Services/DoubanService.swift`（rexxar API）与
/// `DoubanChartService.swift`（chart top_list API）。
/// - rexxar：`https://m.douban.com/rexxar/api/v2/subject_collection/{id}/items`
/// - chart：`https://movie.douban.com/j/chart/top_list?type={typeId}...`
///
/// 解析容错沿用 [DoubanSubject.fromJson] / [DoubanChartSubject.fromJson]，
/// 传输层只负责请求与 JSON 解码，不参与过滤/排序（属用例层）。
library;

import '../../../core/errors/exceptions.dart';
import '../../../core/network/http_client.dart';
import '../../../core/utils/json_utils.dart';
import '../../../domain/entities/douban/douban_models.dart';

/// 豆瓣远程数据源。
class DoubanDatasource {
  /// 构造（[client] 便于测试注入 MockClient）。
  DoubanDatasource({HttpClient? client})
      : _client = client ?? HttpClient();

  /// rexxar API 基址（对齐 iOS `DoubanService.baseURL`）。
  static const String baseURL = 'https://m.douban.com/rexxar/api/v2';

  /// chart 排行榜 API（对齐 iOS `DoubanChartService`）。
  static const String chartBase = 'https://movie.douban.com/j/chart/top_list';

  /// rexxar 请求头（对齐 iOS `DoubanService.swift` L220：iPhone UA + Referer；
  /// iOS `URLSession` 会注入系统 UA，此处显式声明同值）。
  static const Map<String, String> _rexxarHeaders = <String, String>{
    'user-agent':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15',
    'Referer': 'https://movie.douban.com',
    'Accept': 'application/json',
  };

  /// chart 请求头（对齐 iOS `DoubanChartService.swift` L90/L93：**桌面版** Chrome
  /// UA + Referer。豆瓣 chart API 是桌面网页 XHR，国内 WAF 对移动 UA 直接 400，
  /// 故不能用 `NetConstants.defaultUserAgent` 的 Android 移动 UA）。
  static const Map<String, String> _chartHeaders = <String, String>{
    'user-agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'application/json',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'Referer': 'https://movie.douban.com/chart',
  };

  final HttpClient _client;

  /// 拉取合集条目（rexxar `subject_collection`）。
  ///
  /// 非 2xx 视为访问受限（对齐 iOS 403/302 → 抛错）。
  Future<List<DoubanSubject>> fetchCollection(
    String collectionId, {
    int start = 0,
    int count = 20,
  }) async {
    final Uri uri = Uri.parse(
      '$baseURL/subject_collection/$collectionId/items?start=$start&count=$count',
    );
    final HttpClientResponse res = await _client.get(uri, headers: _rexxarHeaders);
    if (!res.isOk) {
      throw NetworkException(
        '豆瓣 API 访问受限 (HTTP ${res.statusCode})',
        code: ErrorCode.httpStatus,
      );
    }
    final Map<String, Object?>? json = JsonUtils.tryDecodeMap(res.text);
    if (json == null) {
      throw const ParseException('豆瓣合集响应非 JSON', code: ErrorCode.parse);
    }
    return JsonUtils.asMapList(json['subject_collection_items'])
        .map(DoubanSubject.fromJson)
        .toList(growable: false);
  }

  /// 拉取合集条目并补齐 TV 类封面（对齐 iOS `fetchCollectionWithTVCovers`）。
  ///
  /// 综艺 / 动漫 / 英美剧 / 韩剧 / 日剧等 `subject_collection`（`tv_variety_show`、
  /// `tv_animation`、`tv_american`…）的列表**不返回** `photos_gadget`/`cover_url`/
  /// `cover`，封面只存在于详情接口 `GET /tv/{id}`。
  ///
  /// 对齐 iOS 语义：对 `needsTvCoverFetch` 的条目**逐条串行**补拉，拿到
  /// `cover_url ?? pic.large ?? pic.normal` 后 [DoubanSubject.withCoverUrl] 回填；
  /// 补拉失败（非 2xx / 非 JSON）静默跳过，不影响整体结果。
  Future<List<DoubanSubject>> fetchCollectionWithTVCovers(
    String collectionId, {
    int start = 0,
    int count = 20,
  }) async {
    final List<DoubanSubject> subjects =
        await fetchCollection(collectionId, start: start, count: count);
    final List<DoubanSubject> result = List<DoubanSubject>.of(subjects);
    for (int i = 0; i < result.length; i++) {
      if (!result[i].needsTvCoverFetch) continue;
      final String? cover = await fetchTVDetailCoverUrl(result[i].id);
      if (cover == null || cover.isEmpty) continue;
      result[i] = result[i].withCoverUrl(cover);
    }
    return result;
  }

  /// 详情接口封面（对齐 iOS `fetchTVDetailCoverURL` +
  /// `DoubanSubjectDetailResponse.bestCoverURL`）：`cover_url` → `pic.large` → `pic.normal`。
  ///
  /// 失败返回 null（对齐 iOS `try?` 的静默降级），不抛异常。
  Future<String?> fetchTVDetailCoverUrl(String id) async {
    final Uri uri = Uri.parse('$baseURL/tv/$id');
    final HttpClientResponse res =
        await _client.get(uri, headers: _rexxarHeaders);
    if (!res.isOk) return null;
    final Map<String, Object?>? json = JsonUtils.tryDecodeMap(res.text);
    if (json == null) return null;
    final String? coverUrl = JsonUtils.pickString(json, 'cover_url');
    if (coverUrl != null && coverUrl.isNotEmpty) return coverUrl;
    final Map<String, Object?> pic = JsonUtils.pickMap(json, 'pic');
    return JsonUtils.pickString(pic, 'large') ??
        JsonUtils.pickString(pic, 'normal');
  }

  /// 搜索作品并返回首个命中的豆瓣 subject id（对齐 iOS `fetchCredits` 的多格式搜索）。
  ///
  /// 依次尝试（命中即返回）：
  ///   ① rexxar `/search?q=..&type=movie` → `subjects.items[].target.id` /
  ///      `subjects.items[].target_id` / `subjects[].id` / `items[].id`；
  ///   ② `movie.douban.com/j/subject_suggest?q=..` → 首项 `id`。
  ///
  /// 全部失败返回 null（不抛异常，对齐 iOS 静默降级）。
  Future<String?> searchSubjectId(String name) async {
    final String encoded = Uri.encodeQueryComponent(name);
    final List<String> urls = <String>[
      '$baseURL/search?q=$encoded&type=movie',
      'https://movie.douban.com/j/subject_suggest?q=$encoded',
    ];
    for (final String urlString in urls) {
      try {
        final HttpClientResponse res =
            await _client.get(Uri.parse(urlString), headers: _rexxarHeaders);
        if (!res.isOk) continue;
        final String? id = _extractSearchId(res.text);
        if (id != null && id.isNotEmpty) return id;
      } catch (_) {
        // 单个搜索 URL 失败 → 试下一个（对齐 iOS for 循环内的 try）。
      }
    }
    return null;
  }

  /// 从搜索结果文本提取首个 subject id（兼容数组 / 多种对象形态）。
  String? _extractSearchId(String text) {
    // 形态①：`subject_suggest` 返回数组 `[{id: ...}]`。
    final List<Object?>? list = JsonUtils.tryDecodeList(text);
    if (list != null && list.isNotEmpty) {
      final Map<String, Object?> first = JsonUtils.asMap(list.first);
      final String? id = JsonUtils.pickString(first, 'id');
      if (id != null && id.isNotEmpty) return id;
    }
    // 形态②/③：对象里的 `subjects` / `items`（对齐 iOS 各分支）。
    final Map<String, Object?>? json = JsonUtils.tryDecodeMap(text);
    if (json == null) return null;
    final Map<String, Object?> subjects = JsonUtils.pickMap(json, 'subjects');
    final List<Map<String, Object?>> subjectItems =
        JsonUtils.asMapList(subjects['items']);
    if (subjectItems.isNotEmpty) {
      final Map<String, Object?> first = subjectItems.first;
      final Map<String, Object?> target = JsonUtils.pickMap(first, 'target');
      final String? targetId =
          JsonUtils.pickString(target, 'id') ?? JsonUtils.pickString(first, 'target_id');
      if (targetId != null && targetId.isNotEmpty) return targetId;
    }
    final List<Map<String, Object?>> subjectsList =
        JsonUtils.asMapList(json['subjects']);
    if (subjectsList.isNotEmpty) {
      final String? id = JsonUtils.pickString(subjectsList.first, 'id');
      if (id != null && id.isNotEmpty) return id;
    }
    final List<Map<String, Object?>> items = JsonUtils.asMapList(json['items']);
    if (items.isNotEmpty) {
      final Map<String, Object?> first = items.first;
      final String? id = JsonUtils.pickString(first, 'id') ??
          JsonUtils.pickString(first, 'target_id');
      if (id != null && id.isNotEmpty) return id;
    }
    return null;
  }

  /// 拉取演职人员（对齐 iOS `fetchCreditsById`：`GET /movie/{id}/celebrities`）。
  ///
  /// 解析 `actors` → 演员；`directors` → 导演（角色固定「导演」），其中 `roles`
  /// 含「编剧」的条目额外并入编剧列表（对齐 iOS 双重身份处理）。
  /// 失败返回空 [DoubanCredits]（不抛异常）。
  Future<DoubanCredits> fetchCelebrities(String subjectId) async {
    final Uri uri = Uri.parse('$baseURL/movie/$subjectId/celebrities');
    final HttpClientResponse res =
        await _client.get(uri, headers: _rexxarHeaders);
    if (!res.isOk) return DoubanCredits(subjectId: subjectId);
    final Map<String, Object?>? json = JsonUtils.tryDecodeMap(res.text);
    if (json == null) return DoubanCredits(subjectId: subjectId);

    final List<DoubanCelebrity> actors = JsonUtils.asMapList(json['actors'])
        .map((Map<String, Object?> j) => DoubanCelebrity.fromJson(j))
        .whereType<DoubanCelebrity>()
        .toList(growable: false);

    final List<DoubanCelebrity> directors = <DoubanCelebrity>[];
    final List<DoubanCelebrity> writers = <DoubanCelebrity>[];
    for (final Map<String, Object?> j in JsonUtils.asMapList(json['directors'])) {
      final DoubanCelebrity? person =
          DoubanCelebrity.fromJson(j, defaultRole: '导演');
      if (person == null) continue;
      directors.add(person);
      final List<String> roles =
          JsonUtils.asList(j['roles']).map((Object? e) => '$e').toList();
      if (roles.contains('编剧')) {
        final DoubanCelebrity writer = DoubanCelebrity(
          id: person.id,
          name: person.name,
          coverUrl: person.coverUrl,
          roles: const <String>['编剧'],
        );
        if (!writers.any((DoubanCelebrity w) => w.id == writer.id)) {
          writers.add(writer);
        }
      }
    }
    return DoubanCredits(
      actors: actors,
      directors: directors,
      writers: writers,
      subjectId: subjectId,
    );
  }

  /// 拉取竖版大封面（对齐 iOS `fetchWallpaperURL`：
  /// `GET /movie/{id}/photos?type=R&count=30`，取首张竖版 `large.url`）。
  ///
  /// 失败 / 无竖版返回 null（不抛异常）。
  Future<String?> fetchWallpaperUrl(String subjectId) async {
    final Uri uri =
        Uri.parse('$baseURL/movie/$subjectId/photos?type=R&count=30');
    final HttpClientResponse res =
        await _client.get(uri, headers: _rexxarHeaders);
    if (!res.isOk) return null;
    final Map<String, Object?>? json = JsonUtils.tryDecodeMap(res.text);
    if (json == null) return null;
    for (final Map<String, Object?> photo in JsonUtils.asMapList(json['photos'])) {
      final Map<String, Object?> large =
          JsonUtils.pickMap(JsonUtils.pickMap(photo, 'image'), 'large');
      final String? raw = JsonUtils.pickString(large, 'url');
      final int? w = JsonUtils.asInt(large['width']);
      final int? h = JsonUtils.asInt(large['height']);
      if (raw == null || raw.isEmpty) continue;
      if (w == null || h == null || h <= w) continue;
      return raw;
    }
    return null;
  }

  /// 拉取分类排行榜（chart `top_list`，返回 JSON 数组）。
  Future<List<DoubanChartSubject>> fetchChartRanking(
    DoubanChartCategory category, {
    int start = 0,
    int count = 20,
  }) async {
    final Uri uri = Uri.parse(
      '$chartBase?type=${category.typeId}&interval_id=100:90&action='
      '&start=$start&limit=$count',
    );
    final HttpClientResponse res = await _client.get(uri, headers: _chartHeaders);
    if (!res.isOk) {
      throw NetworkException(
        '豆瓣榜单访问受限 (HTTP ${res.statusCode})',
        code: ErrorCode.httpStatus,
      );
    }
    final List<Object?>? raw = JsonUtils.tryDecodeList(res.text);
    if (raw == null) {
      throw const ParseException('豆瓣榜单响应非 JSON 数组', code: ErrorCode.parse);
    }
    final List<Map<String, Object?>> items =
        raw.whereType<Map>().map(JsonUtils.asMap).toList(growable: false);
    return <DoubanChartSubject>[
      for (int i = 0; i < items.length; i++)
        DoubanChartSubject.fromJson(items[i], start + i + 1),
    ];
  }
}