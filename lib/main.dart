/// VBox 应用入口。
///
/// 方案 D5：三端全平台并行（Android 手机 / Android TV / Windows / macOS / iOS 维持）。
/// 方案 D6：播放器策略 —— Android Media3+libVLC；桌面 libmpv。
///
/// 本文件仅负责：
///  1. 绑定 Flutter 引擎
///  2. 桌面端 sqflite FFI 初始化
///  3. Windows WebView2 环境引导
///  4. 批次 E 全局装配（崩溃标记钩子 / 启动版本登记）
///  5. 启动 [VBoxApp]
///
/// ⚠️ iOS 不迁移（D1），Flutter 仅负责 Android / TV / Windows / macOS 四端。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app.dart';
import 'core/constants/app_constants.dart';
import 'core/utils/logger.dart';
import 'data/datasources/local/prefs_manager.dart';
import 'platform/update/upgrade_handshake.dart';
import 'platform/webview/in_app_webview_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面端（Windows / macOS / Linux）需初始化 sqflite FFI 后端
  if (!kIsWeb &&
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // Windows 专用：WebView2 环境引导（自定义数据目录；须在 runApp 前完成）。
  if (!kIsWeb && Platform.isWindows) {
    await InAppWebViewBridge.initialize();
  }

  // 批次 E · E3-3：未捕获异常钩子写崩溃标记（对齐 iOS `AppLogStore.swift:259`），
  // 下次启动日志页顶部提示「检测到上次异常退出」。
  _installCrashMarkerHooks();

  runApp(const VBoxApp());

  // Windows 专用：安装器升级握手（方案 D）。安装器在安装目录写
  // .vbox-upgrade-request 标记，本进程发现后关闭自管运行时并退出，
  // 让安装器能覆盖正在被占用的运行时 exe——这是 QQ/微信 那种
  // 「程序自己退」的做法，比外部按路径强杀可靠，且零磁盘/内存代价。
  if (!kIsWeb && Platform.isWindows) {
    UpgradeHandshake.start();
  }

  // 批次 E · E3-3：启动迁移 —— `app_last_launch_version` 版本比对
  // （对齐 iOS `AppSettings.swift:175`；首启/升级分支仅登记日志）。
  unawaited(_recordLaunchVersion());
}

/// 未捕获异常钩子：写 `app_log_crash_marker`（fire-and-forget，不阻断默认流程）。
///
/// 链式包装既有 handler（flutter_test 等宿主自装 onError 的场景下
/// 原样透传，不吞异常、不破坏测试框架的错误上抛）。
void _installCrashMarkerHooks() {
  Future<void> mark() async {
    try {
      await PrefsManager.instance.init();
      await PrefsManager.instance.set('app_log_crash_marker', true);
    } catch (_) {
      // 标记失败不二次抛出（避免崩溃钩子自身引发循环）。
    }
  }

  final void Function(FlutterErrorDetails details)? previousOnError =
      FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    previousOnError?.call(details);
    AppLog.error(
      'app',
      '未捕获框架异常: ${details.exception}',
      error: details.exception,
    );
    unawaited(mark());
  };
  final dispatcher = PlatformDispatcher.instance;
  final bool Function(Object error, StackTrace stack)?
      previousDispatcherOnError = dispatcher.onError;
  dispatcher.onError = (Object error, StackTrace stack) {
    final bool handled =
        previousDispatcherOnError?.call(error, stack) ?? false;
    AppLog.error('app', '未捕获平台异常: $error', error: error);
    unawaited(mark());
    return handled; // 透传既有语义：交回引擎默认处理（debug 打印 / release 崩溃）。
  };
}

/// 启动版本比对（首启 / 升级分支登记；随后写当前版本）。
Future<void> _recordLaunchVersion() async {
  try {
    await PrefsManager.instance.init();
    final String last =
        await PrefsManager.instance.getString('app_last_launch_version');
    const String current = AppInfo.version;
    if (last.isEmpty) {
      AppLog.info('app', '首次启动（无历史版本记录），当前 $current');
    } else if (last != current) {
      AppLog.info('app', '检测到版本升级: $last → $current');
    }
    await PrefsManager.instance.set('app_last_launch_version', current);
  } catch (e) {
    AppLog.warn('app', '启动版本记录失败: $e');
  }
}
