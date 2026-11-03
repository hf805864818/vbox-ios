/// 领域层单测：豆瓣浏览用例（批次 D · D-03）。
///
/// 注入 fake [DoubanDatasource]，验证首页聚合（并发拉取 + 空区块剔除）、
/// 榜单、分类的客户端过滤 / 排序。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/data/datasources/remote/douban_datasource.dart';
import 'package:vbox/domain/entities/douban/douban_models.dart';
import 'package:vbox/domain/usecases/douban_usecases.dart';

/// fake 数据源：按 collectionId / typeId 返回注入数据，并记录请求。
class _FakeDoubanDatasource extends DoubanDatasource {
  Map<String, List<DoubanSubject>> collections = <String, List<DoubanSubject>>{};
  Map<int, List<DoubanChartSubject>> rankings = <int, List<DoubanChartSubject>>{};

  final List<String> requestedCollections = <String>[];
  final List<int> requestedTypeIds = <int>[];

  @override
  Future<List<DoubanSubject>> fetchCollection(
    String collectionId, {
    int start = 0,
    int count = 20,
  }) async {
    requestedCollections.add(collectionId);
    return collections[collectionId] ?? const <DoubanSubject>[];
  }

  @override
  Future<List<DoubanChartSubject>> fetchChartRanking(
    DoubanChartCategory category, {
    int start = 0,
    int count = 20,
  }) async {
    requestedTypeIds.add(category.typeId);
    return rankings[category.typeId] ?? const <DoubanChartSubject>[];
  }
}

/// fake：记录哪些 collection 走了「详情封面补拉」路径。
class _TrackingDoubanDatasource extends _FakeDoubanDatasource {
  final List<String> tvCoverFetched = <String>[];

  @override
  Future<List<DoubanSubject>> fetchCollectionWithTVCovers(
    String collectionId, {
    int start = 0,
    int count = 20,
  }) async {
    tvCoverFetched.add(collectionId);
    return super.fetchCollection(collectionId, start: start, count: count);
  }
}

DoubanSubject subject(
  String id, {
  double rating = 0,
  String? year,
  List<String> genres = const <String>[],
  String? cardSubtitle,
}) =>
    DoubanSubject(
      id: id,
      title: '片$id',
      rating: rating,
      year: year,
      genres: genres,
      cardSubtitle: cardSubtitle,
    );

DoubanChartSubject chart(int id, {int? rank, double rating = 0}) =>
    DoubanChartSubject(
      id: '$id',
      rank: rank ?? id,
      title: '榜$id',
      rating: rating,
    );

void main() {
  group('homeFeed', () {
    test('并发聚合 banner + 非空区块', () async {
      final _FakeDoubanDatasource ds = _FakeDoubanDatasource()
        ..collections = <String, List<DoubanSubject>>{
          'movie_top250': <DoubanSubject>[subject('1'), subject('2')],
          'movie_hot_gaia': <DoubanSubject>[subject('3')],
          'tv_real_time_hotest': <DoubanSubject>[subject('4')],
          'tv_variety_show': <DoubanSubject>[],
          'tv_animation': <DoubanSubject>[subject('5')],
        };

      final Result<DoubanHomeFeed> result =
          await DoubanUseCases(datasource: ds).homeFeed();

      final DoubanHomeFeed? feed = result.valueOrNull;
      expect(feed, isNotNull);
      expect(feed!.banner, hasLength(2));
      // 空区块被剔除：仅 movie_hot_gaia / movie_top250 / tv_real_time_hotest /
      // tv_animation 有数据（TOP250 与 banner 共用 movie_top250；综艺为空被剔除）。
      expect(feed.sections, hasLength(4));
      expect(
        feed.sections.map((s) => s.title),
        <String>['热门电影', 'TOP250', '热门剧集', '热门动漫'],
      );
      // 并发拉取：banner + 11 区块（对齐 iOS HomeView 11 栏目）全部请求。
      expect(ds.requestedCollections, hasLength(12));
    });

    test('完全空载 → isEmpty', () async {
      final Result<DoubanHomeFeed> result =
          await DoubanUseCases(datasource: _FakeDoubanDatasource()).homeFeed();
      final DoubanHomeFeed? feed = result.valueOrNull;
      expect(feed, isNotNull);
      expect(feed!.isEmpty, isTrue);
    });

    test('TV 类栏目（英美剧/动漫/综艺）走详情封面补拉路径', () async {
      final _TrackingDoubanDatasource ds = _TrackingDoubanDatasource()
        ..collections = <String, List<DoubanSubject>>{
          'tv_american': <DoubanSubject>[subject('a')],
          'tv_animation': <DoubanSubject>[subject('b')],
          'tv_variety_show': <DoubanSubject>[subject('c')],
          'movie_hot_gaia': <DoubanSubject>[subject('m')],
        };

      await DoubanUseCases(datasource: ds).homeFeed();

      expect(
        ds.tvCoverFetched,
        containsAll(<String>['tv_american', 'tv_animation', 'tv_variety_show']),
      );
      // 非 TV 栏目不走补拉。
      expect(ds.tvCoverFetched, isNot(contains('movie_hot_gaia')));
      // 补拉内部复用 fetchCollection，总请求数仍为 banner + 11 栏目。
      expect(ds.requestedCollections, hasLength(12));
    });
  });

  group('ranking', () {
    test('按分类返回榜单', () async {
      final _FakeDoubanDatasource ds = _FakeDoubanDatasource()
        ..rankings = <int, List<DoubanChartSubject>>{
          11: <DoubanChartSubject>[chart(1), chart(2)],
        };
      final Result<List<DoubanChartSubject>> result = await DoubanUseCases(
        datasource: ds,
      ).ranking(DoubanChartCategory.all.first);

      expect(result.valueOrNull, hasLength(2));
      expect(ds.requestedTypeIds, <int>[11]);
    });

    test('分页起点换算', () async {
      final _FakeDoubanDatasource ds = _FakeDoubanDatasource();
      await DoubanUseCases(datasource: ds)
          .ranking(DoubanChartCategory.all.first, page: 2);
      expect(ds.requestedTypeIds, <int>[11]);
    });
  });

  group('category', () {
    test('按类型过滤', () async {
      final _FakeDoubanDatasource ds = _FakeDoubanDatasource()
        ..collections = <String, List<DoubanSubject>>{
          'movie_hot_gaia': <DoubanSubject>[
            subject('1', genres: <String>['喜剧']),
            subject('2', genres: <String>['爱情']),
          ],
        };
      final Result<List<DoubanSubject>> result = await DoubanUseCases(
        datasource: ds,
      ).category(
        DoubanCategory.all.first,
        const DoubanFilterParams(genre: '喜剧'),
      );

      final List<DoubanSubject>? list = result.valueOrNull;
      expect(list, hasLength(1));
      expect(list!.single.id, '1');
    });

    test('按年代过滤', () async {
      final _FakeDoubanDatasource ds = _FakeDoubanDatasource()
        ..collections = <String, List<DoubanSubject>>{
          'movie_hot_gaia': <DoubanSubject>[
            subject('1', year: '2015'),
            subject('2', year: '2023'),
          ],
        };
      final Result<List<DoubanSubject>> result = await DoubanUseCases(
        datasource: ds,
      ).category(
        DoubanCategory.all.first,
        const DoubanFilterParams(year: '2010年代'),
      );

      expect(result.valueOrNull, hasLength(1));
      expect(result.valueOrNull!.single.year, '2015');
    });

    test('按评分降序排序', () async {
      final _FakeDoubanDatasource ds = _FakeDoubanDatasource()
        ..collections = <String, List<DoubanSubject>>{
          'movie_hot_gaia': <DoubanSubject>[
            subject('1', rating: 6.5),
            subject('2', rating: 9.1),
            subject('3', rating: 7.0),
          ],
        };
      final Result<List<DoubanSubject>> result = await DoubanUseCases(
        datasource: ds,
      ).category(
        DoubanCategory.all.first,
        const DoubanFilterParams(sort: DoubanSortType.rating),
      );

      final List<DoubanSubject> list = result.valueOrNull ?? const <DoubanSubject>[];
      expect(list.map((s) => s.id).toList(), <String>['2', '3', '1']);
    });
  });
}