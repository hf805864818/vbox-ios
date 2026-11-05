/// 领域层单测：TMDB 用例（批次 B · 图片直连/兜底 + 剧照）。
///
/// 覆盖：直连线路（主 URL 直连 + 兜底代理）、代理线路（主 URL 即代理）、
/// 未配置代理（不请求）、仅剧照也能产出增强数据、演职头像跟随线路。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/core/utils/result.dart';
import 'package:vbox/data/datasources/local/tmdb_config_store.dart';
import 'package:vbox/data/datasources/remote/tmdb_datasource.dart';
import 'package:vbox/data/datasources/remote/tmdb_image_route.dart';
import 'package:vbox/domain/entities/tmdb/tmdb_models.dart';
import 'package:vbox/domain/usecases/tmdb_usecases.dart';

/// 已启用 + 已配置代理的存储（内存态，不触真实 Prefs）。
TmdbConfigStore _readyConfig() => TmdbConfigStore()
  ..setEnabled(true)
  ..setProxyUrl('https://proxy.example.com/')
  ..setUseToken(false);

/// 假数据源：只覆盖网络方法，URL 拼接沿用真实实现。
class _FakeDatasource extends TmdbDatasource {
  _FakeDatasource({
    required this.directOk,
    required this.images,
    required this.credits,
    super.config,
  });

  final bool directOk;
  final TmdbImages? images;
  final TmdbCredits? credits;

  @override
  Future<TmdbSearchResult?> searchMovie(String name, {String? year}) async =>
      const TmdbSearchResult(
        id: 550,
        mediaType: 'movie',
        title: '搏击俱乐部',
        posterPath: '/p.jpg',
      );

  @override
  Future<TmdbImages?> fetchImages(int id, {String mediaType = 'movie'}) async =>
      images;

  @override
  Future<TmdbCredits?> fetchCredits(int id,
          {String mediaType = 'movie'}) async =>
      credits;

  @override
  Future<bool> probeDirectImage(String posterPath) async => directOk;

  @override
  String proxiedImageUrl(String originalUrl) => 'PROXY:$originalUrl';
}

TmdbImage _img(String path, {double aspect = 1.78, double vote = 5}) =>
    TmdbImage(
      filePath: path,
      aspectRatio: aspect,
      width: 1920,
      height: 1080,
      voteAverage: vote,
    );

void main() {
  setUp(() {
    TmdbImageRouteResolver.shared
      ..invalidate()
      ..debugReset();
  });

  TmdbImages images() => TmdbImages(
        id: 550,
        logos: <TmdbImage>[_img('/l.png', aspect: 3.0, vote: 9)],
        posters: <TmdbImage>[_img('/p.jpg', aspect: 0.67)],
        backdrops: <TmdbImage>[_img('/b1.jpg', vote: 9), _img('/b2.jpg', vote: 7)],
      );

  test('直连可用：主 URL 走 Bunny，兜底为代理，剧照同序', () async {
    final TmdbConfigStore cfg = _readyConfig();
    final TmdbUseCases uc = TmdbUseCases(
      config: cfg,
      datasource: _FakeDatasource(
        directOk: true,
        images: images(),
        credits: const TmdbCredits(
          id: 550,
          cast: <TmdbCast>[
            TmdbCast(id: 1, name: '演员A', profilePath: '/a.jpg'),
          ],
        ),
        config: cfg,
      ),
    );

    final Result<TmdbEnrichment?> result = await uc.enrich(name: '搏击俱乐部');
    final TmdbEnrichment e = result.valueOrNull!;

    expect(e.posterUrl, '$kTmdbImageDirectBaseUrl/original/p.jpg');
    expect(e.posterFallbackUrl, 'PROXY:$kTmdbImageDirectBaseUrl/original/p.jpg');
    expect(e.logoUrl, '$kTmdbImageDirectBaseUrl/w500/l.png');
    expect(e.backdropUrl, '$kTmdbImageDirectBaseUrl/original/b1.jpg');

    expect(e.hasStills, isTrue);
    expect(e.stillUrls.length, 2);
    expect(e.stillUrls.first, '$kTmdbImageDirectBaseUrl/w780/b1.jpg');
    expect(e.stillFallbackUrls.length, 2);
    expect(e.stillFallbackUrls.first,
        'PROXY:$kTmdbImageDirectBaseUrl/w780/b1.jpg');

    // 全屏原图：与 w780 同序，直连线路下同样带代理兜底。
    expect(e.stillHdUrls.length, 2);
    expect(e.stillHdUrls.first, '$kTmdbImageDirectBaseUrl/original/b1.jpg');
    expect(e.stillHdFallbackUrls.length, 2);
    expect(e.stillHdFallbackUrls.first,
        'PROXY:$kTmdbImageDirectBaseUrl/original/b1.jpg');

    // 演职头像同样走直连（否则封面正常、头像全空）。
    expect(e.actors.single.coverUrl, '$kTmdbImageDirectBaseUrl/w185/a.jpg');
  });

  test('直连不可用：主 URL 即代理，兜底为空', () async {
    final TmdbConfigStore cfg = _readyConfig();
    final TmdbUseCases uc = TmdbUseCases(
      config: cfg,
      datasource: _FakeDatasource(
        directOk: false,
        images: images(),
        credits: null,
        config: cfg,
      ),
    );

    final TmdbEnrichment e =
        (await uc.enrich(name: '搏击俱乐部')).valueOrNull!;

    expect(e.posterUrl, 'PROXY:$kTmdbImageDirectBaseUrl/original/p.jpg');
    expect(e.posterFallbackUrl, isNull);
    expect(e.stillUrls.first, 'PROXY:$kTmdbImageDirectBaseUrl/w780/b1.jpg');
    expect(e.stillFallbackUrls, isEmpty);
    expect(e.stillHdUrls.first,
        'PROXY:$kTmdbImageDirectBaseUrl/original/b1.jpg');
    expect(e.stillHdFallbackUrls, isEmpty);
  });

  test('未配置代理：不发请求，返回 null（上层回退豆瓣）', () async {
    final TmdbConfigStore cfg = TmdbConfigStore();
    final TmdbUseCases uc = TmdbUseCases(
      config: cfg,
      datasource: _FakeDatasource(
        directOk: true,
        images: images(),
        credits: null,
        config: cfg,
      ),
    );

    expect((await uc.enrich(name: '搏击俱乐部')).valueOrNull, isNull);
  });

  test('仅有 backdrops 时同时产出背景与剧照（无海报、无演职）', () async {
    final TmdbConfigStore cfg = _readyConfig();
    final TmdbUseCases uc = TmdbUseCases(
      config: cfg,
      datasource: _FakeDatasource(
        directOk: true,
        images: TmdbImages(id: 550, backdrops: <TmdbImage>[_img('/b1.jpg')]),
        credits: const TmdbCredits(id: 550),
        config: cfg,
      ),
    );

    final TmdbEnrichment e =
        (await uc.enrich(name: '搏击俱乐部')).valueOrNull!;
    expect(e.hasBackdrop, isTrue);
    expect(e.hasCredits, isFalse);
    expect(e.hasStills, isTrue);
    expect(e.stillUrls.length, 1);
    expect(e.isEmpty, isFalse);
  });
}
