/// 平台层：Node 宿主接缝（批次 I · ND-01）。
///
/// iOS 用 **nodejs-mobile 进程内引擎**（`NodeRunner.startEngine` 跑在独立 2MB 栈线程，
/// 见 `vbox/Services/NodeRuntimeManager.swift` L457-L468）。Flutter 无 `ios/` 目标，
/// 故按平台给出两类等价宿主（与 [PythonRuntime] 的「桌面子进程 / Android 通道」同构）：
///
///  - [ProcessNodeHost]：macOS / Windows / 测试 —— `node <runtimeDir>/main.js`
///    常驻**子进程**，端口矩阵经环境变量注入（与 iOS `setenv` 逐项对齐）；
///  - [ChannelNodeHost]：Android —— Android 无 `node` 可执行文件，改由 nodejs-mobile
///    把 Node 引擎随 APK 打包，经平台通道 `com.vbox.node/host` 在**进程内**启动。
///
/// 二者对上层（[NodeRuntimeManager]）语义相同：只管「拉起 / 停止」，
/// **就绪判定与心跳一律走 HTTP 探活**（对齐 iOS，见 ND-01 说明）；故宿主无感知。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Node 宿主异常。
class NodeHostException implements Exception {
  /// 构造。
  const NodeHostException(this.message);

  /// 文案。
  final String message;

  @override
  String toString() => 'NodeHostException($message)';
}

/// 宿主启动参数（对齐 iOS `launchNodeEngine` 的环境变量注入）。
class NodeHostConfig {
  /// 构造。
  const NodeHostConfig({
    required this.runtimeDir,
    required this.mainScript,
    required this.bundlePath,
    required this.lxPluginsDir,
    required this.lxAckPath,
    required this.environment,
  });

  /// Node 运行时根目录（可写，`<appData>/noderuntime`）。
  final String runtimeDir;

  /// 入口脚本绝对路径（`<runtimeDir>/main.js`）。
  final String mainScript;

  /// bundle 绝对路径（`<runtimeDir>/bundles/kstore_index.js`）。
  final String bundlePath;

  /// lx 插件目录（远程源经 ND-03 下发）。
  final String lxPluginsDir;

  /// lx 桥接握手文件路径（对齐 iOS `LX_ACK_PATH`）。
  final String lxAckPath;

  /// 注入的环境变量（`PORT` / `HEALTH_PORT` / `BUNDLE_PATH` / `LX_*` …）。
  final Map<String, String> environment;
}

/// Node 宿主（拉起 / 停止）。
abstract class NodeHost {
  /// 按平台选择宿主：Android 走 [ChannelNodeHost]，其余走 [ProcessNodeHost]。
  ///
  /// [nodeExecutable] 为 null（缺省）时，[ProcessNodeHost] 会按
  /// [ProcessNodeHost.locate] 自动解析桌面端 Node 运行时，不再硬依赖 PATH。
  factory NodeHost.forCurrentPlatform({
    String? nodeExecutable,
    MethodChannel? channel,
  }) =>
      Platform.isAndroid
          ? ChannelNodeHost(channel: channel)
          : ProcessNodeHost(nodeExecutable: nodeExecutable);

  /// 宿主日志（含降级事件）。
  void Function(String)? onLog;

  /// 子进程意外退出回调（宿主实现负责触发；进程内引擎 / 不可用宿主不触发）。
  ///
  /// 供 [NodeRuntimeManager] 在子进程崩溃时**第一时间**感知：此前只能依赖
  /// HTTP 探活，而子进程死后端口若被其他进程（如旧版残留 node.exe）占住，
  /// 探活会打到冒名进程并误判「就绪」——业务请求全部落到错误进程上。
  void Function(int exitCode)? onChildExited;

  /// 宿主标签（日志用）。
  String get hostLabel;

  /// 启动宿主（幂等：先停再起）。
  ///
  /// 失败抛 [NodeHostException]；**不等待就绪**（就绪由上层 HTTP 探活判定）。
  Future<void> start(NodeHostConfig config);

  /// 停止宿主（幂等）。
  Future<void> stop();

  /// 宿主进程 / 引擎是否在运行（不探活）。
  Future<bool> isRunning();

  /// 子进程 pid（进程内引擎 / 未知返回 null）。
  ///
  /// 探活侧用它与健康端点响应中的 pid 比对，识别「端口被其他进程顶包」。
  Future<int?> pid() async => null;
}

/// Node 可执行文件解析结果。
class NodeExecutableLocation {
  /// 构造。
  const NodeExecutableLocation({required this.resolved, required this.probed});

  /// 命中的绝对路径；全部落空为 null。
  final String? resolved;

  /// 本次探测过的候选位置（失败文案用）。
  final List<String> probed;
}

/// 子进程宿主（`node <main.js>`；macOS / Windows / 测试）。
///
/// 桌面端 Node 运行时解析（对齐 iOS「引擎随包内置、零外部依赖」语义）：
/// iOS 走 nodejs-mobile 进程内引擎，天然不存在「找不到 node」的问题；桌面端
/// 原先直接 `Process.start('node')` 硬依赖 **PATH**，而打包后的 GUI 程序继承到的
/// PATH 通常不含 Node（Windows 装 NVM 或安装未勾选 PATH、macOS 从 Finder 启动
/// 只有 `/usr/bin:/bin`），于是必然报「未找到可执行文件 node」。此处按 [locate]
/// 依次探测内置位置与平台常见安装位置，PATH 仅作最后兜底。
class ProcessNodeHost implements NodeHost {
  /// [nodeExecutable] 可注入（测试 / 自定义打包）；为 null 时自动解析。
  ProcessNodeHost({this.nodeExecutable});

  /// Node 子进程生命周期通道（Windows Native `NodeLifecyclePlugin`）。
  static const MethodChannel _lifecycleChannel =
      MethodChannel('com.vbox.node/lifecycle');

  /// 显式指定的 Node 可执行文件（绝对路径或 PATH 名）；null → 自动解析。
  final String? nodeExecutable;

  Process? _process;
  StreamSubscription<String>? _outSub;
  StreamSubscription<String>? _errSub;

  /// 主动停止中标志：[stop] 杀掉子进程触发的退出回调不应视为「意外退出」。
  bool _stopping = false;

  /// 本次 start 实际使用的可执行文件（诊断用）。
  String? _resolvedExecutable;

  @override
  void Function(String)? onLog;

  @override
  void Function(int exitCode)? onChildExited;

  @override
  String get hostLabel =>
      '子进程 ${_resolvedExecutable ?? nodeExecutable ?? 'node（待解析）'}';

  /// 解析 Node 可执行文件：命中返回绝对路径，全部落空返回 null。
  ///
  /// 探测顺序：
  ///   ① 运行时目录 `<runtimeDir>/node(.exe)`（便携版 node 落点，随包内置）；
  ///   ② 可执行文件同级 `<exeDir>/node(.exe)` · `<exeDir>/noderuntime/node(.exe)`；
  ///   ③ 平台常见安装位置（Windows：Program Files / Program Files(x86) /
  ///      LOCALAPPDATA\Programs\nodejs / nvm-windows；macOS：Homebrew arm64 与
  ///      x86 / /usr/local；Linux：/usr/bin、/usr/local/bin、/snap/bin）；
  ///   ④ PATH 兜底（保留原有行为）。
  static NodeExecutableLocation locate({NodeHostConfig? config}) {
    final String fileName = Platform.isWindows ? 'node.exe' : 'node';
    final List<String> candidates = <String>[
      if (config != null) ..._bundledCandidates(config.runtimeDir, fileName),
      ..._installCandidates(fileName),
    ];
    for (final String candidate in candidates) {
      if (File(candidate).existsSync()) {
        return NodeExecutableLocation(resolved: candidate, probed: candidates);
      }
    }
    return NodeExecutableLocation(
      resolved: _fromPath(fileName),
      probed: candidates,
    );
  }

  /// 随包 / 运行目录候选：优先「便携版 node 与运行时资源放在一起」。
  static List<String> _bundledCandidates(String runtimeDir, String fileName) {
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    return <String>[
      p.join(runtimeDir, fileName),
      p.join(exeDir, fileName),
      p.join(exeDir, 'noderuntime', fileName),
    ];
  }

  /// 平台常见安装位置候选。
  static List<String> _installCandidates(String fileName) {
    if (Platform.isWindows) {
      final Map<String, String> env = Platform.environment;
      final String programFiles = env['ProgramFiles'] ?? r'C:\Program Files';
      final String programFilesX86 =
          env['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
      final List<String> out = <String>[
        p.join(programFiles, 'nodejs', fileName),
        p.join(programFilesX86, 'nodejs', fileName),
      ];
      final String? localAppData = env['LOCALAPPDATA'];
      if (localAppData != null) {
        out.add(p.join(localAppData, 'Programs', 'nodejs', fileName));
      }
      // nvm-windows：`<APPDATA>\nvm\v22.11.0\node.exe`，目录名带版本号 → 逐个扫描。
      final String? appData = env['APPDATA'];
      if (appData != null) {
        out.addAll(_subdirFiles(p.join(appData, 'nvm'), fileName));
      }
      return out;
    }
    return <String>[
      '/opt/homebrew/bin/$fileName',
      '/usr/local/bin/$fileName',
      '/usr/bin/$fileName',
      '/snap/bin/$fileName',
    ];
  }

  /// 列出 [root] 下一级子目录中存在的 [fileName] 绝对路径（容错：目录不存在返回空）。
  static List<String> _subdirFiles(String root, String fileName) {
    final Directory dir = Directory(root);
    if (!dir.existsSync()) return const <String>[];
    final List<String> out = <String>[];
    try {
      for (final FileSystemEntity entity in dir.listSync()) {
        if (entity is Directory) {
          final String candidate = p.join(entity.path, fileName);
          if (File(candidate).existsSync()) out.add(candidate);
        }
      }
    } on FileSystemException {
      // 目录不可读 → 视为无候选。
    }
    return out;
  }

  /// PATH 兜底探测（返回绝对路径；未命中返回 null）。
  static String? _fromPath(String fileName) {
    final String? raw = Platform.environment['PATH'];
    if (raw == null || raw.isEmpty) return null;
    final String separator = Platform.isWindows ? ';' : ':';
    for (final String dir in raw.split(separator)) {
      final String trimmed = dir.trim();
      if (trimmed.isEmpty) continue;
      final String candidate = p.join(trimmed, fileName);
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// 启动失败文案（可操作）：列出全部已探测位置与两条修复路径。
  static String _failureMessage(
    String executable,
    NodeExecutableLocation located,
    ProcessException e,
  ) {
    final StringBuffer buffer = StringBuffer()
      ..writeln('Node 宿主启动失败：未找到可执行文件「$executable」（${e.message}）')
      ..writeln('已探测以下位置（均不存在）：');
    for (final String candidate in located.probed) {
      buffer.writeln('  · $candidate');
    }
    buffer
      ..writeln('  · PATH 环境变量中的 node / node.exe')
      ..writeln('请任选其一：')
      ..writeln('  ① 安装 Node.js（https://nodejs.org）并确认已加入 PATH；')
      ..writeln('  ② 或把便携版 node 放到运行时目录（与 noderuntime 同级）后重启。')
      ..write('说明：iOS 端内置 nodejs-mobile 引擎、无外部依赖；桌面端需本机提供 Node 运行时。');
    return buffer.toString();
  }

  @override
  Future<void> start(NodeHostConfig config) async {
    await stop();
    _stopping = false;
    // ① 显式注入优先；② 否则自动解析；③ 仍无 → 退回 PATH 名（保留旧行为，
    //    覆盖 Windows 应用执行别名等「非真实文件」的 shim 情形）。
    final NodeExecutableLocation located = locate(config: config);
    final String executable = nodeExecutable ??
        located.resolved ??
        (Platform.isWindows ? 'node.exe' : 'node');
    _resolvedExecutable = executable;
    final String? autoResolved = located.resolved;
    if (nodeExecutable == null && autoResolved != null) {
      onLog?.call('🔍 Node 可执行文件解析：$autoResolved');
    }
    try {
      _process = await Process.start(
        executable,
        <String>[config.mainScript],
        workingDirectory: config.runtimeDir,
        environment: config.environment,
        includeParentEnvironment: true,
      );
    } on ProcessException catch (e) {
      throw NodeHostException(_failureMessage(executable, located, e));
    }
    // Windows：把刚拉起的 node.exe 收编进主进程 Job Object（KILL_ON_JOB_CLOSE），
    // 主进程退出/崩溃时由 OS 连带终结子进程，避免孤儿继续占用 58080 端口
    // （「Node 端口已被占用」反复修复未根治的根因）。
    final Process? spawned = _process;
    if (Platform.isWindows && spawned != null) {
      // 同步等 attach 结果：确保子进程已确定性纳入 Job Object（或明确拿到失败
      // 日志），避免 unawaited 竞态导致 node.exe 尚未受保护 start() 就已返回。
      await _attachToJobObject(spawned.pid);
    }
    // 监控子进程退出：崩溃时第一时间回调上层（进程死了但端口可能被
    // 其他进程占住，仅靠 HTTP 探活会误判「就绪」，见 NodeHost.onChildExited）。
    unawaited(_process!.exitCode.then((int code) {
      if (_stopping) return;
      onChildExited?.call(code);
    }));
    _outSub = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
      if (line.trim().isNotEmpty) onLog?.call('[node] $line');
    });
    _errSub = _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
      if (line.trim().isNotEmpty) onLog?.call('[node:err] $line');
    });
    onLog?.call('🚀 已拉起 Node 子进程（$executable ${config.mainScript}）');
  }

  /// 把子进程绑入主进程 Job Object（Windows Native `NodeLifecyclePlugin`）。
  ///
  /// 绑定失败（含 macOS/Linux 无插件、调试器嵌套作业未被允许）不阻断拉起：
  /// 仍有退出时 stop() 与健康监控兜底。
  Future<void> _attachToJobObject(int pid) async {
    try {
      await _lifecycleChannel.invokeMethod<void>('attach', pid);
    } on MissingPluginException {
      // 非 Windows / 未接原生插件：忽略。
    } on PlatformException catch (e) {
      onLog?.call('⚠️ 绑定 Node 子进程到 Job Object 失败（${e.code}）：${e.message}');
    }
  }

  @override
  Future<void> stop() async {
    _stopping = true;
    await _outSub?.cancel();
    await _errSub?.cancel();
    _outSub = null;
    _errSub = null;
    final Process? p = _process;
    _process = null;
    if (p != null) {
      p.kill();
      await p.exitCode;
    }
    _stopping = false;
  }

  @override
  Future<bool> isRunning() async {
    final Process? p = _process;
    return p != null;
  }

  @override
  Future<int?> pid() async => _process?.pid;
}

/// 通道宿主（Android · nodejs-mobile 进程内引擎）。
///
/// 与原生 `NodePlugin.kt` 的 `com.vbox.node/host` 通道对齐：
///  - `start`（`runtimeDir` / `mainScript` / `bundlePath` / `lxPluginsDir` /
///    `lxAckPath` / `environment`）→ `null`
///  - `stop` → `null`
///  - `isRunning` → `bool`
///
/// 通道未注册（未接入 nodejs-mobile / 非 Android）时抛 `E_NODE_UNAVAILABLE`，
/// 上层据此标记 `node-failed` 并降级提示，**不 crash**。
class ChannelNodeHost implements NodeHost {
  /// 构造。
  ChannelNodeHost({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// 原生通道名（与 `NodePlugin.CHANNEL` 一致）。
  static const String channelName = 'com.vbox.node/host';

  /// 通道调用兜底宽限（防原生线程卡死的安全网）。
  static const Duration _backstop = Duration(seconds: 10);

  final MethodChannel _channel;

  @override
  void Function(String)? onLog;

  @override
  void Function(int exitCode)? onChildExited;

  @override
  String get hostLabel => 'Android nodejs-mobile 进程内引擎';

  @override
  Future<void> start(NodeHostConfig config) async {
    try {
      await _channel.invokeMethod<void>('start', <String, Object?>{
        'runtimeDir': config.runtimeDir,
        'mainScript': config.mainScript,
        'bundlePath': config.bundlePath,
        'lxPluginsDir': config.lxPluginsDir,
        'lxAckPath': config.lxAckPath,
        'environment': config.environment,
      }).timeout(_backstop);
      onLog?.call('🚀 已拉起 Node 进程内引擎（nodejs-mobile）');
    } on TimeoutException {
      throw const NodeHostException('Node 宿主启动超时：原生引擎未在 10s 内返回');
    } on MissingPluginException {
      throw const NodeHostException('Node 宿主不可用：Android nodejs-mobile 通道未注册');
    } on PlatformException catch (e) {
      throw NodeHostException(e.message ?? 'Node 宿主启动失败（${e.code}）');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop').timeout(_backstop);
    } on TimeoutException {
      // 停止超时不阻断（幂等语义）。
    } on MissingPluginException {
      // 通道未注册 → 无需停止。
    } on PlatformException {
      // 停止失败不阻断。
    }
  }

  @override
  Future<bool> isRunning() async {
    try {
      return await _channel.invokeMethod<bool>('isRunning').timeout(_backstop) ??
          false;
    } on TimeoutException {
      return false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<int?> pid() async => null;
}

/// 不可用宿主（未接入平台 / 单测缺省；启动即报错，不 crash）。
class UnavailableNodeHost implements NodeHost {
  /// 构造。
  ///
  /// 非 `const`：[NodeHost.onLog] 为可变字段（宿主日志回调），无法声明常量构造。
  UnavailableNodeHost();

  @override
  void Function(String)? onLog;

  @override
  void Function(int exitCode)? onChildExited;

  @override
  String get hostLabel => '未接入';

  @override
  Future<void> start(NodeHostConfig config) async =>
      throw const NodeHostException('Node 宿主尚未接入（等待 ND-01-native 运行时二进制）');

  @override
  Future<void> stop() async {}

  @override
  Future<bool> isRunning() async => false;

  @override
  Future<int?> pid() async => null;
}