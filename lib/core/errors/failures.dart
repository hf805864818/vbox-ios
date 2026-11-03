/// 核心层：失败对象（层边界上替代异常）。
///
/// 与 `exceptions.dart` 的关系：
/// - 内层抛 `VBoxException`；
/// - repository / usecase 边界用 [Failure.from] 归一，返回值改为 `Result<T>`；
/// - 表现层只处理 [Failure]，不 catch 具体异常类型。
library;

import '../utils/logger.dart';
import 'exceptions.dart';

/// 失败基类（sealed：表现层可穷举分支）。
sealed class Failure {
  const Failure(this.message, {this.code = ErrorCode.unknown, this.cause});

  /// 日志标签。
  static const String logTag = 'failure';

  /// 人类可读描述（可直接展示给用户）。
  final String message;

  /// 稳定错误码。
  final ErrorCode code;

  /// 原始对象（日志用）。
  final Object? cause;

  /// 是否具备重试价值（UI 依据此决定是否显示「重试」按钮）。
  bool get isRetryable;

  /// 把任意异常归一为 [Failure]。
  ///
  /// 各仓储的 catch 边界统一走此处，故这里也是**错误日志的唯一汇聚点**。
  static Failure from(Object error, {String? message}) {
    if (error is Failure) return error;
    final Failure failure = error is VBoxException
        ? _fromCode(error, message)
        : UnknownFailure(message ?? '$error', cause: error);
    AppLog.error(logTag, failure.toString(), error: error);
    return failure;
  }

  static Failure _fromCode(VBoxException e, String? message) {
    final String msg = message ?? e.message;
    return switch (e.code) {
      ErrorCode.networkTimeout =>
        NetworkFailure.timeout(msg, cause: e.cause, source: e),
      ErrorCode.networkUnreachable => NetworkFailure(
          msg,
          code: ErrorCode.networkUnreachable,
          cause: e.cause,
          source: e,
        ),
      ErrorCode.httpStatus =>
        NetworkFailure(msg, code: ErrorCode.httpStatus, cause: e.cause, source: e),
      ErrorCode.invalidResponse || ErrorCode.parse =>
        ParseFailure(msg, code: e.code, cause: e.cause, source: e),
      ErrorCode.dbOpen ||
      ErrorCode.dbQuery ||
      ErrorCode.dbMigration =>
        DatabaseFailure(msg, code: e.code, cause: e.cause, source: e),
      ErrorCode.storageIo =>
        StorageFailure(msg, cause: e.cause, source: e),
      ErrorCode.crypto => CryptoFailure(msg, cause: e.cause, source: e),
      ErrorCode.unsupportedPlatform =>
        UnsupportedFailure(msg, cause: e.cause, source: e),
      ErrorCode.spiderRuntime =>
        SpiderFailure(msg, cause: e.cause, source: e),
      ErrorCode.invalidArgument =>
        ValidationFailure(msg, cause: e.cause, source: e),
      ErrorCode.unknown => UnknownFailure(msg, cause: e.cause, source: e),
    };
  }

  @override
  String toString() => '$runtimeType(${code.name}): $message';
}

/// 网络失败。
final class NetworkFailure extends Failure {
  const NetworkFailure(
    super.message, {
    super.code = ErrorCode.networkUnreachable,
    super.cause,
    this.source,
  });

  /// 超时构造（便于判别重试策略）。
  const NetworkFailure.timeout(
    super.message, {
    super.cause,
    this.source,
  }) : super(code: ErrorCode.networkTimeout);

  /// 原始异常（可空）。
  final VBoxException? source;

  @override
  bool get isRetryable => true;
}

/// 解析失败。
final class ParseFailure extends Failure {
  const ParseFailure(
    super.message, {
    super.code = ErrorCode.parse,
    super.cause,
    this.source,
  });

  final VBoxException? source;

  @override
  bool get isRetryable => false;
}

/// 数据库失败。
final class DatabaseFailure extends Failure {
  const DatabaseFailure(
    super.message, {
    super.code = ErrorCode.dbQuery,
    super.cause,
    this.source,
  });

  final VBoxException? source;

  @override
  bool get isRetryable => code == ErrorCode.dbQuery;
}

/// 存储失败。
final class StorageFailure extends Failure {
  const StorageFailure(
    super.message, {
    super.cause,
    this.source,
  }) : super(code: ErrorCode.storageIo);

  final VBoxException? source;

  @override
  bool get isRetryable => false;
}

/// 加密失败。
final class CryptoFailure extends Failure {
  const CryptoFailure(
    super.message, {
    super.cause,
    this.source,
  }) : super(code: ErrorCode.crypto);

  final VBoxException? source;

  @override
  bool get isRetryable => false;
}

/// 平台不支持。
final class UnsupportedFailure extends Failure {
  const UnsupportedFailure(
    super.message, {
    super.cause,
    this.source,
  }) : super(code: ErrorCode.unsupportedPlatform);

  final VBoxException? source;

  @override
  bool get isRetryable => false;
}

/// 蜘蛛运行时失败。
final class SpiderFailure extends Failure {
  const SpiderFailure(
    super.message, {
    super.cause,
    this.source,
  }) : super(code: ErrorCode.spiderRuntime);

  final VBoxException? source;

  @override
  bool get isRetryable => true;
}

/// 入参非法（用例层校验失败，不可重试）。
final class ValidationFailure extends Failure {
  const ValidationFailure(
    super.message, {
    super.cause,
    this.source,
  }) : super(code: ErrorCode.invalidArgument);

  final VBoxException? source;

  @override
  bool get isRetryable => false;
}

/// 未分类失败。
final class UnknownFailure extends Failure {
  const UnknownFailure(
    super.message, {
    super.cause,
    this.source,
  });

  final VBoxException? source;

  @override
  bool get isRetryable => false;
}
