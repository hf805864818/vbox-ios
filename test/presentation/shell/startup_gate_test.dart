/// 启动页门控单测（批次 L · L-壳1）。
///
/// 覆盖（对齐 iOS `ContentView` L149-L190 / L247-L254）：
///   ① 最短展示 3.5s（就绪信号提前到达也需满足）；
///   ② 数据就绪后立即淡出；
///   ③ 10s 兜底强制退出（数据始终未就绪）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/presentation/shell/splash_gate_monitor.dart';
import 'package:vbox/presentation/shell/startup_gate.dart';

/// 占位启动页（隔离品牌闪屏动画，专注门控时序）。
const Key _splashKey = Key('test-splash');
const Widget _splash = ColoredBox(key: _splashKey, color: Colors.black);

/// 模拟首页外壳的根节点形态：**只有 Positioned 子项**的 Stack。
///
/// HomeShellPage 的根节点即此形态，在 Stack 下发的松约束下会塌缩为 0×0。
class _PositionedOnlyShell extends StatelessWidget {
  const _PositionedOnlyShell();

  @override
  Widget build(BuildContext context) {
    return const Stack(
      children: <Widget>[
        Positioned.fill(
          child: ColoredBox(
            key: Key('shell-probe'),
            color: Colors.green,
          ),
        ),
      ],
    );
  }
}

/// 读取覆盖层 [AnimatedOpacity] 的当前不透明度（1 = 仍显示，0 = 已淡出）。
double _splashOpacity(WidgetTester tester) {
  final Finder finder = find.ancestor(
    of: find.byKey(_splashKey),
    matching: find.byType(AnimatedOpacity),
  );
  return tester.widget<AnimatedOpacity>(finder).opacity;
}

void main() {
  setUp(() => SplashGateMonitor.instance.resetForTest());

  testWidgets('数据就绪仍需满足最短展示 3.5s 后才淡出', (WidgetTester tester) async {
    int started = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StartupGate(
          onStartup: () async {
            started++;
            SplashGateMonitor.instance.markHomeReady();
          },
          splash: _splash,
          child: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();
    expect(started, 1);

    // 3.4s：未达最短展示时长 → 仍显示。
    await tester.pump(const Duration(milliseconds: 3400));
    expect(_splashOpacity(tester), 1.0);

    // 越过 3.5s 门限 → 触发淡出。
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 500));
    expect(_splashOpacity(tester), 0.0);

    // 卸载以释放闪屏动画 Ticker / 定时器。
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('数据始终未就绪：10s 兜底强制退出', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StartupGate(
          onStartup: () async {},
          splash: _splash,
          child: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();

    // 9.9s：仅越过最短展示时长，但数据未就绪且未到兜底 → 仍显示。
    await tester.pump(const Duration(milliseconds: 9900));
    expect(_splashOpacity(tester), 1.0);

    // 越过 10s 兜底 → 强制淡出。
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 500));
    expect(_splashOpacity(tester), 0.0);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('就绪信号晚于最短展示时长：到达即淡出', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StartupGate(
          onStartup: () async {},
          splash: _splash,
          child: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();

    // 5s：已过最短展示，但未就绪 → 仍显示。
    await tester.pump(const Duration(seconds: 5));
    expect(_splashOpacity(tester), 1.0);

    // 就绪信号到达 → 立即淡出。
    SplashGateMonitor.instance.markHomeReady();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(_splashOpacity(tester), 0.0);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('首页外壳拿满屏尺寸，不被启动页 Stack 松约束塌缩（黑屏回归）',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StartupGate(
          onStartup: () async {},
          splash: _splash,
          child: const _PositionedOnlyShell(),
        ),
      ),
    );
    await tester.pump();

    // 无 Positioned.fill 包裹时，外壳根 Stack 会塌缩为 0×0，
    // 表现为启动页淡出后整屏黑；此处锁死为全屏尺寸（默认测试窗口 800×600）。
    expect(
      tester.getSize(find.byKey(const Key('shell-probe'))),
      const Size(800, 600),
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });
}