/// 外壳：启动编排（批次 L · L-壳2）。
///
/// 唯一真相源：iOS `VBoxApp.swift` L16-L31（init 子系统拉起）+
/// `ContentView.swift` L149-L190（`onAppear` 并行启动 + 启动页门控）。
///
/// 编排顺序（对齐 iOS 冷启动）：
///   ① **会话恢复** —— 本地登录态 / 音乐播放队列 `restoreQueue`；
///   ② **远程源同步** —— 清单缓存按 TTL 预热（对齐 iOS `RemoteSourceConfigManager`）；
///   ③ **引擎就绪** —— JS 引擎探测（JSC 主 / QuickJS 降级，D6 降级可观测）。
///
/// 失败策略（L-壳2 验收）：**单步失败不阻断** —— 每步 `try/catch` 收敛为
/// [StartupStepResult]，记录日志（`error` 级）后继续后续步骤，
/// 最终照常进入首页（[StartupReport.allOk] 供门控/诊断观测）。
///
/// 设计：任务以 [StartupTask] 注入，纯 Dart 无插件依赖，便于单测。
library;

import '../../core/utils/logger.dart';

/// 单个启动步骤（名称 + 动作）。
class StartupTask {
  /// 构造。
  const StartupTask(this.name, this.run);

  /// 步骤名（日志 / 报告可读）。
  final String name;

  /// 步骤动作（抛错即视为该步失败，由编排器收敛）。
  final Future<void> Function() run;
}

/// 单步执行结果。
class StartupStepResult {
  /// 构造。
  const StartupStepResult({
    required this.name,
    required this.ok,
    required this.elapsed,
    this.error,
  });

  /// 步骤名。
  final String name;

  /// 是否成功。
  final bool ok;

  /// 耗时。
  final Duration elapsed;

  /// 失败原因（成功为 null）。
  final Object? error;
}

/// 编排总报告（冷启动一次生成）。
class StartupReport {
  /// 构造。
  const StartupReport(this.steps);

  /// 各步结果（按执行顺序）。
  final List<StartupStepResult> steps;

  /// 是否全部成功。
  bool get allOk => steps.every((StartupStepResult s) => s.ok);

  /// 失败的步骤名。
  List<String> get failedSteps =>
      steps.where((StartupStepResult s) => !s.ok).map((StartupStepResult s) => s.name).toList();
}

/// 启动编排器：顺序执行 [StartupTask]，单步失败降级不阻断。
class StartupOrchestrator {
  /// 构造。
  const StartupOrchestrator({this.logTag = 'startup'});

  /// 日志标签。
  final String logTag;

  /// 顺序执行 [tasks]，返回总报告；每步结果经 [onStep] 实时回调（可空）。
  Future<StartupReport> run(
    List<StartupTask> tasks, {
    void Function(StartupStepResult result)? onStep,
  }) async {
    final List<StartupStepResult> results = <StartupStepResult>[];
    for (final StartupTask task in tasks) {
      final Stopwatch sw = Stopwatch()..start();
      try {
        await task.run();
        sw.stop();
        final StartupStepResult result = StartupStepResult(
          name: task.name,
          ok: true,
          elapsed: sw.elapsed,
        );
        AppLog.info(logTag, '启动步骤「${task.name}」完成（${sw.elapsedMilliseconds}ms）');
        results.add(result);
        onStep?.call(result);
      } catch (e) {
        sw.stop();
        // 单步失败不阻断：记录日志后继续下一步。
        AppLog.error(logTag, '启动步骤「${task.name}」失败，已降级跳过', error: e);
        final StartupStepResult result = StartupStepResult(
          name: task.name,
          ok: false,
          elapsed: sw.elapsed,
          error: e,
        );
        results.add(result);
        onStep?.call(result);
      }
    }
    final StartupReport report = StartupReport(results);
    AppLog.info(
      logTag,
      report.allOk
          ? '启动编排完成（${results.length} 步全部成功）'
          : '启动编排完成（失败 ${report.failedSteps.length}/${results.length} 步，已降级）',
    );
    return report;
  }
}