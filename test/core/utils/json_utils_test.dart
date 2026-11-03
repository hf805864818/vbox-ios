/// 核心层单测：JSON 安全取值。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/core/utils/json_utils.dart';

void main() {
  group('asString', () {
    test('基础转换', () {
      expect(JsonUtils.asString('a'), 'a');
      expect(JsonUtils.asString(12), '12');
      expect(JsonUtils.asString(1.5), '1.5');
      expect(JsonUtils.asString(true), 'true');
      expect(JsonUtils.asString(null), isNull);
      expect(JsonUtils.asString(<int>[1]), isNull);
    });
  });

  group('asInt', () {
    test('数值 / 字符串 / 布尔宽容转换', () {
      expect(JsonUtils.asInt(12), 12);
      expect(JsonUtils.asInt(12.9), 12);
      expect(JsonUtils.asInt(12.0), 12);
      expect(JsonUtils.asInt(' 42 '), 42);
      expect(JsonUtils.asInt(true), 1);
      expect(JsonUtils.asInt(false), 0);
      expect(JsonUtils.asInt('abc'), isNull);
      expect(JsonUtils.asInt(null), isNull);
      expect(JsonUtils.asInt(double.nan), isNull);
    });
  });

  group('asDouble', () {
    test('基础转换', () {
      expect(JsonUtils.asDouble(1.5), 1.5);
      expect(JsonUtils.asDouble(2), 2.0);
      expect(JsonUtils.asDouble('3.25'), 3.25);
      expect(JsonUtils.asDouble('x'), isNull);
    });
  });

  group('asBool', () {
    test('1/0 与 yes/no 等写法', () {
      for (final String v in <String>['true', 'TRUE', '1', 'yes', 'y']) {
        expect(JsonUtils.asBool(v), isTrue, reason: v);
      }
      for (final String v in <String>['false', '0', 'no', 'n']) {
        expect(JsonUtils.asBool(v), isFalse, reason: v);
      }
      expect(JsonUtils.asBool(1), isTrue);
      expect(JsonUtils.asBool(0), isFalse);
      expect(JsonUtils.asBool('maybe'), isNull);
      expect(JsonUtils.asBool(null), isNull);
    });
  });

  group('asList / asMap / asMapList', () {
    test('非目标类型返回空容器（不抛异常）', () {
      expect(JsonUtils.asList(null), isEmpty);
      expect(JsonUtils.asList('nope'), isEmpty);
      expect(JsonUtils.asList(<Object?>[1, 2]), <Object?>[1, 2]);
      expect(JsonUtils.asMap(null), isEmpty);
      expect(JsonUtils.asMap(<String, Object?>{'a': 1})['a'], 1);
    });

    test('key 统一 toString', () {
      final Map<String, Object?> m = JsonUtils.asMap(<Object?, Object?>{1: 'a'});
      expect(m['1'], 'a');
    });

    test('asMapList 丢弃非对象元素', () {
      final List<Map<String, Object?>> list =
          JsonUtils.asMapList(<Object?>[
        <String, Object?>{'a': 1},
        'skip',
        7,
        <String, Object?>{'b': 2},
      ]);
      expect(list.length, 2);
      expect(list[1]['b'], 2);
    });
  });

  group('decode', () {
    test('tryDecodeMap 合法 / 非法', () {
      expect(JsonUtils.tryDecodeMap('{"a":1}')?['a'], 1);
      expect(JsonUtils.tryDecodeMap('[1,2]'), isNull);
      expect(JsonUtils.tryDecodeMap('oops'), isNull);
    });

    test('tryDecodeList 合法 / 非法', () {
      expect(JsonUtils.tryDecodeList('[1,2]'), <Object?>[1, 2]);
      expect(JsonUtils.tryDecodeList('{"a":1}'), isNull);
      expect(JsonUtils.tryDecodeList('oops'), isNull);
    });

    test('encode / decode 往返', () {
      const Map<String, Object?> src = <String, Object?>{'a': 1, 'b': 'x'};
      final Object? back = JsonUtils.decode(JsonUtils.encode(src));
      expect(JsonUtils.asMap(back)['b'], 'x');
    });
  });

  group('pick* 便捷取值', () {
    test('带默认值', () {
      final Map<String, Object?> m = <String, Object?>{
        's': 'v',
        'i': '7',
        'b': 1,
        'o': <String, Object?>{'k': 'kv'},
      };
      expect(JsonUtils.pickString(m, 's'), 'v');
      expect(JsonUtils.pickString(m, 'missing'), isNull);
      expect(JsonUtils.pickStringOr(m, 'missing', 'd'), 'd');
      expect(JsonUtils.pickInt(m, 'i'), 7);
      expect(JsonUtils.pickInt(m, 'missing', fallback: 3), 3);
      expect(JsonUtils.pickBool(m, 'b'), isTrue);
      expect(JsonUtils.pickBool(m, 'missing'), isFalse);
      expect(JsonUtils.pickMap(m, 'o')['k'], 'kv');
      expect(JsonUtils.pickMap(m, 'missing'), isEmpty);
    });
  });
}
