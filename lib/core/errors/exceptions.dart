/// 核心层：异常定义。
///
/// 约定：
/// - **内部**抛异常（`VBoxException` 子类），在层边界（repository / usecase）
///   统一转为 `Failure`（见 `failures.dart`），避免异常穿透到表现层。
/// - 错误码与文案解耦：UI 按 [ErrorCode] 决定展示与重试策略。
library;

/// 错误码（稳定标识，可上报 / 落日志）。
enum ErrorCode {
  /// 请求超时。
  networkTimeout,

  /// 网络不可达 / DNS 失败 / 连接被拒。
  networkUnreachable,

  /// HTTP 状态码非 2xx。
  httpStatus,

  /// 响应内容无法解析（编码 / JSON / HTML 结构）。
  invalidResponse,

  /// 数据库打开失败。
  dbOpen,

  /// 数据库查询 / 写入失败。
  dbQuery,

  /// 数据库迁移失败。
  dbMigration,

  /// 解析失败（脚本输出 / 配置 / 备份信封）。
  parse,

  /// 文件读写失败。
  storageIo,

  /// 加密 / 解密失败。
  crypto,

  /// 当前平台不支持该能力。
  unsupportedPlatform,

  /// 蜘蛛脚本运行时错误。
  spiderRuntime,

  /// 入参非法（用例层校验失败）。
  invalidArgument,

  /// 未分类。
  unknown,
}

/// 全部业务异常的基类。
sealed class VBoxException implements Exception {
  const VBoxException(
    this.message, {
    this.code = ErrorCode.unknown,
    this.cause,
  });

  /// 人类可读描述。
  final String message;

  /// 稳定错误码。
  final ErrorCode code;

  /// 原始异常（保留栈信息用于日志）。
  final Object? cause;

  @override
  String toString() =>
      '$runtimeType(${code.name}): $message${cause == null ? '' : ' ← $cause'}';
}

/// 网络异常。
final class NetworkException extends VBoxException {
  const NetworkException(
    super.message, {
    super.code = ErrorCode.networkUnreachable,
    super.cause,
  });
}

/// 数据库异常。
final class DatabaseException extends VBoxException {
  const DatabaseException(
    super.message, {
    super.code = ErrorCode.dbQuery,
    super.cause,
  });
}

/// 解析异常。
final class ParseException extends VBoxException {
  const ParseException(
    super.message, {
    super.code = ErrorCode.parse,
    super.cause,
  });
}

/// 存储异常。
final class StorageException extends VBoxException {
  const StorageException(
    super.message, {
    super.code = ErrorCode.storageIo,
    super.cause,
  });
}

/// 加密异常。
final class CryptoException extends VBoxException {
  const CryptoException(
    super.message, {
    super.code = ErrorCode.crypto,
    super.cause,
  });
}

/// 平台能力缺失异常。
final class UnsupportedPlatformException extends VBoxException {
  const UnsupportedPlatformException(
    super.message, {
    super.code = ErrorCode.unsupportedPlatform,
    super.cause,
  });
}

/// 蜘蛛运行时异常。
final class SpiderRuntimeException extends VBoxException {
  const SpiderRuntimeException(
    super.message, {
    super.code = ErrorCode.spiderRuntime,
    super.cause,
  });
}
