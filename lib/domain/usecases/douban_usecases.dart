/// 领域层：豆瓣浏览用例（首页 / 榜单 / 分类浏览，并发拉取）。
///
/// 对齐 iOS `DoubanService` / `DoubanChartService` / `DoubanCategoryViewModel`：
/// - 首页聚合：banner（TOP250 前若干）+ 热门区块，**并发拉取**；
/// - 榜单：chart `top_list` 按分类 typeId 拉取；
/// - 分类浏览：rexxar 合集 + 客户端过滤 / 排序（对齐 iOS `applyFilters` / `applySort`）。
library;

import '../../core/errors/failures.dart';
import '../../core/utils/result.dart';
import '../../data/datasources/remote/douban_datasource.dart';
import '../entities/douban/douban_models.dart';

/// 豆瓣浏览用例。
class DoubanUseCases {
  /// 构造（[datasource] 便于测试注入 fake）。
  DoubanUseCases({DoubanDatasource? datasource})
      : _datasource = datasource ?? DoubanDatasource();

  final DoubanDatasource _datasource;

  /// 分页大小。
  static const int pageSize = 20;

  /// 首页区块定义（标题 → collectionId），顺序即展示顺序。
  ///
  /// 对齐 iOS `MainViews.swift HomeView.doubanHomeContent`（L392-L472）的 11 个栏目
  /// 及顺序：影院热映 → 即将上映 → 热门电影 → 一周口碑榜 → 新片榜 → TOP250 →
  /// 热门剧集 → 华语口碑剧集 → 值得看的英美剧 → 热门动漫 → 热门综艺。
  static const List<(String, String)> _homeSections = <(String, String)>[
    ('影院热映', 'movie_showing'),
    ('即将上映', 'movie_soon'),
    ('热门电影', 'movie_hot_gaia'),
    ('一周口碑榜', 'movie_weekly_best'),
    ('新片榜', 'movie_latest'),
    ('TOP250', 'movie_top250'),
    ('热门剧集', 'tv_real_time_hotest'),
    ('华语口碑剧集', 'tv_chinese_best_weekly'),
    ('值得看的英美剧', 'tv_american'),
    ('热门动漫', 'tv_animation'),
    ('热门综艺', 'tv_variety_show'),
  ];

  /// 空搜索页「豆瓣榜单」栏目标签（标签名 → collectionId）。
  ///
  /// 对齐 iOS `MainViews.swift SearchView.doubanTabs`（L1357）+
  /// `DoubanService.fetchByTab`（L376-L389）。
  static const List<(String, String)> searchTabs = <(String, String)>[
    ('豆瓣周榜', 'movie_weekly_best'),
    ('华语口碑剧集', 'tv_chinese_best_weekly'),
    ('一周口碑电影榜', 'movie_hot_gaia'),
    ('国内即将上映', 'movie_showing'),
  ];

  /// 需补拉详情封面的 collection（对齐 iOS `fetchCollectionWithTVCovers` 的调用点：
  /// 综艺 / 动漫 / 英美剧 / 韩剧 / 日剧）——这些合集列表不返回封面字段。
  static const Set<String> tvCoverCollections = <String>{
    'tv_variety_show',
    'tv_animation',
    'tv_american',
    'tv_korean',
    'tv_japanese',
  };

  /// 按 collectionId 选择拉取方式（TV 类走详情封面补拉，对齐 iOS）。
  Future<List<DoubanSubject>> _fetchCollection(
    String collectionId, {
    int start = 0,
    int count = pageSize,
  }) {
    if (tvCoverCollections.contains(collectionId)) {
      return _datasource.fetchCollectionWithTVCovers(
        collectionId,
        start: start,
        count: count,
      );
    }
    return _datasource.fetchCollection(collectionId, start: start, count: count);
  }

  /// 首页聚合：banner（TOP250 前 10）+ 栏目区块，**并发拉取**。
  ///
  /// 对齐 iOS `fetchSafely` 语义：**单个栏目失败不影响其余栏目**（失败返回空，
  /// 不整体抛错），避免一条 collection 限流导致整页空白。
  Future<Result<DoubanHomeFeed>> homeFeed() async {
    final List<List<DoubanSubject>> results = await Future.wait(
      <Future<List<DoubanSubject>>>[
        _safeFetch(() => _datasource.fetchCollection('movie_top250', start: 0, count: 10)),
        for (final (_, String collectionId) in _homeSections)
          _safeFetch(() => _fetchCollection(collectionId, start: 0, count: pageSize)),
      ],
    );
    final List<DoubanHomeSection> sections = <DoubanHomeSection>[
      for (int i = 0; i < _homeSections.length; i++)
        if (results[i + 1].isNotEmpty)
          DoubanHomeSection(
            title: _homeSections[i].$1,
            items: results[i + 1],
          ),
    ];
    return Success<DoubanHomeFeed>(
      DoubanHomeFeed(banner: results.first, sections: sections),
    );
  }

  /// 拉取单个 collection（供空搜索页「豆瓣榜单」栏目使用）。
  Future<Result<List<DoubanSubject>>> collection(
    String collectionId, {
    int start = 0,
    int count = pageSize,
  }) async {
    try {
      final List<DoubanSubject> list =
          await _datasource.fetchCollection(collectionId, start: start, count: count);
      return Success<List<DoubanSubject>>(list);
    } catch (e) {
      return Err<List<DoubanSubject>>(Failure.from(e));
    }
  }

  /// 单栏目容错拉取（失败返回空列表，不阻断其余栏目）。
  Future<List<DoubanSubject>> _safeFetch(
    Future<List<DoubanSubject>> Function() fetch,
  ) async {
    try {
      return await fetch();
    } catch (_) {
      return const <DoubanSubject>[];
    }
  }

  /// 分类排行榜（分页）。
  Future<Result<List<DoubanChartSubject>>> ranking(
    DoubanChartCategory category, {
    int page = 1,
  }) async {
    try {
      final int start = (page - 1) * pageSize;
      final List<DoubanChartSubject> list = await _datasource.fetchChartRanking(
        category,
        start: start,
        count: pageSize,
      );
      return Success<List<DoubanChartSubject>>(list);
    } catch (e) {
      return Err<List<DoubanChartSubject>>(Failure.from(e));
    }
  }

  /// 分类浏览（分页 + 客户端过滤 / 排序）。
  Future<Result<List<DoubanSubject>>> category(
    DoubanCategory category,
    DoubanFilterParams filters, {
    int page = 1,
  }) async {
    try {
      final int start = (page - 1) * pageSize;
      final List<DoubanSubject> list = await _datasource.fetchCollection(
        category.collectionId,
        start: start,
        count: pageSize,
      );
      final List<DoubanSubject> filtered = _applyFilters(list, filters);
      _applySort(filtered, filters.sort);
      return Success<List<DoubanSubject>>(filtered);
    } catch (e) {
      return Err<List<DoubanSubject>>(Failure.from(e));
    }
  }

  // ─────────────── 过滤 / 排序（对齐 iOS）───────────────

  List<DoubanSubject> _applyFilters(
    List<DoubanSubject> subjects,
    DoubanFilterParams filters,
  ) {
    List<DoubanSubject> result = subjects;

    if (filters.genre != null && filters.genre != '全部') {
      result = result
          .where((DoubanSubject s) => s.genres.contains(filters.genre))
          .toList(growable: false);
    }
    if (filters.year != null && filters.year != '全部') {
      result = result
          .where((DoubanSubject s) => _yearMatches(s.year, filters.year!))
          .toList(growable: false);
    }
    if (filters.region != null && filters.region != '全部') {
      result = result
          .where((DoubanSubject s) => _regionMatches(s, filters.region!))
          .toList(growable: false);
    }
    if (filters.platform != null && filters.platform != '全部') {
      result = result
          .where((DoubanSubject s) => _platformMatches(s, filters.platform!))
          .toList(growable: false);
    }
    return result;
  }

  void _applySort(List<DoubanSubject> subjects, DoubanSortType sort) {
    switch (sort) {
      case DoubanSortType.rating:
        subjects.sort((DoubanSubject a, DoubanSubject b) => b.rating.compareTo(a.rating));
      case DoubanSortType.year:
      case DoubanSortType.latest:
        subjects.sort(
          (DoubanSubject a, DoubanSubject b) =>
              (b.year ?? '').compareTo(a.year ?? ''),
        );
      case DoubanSortType.hot:
        // 豆瓣返回顺序即热度序，保持原样。
        break;
    }
  }

  bool _yearMatches(String? subjectYear, String year) {
    if (subjectYear == null) return false;
    switch (year) {
      case '2010年代':
        return subjectYear.compareTo('2010') >= 0 &&
            subjectYear.compareTo('2020') < 0;
      case '2000年代':
        return subjectYear.compareTo('2000') >= 0 &&
            subjectYear.compareTo('2010') < 0;
      case '90年代':
        return subjectYear.compareTo('1990') >= 0 &&
            subjectYear.compareTo('2000') < 0;
      case '更早':
        return subjectYear.compareTo('1990') < 0;
      default:
        return subjectYear == year;
    }
  }

  bool _regionMatches(DoubanSubject s, String region) {
    final String text = '${s.cardSubtitle ?? ''} ${s.intro ?? ''}';
    switch (region) {
      case '华语':
        return text.contains('中国大陆') ||
            text.contains('中国') ||
            text.contains('台湾') ||
            text.contains('香港') ||
            text.contains('华语');
      case '欧美':
        return text.contains('美国') ||
            text.contains('英国') ||
            text.contains('法国') ||
            text.contains('德国') ||
            text.contains('意大利') ||
            text.contains('西班牙') ||
            text.contains('加拿大');
      case '日本':
        return text.contains('日本');
      case '韩国':
        return text.contains('韩国');
      case '印度':
        return text.contains('印度');
      case '泰国':
        return text.contains('泰国');
      default:
        return true;
    }
  }

  bool _platformMatches(DoubanSubject s, String platform) {
    final String text = '${s.cardSubtitle ?? ''} ${s.intro ?? ''} ${s.title}';
    return text.contains(platform);
  }

  // ─────────────── 详情增强：演职 / 大封面（对齐 iOS `fetchCredits` / `fetchWallpaperURL`）───────────────

  /// 拉取作品演职（对齐 iOS `DoubanService.fetchCredits(for:)`）：
  /// 先按作品名搜索出 subject id，再拉 `/movie/{id}/celebrities`。
  ///
  /// 搜索不到 / 请求失败 → 返回空演职（不阻断详情页），对齐 iOS 的兜底语义。
  Future<Result<DoubanCredits>> credits(String workName) async {
    final String name = workName.trim();
    if (name.isEmpty) return const Success<DoubanCredits>(DoubanCredits());
    try {
      final String? subjectId = await _datasource.searchSubjectId(name);
      if (subjectId == null || subjectId.isEmpty) {
        return const Success<DoubanCredits>(DoubanCredits());
      }
      final DoubanCredits credits =
          await _datasource.fetchCelebrities(subjectId);
      return Success<DoubanCredits>(credits);
    } catch (e) {
      return Err<DoubanCredits>(Failure.from(e));
    }
  }

  /// 拉取竖版大封面（对齐 iOS `fetchWallpaperURL(subjectId:)`）。
  ///
  /// 无封面 / 请求失败 → 返回 null（详情页回退站点封面）。
  Future<Result<String?>> wallpaper(String subjectId) async {
    if (subjectId.isEmpty) return const Success<String?>(null);
    try {
      final String? url = await _datasource.fetchWallpaperUrl(subjectId);
      return Success<String?>(url);
    } catch (e) {
      return Err<String?>(Failure.from(e));
    }
  }
}