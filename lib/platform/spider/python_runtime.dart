/// 平台层：Python 运行时抽象（Wave G · RT-运1）。
///
/// 蜘蛛脚本一律按 `contract/docs/abi_v1.md` §7 的 **stdio ABI** 编写：脚本先
/// `print('READY')`，随后逐行读请求、逐行写响应。运行该脚本的「宿主」有两类：
///
///  - [StdioPythonRuntime]：桌面 / 测试 —— `python3 -u <bridge> <script>`
///    常驻**子进程**，宿主经 stdin/stdout 交换行；`<bridge>` 为
///    [vboxPythonBridgeScript] 落盘的桥接垫片，负责 `exec` 用户脚本并以
///    **对象调用**提供服务（对齐 iOS `PythonBridge.m` / Android 桥，见 S1/S3）；
///  - [ChannelPythonRuntime]：Android —— Android 无 `python3` 可执行文件，
///    改由 Chaquopy 把 CPython 解释器随 APK 打包，经平台通道
///    `com.vbox.python/python` 在**进程内**运行同一份脚本（RT-运1）。
///
/// 二者对上层（[PythonBridgeEngine]）暴露完全相同的语义，故引擎对宿主无感知。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../domain/entities/spider/spider_engine.dart';
import 'python_bridge_script.dart';

/// Windows Python 可执行名探测缓存（批次 E · E5-1；首次调用后进程级缓存，
/// 避免每次启动重复探测）。
String? _probedWindowsExecutable;
List<String> _probedWindowsExtraArgs = const <String>[];

/// Windows 依次探测 `python3` → `python` → `py -3`（`Process.runSync('--version')`
/// 一次成功即缓存；全失败回退 `python3`——launch 时如实报不可用，登记）。
List<String> _probeWindowsPythonCommand() {
  if (_probedWindowsExecutable != null) {
    return <String>[_probedWindowsExecutable!, ..._probedWindowsExtraArgs];
  }
  const List<(String, List<String>)> candidates = <(String, List<String>)>[
    ('python3', <String>[]),
    ('python', <String>[]),
    ('py', <String>['-3']),
  ];
  for (final (String, List<String>) candidate in candidates) {
    try {
      final ProcessResult result = Process.runSync(candidate.$1,
          <String>[...candidate.$2, '--version']);
      if (result.exitCode == 0) {
        _probedWindowsExecutable = candidate.$1;
        _probedWindowsExtraArgs = candidate.$2;
        return <String>[candidate.$1, ...candidate.$2];
      }
    } catch (_) {
      // 可执行名不存在：尝试下一个。
    }
  }
  // 全失败：回退 python3，交由 launch 如实报不可用（E5-1 登记）。
  _probedWindowsExecutable = 'python3';
  _probedWindowsExtraArgs = const <String>[];
  return const <String>['python3'];
}

/// Python 可执行文件解析结果（镜像 `NodeExecutableLocation`）。
class PythonExecutableLocation {
  /// 构造。
  const PythonExecutableLocation({
    required this.resolved,
    required this.probed,
    this.extraArgs = const <String>[],
  });

  /// 命中的绝对路径 / 裸名；全部落空为 null。
  final String? resolved;

  /// 本次探测过的候选位置（失败文案用）。
  final List<String> probed;

  /// 可执行名之后的附加参数（Windows `py -3` 场景为 `['-3']`）。
  final List<String> extraArgs;
}

/// 蜘蛛脚本运行时（常驻 + 逐行 JSON ABI）。
abstract class PythonRuntime {
  /// 按平台选择运行时：Android 走 Chaquopy 进程内（[ChannelPythonRuntime]），
  /// 其余平台走子进程（[StdioPythonRuntime]）。
  ///
  /// 桌面端按 [locatePython] 的「**内置优先 → 系统回退**」四段式解析解释器
  /// （镜像 [ProcessNodeHost.locate]）；[pythonExecutable] 显式传入非缺省名时
  /// 直接采用、不探测（测试 / 自定义打包可覆盖）。
  factory PythonRuntime.forCurrentPlatform({
    String pythonExecutable = 'python3',
    Duration timeout = const Duration(seconds: 15),
  }) {
    if (Platform.isAndroid) return ChannelPythonRuntime(timeout: timeout);
    if (pythonExecutable != 'python3') {
      return StdioPythonRuntime(
        pythonExecutable: pythonExecutable,
        timeout: timeout,
      );
    }
    final PythonExecutableLocation located = locatePython();
    return StdioPythonRuntime(
      pythonExecutable: located.resolved ?? 'python3',
      extraArgs: located.extraArgs,
      timeout: timeout,
      pythonPath: _resolvePythonStdlibDir(),
      probedCandidates: located.probed,
    );
  }

  /// 解析桌面端 Python 可执行文件：命中返回绝对路径 / 裸名，全部落空返回 null。
  ///
  /// 探测顺序（逐字镜像 `ProcessNodeHost.locate` 四段式）：
  ///   ① 随包内置 `<exeDir>/pyruntime/python(.exe)`（Windows）·
  ///      `<App>/Contents/Resources/pyruntime/bin/python3`（macOS，Resources 为
  ///      数据区，避开 codesign 对 `Contents/MacOS` 子树的嵌套代码校验）；
  ///   ② 平台常见安装位置（Windows：LOCALAPPDATA\Programs\Python、
  ///      Program Files、Program Files(x86)、系统盘根下的 `Python3xx`；
  ///      macOS：Homebrew arm64 / x86、/usr/local、/usr/bin）；
  ///   ③ PATH 兜底；
  ///   ④ 裸名兜底（Windows 再按 `python3 → python → py -3` 探测，其余 `python3`）。
  static PythonExecutableLocation locatePython() {
    final List<String> candidates = <String>[
      ..._bundledCandidates(),
      ..._installCandidates(),
    ];
    for (final String candidate in candidates) {
      if (File(candidate).existsSync()) {
        return PythonExecutableLocation(resolved: candidate, probed: candidates);
      }
    }
    final String? fromPath =
        _fromPath(Platform.isWindows ? 'python.exe' : 'python3');
    if (fromPath != null) {
      return PythonExecutableLocation(resolved: fromPath, probed: candidates);
    }
    if (Platform.isWindows) {
      final List<String> command = _probeWindowsPythonCommand();
      return PythonExecutableLocation(
        resolved: command.first,
        extraArgs: command.sublist(1),
        probed: candidates,
      );
    }
    return PythonExecutableLocation(resolved: 'python3', probed: candidates);
  }

  /// 随包内置候选（新增档，对齐 Node `<exeDir>/noderuntime`）。
  ///
  /// macOS 落点须为 `<App>/Contents/Resources/pyruntime`（**非** `Contents/MacOS`）：
  /// codesign 把 `Contents/MacOS` 下整棵子树视为代码，`python-stdlib/**/*.py` 会被
  /// 判为「未签名的嵌套代码」而令 App 重签失败（Node 仅单个 Mach-O，故不受影响）。
  static List<String> _bundledCandidates() {
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    if (Platform.isWindows) {
      return <String>[
        p.join(exeDir, 'pyruntime', 'python.exe'),
        p.join(exeDir, 'python.exe'),
      ];
    }
    return <String>[
      p.join(_macResourcesDir(exeDir), 'pyruntime', 'bin', 'python3'),
      p.join(exeDir, 'pyruntime', 'bin', 'python3'),
      p.join(exeDir, 'python3'),
    ];
  }

  /// macOS 专属：`<App>/Contents/Resources`（`exeDir` 为 `Contents/MacOS`）。
  static String _macResourcesDir(String exeDir) =>
      p.normalize(p.join(exeDir, '..', 'Resources'));

  /// 平台常见安装位置候选。
  static List<String> _installCandidates() {
    if (Platform.isWindows) {
      final Map<String, String> env = Platform.environment;
      final List<String> out = <String>[];
      final String? localAppData = env['LOCALAPPDATA'];
      if (localAppData != null) {
        // `%LOCALAPPDATA%\Programs\Python\Python3xx\python.exe`。
        out.addAll(_subdirFiles(
          p.join(localAppData, 'Programs', 'Python'),
          'python.exe',
          dirPrefix: 'Python3',
        ));
      }
      final String programFiles = env['ProgramFiles'] ?? r'C:\Program Files';
      final String programFilesX86 =
          env['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
      out.addAll(_subdirFiles(programFiles, 'python.exe', dirPrefix: 'Python3'));
      out.addAll(
          _subdirFiles(programFilesX86, 'python.exe', dirPrefix: 'Python3'));
      // 盘根安装：`<SystemDrive>:\Python3xx\python.exe`（安装器「所有用户」默认）。
      final String systemDrive = env['SystemDrive'] ?? 'C:';
      out.addAll(
          _subdirFiles('$systemDrive\\', 'python.exe', dirPrefix: 'Python3'));
      return out;
    }
    return <String>[
      '/opt/homebrew/bin/python3',
      '/usr/local/bin/python3',
      '/usr/bin/python3',
    ];
  }

  /// 列出 [root] 下一级子目录（可加 [dirPrefix] 前缀过滤）中存在的 [fileName]
  /// 绝对路径（容错：目录不存在 / 不可读返回空）。
  static List<String> _subdirFiles(
    String root,
    String fileName, {
    String? dirPrefix,
  }) {
    final Directory dir = Directory(root);
    if (!dir.existsSync()) return const <String>[];
    final List<String> out = <String>[];
    try {
      for (final FileSystemEntity entity in dir.listSync()) {
        if (entity is! Directory) continue;
        if (dirPrefix != null &&
            !p.basename(entity.path).startsWith(dirPrefix)) {
          continue;
        }
        final String candidate = p.join(entity.path, fileName);
        if (File(candidate).existsSync()) out.add(candidate);
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

  /// 解析内置纯 py 依赖目录（`base/` + requests 栈），供 `PYTHONPATH` 注入。
  ///
  /// 依赖以 `assets/python-stdlib` 随包分发（S4/S5 落盘）；此处按候选位置探测，
  /// 找不到返回 null（此时仅注入 no-user-site / no-bytecode，脚本 import base
  /// 会自行报错，便于定位）。
  static String? _resolvePythonStdlibDir() {
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    final List<String> candidates = <String>[
      p.join(_macResourcesDir(exeDir), 'pyruntime', 'python-stdlib'),
      p.join(exeDir, 'pyruntime', 'python-stdlib'),
      p.join(exeDir, 'python-stdlib'),
      p.join(exeDir, 'data', 'flutter_assets', 'assets', 'python-stdlib'),
    ];
    for (final String candidate in candidates) {
      if (Directory(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// 运行时日志（含降级事件）。
  void Function(String)? onLog;

  /// 运行时标签（日志用，如「子进程 python3」/「Android Chaquopy 进程内运行时」）。
  String get runtimeLabel;

  /// 启动并等待脚本输出 `READY`；失败抛 [SpiderException]（`scriptLoad`）。
  Future<void> launch(String script);

  /// 写入一行请求，返回一行响应；超时抛 [SpiderException]（`timeout`）。
  Future<String> roundTrip(String requestLine);

  /// 关闭运行时（幂等）。
  Future<void> shutdown();
}

/// 子进程运行时（`python3 -u <bridge> <script>` + stdio ABI；桌面 / 测试）。
///
/// **桥接层（S3）**：桌面端不再直接把用户脚本当 ABI 脚本跑，而是把
/// [vboxPythonBridgeScript] 落盘为垫片、以 `python -u <bridge> <scriptPath>`
/// 启动，由桥接层 `exec` 用户脚本并以**对象调用**提供服务（对齐 iOS
/// `PythonBridge.m` / Android 桥）。**Dart↔宿主 ABI 形态不变**（仍是 JSON 行）。
class StdioPythonRuntime implements PythonRuntime {
  /// [pythonExecutable] 可注入（测试用 `python3`）。
  ///
  /// [extraArgs] 为可执行名之后的附加参数（E5-1：Windows 探测命中 `py` 时
  /// 传 `['-3']` 指定 Python3）。
  ///
  /// [bridgeScript] 为桥接垫片源码（缺省 [vboxPythonBridgeScript]，测试可覆盖）。
  /// [pythonPath] 命中内置纯 py 依赖目录时注入 `PYTHONPATH`（见 §3.9）。
  /// [probedCandidates] 供启动失败文案列出已探测位置（对齐 Node）。
  StdioPythonRuntime({
    this.pythonExecutable = 'python3',
    this.extraArgs = const <String>[],
    this.timeout = const Duration(seconds: 15),
    this.bridgeScript = vboxPythonBridgeScript,
    this.pythonPath,
    this.probedCandidates = const <String>[],
  });

  final String pythonExecutable;

  /// 启动参数前缀（插在 `-u` 与桥接垫片路径之前）。
  final List<String> extraArgs;

  final Duration timeout;

  /// 桥接垫片源码（落盘后作为 `argv[0]` 位置的脚本执行）。
  final String bridgeScript;

  /// `PYTHONPATH` 注入值（内置纯 py 依赖目录）；null → 不注入。
  final String? pythonPath;

  /// 本次探测过的候选位置（失败文案用）。
  final List<String> probedCandidates;

  Process? _process;
  StreamSubscription<String>? _sub;
  final Queue<Completer<String>> _pending = Queue<Completer<String>>();

  @override
  void Function(String)? onLog;

  @override
  String get runtimeLabel => '子进程 $pythonExecutable';

  /// 注入子进程环境变量（§3.9，对齐 Android / 避免污染）：
  /// `PYTHONNOUSERSITE=1`（不读用户 site-packages）、
  /// `PYTHONDONTWRITEBYTECODE=1`（只读目录不写 pyc）、
  /// 命中内置依赖目录时注入 `PYTHONPATH`。
  Map<String, String> _buildEnvironment() {
    return <String, String>{
      'PYTHONNOUSERSITE': '1',
      'PYTHONDONTWRITEBYTECODE': '1',
      if (pythonPath != null && pythonPath!.isNotEmpty) 'PYTHONPATH': pythonPath!,
    };
  }

  /// 启动失败文案（可操作）：列出全部已探测位置与两条修复路径。
  String _launchFailureMessage(ProcessException e) {
    final StringBuffer buffer = StringBuffer()
      ..writeln('Python 运行时启动失败：未找到可执行文件「$pythonExecutable」（${e.message}）');
    if (probedCandidates.isNotEmpty) {
      buffer.writeln('已探测以下位置（均不存在）：');
      for (final String candidate in probedCandidates) {
        buffer.writeln('  · $candidate');
      }
      buffer.writeln('  · PATH 环境变量中的 python3 / python.exe');
    }
    buffer
      ..writeln('请任选其一：')
      ..writeln('  ① 安装 Python 3 并确认已加入 PATH；')
      ..writeln('  ② 或使用内置运行时（把 CPython 放到 <exeDir>/pyruntime/ 后重启）。');
    return buffer.toString();
  }

  /// Node/Python 子进程生命周期通道（Windows Native `NodeLifecyclePlugin`）。
  static const MethodChannel _lifecycleChannel =
      MethodChannel('com.vbox.node/lifecycle');

  /// 绑定子进程到主进程的 Job Object（失败不阻断，仅记日志）。
  ///
  /// 对齐 `ProcessNodeHost._attachToJobObject`：主进程退出时由 OS 依据
  /// KILL_ON_JOB_CLOSE 连带终结，是「运行时文件被占用」的第一道防线。
  Future<void> _attachToJobObject(int pid) async {
    try {
      await _lifecycleChannel.invokeMethod<void>('attach', pid);
    } on MissingPluginException {
      // 非 Windows / 未接原生插件：忽略。
    } on PlatformException catch (e) {
      onLog?.call('⚠️ 绑定 Python 子进程到 Job Object 失败（${e.code}）：${e.message}');
    }
  }
  @override
  Future<void> launch(String script) async {
    await shutdown();
    // ① 桥接垫片落盘（每次启动独立临时文件，避免并发串扰）。
    // ② 用户脚本落盘，经 argv[1] 交给桥接层读取（对齐 Android v2）。
    final String stamp = DateTime.now().microsecondsSinceEpoch.toString();
    final Directory tmpDir = Directory.systemTemp;
    final File bridgeTmp = File('${tmpDir.path}/vbox_py_bridge_$stamp.py');
    await bridgeTmp.writeAsString(bridgeScript);
    final File scriptTmp = File('${tmpDir.path}/vbox_py_spider_$stamp.py');
    await scriptTmp.writeAsString(script);

    final Process p;
    try {
      p = await Process.start(
        pythonExecutable,
        <String>[...extraArgs, '-u', bridgeTmp.path, scriptTmp.path],
        environment: _buildEnvironment(),
        includeParentEnvironment: true,
      );
    } on ProcessException catch (e) {
      throw SpiderException(SpiderErrorCode.scriptLoad, _launchFailureMessage(e));
    }
    _process = p;
    // Windows：把 Python 子进程也纳入主进程的 Job Object（KILL_ON_JOB_CLOSE）。
    // 主进程退出（含被安装器要求优雅退出）时由 OS 连带终结，避免
    // pyruntime\python.exe 常驻锁住安装目录里的运行时文件——那正是安装器
    // 覆盖时报「DeleteFile 失败；错误代码 5」的根因之一。
    if (Platform.isWindows) {
      await _attachToJobObject(p.pid);
    }
    _sub = p.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);

    // 等待脚本 READY 行
    final Completer<String> ready = Completer<String>();
    _pending.add(ready);
    final String line;
    try {
      line = await ready.future.timeout(timeout);
    } on TimeoutException {
      await shutdown();
      throw const SpiderException(
        SpiderErrorCode.scriptLoad,
        'Python 桥启动超时：进程未输出 READY',
      );
    }
    if (line != 'READY') {
      await shutdown();
      throw SpiderException(
        SpiderErrorCode.scriptLoad,
        'Python 桥启动失败：首个输出为「$line」',
      );
    }
  }

  @override
  Future<String> roundTrip(String requestLine) async {
    final Process? p = _process;
    if (p == null) {
      throw const SpiderException(
        SpiderErrorCode.register,
        'Python 桥未就绪：请先 loadScript + registerSpider',
      );
    }
    final Completer<String> c = Completer<String>();
    _pending.add(c);
    p.stdin.writeln(requestLine);
    try {
      return await c.future.timeout(timeout);
    } on TimeoutException {
      throw const SpiderException(SpiderErrorCode.timeout, 'Python 桥响应超时');
    }
  }

  @override
  Future<void> shutdown() async {
    await _sub?.cancel();
    _sub = null;
    final Process? p = _process;
    _process = null;
    _pending.clear();
    if (p != null) {
      p.kill();
    }
    await p?.exitCode;
  }

  void _onLine(String line) {
    if (_pending.isNotEmpty) {
      _pending.removeFirst().complete(line);
    } else if (line.trim().isNotEmpty) {
      onLog?.call('[py] $line');
    }
  }
}

/// 通道运行时（Android · Chaquopy 进程内解释器；RT-运1）。
///
/// 与原生 `PythonPlugin.kt` 的 `com.vbox.python/python` 通道对齐：
///  - `launch`（`script` / `timeoutMs`）→ `null`（等待脚本 `READY`）
///  - `request`（`line` / `timeoutMs`）→ 一行响应
///  - `shutdown` → `null`
///
/// 通道未注册（未接入 Chaquopy / 非 Android）时抛 `E_UNIMPLEMENTED`，
/// 上层可据此降级提示，不 crash。
class ChannelPythonRuntime implements PythonRuntime {
  ChannelPythonRuntime({
    this.timeout = const Duration(seconds: 15),
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel(channelName);

  /// 原生通道名（与 `PythonPlugin.CHANNEL` 一致）。
  static const String channelName = 'com.vbox.python/python';

  /// 通道调用兜底宽限：原生侧已按 [timeout] 先回，此为防原生线程卡死的安全网。
  static const Duration _backstop = Duration(seconds: 5);

  final Duration timeout;
  final MethodChannel _channel;

  @override
  void Function(String)? onLog;

  @override
  String get runtimeLabel => 'Android Chaquopy 进程内运行时';

  Duration get _budget => timeout + _backstop;

  @override
  Future<void> launch(String script) async {
    try {
      await _channel.invokeMethod<void>('launch', <String, Object?>{
        'script': script,
        'timeoutMs': timeout.inMilliseconds,
      }).timeout(_budget);
    } on TimeoutException {
      throw const SpiderException(
        SpiderErrorCode.scriptLoad,
        'Python 桥启动超时：未输出 READY',
      );
    } on MissingPluginException {
      throw const SpiderException(
        SpiderErrorCode.unimplemented,
        'Python 运行时不可用：Android Chaquopy 通道未注册',
      );
    } on PlatformException catch (e) {
      throw SpiderException(
        SpiderErrorCode.scriptLoad,
        e.message ?? 'Python 运行时启动失败',
      );
    }
  }

  @override
  Future<String> roundTrip(String requestLine) async {
    try {
      final String? resp =
          await _channel.invokeMethod<String>('request', <String, Object?>{
        'line': requestLine,
        'timeoutMs': timeout.inMilliseconds,
      }).timeout(_budget);
      return resp ?? '';
    } on TimeoutException {
      throw const SpiderException(SpiderErrorCode.timeout, 'Python 桥响应超时');
    } on MissingPluginException {
      throw const SpiderException(
        SpiderErrorCode.unimplemented,
        'Python 运行时不可用：Android Chaquopy 通道未注册',
      );
    } on PlatformException catch (e) {
      if (e.code == 'E_TIMEOUT') {
        throw SpiderException(
          SpiderErrorCode.timeout,
          e.message ?? 'Python 桥响应超时',
        );
      }
      throw SpiderException(
        SpiderErrorCode.runtime,
        e.message ?? 'Python 运行时调用失败',
      );
    }
  }

  @override
  Future<void> shutdown() async {
    try {
      await _channel.invokeMethod<void>('shutdown');
    } on MissingPluginException {
      // 通道未注册（非 Android / 未接入）→ 无需关闭。
    } on PlatformException {
      // 关闭失败不阻断（幂等语义）。
    }
  }
}
