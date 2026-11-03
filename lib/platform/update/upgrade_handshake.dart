/// 安装器 ↔ 运行中应用的「优雅升级」握手（方案 D）。
///
/// 背景（3.1889 安装器错误的根因之一）：Windows 上被当成映像加载的 exe 无法被
/// 删除/改名，安装器覆盖 `<安装目录>\pyruntime\python.exe`、`noderuntime\node.exe`
/// 时会失败（DeleteFile 错误码 5）。外部按路径强杀只能靠猜，猜漏就装不上。
///
/// 大厂（QQ / 微信 / Discord / Chrome）的通行做法是**让应用自己先退**：
///  1. 安装器在安装目录写标记文件 `.vbox-upgrade-request`；
///  2. 本进程每秒轮询，发现标记 → 关闭自管子进程 → 主动退出；
///  3. 安装器轮询「运行时文件能否改名」，能了就继续覆盖。
///
/// 与强杀（installer.iss 里 kill-runtime.ps1 那套）的关系：
/// 本方案是**第一顺位**，强杀只作为「应用崩溃残留 / 不响应」时的兜底。
///
/// 零磁盘、零常驻内存代价：只是每秒一次 `File.exists`。
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/utils/logger.dart';
import '../node/node_runtime_manager.dart';

/// 升级握手：监听安装器下发的退出请求。
class UpgradeHandshake {
  UpgradeHandshake._();

  /// 标记文件名（与 `windows/installer/installer.iss` 的 `UPGRADE_FLAG` 保持一致）。
  static const String flagFileName = '.vbox-upgrade-request';

  /// 轮询间隔：1s 足够快（安装器最长等 8s），对 CPU/IO 无感。
  static const Duration pollInterval = Duration(seconds: 1);

  /// 应用启动时刻：早于「启动前 30s」写入的标记视为上次安装残留，忽略并清理。
  static final DateTime _startedAt = DateTime.now();

  static Timer? _timer;
  static bool _handling = false;

  /// 启动监听（幂等；非 Windows 直接返回）。
  static void start() {
    if (!Platform.isWindows || _timer != null) return;

    final String? flagPath = _flagPath();
    if (flagPath == null) return;

    _timer = Timer.periodic(pollInterval, (Timer timer) async {
      if (_handling) return;
      final File flag = File(flagPath);
      if (!flag.existsSync()) return;

      // 残留标记：上次安装中途失败/被杀，标记没清掉。直接删掉，不影响本次启动。
      DateTime mtime;
      try {
        mtime = flag.lastModifiedSync();
      } catch (_) {
        return; // 文件刚好被安装器删掉 → 下次再判
      }
      if (mtime.isBefore(_startedAt.subtract(const Duration(seconds: 30)))) {
        try {
          flag.deleteSync();
        } catch (_) {}
        AppLog.info('app', '升级握手：清理残留标记 ${flag.path}');
        return;
      }

      _handling = true;
      timer.cancel();
      _timer = null;
      AppLog.info('app', '升级握手：检测到安装器升级请求，准备退出以便覆盖运行时文件');
      await _shutdownAndExit();
    });
  }

  /// 停止监听（测试 / 后台常驻模式用）。
  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 关闭自管运行时后退出进程。
  ///
  /// node / python 子进程已在 Windows 侧纳入主进程的 Job Object
  /// （`com.vbox.node/lifecycle` 的 attach，KILL_ON_JOB_CLOSE），
  /// 因此本进程退出时由 OS 连带终结它们，运行时文件随即解锁。
  static Future<void> _shutdownAndExit() async {
    try {
      await NodeRuntimeManager.instance.stop().timeout(const Duration(seconds: 3));
    } catch (e) {
      AppLog.warn('app', '升级握手：停止 Node 运行时失败（忽略）: $e');
    }
    // 给句柄关闭留出一点时间（Job Object 在进程退出时由 OS 关闭）。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    AppLog.info('app', '升级握手：退出进程');
    exit(0);
  }

  /// 标记文件绝对路径：`<exeDir>/.vbox-upgrade-request`。
  static String? _flagPath() {
    try {
      final String exeDir = File(Platform.resolvedExecutable).parent.path;
      return p.join(exeDir, flagFileName);
    } catch (_) {
      return null;
    }
  }
}
