/// 平台层单测：桌面 Python 运行时一致性（S7 · 对齐 iOS/Android 语义）。
///
/// 与 `python_bridge_engine_test.dart`（引擎层）互补，本文件聚焦**运行时层**，
/// 覆盖落地方案 S2/S3/S7 的桌面一致性验收点：
///  1. `PythonRuntime.locatePython()` 探测链「**内置优先 → 系统回退**」四段式，
///     镜像 `ProcessNodeHost.locate`（`probed` 首项必为随包 `<...>/pyruntime/...`，
///     macOS 落点 `Contents/Resources/pyruntime`）；
///  2. `StdioPythonRuntime` 启动失败文案可操作：列出已探测位置 + 两条修复路径
///     （对应验收标准 ③「未装系统 Python 不报『启动超时』」）；
///  3. **冒烟**：真实 TVBox `Spider` 类脚本（`python_spider_class.py`）经桌面
///     运行时 `python -u <bridge> <script>` 直连 → `homeContent`/`categoryContent`
///     有分类胶囊 + 列表数据（对应验收标准 ①）。
///
/// 环境无 python3 时第 3 组整组跳过（`skip`），不破坏门禁全绿。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vbox/domain/entities/spider/spider_engine.dart';
import 'package:vbox/domain/entities/spider/spider_models.dart';
import 'package:vbox/platform/spider/python_runtime.dart';
import 'package:vbox/platform/spider/spider_abi.dart';

/// 环境是否可用 python3（同步探测，便于静态 `skip` 判定）。
bool _pythonAvailable() {
  try {
    return Process.runSync('python3', <String>['--version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// 读取真实 Spider 类脚本内容（fixtures 常驻脚本）。
String _spiderScript() =>
    File('conformance/fixtures/python_spider_class.py').readAsStringSync();

void main() {
  const SpiderAbiCodec codec = SpiderAbiCodec();

  group('PythonRuntime.locatePython（桌面探测链 · 镜像 Node 四段式）', () {
    test('probed 首项为随包内置候选（<exeDir>/pyruntime/...）', () {
      final PythonExecutableLocation located = PythonRuntime.locatePython();

      // 内置候选随平台不同：Windows `pyruntime/python.exe`，其余 `pyruntime/bin/python3`。
      final String bundledSuffix = Platform.isWindows
          ? p.join('pyruntime', 'python.exe')
          : p.join('pyruntime', 'bin', 'python3');

      expect(located.probed, isNotEmpty);
      expect(
        located.probed.first,
        endsWith(bundledSuffix),
        reason: '「内置优先」：随包候选必须排在探测清单最前',
      );
      expect(
        located.probed.length,
        greaterThanOrEqualTo(2),
        reason: '内置档之后应接平台安装位置候选',
      );
    });

    test('probed 含平台安装位置候选（非 Windows 分支）', () {
      if (Platform.isWindows) return; // Windows 分支依赖环境变量，另测
      final PythonExecutableLocation located = PythonRuntime.locatePython();
      expect(
        located.probed,
        contains('/usr/bin/python3'),
        reason: 'macOS/Linux 安装位置档应包含 /usr/bin/python3',
      );
    });

    test('resolved 恒非空（全落空回退裸名，交由 launch 如实报不可用）', () {
      final PythonExecutableLocation located = PythonRuntime.locatePython();
      expect(located.resolved, isNotNull);
      expect(located.resolved, isNotEmpty);
    });
  });

  group('StdioPythonRuntime 启动失败文案（可操作 · 对齐 Node _failureMessage）', () {
    test('可执行文件不存在 → scriptLoad + 列出探测位置与修复路径', () async {
      final StdioPythonRuntime runtime = StdioPythonRuntime(
        pythonExecutable: 'vbox-no-such-python-xyz',
        probedCandidates: const <String>[
          r'C:\app\pyruntime\python.exe',
          '/Applications/vbox.app/Contents/Resources/pyruntime/bin/python3',
        ],
      );
      try {
        await expectLater(
          runtime.launch('print("READY")\n'),
          throwsA(
            isA<SpiderException>()
                .having((SpiderException e) => e.code, 'code',
                    SpiderErrorCode.scriptLoad)
                .having((SpiderException e) => e.message, 'message',
                    contains('vbox-no-such-python-xyz'))
                .having((SpiderException e) => e.message, 'message',
                    contains(r'C:\app\pyruntime\python.exe'))
                .having((SpiderException e) => e.message, 'message',
                    contains('PATH'))
                .having((SpiderException e) => e.message, 'message',
                    contains('安装 Python 3'))
                .having((SpiderException e) => e.message, 'message',
                    contains('内置运行时'))
                .having((SpiderException e) => e.message, 'message',
                    contains('pyruntime')),
          ),
        );
      } finally {
        await runtime.shutdown();
      }
    });
  });

  group('桌面一致性冒烟（真实 Spider 类脚本 → 首页/分类有数据）', () {
    final bool hasPython = _pythonAvailable();
    final Object skip = hasPython ? false : '环境无 python3，跳过子进程测试';

    test('StdioPythonRuntime 直连 ABI：homeContent 出分类 + 列表', () async {
      final StdioPythonRuntime runtime = StdioPythonRuntime(
        timeout: const Duration(seconds: 20),
      );
      try {
        await runtime.launch(_spiderScript());

        final String line = await runtime.roundTrip(
          jsonEncode(codec.encodeRequest('homeContent', const <String, Object?>{})),
        );
        final AbiResponse resp = codec.decodeResponse(line);
        final HomeContentResult home =
            HomeContentResult.fromJson(resp.data ?? const <String, Object?>{});

        expect(home.classes, hasLength(3), reason: '分类胶囊应有数据');
        expect(home.classes!.first.typeName, '电影');
        expect(home.list, hasLength(1), reason: '首页列表应有数据');
        expect(home.list!.first.vodId, '1001');
      } finally {
        await runtime.shutdown();
      }
    }, skip: skip);

    test('StdioPythonRuntime 直连 ABI：categoryContent 出分页元数据', () async {
      final StdioPythonRuntime runtime = StdioPythonRuntime(
        timeout: const Duration(seconds: 20),
      );
      try {
        await runtime.launch(_spiderScript());

        final String line = await runtime.roundTrip(
          jsonEncode(codec.encodeRequest('categoryContent', <String, Object?>{
            'tid': '1',
            'pg': 1,
            'extend': '',
          })),
        );
        final AbiResponse resp = codec.decodeResponse(line);
        final CategoryContentResult cat =
            CategoryContentResult.fromJson(resp.data ?? const <String, Object?>{});

        expect(cat.page, 1);
        expect(cat.limit, 20);
        expect(cat.total, 200);
      } finally {
        await runtime.shutdown();
      }
    }, skip: skip);
  });
}
