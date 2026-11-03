/// 核心层 barrel（通用能力：常量 / 错误 / 网络 / 存储 / 工具）。
///
/// 依赖方向：`core` 不依赖任何层；`data` 依赖 `core` 与 `domain`；
/// `domain` 只依赖 `core`；`presentation` 依赖 `domain`（经 provider 注入）。
library;

export 'constants/constants.dart';
export 'errors/errors.dart';
export 'network/network.dart';
export 'storage/storage.dart';
export 'utils/utils.dart';
