/// 领域层单测：TMDB 实体（批次 G · G-06）。
///
/// 对齐真相源：iOS `vbox/Services/TMDBService.swift` L149-L301（Models 段）：
///   · `TMDBSearchResult` / `TMDBImages` / `TMDBImage` / `TMDBCredits` /
///     `TMDBCast` / `TMDBCrew` 字段与 JSON 键；
///   · `bestLogo`（中文优先 → 英文 → 最高票）/ `bestPoster`（竖版最高票）/
///     `bestBackdrop`（最高票）；
///   · `TMDBCredits.actors / directors / writers` 归一映射。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/tmdb/tmdb_models.dart';

void main() {
  group('TmdbSearchResult（对齐 iOS TMDBSearchResult）', () {
    test('fromJson 解析蛇形键 + displayTitle + URL 拼接', () {
      final TmdbSearchResult r = TmdbSearchResult.fromJson(<String, Object?>{
        'id': 550,
        'media_type': 'movie',
        'title': '搏击俱乐部',
        'poster_path': '/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg',
        'backdrop_path': '/hZkgoQYus5vegHoetLkCJzb17zJ.jpg',
        'release_date': '1999-10-15',
      });
      expect(r.id, 550);
      expect(r.mediaType, 'movie');
      expect(r.displayTitle, '搏击俱乐部');
      expect(r.isMovieOrTv, isTrue);
      expect(
        r.posterUrl,
        '$kTmdbImageBaseUrl/w500/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg',
      );
      expect(
        r.backdropUrl,
        '$kTmdbImageBaseUrl/original/hZkgoQYus5vegHoetLkCJzb17zJ.jpg',
      );
    });

    test('tv：name 兜底 displayTitle + 缺图路径 → URL 为 null', () {
      final TmdbSearchResult r = TmdbSearchResult.fromJson(<String, Object?>{
        'id': 1399,
        'media_type': 'tv',
        'name': '权力的游戏',
      });
      expect(r.title, isNull);
      expect(r.displayTitle, '权力的游戏');
      expect(r.posterUrl, isNull);
      expect(r.backdropUrl, isNull);
    });

    test('非 movie/tv 不参与匹配', () {
      final TmdbSearchResult r = TmdbSearchResult.fromJson(<String, Object?>{
        'id': 1,
        'media_type': 'person',
      });
      expect(r.isMovieOrTv, isFalse);
    });
  });

  group('TmdbImage / TmdbImages', () {
    test('TmdbImage 三档 URL（original / w500 / w1280）', () {
      final TmdbImage i = TmdbImage.fromJson(<String, Object?>{
        'file_path': '/x.jpg',
        'aspect_ratio': 0.667,
        'width': 1000,
        'height': 1500,
        'vote_average': 5.5,
        'iso_639_1': 'zh',
      });
      expect(i.originalUrl, '$kTmdbImageBaseUrl/original/x.jpg');
      expect(i.w500Url, '$kTmdbImageBaseUrl/w500/x.jpg');
      expect(i.w1280Url, '$kTmdbImageBaseUrl/w1280/x.jpg');
      expect(i.language, 'zh');
    });

    test('bestLogo：中文优先 → 英文 → 最高票', () {
      final TmdbImages zhAndEn = TmdbImages.fromJson(<String, Object?>{
        'id': 1,
        'logos': <Map<String, Object?>>[
          <String, Object?>{'file_path': '/en.png', 'iso_639_1': 'en', 'vote_average': 9},
          <String, Object?>{'file_path': '/zh.png', 'iso_639_1': 'zh', 'vote_average': 1},
        ],
      });
      expect(zhAndEn.bestLogo!.filePath, '/zh.png');

      final TmdbImages enOnly = TmdbImages.fromJson(<String, Object?>{
        'id': 1,
        'logos': <Map<String, Object?>>[
          <String, Object?>{'file_path': '/none.png', 'iso_639_1': null, 'vote_average': 9},
          <String, Object?>{'file_path': '/en.png', 'iso_639_1': 'en', 'vote_average': 1},
        ],
      });
      expect(enOnly.bestLogo!.filePath, '/en.png');

      final TmdbImages fallback = TmdbImages.fromJson(<String, Object?>{
        'id': 1,
        'logos': <Map<String, Object?>>[
          <String, Object?>{'file_path': '/a.png', 'iso_639_1': 'fr', 'vote_average': 3},
          <String, Object?>{'file_path': '/b.png', 'iso_639_1': 'de', 'vote_average': 7},
        ],
      });
      expect(fallback.bestLogo!.filePath, '/b.png');
      expect(const TmdbImages(id: 1).bestLogo, isNull);
    });

    test('bestPoster：仅取竖版（aspect<1）最高票', () {
      final TmdbImages images = TmdbImages.fromJson(<String, Object?>{
        'id': 1,
        'posters': <Map<String, Object?>>[
          <String, Object?>{
            'file_path': '/wide.jpg',
            'aspect_ratio': 1.78,
            'vote_average': 9,
          },
          <String, Object?>{
            'file_path': '/v1.jpg',
            'aspect_ratio': 0.667,
            'vote_average': 3,
          },
          <String, Object?>{
            'file_path': '/v2.jpg',
            'aspect_ratio': 0.75,
            'vote_average': 8,
          },
        ],
      });
      expect(images.bestPoster!.filePath, '/v2.jpg');
    });

    test('bestBackdrop：最高票；空集 → null', () {
      final TmdbImages images = TmdbImages.fromJson(<String, Object?>{
        'id': 1,
        'backdrops': <Map<String, Object?>>[
          <String, Object?>{'file_path': '/a.jpg', 'vote_average': 2},
          <String, Object?>{'file_path': '/b.jpg', 'vote_average': 6},
        ],
      });
      expect(images.bestBackdrop!.filePath, '/b.jpg');
      expect(const TmdbImages(id: 1).bestBackdrop, isNull);
    });

    test('空 file_path 项被丢弃 + isEmpty', () {
      final TmdbImages images = TmdbImages.fromJson(<String, Object?>{
        'id': 1,
        'logos': <Map<String, Object?>>[
          <String, Object?>{'file_path': '', 'vote_average': 9},
        ],
        'posters': <Map<String, Object?>>[
          <String, Object?>{'file_path': '/p.jpg', 'aspect_ratio': 0.6},
        ],
      });
      expect(images.logos, isEmpty);
      expect(images.posters, hasLength(1));
      expect(images.isEmpty, isFalse);
      expect(const TmdbImages(id: 1).isEmpty, isTrue);
    });
  });

  group('TmdbCredits（对齐 iOS TMDBCredits 映射）', () {
    TmdbCredits credits() => TmdbCredits.fromJson(<String, Object?>{
          'id': 550,
          'cast': <Map<String, Object?>>[
            for (int i = 0; i < 12; i++)
              <String, Object?>{
                'id': 100 + i,
                'name': '演员$i',
                'character': '角色$i',
                'profile_path': '/a$i.jpg',
              },
          ],
          'crew': <Map<String, Object?>>[
            <String, Object?>{'id': 1, 'name': '导演甲', 'job': 'Director'},
            <String, Object?>{'id': 2, 'name': '编剧乙', 'job': 'Writer'},
            <String, Object?>{'id': 3, 'name': '编剧丙', 'job': 'Screenplay'},
            <String, Object?>{'id': 4, 'name': '故事丁', 'job': 'Story'},
            <String, Object?>{'id': 5, 'name': '剪辑戊', 'job': 'Editor'},
          ],
        });

    test('actors 取前 10 + coverUrl w185', () {
      final TmdbCredits c = credits();
      expect(c.actors, hasLength(10));
      expect(c.actors.first.id, '100');
      expect(c.actors.first.character, '角色0');
      expect(c.actors.first.coverUrl, '$kTmdbImageBaseUrl/w185/a0.jpg');
    });

    test('directors / writers 过滤 + 无头像 coverUrl 为 null', () {
      final TmdbCredits c = credits();
      expect(c.directors.map((TmdbPerson p) => p.name), <String>['导演甲']);
      expect(
        c.writers.map((TmdbPerson p) => p.name),
        <String>['编剧乙', '编剧丙', '故事丁'],
      );
      expect(c.directors.single.coverUrl, isNull);
      expect(c.hasAny, isTrue);
    });

    test('空演职 → actors/directors/writers 空 + hasAny false', () {
      const TmdbCredits c = TmdbCredits(id: 1);
      expect(c.actors, isEmpty);
      expect(c.directors, isEmpty);
      expect(c.writers, isEmpty);
      expect(c.hasAny, isFalse);
    });
  });

  group('TmdbEnrichment（对齐 iOS 详情增强结果）', () {
    test('hasBackdrop / hasCredits / isEmpty 判定', () {
      const TmdbEnrichment empty = TmdbEnrichment();
      expect(empty.hasBackdrop, isFalse);
      expect(empty.hasCredits, isFalse);
      expect(empty.isEmpty, isTrue);

      const TmdbEnrichment poster = TmdbEnrichment(posterUrl: 'p');
      expect(poster.hasBackdrop, isTrue);
      expect(poster.isEmpty, isFalse);

      const TmdbEnrichment credits = TmdbEnrichment(
        actors: <TmdbPerson>[TmdbPerson(id: '1', name: '甲')],
      );
      expect(credits.hasCredits, isTrue);
      expect(credits.isEmpty, isFalse);
    });
  });
}