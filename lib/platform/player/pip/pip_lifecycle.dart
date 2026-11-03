/// 平台层：播放器应用生命周期（批次 C · C-05 后台 / 画中画共用）。
///
/// 避免平台层耦合 Flutter `AppLifecycleState`（widgets binding），由 UI 层
/// （`WidgetsBindingObserver`）把系统生命周期归一为本枚举：
///  - 前台 = `resumed`
///  - 后台 = `inactive` / `hidden` / `paused` / `detached`
library;

/// 播放器应用生命周期（归一枚举）。
enum PlaybackLifecycle {
  /// 前台（App 可见可交互）。
  foreground,

  /// 后台（App 不可见 / 挂起）。
  background;

  /// 由 Flutter `AppLifecycleState` 名称归一（未知值按前台处理，保守不误触发）。
  static PlaybackLifecycle fromAppStateName(String name) => switch (name) {
        'inactive' || 'hidden' || 'paused' || 'detached' => PlaybackLifecycle.background,
        _ => PlaybackLifecycle.foreground,
      };
}
