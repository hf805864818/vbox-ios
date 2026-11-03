/// 领域层：TMDB 实体（批次 G · G-06）。
///
/// 唯一真相源：iOS `vbox/Services/TMDBService.swift` L149-L301（Models 段）
///   · `TMDBSearchResult` / `TMDBImages` / `TMDBImage` / `TMDBCredits` /
///     `TMDBCast` / `TMDBCrew`：字段与 JSON 键（`media_type` / `poster_path` /
///     `file_path` / `aspect_ratio` / `iso_639_1` / `vote_average` / `profile_path`）
///     逐一对齐；
///   · `displayTitle` / `posterURL` / `backdropURL`；
///   · `bestLogo`（中文优先 → 英文 → 最高票）/ `bestPoster`（竖版 `aspect<1`
///     最高票）/ `bestBackdrop`（最高票）。
///
/// 差异登记：
///   · iOS `TMDBCredits.actors/directors/writers` 归一为 `DoubanCelebrity`；
///     Flutter 侧暂无该实体（详情页演职仍为纯文本 chips），故以同形 [TmdbPerson]
///     承接（`id`/`name`/`coverUrl`/`character` 与 iOS 映射一致），待后续详情页
///     富演职卡落地时统一切换。
library;

import '../../../core/utils/json_utils.dart';

/// TMDB 图片基址（对齐 iOS `TMDBService.imageBaseURL`）。
const String kTmdbImageBaseUrl = 'https://image.tmdb.org/t/p';

/// 搜索候选条目（对齐 iOS `TMDBSearchResult`）。
class TmdbSearchResult {
  /// 构造。
  const TmdbSearchResult({
    required this.id,
    required this.mediaType,
    this.title,
    this.name,
    this.posterPath,
    this.backdropPath,
    this.releaseDate,
    this.firstAirDate,
  });

  /// TMDB 影片 ID。
  final int id;

  /// `movie` / `tv`（对齐 iOS `media_type`）。
  final String mediaType;

  /// 电影标题（`movie`）。
  final String? title;

  /// 剧集名（`tv`）。
  final String? name;

  /// 海报相对路径。
  final String? posterPath;

  /// 背景相对路径。
  final String? backdropPath;

  /// 上映日期（电影）。
  final String? releaseDate;

  /// 首播日期（剧集）。
  final String? firstAirDate;

  /// 解析（对齐 iOS `CodingKeys`）。
  factory TmdbSearchResult.fromJson(Map<String, Object?> j) => TmdbSearchResult(
        id: JsonUtils.pickInt(j, 'id'),
        mediaType: JsonUtils.pickString(j, 'media_type') ?? '',
        title: JsonUtils.pickString(j, 'title'),
        name: JsonUtils.pickString(j, 'name'),
        posterPath: JsonUtils.pickString(j, 'poster_path'),
        backdropPath: JsonUtils.pickString(j, 'backdrop_path'),
        releaseDate: JsonUtils.pickString(j, 'release_date'),
        firstAirDate: JsonUtils.pickString(j, 'first_air_date'),
      );

  /// 展示标题（对齐 iOS `displayTitle`）。
  String get displayTitle => title ?? name ?? '';

  /// 是否可参与匹配（对齐 iOS `searchMovie` 的 `mediaType` 过滤）。
  bool get isMovieOrTv => mediaType == 'movie' || mediaType == 'tv';

  /// 海报原始 URL（`w500`，对齐 iOS `posterURL`）。
  String? get posterUrl =>
      posterPath == null ? null : '$kTmdbImageBaseUrl/w500$posterPath';

  /// 背景原始 URL（`original`，对齐 iOS `backdropURL`）。
  String? get backdropUrl =>
      backdropPath == null ? null : '$kTmdbImageBaseUrl/original$backdropPath';
}

/// 单张图片（对齐 iOS `TMDBImage`）。
class TmdbImage {
  /// 构造。
  const TmdbImage({
    required this.filePath,
    required this.aspectRatio,
    required this.width,
    required this.height,
    required this.voteAverage,
    this.language,
  });

  /// 相对路径（`file_path`）。
  final String filePath;

  /// 宽高比（`aspect_ratio`）。
  final double aspectRatio;

  /// 宽。
  final int width;

  /// 高。
  final int height;

  /// 平均票数（`vote_average`）。
  final double voteAverage;

  /// 语言（`iso_639_1`）。
  final String? language;

  /// 解析。
  factory TmdbImage.fromJson(Map<String, Object?> j) => TmdbImage(
        filePath: JsonUtils.pickString(j, 'file_path') ?? '',
        aspectRatio: JsonUtils.asDouble(j['aspect_ratio']) ?? 0,
        width: JsonUtils.pickInt(j, 'width'),
        height: JsonUtils.pickInt(j, 'height'),
        voteAverage: JsonUtils.asDouble(j['vote_average']) ?? 0,
        language: JsonUtils.pickString(j, 'iso_639_1'),
      );

  /// 原图 URL（对齐 iOS `originalURL`）。
  String get originalUrl => '$kTmdbImageBaseUrl/original$filePath';

  /// `w500` URL（对齐 iOS `w500URL`）。
  String get w500Url => '$kTmdbImageBaseUrl/w500$filePath';

  /// `w1280` URL（对齐 iOS `w1280URL`）。
  String get w1280Url => '$kTmdbImageBaseUrl/w1280$filePath';
}

/// 图片集（对齐 iOS `TMDBImages`）。
class TmdbImages {
  /// 构造。
  const TmdbImages({
    required this.id,
    this.logos = const <TmdbImage>[],
    this.posters = const <TmdbImage>[],
    this.backdrops = const <TmdbImage>[],
  });

  /// TMDB 影片 ID。
  final int id;

  /// logo 图集。
  final List<TmdbImage> logos;

  /// 竖/横海报图集。
  final List<TmdbImage> posters;

  /// 背景图集。
  final List<TmdbImage> backdrops;

  /// 解析。
  factory TmdbImages.fromJson(Map<String, Object?> j) => TmdbImages(
        id: JsonUtils.pickInt(j, 'id'),
        logos: _images(j['logos']),
        posters: _images(j['posters']),
        backdrops: _images(j['backdrops']),
      );

  static List<TmdbImage> _images(Object? raw) => JsonUtils.asMapList(raw)
      .map(TmdbImage.fromJson)
      .where((TmdbImage i) => i.filePath.isNotEmpty)
      .toList(growable: false);

  /// 最佳 logo（对齐 iOS `bestLogo`：中文优先 → 英文 → 最高票）。
  TmdbImage? get bestLogo {
    final List<TmdbImage> sorted = List<TmdbImage>.of(logos)
      ..sort((TmdbImage a, TmdbImage b) => b.voteAverage.compareTo(a.voteAverage));
    for (final String code in <String>['zh', 'en']) {
      for (final TmdbImage i in sorted) {
        if (i.language == code) return i;
      }
    }
    return sorted.isEmpty ? null : sorted.first;
  }

  /// 最佳竖版海报（对齐 iOS `bestPoster`：`aspect<1` 最高票）。
  TmdbImage? get bestPoster {
    final List<TmdbImage> vertical = posters
        .where((TmdbImage i) => i.aspectRatio < 1.0)
        .toList(growable: false)
      ..sort((TmdbImage a, TmdbImage b) => b.voteAverage.compareTo(a.voteAverage));
    return vertical.isEmpty ? null : vertical.first;
  }

  /// 最佳背景（对齐 iOS `bestBackdrop`：最高票）。
  TmdbImage? get bestBackdrop {
    if (backdrops.isEmpty) return null;
    final List<TmdbImage> sorted = List<TmdbImage>.of(backdrops)
      ..sort((TmdbImage a, TmdbImage b) => b.voteAverage.compareTo(a.voteAverage));
    return sorted.first;
  }

  /// 是否无任何图片。
  bool get isEmpty => logos.isEmpty && posters.isEmpty && backdrops.isEmpty;
}

/// 演职人员归一实体（对齐 iOS `TMDBCredits` → `DoubanCelebrity` 映射结果）。
class TmdbPerson {
  /// 构造。
  const TmdbPerson({
    required this.id,
    required this.name,
    this.coverUrl,
    this.character,
  });

  /// 人员 ID（TMDB 数值 ID 的字符串形式，对齐 iOS `"\(member.id)"`）。
  final String id;

  /// 姓名。
  final String name;

  /// 头像 URL（`w185`）。
  final String? coverUrl;

  /// 角色 / 职务（`character` 或 `job`，对齐 iOS `character`）。
  final String? character;
}

/// 演员（对齐 iOS `TMDBCast`）。
class TmdbCast {
  /// 构造。
  const TmdbCast({
    required this.id,
    required this.name,
    this.character,
    this.profilePath,
  });

  /// 人员 ID。
  final int id;

  /// 姓名。
  final String name;

  /// 饰演角色。
  final String? character;

  /// 头像相对路径。
  final String? profilePath;

  /// 解析。
  factory TmdbCast.fromJson(Map<String, Object?> j) => TmdbCast(
        id: JsonUtils.pickInt(j, 'id'),
        name: JsonUtils.pickString(j, 'name') ?? '',
        character: JsonUtils.pickString(j, 'character'),
        profilePath: JsonUtils.pickString(j, 'profile_path'),
      );

  /// 归一为 [TmdbPerson]（对齐 iOS `actors` 映射）。
  TmdbPerson toPerson() => TmdbPerson(
        id: '$id',
        name: name,
        coverUrl: profilePath == null
            ? null
            : '$kTmdbImageBaseUrl/w185$profilePath',
        character: character,
      );
}

/// 剧组成员（对齐 iOS `TMDBCrew`）。
class TmdbCrew {
  /// 构造。
  const TmdbCrew({
    required this.id,
    required this.name,
    this.job,
    this.profilePath,
  });

  /// 人员 ID。
  final int id;

  /// 姓名。
  final String name;

  /// 职务（`Director` / `Writer` …）。
  final String? job;

  /// 头像相对路径。
  final String? profilePath;

  /// 解析。
  factory TmdbCrew.fromJson(Map<String, Object?> j) => TmdbCrew(
        id: JsonUtils.pickInt(j, 'id'),
        name: JsonUtils.pickString(j, 'name') ?? '',
        job: JsonUtils.pickString(j, 'job'),
        profilePath: JsonUtils.pickString(j, 'profile_path'),
      );

  /// 归一为 [TmdbPerson]（对齐 iOS `directors` / `writers` 映射）。
  TmdbPerson toPerson() => TmdbPerson(
        id: '$id',
        name: name,
        coverUrl: profilePath == null
            ? null
            : '$kTmdbImageBaseUrl/w185$profilePath',
        character: job,
      );
}

/// 演职人员集（对齐 iOS `TMDBCredits`）。
class TmdbCredits {
  /// 构造。
  const TmdbCredits({
    required this.id,
    this.cast = const <TmdbCast>[],
    this.crew = const <TmdbCrew>[],
  });

  /// TMDB 影片 ID。
  final int id;

  /// 演员表。
  final List<TmdbCast> cast;

  /// 剧组成员。
  final List<TmdbCrew> crew;

  /// 解析。
  factory TmdbCredits.fromJson(Map<String, Object?> j) => TmdbCredits(
        id: JsonUtils.pickInt(j, 'id'),
        cast: JsonUtils.asMapList(j['cast'])
            .map(TmdbCast.fromJson)
            .toList(growable: false),
        crew: JsonUtils.asMapList(j['crew'])
            .map(TmdbCrew.fromJson)
            .toList(growable: false),
      );

  /// 演员（取前 10，对齐 iOS `actors`）。
  List<TmdbPerson> get actors => cast
      .take(10)
      .map((TmdbCast c) => c.toPerson())
      .toList(growable: false);

  /// 导演（`job == "Director"`，对齐 iOS `directors`）。
  List<TmdbPerson> get directors => crew
      .where((TmdbCrew c) => c.job == 'Director')
      .map((TmdbCrew c) => c.toPerson())
      .toList(growable: false);

  /// 编剧（`writer` / `screenplay` / `story`，对齐 iOS `writers`）。
  List<TmdbPerson> get writers => crew
      .where((TmdbCrew c) {
        final String job = c.job?.toLowerCase() ?? '';
        return job == 'writer' || job == 'screenplay' || job == 'story';
      })
      .map((TmdbCrew c) => c.toPerson())
      .toList(growable: false);

  /// 是否有任一演职数据（对齐 iOS `hasTMDBCredits` 判定）。
  bool get hasAny =>
      actors.isNotEmpty || directors.isNotEmpty || writers.isNotEmpty;
}

/// 详情页 TMDB 增强聚合结果（对齐 iOS `VideoDetailView` 的
/// `tmdbLogoURL` / `tmdbPosterURL` / `tmdbBackdropURL` + 演职替换）。
class TmdbEnrichment {
  /// 构造。
  const TmdbEnrichment({
    this.logoUrl,
    this.posterUrl,
    this.backdropUrl,
    this.actors = const <TmdbPerson>[],
    this.directors = const <TmdbPerson>[],
    this.writers = const <TmdbPerson>[],
  });

  /// logo 代理 URL（`w500` 走代理）。
  final String? logoUrl;

  /// 海报代理 URL（`original` 走代理）。
  final String? posterUrl;

  /// 背景代理 URL（`original` 走代理，备用）。
  final String? backdropUrl;

  /// 演员（TMDB 有则替换豆瓣）。
  final List<TmdbPerson> actors;

  /// 导演。
  final List<TmdbPerson> directors;

  /// 编剧。
  final List<TmdbPerson> writers;

  /// 是否有大封面（对齐 iOS `hasTMDBBackdrop`）。
  bool get hasBackdrop => posterUrl != null || backdropUrl != null;

  /// 是否有演职人员（对齐 iOS `hasTMDBCredits`）。
  bool get hasCredits =>
      actors.isNotEmpty || directors.isNotEmpty || writers.isNotEmpty;

  /// 是否存在任何增强内容。
  bool get isEmpty => logoUrl == null && !hasBackdrop && !hasCredits;
}