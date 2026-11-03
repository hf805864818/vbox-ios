/// 核心层单测：字符串工具 + 时间工具。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/core/utils/string_utils.dart';
import 'package:vbox/core/utils/time_utils.dart';

void main() {
  group('StringUtils', () {
    test('isBlank / isNotBlank', () {
      expect(StringUtils.isBlank(null), isTrue);
      expect(StringUtils.isBlank(''), isTrue);
      expect(StringUtils.isBlank('  \t '), isTrue);
      expect(StringUtils.isBlank('a'), isFalse);
      expect(StringUtils.isNotBlank(' a '), isTrue);
    });

    test('truncate', () {
      expect(StringUtils.truncate('abcdef', 10), 'abcdef');
      expect(StringUtils.truncate('abcdef', 3), 'abc…');
      expect(StringUtils.truncate('abcdef', 0), '');
      expect(StringUtils.truncate('abcdef', 3, ellipsis: '..'), 'abc..');
    });

    test('sha256Hex 与标准测试向量一致', () {
      expect(
        StringUtils.sha256Hex('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('md5Hex 与标准测试向量一致', () {
      expect(StringUtils.md5Hex('abc'), '900150983cd24fb0d6963f7d28e17f72');
    });

    test('stripHtmlTags + decodeHtmlEntities', () {
      expect(StringUtils.stripHtmlTags('<p>hi</p>'), 'hi');
      expect(
        StringUtils.decodeHtmlEntities('a&amp;b&nbsp;c&lt;d&gt;'),
        'a&b c<d>',
      );
    });

    test('hostOf / extensionOf', () {
      expect(StringUtils.hostOf('https://a.example.com/x/y.mp4'), 'a.example.com');
      expect(StringUtils.hostOf('not a url'), '');
      expect(StringUtils.extensionOf('https://a.com/v.MP4?x=1'), 'mp4');
      expect(StringUtils.extensionOf('https://a.com/noext'), '');
      expect(StringUtils.extensionOf('https://a.com/'), '');
    });

    test('resolveUrl 相对路径拼接', () {
      expect(
        StringUtils.resolveUrl('https://a.com/dir/page.html', '../x.js').toString(),
        'https://a.com/x.js',
      );
      expect(
        StringUtils.resolveUrl('https://a.com/d/', 'b.js').toString(),
        'https://a.com/d/b.js',
      );
      // 未闭合 IPv6 主机 → Uri.tryParse 返回 null
      expect(StringUtils.resolveUrl('http://[::1', 'x'), isNull);
    });
  });

  group('TimeUtils', () {
    test('Unix 秒往返', () {
      final DateTime dt = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      expect(TimeUtils.toUnixSeconds(dt), 1700000000);
      expect(TimeUtils.fromUnixSeconds(1700000000), dt);
    });

    test('nowUnixSeconds 与系统时间同秒', () {
      final int a = TimeUtils.nowUnixSeconds();
      final int b = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect((a - b).abs() <= 1, isTrue);
    });

    test('formatDateTime / formatUnixSeconds', () {
      final DateTime dt = DateTime(2026, 1, 2, 3, 4, 5);
      expect(TimeUtils.formatDateTime(dt), '2026-01-02 03:04:05');
      expect(
        TimeUtils.formatUnixSeconds(TimeUtils.toUnixSeconds(dt)),
        '2026-01-02 03:04:05',
      );
      expect(
        TimeUtils.formatDateTime(dt, pattern: 'yyyy/MM/dd'),
        '2026/01/02',
      );
    });

    test('relative 分级', () {
      final DateTime now = DateTime(2026, 1, 10, 12, 0, 0);
      expect(TimeUtils.relative(now.subtract(const Duration(seconds: 30)), now: now), '刚刚');
      expect(TimeUtils.relative(now.subtract(const Duration(minutes: 5)), now: now), '5 分钟前');
      expect(TimeUtils.relative(now.subtract(const Duration(hours: 3)), now: now), '3 小时前');
      expect(TimeUtils.relative(now.subtract(const Duration(days: 2)), now: now), '2 天前');
      expect(
        TimeUtils.relative(now.subtract(const Duration(days: 40)), now: now),
        '2025-12-01',
      );
      // 未来时间降级为绝对时间
      expect(
        TimeUtils.relative(now.add(const Duration(hours: 1)), now: now),
        '2026-01-10 13:00:00',
      );
    });

    test('duration 格式化', () {
      expect(TimeUtils.duration(const Duration(seconds: 65)), '01:05');
      expect(
        TimeUtils.duration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03',
      );
      expect(TimeUtils.durationFromSeconds(59), '00:59');
      expect(TimeUtils.duration(const Duration(seconds: -5)), '-00:05');
    });
  });
}
