/// 核心层：网络可达性抽象。
///
/// 分层约束（方案 §2.4 约束 4）：核心层**不得**直接依赖插件，
/// 故此处只定义接口；真实实现（connectivity 插件 / 原生 API）
/// 位于 `lib/platform/system/`，在启动时注入。
library;

/// 网络可达性。
abstract interface class NetworkInfo {
  /// 当前是否有可用网络。
  Future<bool> get isConnected;
}

/// 默认实现：始终在线（平台实现接入前使用）。
///
/// 说明：这不是「假装有网」，而是**不做主动判断**——
/// 真要判断时由请求本身失败并归一为 `NetworkFailure` 决定重试。
class AlwaysOnlineNetworkInfo implements NetworkInfo {
  /// 构造。
  const AlwaysOnlineNetworkInfo();

  @override
  Future<bool> get isConnected async => true;
}
