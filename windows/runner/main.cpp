#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // 批次 Q · Q-03：Windows JSC 引擎预加载（与 macOS MainFlutterWindow 的 dlopen、
  // Android MainActivity 的 System.loadLibrary 对称）。先于 Dart FFI
  // DynamicLibrary.open("vbox_jsc.dll") 触发：vbox_jsc.dll 随安装包与
  // runner.exe 同目录分发，Windows 默认按应用程序目录搜索 DLL，无需额外 PATH。
  // 加载失败仅记录调试日志（OutputDebugString），不 crash —— Dart 侧
  // jsc_ffi 的 isAvailable=false，工厂按 D6 自动降级 QuickJS（降级可观测）。
  if (::LoadLibraryW(L"vbox_jsc.dll") == nullptr) {
    ::OutputDebugStringW(
        L"vbox: vbox_jsc.dll 加载失败，JSC 将按 D6 降级 QuickJS\n");
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"vbox", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
