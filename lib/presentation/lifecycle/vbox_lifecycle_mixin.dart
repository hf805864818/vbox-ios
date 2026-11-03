/// 表现层：应用生命周期监听 Mixin（UI-E4）。
///
/// 对齐 iOS 各视图的生命周期钩子（`onAppear` / `onDisappear` / `scenePhase` /
/// `UIApplication.didBecomeActive|willResignActive|didEnterBackground`）：
/// 把 Flutter 的 [AppLifecycleState] 归一为三个可覆写钩子：
///  - [onAppResumed]：回前台（对齐 iOS `onAppear` / `scenePhase .active`）→ 刷新数据、恢复轮播；
///  - [onAppInactive]：失活（对齐 iOS `scenePhase .inactive` / willResignActive）→ 暂停轮播 / 定时器；
///  - [onAppPaused]：进后台（对齐 iOS `scenePhase .background` / didEnterBackground）→ 停定时器、释放大资源。
///
/// 用法：`class _FooState extends State<Foo> with VboxLifecycleMixin`，
/// 覆写需要的钩子即可；mixin 自负责注册 / 注销 observer（initState / dispose）。
/// 播放页不使用本 mixin（其生命周期语义更复杂，见 `player_page.dart` 的 UI-F22 接线）。
library;

import 'package:flutter/material.dart';

/// 应用生命周期监听 Mixin。
mixin VboxLifecycleMixin<T extends StatefulWidget> on State<T> {
  _VboxLifecycleObserver? _observer;

  @override
  void initState() {
    super.initState();
    _observer = _VboxLifecycleObserver(didChangeAppLifecycleState);
    WidgetsBinding.instance.addObserver(_observer!);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_observer!);
    _observer = null;
    super.dispose();
  }

  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        onAppResumed();
      case AppLifecycleState.inactive:
        onAppInactive();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        onAppPaused();
    }
  }

  /// 回前台：刷新数据 / 恢复轮播（对齐 iOS `onAppear` / `scenePhase .active`）。
  void onAppResumed() {}

  /// 失活：暂停轮播 / 定时器（对齐 iOS `scenePhase .inactive` / willResignActive）。
  void onAppInactive() {}

  /// 进后台：停止轮播 / 释放大资源（对齐 iOS `scenePhase .background` /
  /// didEnterBackground）。
  void onAppPaused() {}
}

/// 内部 observer（`with WidgetsBindingObserver` 挂默认实现，仅转发生命周期
/// 事件到宿主回调；宿主 `this` 未实现 observer 协议，不可直接注册）。
class _VboxLifecycleObserver with WidgetsBindingObserver {
  _VboxLifecycleObserver(this._onStateChanged);

  final void Function(AppLifecycleState state) _onStateChanged;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _onStateChanged(state);
}
