/// 核心层：显式结果类型。
///
/// 用途：usecase / repository 的返回值统一为 `Result<T>`，
/// 失败不再是异常而是值，表现层用 `fold` 穷举成功/失败分支。
library;

import '../errors/failures.dart';

/// 结果（成功或失败）。
sealed class Result<T> {
  const Result();

  /// 是否成功。
  bool get isSuccess;

  /// 成功值（失败时为 null）。
  T? get valueOrNull;

  /// 失败对象（成功时为 null）。
  Failure? get failureOrNull;

  /// 分支处理（**唯一**推荐的取值方式）。
  R fold<R>(
    R Function(T value) onSuccess,
    R Function(Failure failure) onFailure,
  );

  /// 映射成功值（失败原样传递）。
  Result<R> map<R>(R Function(T value) transform);
}

/// 成功。
final class Success<T> extends Result<T> {
  const Success(this.value);

  /// 成功值。
  final T value;

  @override
  bool get isSuccess => true;

  @override
  T? get valueOrNull => value;

  @override
  Failure? get failureOrNull => null;

  @override
  R fold<R>(
    R Function(T value) onSuccess,
    R Function(Failure failure) onFailure,
  ) =>
      onSuccess(value);

  @override
  Result<R> map<R>(R Function(T value) transform) => Success<R>(transform(value));

  @override
  String toString() => 'Success($value)';
}

/// 失败。
final class Err<T> extends Result<T> {
  const Err(this.failure);

  /// 失败对象。
  final Failure failure;

  @override
  bool get isSuccess => false;

  @override
  T? get valueOrNull => null;

  @override
  Failure? get failureOrNull => failure;

  @override
  R fold<R>(
    R Function(T value) onSuccess,
    R Function(Failure failure) onFailure,
  ) =>
      onFailure(failure);

  @override
  Result<R> map<R>(R Function(T value) transform) => Err<R>(failure);

  @override
  String toString() => 'Err($failure)';
}
