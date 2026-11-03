cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "player_plugin.cpp"
  "baidu_token_bridge.cpp"
  "node_lifecycle_plugin.cpp"
  "screen_controls_plugin.cpp"
  "floating_plugin.cpp"
  "music_media_plugin.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
# 注：flutter_wrapper_plugin 提供 plugin_registrar.cc（PluginRegistrarManager /
# PluginRegistrar::AddPlugin 等符号）。flutter_window.cpp 与 player_plugin.cpp
# 在 runner 进程中直接完成手动插件注册（对齐插件侧模式），需链接该静态库，
# 否则链接期报 LNK2019（PluginRegistrar/PluginRegistrarManager 未解析）。
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app flutter_wrapper_plugin)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# 问题 5：桌面 render context 改走 OpenGL(GPU) 后端，player_plugin.cpp 用到
# ChoosePixelFormat / SetPixelFormat / GetDC / ReleaseDC（gdi32）。opengl32.dll
# 与 WGL 入口仍走运行期 LoadLibraryW/GetProcAddress 动态解析，无需链接导入库。
target_link_libraries(${BINARY_NAME} PRIVATE "gdi32.lib")
# 批次 D · D3：SMTC 走 C++/WinRT（music_media_plugin.cpp），需链接 Windows 运行时
# 伞形导入库，否则 LNK2019（RoGetActivationFactory / RoOriginateLanguageException）。
target_link_libraries(${BINARY_NAME} PRIVATE "windowsapp.lib")
# 百度 bdstoken 原生 WebView2 桥（baidu_token_bridge.cpp）：静态链接 WebView2
# 加载器（免分发 WebView2Loader.dll），运行期依赖系统 Evergreen 运行时
# （登录网关同款依赖）。随包预置的 webview2/include 头文件来自
# Microsoft.Web.WebView2 1.0.2903.40（NuGet，仅引入 build/native 两件套）。
target_include_directories(${BINARY_NAME} PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/webview2/include")
target_link_libraries(${BINARY_NAME} PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/webview2/WebView2LoaderStatic.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "ole32.lib" "oleaut32.lib"
    "uuid.lib" "advapi32.lib" "version.lib" "shell32.lib")
# WinHTTP（Schannel 系统栈）bdstoken 直取（baidu_token_bridge.cpp
# FetchBdstokenViaWinHttp，对齐 iOS URLSession 第 1 层）。
target_link_libraries(${BINARY_NAME} PRIVATE "winhttp.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
