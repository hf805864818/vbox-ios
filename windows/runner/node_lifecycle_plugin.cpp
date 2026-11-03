//
//  node_lifecycle_plugin.cpp
//  Runner
//
//  实现见 node_lifecycle_plugin.h 文件头注释。

#include "node_lifecycle_plugin.h"

#include <windows.h>

#include <cstdint>
#include <variant>

#include <flutter/standard_method_codec.h>

namespace vbox {

namespace {

// 惰性创建（幂等）Job Object：KILL_ON_JOB_CLOSE 保证主进程退出/崩溃时 OS 关闭
// 唯一句柄并连带终结所有已绑定子进程。static 句柄随进程结束由 OS 回收。
HANDLE EnsureJobObject() {
  static HANDLE job = []() -> HANDLE {
    HANDLE h = ::CreateJobObjectW(nullptr, nullptr);
    if (h == nullptr) {
      return nullptr;
    }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info{};
    info.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!::SetInformationJobObject(h, JobObjectExtendedLimitInformation, &info,
                                   sizeof(info))) {
      ::CloseHandle(h);
      return nullptr;
    }
    return h;
  }();
  return job;
}

// 从 EncodableValue 提取 pid（Dart int 可能是 int32 或 int64）。
int64_t ExtractPid(const flutter::EncodableValue* value) {
  if (value == nullptr) {
    return 0;
  }
  if (std::holds_alternative<int32_t>(*value)) {
    return static_cast<int64_t>(std::get<int32_t>(*value));
  }
  if (std::holds_alternative<int64_t>(*value)) {
    return std::get<int64_t>(*value);
  }
  return 0;
}

}  // namespace

void NodeLifecyclePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(std::make_unique<NodeLifecyclePlugin>(registrar));
}

void NodeLifecyclePlugin::TerminateAll() {
  HANDLE job = EnsureJobObject();
  if (job != nullptr) {
    ::TerminateJobObject(job, 1);
  }
}

NodeLifecyclePlugin::NodeLifecyclePlugin(
    flutter::PluginRegistrarWindows* registrar)
    : channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "com.vbox.node/lifecycle",
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

void NodeLifecyclePlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != "attach") {
    result->NotImplemented();
    return;
  }

  const int64_t pid = ExtractPid(call.arguments());
  if (pid <= 0) {
    result->Error("E_BAD_ARGUMENT", "attach 需要正整数 pid");
    return;
  }

  HANDLE job = EnsureJobObject();
  if (job == nullptr) {
    result->Error("E_JOB_OBJECT", "Job Object 创建失败");
    return;
  }

  // PROCESS_SET_QUOTA 用于 AssignProcessToJobObject，PROCESS_TERMINATE 预留兜底。
  HANDLE process = ::OpenProcess(
      PROCESS_SET_QUOTA | PROCESS_TERMINATE, FALSE, static_cast<DWORD>(pid));
  if (process == nullptr) {
    result->Error("E_OPEN_PROCESS",
                  "打开目标进程失败（Win32 错误 " +
                      std::to_string(::GetLastError()) + "）");
    return;
  }

  const BOOL assigned = ::AssignProcessToJobObject(job, process);
  ::CloseHandle(process);
  if (!assigned) {
    // 目标进程可能已处于其他 Job（如调试器/嵌套作业），失败不阻断拉起，
    // 由健康监控 + 退出时 stop() 兜底。
    result->Error("E_ASSIGN",
                  "绑定 Job Object 失败（Win32 错误 " +
                      std::to_string(::GetLastError()) + "）");
    return;
  }

  result->Success();
}

}  // namespace vbox