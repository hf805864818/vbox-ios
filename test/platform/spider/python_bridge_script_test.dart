/// 平台层单测：桌面 Python 桥接脚本字符串常量（S1 · 对齐
/// `android/app/src/main/python/vbox_python_bridge.py`）。
///
/// [vboxPythonBridgeScript] 承载 `python -u <bridge> <script>` 桥接垫片的完整
/// 源码，是桌面 Python 运行时的唯一真相源之一。此处只做常量完整性契约断言
/// （非空 + 关键 ABI 标记），子进程端到端行为由 `python_bridge_engine_test.dart`
/// 覆盖。
///
/// 另：直接 import 本库使 `python_bridge_script.dart` 被测试富集触达——该文件
/// 本身只是单个 `const String` 声明，覆盖门槛若按多行字符串源码做启发式分母
/// 会系统性高估；触达后即回归真实的 1 行口径。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vbox/platform/spider/python_bridge_script.dart';

void main() {
  test('vboxPythonBridgeScript 非空且包含关键 ABI 标记', () {
    expect(vboxPythonBridgeScript, isNotEmpty);

    // 就绪握手：宿主等待脚本在 exec 用户脚本后输出 READY 才进入请求循环。
    expect(vboxPythonBridgeScript, contains('READY'));

    // 关键错误码：宿主动脉靠这些前缀做状态机判定。
    expect(vboxPythonBridgeScript, contains('E_NO_SPIDER'));
    expect(vboxPythonBridgeScript, contains('E_SCRIPT_EXEC'));

    // 宿主 stdio 适配器与 TVBox 调用面（与 Android v2 桥语义同步）。
    expect(vboxPythonBridgeScript, contains('class _StdioIO'));
    expect(vboxPythonBridgeScript, contains('def _handle'));
  });
}