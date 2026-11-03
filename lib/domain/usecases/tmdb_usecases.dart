/// 领域层：TMDB 用例（批次 G · G-06）。
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
library;

import '../../core/utils/result.dart';
import '../../data/datasources/local/tmdb_config_store.dart';
import '../../data/datasources/remote/tmdb_datasource.dart';
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

  /// 详情增强：搜索 → 图片 / 演职并发 → 代理 URL 聚合。
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

      final List<Object?> pair = await Future.wait(<Future<Object?>>[
        _datasource.fetchImages(hit.id, mediaType: hit.mediaType),
        _datasource.fetchCredits(hit.id, mediaType: hit.mediaType),
      ]);
      final TmdbImages? images = pair[0] as TmdbImages?;
      final TmdbCredits? credits = pair[1] as TmdbCredits?;

      final TmdbImage? logo = images?.bestLogo;
      final TmdbImage? poster = images?.bestPoster;
      final TmdbImage? backdrop = images?.bestBackdrop;

      return Success<TmdbEnrichment?>(
        TmdbEnrichment(
          logoUrl: logo == null
              ? null
              : _datasource.proxiedImageUrl(logo.w500Url),
          posterUrl: poster == null
              ? null
              : _datasource.proxiedImageUrl(poster.originalUrl),
          backdropUrl: backdrop == null
              ? null
              : _datasource.proxiedImageUrl(backdrop.originalUrl),
          actors: credits?.actors ?? const <TmdbPerson>[],
          directors: credits?.directors ?? const <TmdbPerson>[],
          writers: credits?.writers ?? const <TmdbPerson>[],
        ),
      );
    } catch (e) {
      // 对齐 iOS：任何异常均视为「无 TMDB 数据」→ 上层回退豆瓣。
      return const Success<TmdbEnrichment?>(null);
    }
  }
}