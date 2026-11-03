/// G-02-A：MediaKitProfile 起播调优档分派（纯 Dart，无原生依赖）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/player/player.dart';
import 'package:vbox/platform/player/media_kit_profile.dart';

void main() {
  group('MediaKitProfile.forSource', () {
    test('直播源 → live 档（压低起播延迟）', () {
      expect(
        MediaKitProfile.forSource(
          const PlayerSource(url: 'https://x/live.flv', isLive: true),
        ),
        MediaKitProfile.live,
      );
    });

    test('HLS（m3u8）→ live 档', () {
      expect(
        MediaKitProfile.forSource(
          const PlayerSource(url: 'https://x/stream.m3u8'),
        ),
        MediaKitProfile.live,
      );
    });

    test('复杂封装（URL 含 .mkv）→ largeContainer 档', () {
      expect(
        MediaKitProfile.forSource(
          const PlayerSource(url: 'https://x/movie.mkv'),
        ),
        MediaKitProfile.largeContainer,
      );
    });

    test('复杂封装（仅真实标题含扩展名，URL 无扩展名）→ largeContainer 档', () {
      expect(
        MediaKitProfile.forSource(
          const PlayerSource(
            url: 'http://127.0.0.1:58080/spider/push/abc',
            title: '蓝光原盘.m2ts',
          ),
        ),
        MediaKitProfile.largeContainer,
      );
    });

    test('常规点播（mp4）→ onDemand 档', () {
      expect(
        MediaKitProfile.forSource(
          const PlayerSource(url: 'https://x/a.mp4'),
        ),
        MediaKitProfile.onDemand,
      );
    });

    test('档位常量数值符合 uz 逆向基线', () {
      expect(MediaKitProfile.onDemand.demuxerMaxBytes, 64 * 1024 * 1024);
      expect(MediaKitProfile.onDemand.demuxerReadaheadSecs, 60.0);
      expect(MediaKitProfile.largeContainer.demuxerMaxBytes, 256 * 1024 * 1024);
      expect(MediaKitProfile.largeContainer.demuxerReadaheadSecs, 120.0);
      expect(MediaKitProfile.live.demuxerMaxBytes, 32 * 1024 * 1024);
      expect(MediaKitProfile.live.demuxerReadaheadSecs, 10.0);
    });
  });
}