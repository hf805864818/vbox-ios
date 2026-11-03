/// 单元测试：Spider 错误模型与错误检测辅助。
///
/// 对应源码：lib/domain/entities/spider/spider_engine.dart
/// 契约：contract/docs/abi_v1.md §5（错误检测规则 + 注册检测）
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/domain/entities/spider/spider_engine.dart';

void main() {
  group('SpiderErrorCode 枚举值', () {
    test('成员数量与顺序（契约 §5.1 建议错误码）', () {
      expect(SpiderErrorCode.values, <SpiderErrorCode>[
        SpiderErrorCode.register,
        SpiderErrorCode.scriptLoad,
        SpiderErrorCode.protocol,
        SpiderErrorCode.timeout,
        SpiderErrorCode.runtime,
        SpiderErrorCode.unsupported,
        SpiderErrorCode.unimplemented,
      ]);
      expect(SpiderErrorCode.values.length, 7);
    });

    test('name 与契约场景映射一致', () {
      expect(SpiderErrorCode.register.name, 'register');
      expect(SpiderErrorCode.scriptLoad.name, 'scriptLoad');
      expect(SpiderErrorCode.protocol.name, 'protocol');
      expect(SpiderErrorCode.timeout.name, 'timeout');
      expect(SpiderErrorCode.runtime.name, 'runtime');
    });
  });

  group('SpiderException', () {
    test('字段与 toString 格式', () {
      const SpiderException e =
          SpiderException(SpiderErrorCode.register, '未找到 __JS_SPIDER__');
      expect(e.code, SpiderErrorCode.register);
      expect(e.message, '未找到 __JS_SPIDER__');
      expect(e.toString(),
          'SpiderException[register]: 未找到 __JS_SPIDER__');
    });

    test('toString 使用错误码 name（如 protocol）', () {
      const SpiderException e = SpiderException(SpiderErrorCode.protocol, 'JS 返回 nil');
      expect(e.toString(), 'SpiderException[protocol]: JS 返回 nil');
    });

    test('实现 Exception（可被 catch 捕获）', () {
      const SpiderException e = SpiderException(SpiderErrorCode.timeout, 't');
      expect(e, isA<Exception>());
    });
  });

  group('SpiderErrorDetector.looksLikeError', () {
    test('4 个契约前缀均识别为错误', () {
      expect(SpiderErrorDetector.looksLikeError('Error: boom'), isTrue);
      expect(SpiderErrorDetector.looksLikeError('TypeError: bad'), isTrue);
      expect(SpiderErrorDetector.looksLikeError('ReferenceError: x'), isTrue);
      expect(SpiderErrorDetector.looksLikeError('SyntaxError: y'), isTrue);
    });

    test('前缀判定基于 startsWith（含更长前缀也命中）', () {
      expect(SpiderErrorDetector.looksLikeError('TypeErrorXYZ'), isTrue);
      expect(SpiderErrorDetector.looksLikeError('Errorfoo'), isTrue);
    });

    test('方法不做内部 trim，前导空白导致漏判（契约以已 trim 串为输入）', () {
      expect(SpiderErrorDetector.looksLikeError(' Error: boom'), isFalse);
    });

    test('非错误串 / 空串 → false', () {
      expect(SpiderErrorDetector.looksLikeError(''), isFalse);
      expect(SpiderErrorDetector.looksLikeError('ok'), isFalse);
      expect(SpiderErrorDetector.looksLikeError('error: lowercase'), isFalse);
      expect(SpiderErrorDetector.looksLikeError('null'), isFalse);
    });
  });

  group('SpiderErrorDetector.isRegistered', () {
    test('契约三种等价形式：object / "object" / 含 object', () {
      expect(SpiderErrorDetector.isRegistered('object'), isTrue);
      expect(SpiderErrorDetector.isRegistered('"object"'), isTrue);
      expect(SpiderErrorDetector.isRegistered('typeof -> object'), isTrue);
    });

    test('输入自动 trim', () {
      expect(SpiderErrorDetector.isRegistered('  object  '), isTrue);
      expect(SpiderErrorDetector.isRegistered('\t"object"\n'), isTrue);
    });

    test('大小写敏感：Object 不识别', () {
      expect(SpiderErrorDetector.isRegistered('Object'), isFalse);
    });

    test('未注册 / 空 / 其他类型 → false', () {
      expect(SpiderErrorDetector.isRegistered('undefined'), isFalse);
      expect(SpiderErrorDetector.isRegistered('function'), isFalse);
      expect(SpiderErrorDetector.isRegistered(''), isFalse);
      expect(SpiderErrorDetector.isRegistered('null'), isFalse);
    });

    test('含 object 子串的宽判定（如 noobject）→ true', () {
      // 契约字面要求「含 object」，此处如实记录其宽泛性
      expect(SpiderErrorDetector.isRegistered('noobject'), isTrue);
    });
  });
}