/// 批次 C · C-12：MediaUrlChecker 探测 + MPV 后端矩阵（注入 MockClient，纯 Dart）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/platform/player/media_url_checker.dart';

void main() {
  group('MediaUrlChecker.check', () {
    test('HEAD 200 + video/mp4 → 可达 + 媒体特征', () async {
      final MediaUrlChecker checker = MediaUrlChecker(
        client: MockClient((http.Request r) async {
          return http.Response(
            '',
            200,
            headers: <String, String>{'Content-Type': 'video/mp4'},
          );
        }),
      );
      final MediaUrlCheckResult r =
          await checker.check('https://x/a.mp4');
      expect(r.reachable, isTrue);
      expect(r.statusCode, 200);
      expect(r.contentType, 'video/mp4');
      expect(r.looksLikeMedia, isTrue);
      expect(r.shouldAttemptPlay, isTrue);
    });

    test('HEAD 405 → 回退 GET(Range) → 206 可达', () async {
      int headCount = 0;
      final MediaUrlChecker checker = MediaUrlChecker(
        client: MockClient((http.Request r) async {
          if (r.method == 'HEAD') {
            headCount++;
            return http.Response('', 405);
          }
          expect(r.headers['Range'], 'bytes=0-0');
          return http.Response(
            '',
            206,
            headers: <String, String>{
              'Content-Type': 'application/vnd.apple.mpegurl',
            },
          );
        }),
      );
      final MediaUrlCheckResult r = await checker.check('https://x/l.m3u8');
      expect(headCount, 1);
      expect(r.reachable, isTrue);
      expect(r.statusCode, 206);
      expect(r.looksLikeMedia, isTrue);
    });

    test('HEAD 404 → 不可达', () async {
      final MediaUrlChecker checker = MediaUrlChecker(
        client: MockClient((http.Request r) async {
          return http.Response('', 404);
        }),
      );
      final MediaUrlCheckResult r = await checker.check('https://x/gone.mp4');
      expect(r.reachable, isFalse);
      expect(r.statusCode, 404);
      expect(r.shouldAttemptPlay, isFalse);
    });

    test('重定向 → effectiveUrl 解析 + redirected 标记', () async {
      final MediaUrlChecker checker = MediaUrlChecker(
        client: MockClient((http.Request r) async {
          if (r.url.path == '/old.mp4') {
            return http.Response('', 302, headers: <String, String>{
              'Location': '/new.mp4',
              'Content-Type': 'text/html',
            });
          }
          return http.Response('', 200, headers: <String, String>{
            'Content-Type': 'video/mp4',
          });
        }),
      );
      final MediaUrlCheckResult r =
          await checker.check('https://x/old.mp4');
      expect(r.redirected, isTrue);
      expect(r.effectiveUrl, 'https://x/new.mp4');
      expect(r.reachable, isTrue);
    });

    test('网络异常 → 不可达（不抛）', () async {
      final MediaUrlChecker checker = MediaUrlChecker(
        client: MockClient((http.Request r) async {
          throw http.ClientException('connection refused');
        }),
      );
      final MediaUrlCheckResult r = await checker.check('https://x/a.mp4');
      expect(r.reachable, isFalse);
      expect(r.statusCode, isNull);
    });

    test('非 http(s) URL → 直接不可达', () async {
      final MediaUrlChecker checker = MediaUrlChecker(
        client: MockClient((http.Request r) async {
          fail('不应发起请求');
        }),
      );
      final MediaUrlCheckResult r = await checker.check('file:///x/a.mp4');
      expect(r.reachable, isFalse);
    });
  });

  group('MpvBackendMatrix.selectInitial', () {
    const List<PlayerBackend> chain = <PlayerBackend>[
      PlayerBackend.libmpv,
      PlayerBackend.media3,
    ];

    test('mpv 偏好 → libmpv', () {
      expect(
        MpvBackendMatrix.selectInitial(
          const PlayerSource(url: 'https://x/a.mp4'),
          MpvBackendPreference.mpv,
          chain,
        ),
        PlayerBackend.libmpv,
      );
    });

    test('free 偏好 → media3', () {
      expect(
        MpvBackendMatrix.selectInitial(
          const PlayerSource(url: 'https://x/a.mp4'),
          MpvBackendPreference.free,
          chain,
        ),
        PlayerBackend.media3,
      );
    });

    test('auto + 复杂封装 → libmpv', () {
      expect(
        MpvBackendMatrix.selectInitial(
          const PlayerSource(url: 'https://x/a.mkv'),
          MpvBackendPreference.auto,
          chain,
        ),
        PlayerBackend.libmpv,
      );
    });

    test('auto + mp4 → media3', () {
      expect(
        MpvBackendMatrix.selectInitial(
          const PlayerSource(url: 'https://x/a.mp4'),
          MpvBackendPreference.auto,
          chain,
        ),
        PlayerBackend.media3,
      );
    });

    test('偏好后端不在链内 → 回退链首', () {
      expect(
        MpvBackendMatrix.selectInitial(
          const PlayerSource(url: 'https://x/a.mp4'),
          MpvBackendPreference.mpv,
          const <PlayerBackend>[PlayerBackend.media3],
        ),
        PlayerBackend.media3,
      );
    });
  });
}
