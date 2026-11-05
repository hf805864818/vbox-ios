/// 领域层单测：TMDB 剧照与图片基址（批次 B）。
///
/// 独立文件，避免与既有 `tmdb_models_test.dart` 的编码内容互相干扰。
/// 覆盖：`TmdbImages.stills` 的过滤/排序/去重/上限、`TmdbImage.urlOn` 双基址、
/// `TmdbEnrichment.hasStills` 与 `isEmpty`。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/tmdb/tmdb_models.dart';

TmdbImage _img(String path, {double aspect = 1.78, double vote = 5}) =>
    TmdbImage(
      filePath: path,
      aspectRatio: aspect,
      width: 1920,
      height: 1080,
      voteAverage: vote,
    );

void main() {
  group('TmdbImages.stills（剧照 = 横版 backdrops）', () {
    test('过滤掉竖版/方图（aspect < 1.3）', () {
      final TmdbImages images = TmdbImages(
        id: 1,
        backdrops: <TmdbImage>[
          _img('/wide.jpg', aspect: 1.78),
          _img('/square.jpg', aspect: 1.0),
          _img('/tall.jpg', aspect: 0.67),
        ],
      );
      expect(images.stills().map((TmdbImage i) => i.filePath), <String>['/wide.jpg']);
    });

    test('按票数降序 + 同 filePath 去重', () {
      final TmdbImages images = TmdbImages(
        id: 1,
        backdrops: <TmdbImage>[
          _img('/a.jpg', vote: 3),
          _img('/b.jpg', vote: 9),
          _img('/a.jpg', vote: 8),
        ],
      );
      expect(
        images.stills().map((TmdbImage i) => i.filePath),
        <String>['/b.jpg', '/a.jpg'],
      );
    });

    test('limit 生效', () {
      final TmdbImages images = TmdbImages(
        id: 1,
        backdrops: <TmdbImage>[
          for (int i = 0; i < 30; i++) _img('/s$i.jpg', vote: i.toDouble()),
        ],
      );
      expect(images.stills(limit: 10).length, 10);
      expect(images.stills().length, 10);
    });

    test('无 backdrops → 空表', () {
      expect(const TmdbImages(id: 1).stills(), isEmpty);
    });
  });

  group('TmdbImage 双基址', () {
    test('urlOn 默认官方 CloudFront，直连取 Bunny', () {
      final TmdbImage i = _img('/x.jpg');
      expect(i.urlOn('w780'), '$kTmdbImageBaseUrl/w780/x.jpg');
      expect(
        i.urlOn('w780', base: kTmdbImageDirectBaseUrl),
        '$kTmdbImageDirectBaseUrl/w780/x.jpg',
      );
    });

    test('原有 getter 行为不变', () {
      final TmdbImage i = _img('/x.jpg');
      expect(i.originalUrl, '$kTmdbImageBaseUrl/original/x.jpg');
      expect(i.w500Url, '$kTmdbImageBaseUrl/w500/x.jpg');
      expect(i.w1280Url, '$kTmdbImageBaseUrl/w1280/x.jpg');
    });
  });

  group('TmdbEnrichment 剧照判定', () {
    test('有剧照 → hasStills=true 且 isEmpty=false', () {
      const TmdbEnrichment e = TmdbEnrichment(
        stillUrls: <String>['https://images.tmdb.org/t/p/w780/a.jpg'],
      );
      expect(e.hasStills, isTrue);
      expect(e.isEmpty, isFalse);
    });

    test('空对象 → hasStills=false 且 isEmpty=true', () {
      const TmdbEnrichment e = TmdbEnrichment();
      expect(e.hasStills, isFalse);
      expect(e.isEmpty, isTrue);
    });
  });
}
