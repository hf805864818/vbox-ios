/// 启动编排单测（批次 L · L-壳2）。
///
/// 覆盖：顺序执行、全成功报告、**单步失败降级不阻断**（后续步骤照常执行）
/// 与失败步骤登记（验收口径：单步失败不阻塞进入首页且有日志）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/presentation/shell/startup_orchestrator.dart';

void main() {
  test('全部成功：按序执行且 allOk 为 true', () async {
    final List<String> calls = <String>[];
    const StartupOrchestrator orchestrator = StartupOrchestrator();
    final StartupReport report = await orchestrator.run(<StartupTask>[
      StartupTask('会话恢复', () async => calls.add('session')),
      StartupTask('远程源同步', () async => calls.add('remote')),
      StartupTask('引擎就绪', () async => calls.add('engine')),
    ]);

    expect(calls, <String>['session', 'remote', 'engine']);
    expect(report.allOk, isTrue);
    expect(report.failedSteps, isEmpty);
    expect(report.steps.length, 3);
  });

  test('单步失败降级不阻断：后续步骤照常执行', () async {
    final List<String> calls = <String>[];
    const StartupOrchestrator orchestrator = StartupOrchestrator();
    final StartupReport report = await orchestrator.run(<StartupTask>[
      StartupTask('会话恢复', () async => calls.add('session')),
      StartupTask('远程源同步', () async => throw StateError('离线')),
      StartupTask('引擎就绪', () async => calls.add('engine')),
    ]);

    // 失败步骤被跳过，但后续步骤不被阻断。
    expect(calls, <String>['session', 'engine']);
    expect(report.allOk, isFalse);
    expect(report.failedSteps, <String>['远程源同步']);
    expect(report.steps[1].ok, isFalse);
    expect(report.steps[1].error, isA<StateError>());
    expect(report.steps[2].ok, isTrue);
  });

  test('每步结果经 onStep 实时回调', () async {
    final List<String> seen = <String>[];
    const StartupOrchestrator orchestrator = StartupOrchestrator();
    await orchestrator.run(
      <StartupTask>[
        StartupTask('a', () async {}),
        StartupTask('b', () async => throw Exception('x')),
      ],
      onStep: (StartupStepResult r) => seen.add('${r.name}:${r.ok}'),
    );

    expect(seen, <String>['a:true', 'b:false']);
  });
}