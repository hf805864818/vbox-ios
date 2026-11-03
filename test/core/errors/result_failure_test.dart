/// 核心层单测：Result 与 Failure 归一。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/core/errors/errors.dart';
import 'package:vbox/core/utils/result.dart';

void main() {
  group('Result', () {
    test('Success 取值与 fold', () {
      const Result<int> r = Success<int>(7);
      expect(r.isSuccess, isTrue);
      expect(r.valueOrNull, 7);
      expect(r.failureOrNull, isNull);
      expect(r.fold((int v) => 'ok:$v', (Failure f) => 'err'), 'ok:7');
      expect(r.toString(), 'Success(7)');
    });

    test('Err 取值与 fold', () {
      const Failure f = ParseFailure('坏数据');
      const Result<int> r = Err<int>(f);
      expect(r.isSuccess, isFalse);
      expect(r.valueOrNull, isNull);
      expect(r.failureOrNull, same(f));
      expect(r.fold((int v) => 'ok', (Failure x) => 'err:${x.code.name}'), 'err:parse');
    });

    test('map 只作用于成功分支', () {
      const Result<int> ok = Success<int>(2);
      const Result<int> bad = Err<int>(UnknownFailure('x'));
      expect(ok.map((int v) => v * 3).valueOrNull, 6);
      expect(bad.map((int v) => v * 3).isSuccess, isFalse);
      expect(bad.map((int v) => v * 3).failureOrNull?.message, 'x');
    });
  });

  group('Failure.from 归一', () {
    test('已是 Failure 原样返回', () {
      const Failure f = CryptoFailure('x');
      expect(Failure.from(f), same(f));
    });

    test('NetworkException → NetworkFailure（可重试）', () {
      final Failure f = Failure.from(
        const NetworkException('超时', code: ErrorCode.networkTimeout),
      );
      expect(f, isA<NetworkFailure>());
      expect(f.code, ErrorCode.networkTimeout);
      expect(f.isRetryable, isTrue);
    });

    test('DatabaseException → DatabaseFailure（迁移失败不可重试）', () {
      final Failure mig = Failure.from(
        const DatabaseException('迁移失败', code: ErrorCode.dbMigration),
      );
      expect(mig, isA<DatabaseFailure>());
      expect(mig.isRetryable, isFalse);

      final Failure q = Failure.from(const DatabaseException('查询失败'));
      expect(q.isRetryable, isTrue);
    });

    test('ParseException → ParseFailure（不可重试）', () {
      final Failure f = Failure.from(const ParseException('坏 JSON'));
      expect(f, isA<ParseFailure>());
      expect(f.code, ErrorCode.parse);
      expect(f.isRetryable, isFalse);
    });

    test('StorageException / CryptoException / UnsupportedPlatformException', () {
      expect(Failure.from(const StorageException('写失败')), isA<StorageFailure>());
      expect(Failure.from(const CryptoException('解密失败')), isA<CryptoFailure>());
      expect(
        Failure.from(const UnsupportedPlatformException('TV 音量键')),
        isA<UnsupportedFailure>(),
      );
      expect(Failure.from(const SpiderRuntimeException('引擎崩溃')), isA<SpiderFailure>());
    });

    test('普通错误 → UnknownFailure（可自定义文案）', () {
      final Failure f = Failure.from(ArgumentError('x'));
      expect(f, isA<UnknownFailure>());
      expect(f.code, ErrorCode.unknown);
      expect(f.isRetryable, isFalse);

      final Failure custom = Failure.from(ArgumentError('x'), message: '自定义');
      expect(custom.message, '自定义');
    });

    test('异常 toString 含错误码与 cause', () {
      final String s = const NetworkException('断了', code: ErrorCode.networkUnreachable)
          .toString();
      expect(s.contains('networkUnreachable'), isTrue);
      expect(s.contains('断了'), isTrue);
    });
  });
}
