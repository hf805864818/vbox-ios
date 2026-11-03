/// 播放请求头集中层单测（F-P12）。
///
/// 对齐基准（唯一真相源）：
/// - iOS `initPlayer` 缺省播放头（`vbox/Views/PlayerViewsV2.swift:6446-6450`）；
/// - iOS 阿里步骤7「转码 m3u8 不注入 UA/Referer」特例
///   （`vbox/Services/AliyunPgPlayManager.swift:306-323`）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/player/playback_headers.dart';

void main() {
  group('缺省播放头常量（逐字对齐 iOS initPlayer）', () {
    test('UA / Accept / Accept-Language', () {
      expect(
        PlaybackHeaders.defaultUserAgent,
        'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 '
        'Safari/604.1',
      );
      expect(PlaybackHeaders.defaultAccept, '*/*');
      expect(PlaybackHeaders.defaultAcceptLanguage, 'zh-CN,zh;q=0.9');
    });

    test('阿里直链缺省头（步骤7）', () {
      expect(
        PlaybackHeaders.aliyunDesktopUA,
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
      );
      expect(PlaybackHeaders.aliyunReferer, 'https://api.alipan.com');
    });
  });

  group('isAliTranscodeM3u8（对齐 iOS 步骤7 判据）', () {
    test('host 含 aliyun+video 且 path 含 /lt/ 或 /qv/ → true', () {
      expect(
        PlaybackHeaders.isAliTranscodeM3u8(
          'https://cn-beijing-video-preview.aliyundrive.net/lt/abc/index.m3u8',
        ),
        isTrue,
      );
      expect(
        PlaybackHeaders.isAliTranscodeM3u8(
          'https://cn-video.aliyundrive.net/qv/x/y.m3u8',
        ),
        isTrue,
      );
    });

    test('数据 CDN / 直链下载 / 非阿里域名 → false', () {
      expect(
        PlaybackHeaders.isAliTranscodeM3u8(
          'https://data.aliyundrive.net/raw.mp4',
        ),
        isFalse,
      );
      expect(
        PlaybackHeaders.isAliTranscodeM3u8(
          'https://cdn.example.com/v.m3u8',
        ),
        isFalse,
      );
      expect(PlaybackHeaders.isAliTranscodeM3u8('not a url'), isFalse);
    });

    test('isTranscodeM3u8 与 isAliTranscodeM3u8 同口径', () {
      const String url = 'https://video.aliyun.example/lt/a.m3u8';
      expect(
        PlaybackHeaders.isTranscodeM3u8(url),
        PlaybackHeaders.isAliTranscodeM3u8(url),
      );
    });
  });

  group('stripAuthHeaders（忽略大小写剔除 UA / Referer）', () {
    test('剔除 User-Agent / referer，保留其余', () {
      final Map<String, String> out = PlaybackHeaders.stripAuthHeaders(
        <String, String>{
          'user-agent': 'UA',
          'Referer': 'https://api.alipan.com',
          'Cookie': 'a=1',
          'X-Custom': '1',
        },
      );
      expect(out, <String, String>{'Cookie': 'a=1', 'X-Custom': '1'});
    });

    test('空表原样返回（同一实例）', () {
      const Map<String, String> empty = <String, String>{};
      expect(identical(PlaybackHeaders.stripAuthHeaders(empty), empty), isTrue);
    });
  });

  group('guardTranscode（集中固化「转码不注入 UA/Referer」）', () {
    final Map<String, String> headers = <String, String>{
      'User-Agent': PlaybackHeaders.aliyunDesktopUA,
      'Referer': PlaybackHeaders.aliyunReferer,
      'Cookie': 'a=1',
    };

    test('url 命中特例 → 剔除 UA / Referer', () {
      final Map<String, String> out = PlaybackHeaders.guardTranscode(
        url: 'https://cn-video.aliyundrive.net/lt/x.m3u8',
        headers: headers,
      );
      expect(out.containsKey('User-Agent'), isFalse);
      expect(out.containsKey('Referer'), isFalse);
      expect(out['Cookie'], 'a=1');
    });

    test('forcedTranscode=true → 即使 url 未命中仍剔除（调用方已确定转码线路）', () {
      final Map<String, String> out = PlaybackHeaders.guardTranscode(
        url: 'https://cdn.example.com/trans.m3u8',
        headers: headers,
        forcedTranscode: true,
      );
      expect(out.containsKey('User-Agent'), isFalse);
      expect(out.containsKey('Referer'), isFalse);
    });

    test('非转码 → 原样返回（同一实例）', () {
      final Map<String, String> out = PlaybackHeaders.guardTranscode(
        url: 'https://cdn.example.com/raw.mp4',
        headers: headers,
      );
      expect(identical(out, headers), isTrue);
    });
  });
}