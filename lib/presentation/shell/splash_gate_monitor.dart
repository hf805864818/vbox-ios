/// 外壳：启动页数据门控（批次 L · L-壳1/L-壳2）。
///
/// 唯一真相源：iOS `vbox/Services/SplashGateMonitor.swift`。
///
/// HomeView 在确认首页有可展示数据时调用 `markHomeReady()`；
/// [StartupGate] 监听 `homeDataReady`，数据就绪即淡出启动页进入首页；
/// 若 10 秒内未就绪，由 [StartupGate] 的兜底定时器强制退出启动页。
library;

import 'package:flutter/foundation.dart';

/// 启动页数据门控（进程内单例）。
class SplashGateMonitor extends ChangeNotifier {
  SplashGateMonitor._();

  /// 单例。
  static final SplashGateMonitor instance = SplashGateMonitor._();

  bool _homeDataReady = false;

  /// 首页是否已有可展示数据。
  bool get homeDataReady => _homeDataReady;

  /// 首页已有可展示数据时调用（幂等，重复调用无副作用）。
  void markHomeReady() {
    if (_homeDataReady) return;
    _homeDataReady = true;
    notifyListeners();
  }

  /// 测试复位（仅测试使用）。
  @visibleForTesting
  void resetForTest() {
    _homeDataReady = false;
  }
}