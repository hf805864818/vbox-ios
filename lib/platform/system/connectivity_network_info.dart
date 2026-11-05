/// 平台层：网络可达性实现（A2 接线）。
///
/// 分层约束（方案 §2.4 约束 4）：核心层 [NetworkInfo] 只定义接口、**不依赖插件**；
/// 真实实现就近放在平台层，由 `app.dart` 在启动时构造并注入 [HttpClient]。
///
/// 语义：**失败开放（fail-open）** —— 探针不可用（插件缺失 / 桌面通道异常）时
/// 一律返回「在线」，绝不因探测失败而误拦截请求；只有明确拿到 `none` 时才判离线。
library;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';

import '../../core/network/network_info.dart';

/// 连通性探针签名（便于单测注入 fake，不触碰平台通道）。
typedef ConnectivityProbe = Future<List<ConnectivityResult>> Function();

/// 基于 `connectivity_plus` 的网络可达性实现。
class ConnectivityNetworkInfo implements NetworkInfo {
  /// 构造（[probe] 便于单测注入；缺省走 `connectivity_plus` 的平台通道）。
  ConnectivityNetworkInfo({ConnectivityProbe? probe})
      : _probe = probe ?? Connectivity().checkConnectivity;

  final ConnectivityProbe _probe;

  /// 判定结果集是否代表「有网络」。
  ///
  /// 空集或仅含 [ConnectivityResult.none] → 离线；其余（wifi/mobile/ethernet/vpn…）→ 在线。
  static bool hasConnection(List<ConnectivityResult> results) {
    if (results.isEmpty) return false;
    if (results.length == 1 && results.first == ConnectivityResult.none) {
      return false;
    }
    return true;
  }

  @override
  Future<bool> get isConnected async {
    try {
      return hasConnection(await _probe());
    } on MissingPluginException {
      // 测试 / 未注册插件的平台 → 不主动拦截
      return true;
    } on PlatformException {
      return true;
    } on UnsupportedError {
      // 桌面部分平台无实现 → 同上
      return true;
    }
  }

  /// 连通性变化流（true = 有网；按「有网/无网」去重）。
  ///
  /// 用途：网络切换（Wi-Fi ↔ 蜂窝 / 断网恢复）后让 TMDB 图片线路重新探测。
  /// 插件缺失 / 平台不支持时返回空流（fail-open，不影响主流程）。
  Stream<bool> get onConnectivityChanged {
    try {
      return Connectivity().onConnectivityChanged.map(hasConnection).distinct();
    } catch (_) {
      return const Stream<bool>.empty();
    }
  }
}