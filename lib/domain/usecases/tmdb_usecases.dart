/// 领域层：TMDB 用例（批次 G · G-06；批次 B 增补图片直连与剧照）。
///
/// 唯一真相源：iOS `vbox/Views/PlayerViews.swift` `VideoDetailView.loadTMDBData`
/// （L306-L359）：
///   1. `guard settings.enableTMDB` → 未启用直接跳过（回退豆瓣）；
///   2. 搜索 `searchMovie(name:year:)` → 无结果回退豆瓣；
///   3. `fetchImages` 与 `fetchCredits` **并发**拉取；
///   4. logo 取 `bestLogo.w500URL`、海报取 `bestPoster.originalURL`、背景取
///      `bestBackdrop.originalURL`，三者均经代理；
///   5. 演职人员 TMDB 有则整体替换豆瓣（演员/导演/编剧）；
///   6. 无大封面或无演职 → 触发豆瓣兜底（由呈现层判定，本用例只产出增强数据）。
///
/// 批次 B 差异（与 iOS 同步落地）：
///   · 图片线路先探测（[TmdbImageRouteResolver]）：直连可用 → 主 URL 走
///     `images.tmdb.org`（TMDB 的 BunnyCDN），兜底 URL 为代理版；
///     探测失败 → 主 URL 直接是代理版（= 旧行为）；
///   · 侦察与 `fetchImages`/`fetchCredits` 并发，不增加首屏等待；
///   · 新增剧照（TMDB `backdrops`，见 `TmdbImages.stills`）。
library;

import '../../core/utils/result.dart';
import '../../data/datasources/local/tmdb_config_store.dart';
import '../../data/datasources/remote/tmdb_datasource.dart';
import '../../data/datasources/remote/tmdb_image_route.dart';
import '../entities/tmdb/tmdb_models.dart';

/// TMDB 用例。
class TmdbUseCases {
  /// 构造（[datasource] / [config] 便于测试注入 fake）。
  TmdbUseCases({TmdbDatasource? datasource, TmdbConfigStore? config})
      : _config = config,
        _datasource = datasource ?? TmdbDatasource(config: config);

  final TmdbDatasource _datasource;
  final TmdbConfigStore? _config;

  TmdbConfigStore? get _cfg {
    final TmdbConfigStore? injected = _config;
    if (injected != null) return injected;
    try {
      return TmdbConfigStore.shared;
    } catch (_) {
      return null;
    }
  }

  /// 是否已启用 TMDB（对齐 iOS `guard settings.enableTMDB`）。
  bool get enabled => _cfg?.enabled ?? false;

  /// 是否可发起请求（已启用 + 代理非空）。
  bool get ready => _cfg?.isReady ?? false;

  /// 详情增强：搜索 → 图片 / 演职并发 → 线路探测 → 主/兜底 URL 聚合。
  ///
  /// 返回 `Success(null)` 表示「未启用 / 未配置 / 无匹配 / 请求失败」，调用方按
  /// iOS 语义回退豆瓣；只有用例自身异常才返回 `Err`。
  Future<Result<TmdbEnrichment?>> enrich({
    required String name,
    String? year,
  }) async {
    if (!ready) return const Success<TmdbEnrichment?>(null);
    final String query = name.trim();
    if (query.isEmpty) return const Success<TmdbEnrichment?>(null);
    try {
      final TmdbSearchResult? hit =
          await _datasource.searchMovie(query, year: year);
      if (hit == null) return const Success<TmdbEnrichment?>(null);

      // 线路探测与图片/演职并发：探测（≤3s）被后两者耗时覆盖，不额外增加等待。
      final List<Object?> results = await Future.wait(<Future<Object?>>[
        _datasource.fetchImages(hit.id, mediaType: hit.mediaType),
        _datasource.fetchCredits(hit.id, mediaType: hit.mediaType),
        TmdbImageRouteResolver.shared.resolve(
          proxyReady: true,
          // 海报缺失时用背景图探测（同一图床，结果等价）。
          probe: () => _datasource.probeDirectImage(
            hit.posterPath ?? hit.backdropPath ?? '',
          ),
        ),
      ]);
      final TmdbImages? images = results[0] as TmdbImages?;
      final TmdbCredits? credits = results[1] as TmdbCredits?;
      final TmdbImageRoute route = results[2] as TmdbImageRoute;
      final bool direct = route == TmdbImageRoute.direct;

      /// 主 URL：直连线路取 Bunny 原始地址，否则套代理。
      String? primary(String path, String size) {
        if (path.isEmpty) return null;
        final String raw = TmdbDatasource.imageUrl(path, size, direct: true);
        return direct ? raw : _datasource.proxiedImageUrl(raw);
      }

      /// 兜底 URL：仅直连线路存在（代理版）；代理线路主 URL 已是代理 → null。
      String? fallback(String path, String size) {
        if (path.isEmpty || !direct) return null;
        return _datasource.proxiedImageUrl(
          TmdbDatasource.imageUrl(path, size, direct: true),
        );
      }

      final TmdbImage? logo = images?.bestLogo;
      final TmdbImage? poster = images?.bestPoster;
      final TmdbImage? backdrop = images?.bestBackdrop;
      final List<TmdbImage> stills =
          images?.stills(limit: 10) ?? const <TmdbImage>[];

      return Success<TmdbEnrichment?>(
        TmdbEnrichment(
          logoUrl: primary(logo?.filePath ?? '', 'w500'),
          logoFallbackUrl: fallback(logo?.filePath ?? '', 'w500'),
          posterUrl: primary(poster?.filePath ?? '', 'original'),
          posterFallbackUrl: fallback(poster?.filePath ?? '', 'original'),
          backdropUrl: primary(backdrop?.filePath ?? '', 'original'),
          backdropFallbackUrl: fallback(backdrop?.filePath ?? '', 'original'),
          stillUrls: <String>[
            for (final TmdbImage i in stills) primary(i.filePath, 'w780')!,
          ],
          stillFallbackUrls: <String>[
            if (direct)
              for (final TmdbImage i in stills) fallback(i.filePath, 'w780')!,
          ],
          // 全屏浏览用的高清版（渐进替换：列表 w780 秒开，全屏叠 original）。
          stillHdUrls: <String>[
            for (final TmdbImage i in stills)
              primary(i.filePath, 'original')!,
          ],
          stillHdFallbackUrls: <String>[
            if (direct)
              for (final TmdbImage i in stills)
                fallback(i.filePath, 'original')!,
          ],
          actors: _routePeople(credits?.actors ?? const <TmdbPerson>[], direct),
          directors:
              _routePeople(credits?.directors ?? const <TmdbPerson>[], direct),
          writers:
              _routePeople(credits?.writers ?? const <TmdbPerson>[], direct),
        ),
      );
    } catch (e) {
      // 对齐 iOS：任何异常均视为「无 TMDB 数据」→ 上层回退豆瓣。
      return const Success<TmdbEnrichment?>(null);
    }
  }

  /// 演职头像同样跟随线路（否则 CloudFront 被阻断时封面正常、头像全空）。
  List<TmdbPerson> _routePeople(List<TmdbPerson> people, bool direct) {
    if (people.isEmpty) return const <TmdbPerson>[];
    String? rewrite(String? url) {
      if (url == null || url.isEmpty) return null;
      final String raw = url.startsWith(kTmdbImageBaseUrl)
          ? '$kTmdbImageDirectBaseUrl${url.substring(kTmdbImageBaseUrl.length)}'
          : url;
      return direct ? raw : _datasource.proxiedImageUrl(raw);
    }

    return <TmdbPerson>[
      for (final TmdbPerson p in people)
        TmdbPerson(
          id: p.id,
          name: p.name,
          character: p.character,
          coverUrl: rewrite(p.coverUrl),
        ),
    ];
  }
}