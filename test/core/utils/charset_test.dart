/// 核心层单测：字符集原语（契约 §4.2）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/core/utils/charset.dart';

void main() {
  // 全局码表是可变状态，逐用例重置以保证独立性
  setUp(() => registerCharsetTables(gbk: <int, String>{}, big5: <int, String>{}));

  group('normalizeCharset', () {
    test('UTF-8 两种写法归一', () {
      expect(normalizeCharset('UTF-8'), 'utf-8');
      expect(normalizeCharset(' utf8 '), 'utf-8');
      expect(normalizeCharset('"utf-8"'), 'utf-8');
    });

    test('GBK 8 变体归一', () {
      for (final String v in <String>[
        'gbk',
        'gb2312',
        'gb-2312',
        'gb18030',
        'gb-18030',
        'gb18030-2000',
        'GBK',
        'GB2312',
      ]) {
        expect(normalizeCharset(v), 'gbk', reason: v);
      }
    });

    test('Big5 / Latin1 归一', () {
      expect(normalizeCharset('big5'), 'big5');
      expect(normalizeCharset('big-5'), 'big5');
      expect(normalizeCharset('iso-8859-1'), 'latin1');
      expect(normalizeCharset('latin-1'), 'latin1');
      expect(normalizeCharset('latin1'), 'latin1');
    });

    test('未知编码原样返回（小写去引号）', () {
      expect(normalizeCharset('Shift_JIS'), 'shift_jis');
    });
  });

  group('charsetFromContentType', () {
    test('提取 charset', () {
      expect(
        charsetFromContentType('text/html; charset=utf-8'),
        'utf-8',
      );
      expect(
        charsetFromContentType('text/html;charset=GBK;foo=bar'),
        'GBK',
      );
    });

    test('无 charset 返回 null', () {
      expect(charsetFromContentType('text/html'), isNull);
      expect(charsetFromContentType(null), isNull);
    });
  });

  group('sniffMetaCharset', () {
    test('识别 meta charset（双引号 / 单引号 / 无引号）', () {
      expect(
        sniffMetaCharset(
          Uint8List.fromList('<html><head><meta charset="gbk"></head>'.codeUnits),
        ),
        'gbk',
      );
      expect(
        sniffMetaCharset(
          Uint8List.fromList("<meta http-equiv='Content-Type' charset='Big5'>".codeUnits),
        ),
        'Big5',
      );
      expect(
        sniffMetaCharset(
          Uint8List.fromList('<meta charset=utf-8>'.codeUnits),
        ),
        'utf-8',
      );
    });

    test('无 meta 返回 null', () {
      expect(sniffMetaCharset(Uint8List.fromList('<html></html>'.codeUnits)), isNull);
    });
  });

  group('decodeBytesWith', () {
    test('utf-8 合法字节', () {
      expect(decodeBytesWith(Uint8List.fromList(utf8.encode('中文')), 'utf-8'), '中文');
    });

    test('utf-8 非法字节返回 null（不静默替换）', () {
      expect(decodeBytesWith(Uint8List.fromList(<int>[0xC4, 0xE3]), 'utf-8'), isNull);
    });

    test('latin1 恒成功', () {
      expect(decodeBytesWith(Uint8List.fromList(<int>[0xC4, 0xE3]), 'latin1'), 'Äã');
    });

    test('未注册码表时 gbk / big5 返回 null（不产出乱码）', () {
      expect(hasMultibyteTables, isFalse);
      expect(decodeBytesWith(Uint8List.fromList(<int>[0xC4, 0xE3]), 'gbk'), isNull);
      expect(decodeBytesWith(Uint8List.fromList(<int>[0xA4, 0x40]), 'big5'), isNull);
    });

    test('注册码表后可解码多字节', () {
      registerCharsetTables(gbk: <int, String>{0xC4E3: '你'});
      addTearDown(() => registerCharsetTables(gbk: <int, String>{}));
      expect(hasMultibyteTables, isTrue);
      expect(decodeBytesWith(Uint8List.fromList(<int>[0xC4, 0xE3]), 'gbk'), '你');
      // ASCII 区不受码表影响
      expect(decodeBytesWith(Uint8List.fromList('ok'.codeUnits), 'gbk'), 'ok');
    });

    test('注册码表后严格语义：未覆盖对 / 悬空高位字节 → null（B-09）', () {
      registerCharsetTables(gbk: <int, String>{0xC4E3: '你'});
      addTearDown(() => registerCharsetTables(gbk: <int, String>{}));
      // 未覆盖双字节对：不静默替换、不吞字节 → 该级失败（链式回退前提）
      expect(decodeBytesWith(Uint8List.fromList(<int>[0xC4, 0xE4]), 'gbk'), isNull);
      // 悬空高位字节
      expect(decodeBytesWith(Uint8List.fromList(<int>[0xC4]), 'gbk'), isNull);
      // 已覆盖对不受影响
      expect(decodeBytesWith(Uint8List.fromList(<int>[0xC4, 0xE3]), 'gbk'), '你');
    });

    test('未知编码名返回 null', () {
      expect(decodeBytesWith(Uint8List.fromList(<int>[1, 2, 3]), 'shift_jis'), isNull);
    });
  });
}
