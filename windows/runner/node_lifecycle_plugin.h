//
//  node_lifecycle_plugin.h
//  Runner
//
//  批次 I · ND-01 补充：Node 子进程生命周期绑定（Windows）。
//
//  根因（「Node 端口 58080 已被占用」反复修复未根治）：Node 常驻子进程由 Dart
//  `Process.start` 拉起，主进程崩溃/强退时该子进程变为孤儿 node.exe，继续占用
//  58080，导致下次启动 EADDRINUSE / 顶包误判。
//
//  修复：进程内创建带 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 的 Job Object，把
//  Dart 拉起的 node 子进程收编进来；主进程退出/崩溃时 OS 关闭 Job 句柄并连带
//  终结全部子进程，从根本上杜绝孤儿。
//
//  MethodChannel `com.vbox.node/lifecycle`：`attach(pid)` 把指定 pid 的进程绑入
//  Job Object。Dart 端 `ProcessNodeHost.start()` 拉起子进程后立即调用。
//

#ifndef RUNNER_NODE_LIFECYCLE_PLUGIN_H_
#define RUNNER_NODE_LIFECYCLE_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace vbox {

class NodeLifecyclePlugin : public flutter::Plugin {
 public:
  explicit NodeLifecyclePlugin(flutter::PluginRegistrarWindows* registrar);

  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows* registrar);

  // 同步终结 Job Object 内全部已绑定子进程。主窗口关闭路径（WM_DESTROY → 本类
  // OnDestroy）在 Dart isolate 被引擎销毁前确定性调用，弥补 detach→stop() 异步
  // 链路在引擎销毁时可能来不及完成的缺口，杜绝 node.exe 残留成孤儿占用 58080。
  static void TerminateAll();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace vbox

#endif  // RUNNER_NODE_LIFECYCLE_PLUGIN_H_