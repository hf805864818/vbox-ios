/// 平台层：桌面 Python 桥接脚本（S1 · 对齐 iOS `PythonBridge.m` / Android `vbox_python_bridge.py`）。
///
/// 为什么需要它（G2，决定性缺口）：
/// 桌面端 [StdioPythonRuntime] 原先把**原始蜘蛛脚本**当 stdio ABI 脚本直接
/// `python3 -u <script>` 运行，等待脚本自行 `print('READY')`。而真实 TVBox py 源
/// 是标准 `Spider` 类定义脚本，**没有 ABI 循环** → 宿主永远等不到 READY →
/// 分类数据「暂无数据」。iOS 端正常，因为它走 `PythonBridge.m` 的 callSpider
/// **对象调用**；Android 已用 `vbox_python_bridge.py`（v2）对齐。**桌面端此前
/// 缺这一层**，本脚本即为补齐。
///
/// 语义（与 Android v2 逐阶段一致）：
///  1. exec 蜘蛛脚本 → globals（对齐 iOS `PyRun_File`）；
///  2. 校验 `Spider` 类存在（缺失 → `E_NO_SPIDER`，宿主 launch 报「首个输出非 READY」）；
///  3. 输出 `READY`，进入请求循环（**Dart↔宿主 ABI 形态不变**）；
///  4. 每请求：实例化 Spider → 可选 `init("")` → 按 TVBox 签名调用目标方法 →
///     `{ok, data, logs}` 响应行。
///
/// 与 Android 的差异仅两点（均为宿主环境差异，语义等价）：
///  - 入参 `io` 由本文件的 [_StdioIO] 适配 `sys.stdin/stdout`（Android 侧是
///    Kotlin `PythonPlugin.StdioBridge`）；
///  - 用户脚本经 `argv[1]` 传入路径，由 [_main] 读取后交给 [run]。
///
/// ⚠️ 维护约定：`run` / `_handle` / `_adapt` / `_build_args` / `_to_json_object`
/// 与 `android/app/src/main/python/vbox_python_bridge.py` 必须保持语义同步。
library;

/// 桌面桥接脚本源码（写入临时文件后由内置/系统 Python 解释器执行）。
///
/// 用 Dart 原始字符串（`r'''`）承载，避免 `\n` 被 Dart 转义；脚本内自包含，
/// 不 import 任何本地模块，故可作为单文件落盘执行。
const String vboxPythonBridgeScript = r'''
"""桌面端 Python 桥 v2 —— 对齐 iOS PythonBridge.m 的对象调用模型。

由 Flutter 桌面端 StdioPythonRuntime 以
`python3 -u <本脚本> <用户脚本路径>` 方式启动，经 stdio 与宿主交换 JSON 行。
"""

import json
import sys

# op → Spider 方法名（op 与 Dart SpiderAbiCodec.encodeRequest 一致）
_FN_MAP = {
    'init': 'init',
    'homeContent': 'homeContent',
    'homeVideoContent': 'homeVideoContent',
    'categoryContent': 'categoryContent',
    'detailContent': 'detailContent',
    'searchContent': 'searchContent',
    'searchContentPage': 'searchContentPage',
    'playerContent': 'playerContent',
}


def run(script, io):
    """在替换后的 stdio 上加载脚本并服务 ABI 请求循环（阻塞至宿主关闭）。

    :param script: 蜘蛛脚本源码（TVBox `Spider` 类定义）
    :param io: 宿主 stdio 适配器（`readLine()` / `write(s)`）
    """

    class _Stdin:
        """`sys.stdin` 替身：readline() 阻塞取宿主请求行，EOF 时返回空串。"""

        def readline(self, *args, **kwargs):
            line = io.readLine()
            if line is None:
                return ''
            return line if line.endswith('\n') else line + '\n'

        def read(self, *args, **kwargs):
            return self.readline()

        def readable(self):
            return True

    class _LogWriter:
        """`sys.stdout` / `sys.stderr` 替身：脚本输出进日志缓冲，不进协议。"""

        def __init__(self):
            self.buffer = []

        def write(self, text):
            if text:
                self.buffer.append(str(text))
                if len(self.buffer) > 64:
                    del self.buffer[:-64]
            return len(text)

        def flush(self):
            pass

        def writable(self):
            return True

    logs = _LogWriter()
    sys.stdin = _Stdin()
    sys.stdout = logs
    sys.stderr = logs

    def take_logs():
        out = ''.join(logs.buffer)
        del logs.buffer[:]
        return [ln for ln in out.splitlines() if ln.strip()][-32:]

    # Phase 1: exec 蜘蛛脚本（对齐 iOS PyRun_File → globals）
    # __name__ 必须非 '__main__'：部分脚本尾部有
    # `if __name__ == "__main__": self_test()` 自测代码，加载时执行会阻塞 launch。
    namespace = {'__name__': 'vbox_spider', '__file__': '<vbox_spider>'}
    try:
        exec(compile(script, '<vbox_spider>', 'exec'), namespace)
    except Exception as e:
        io.write('E_SCRIPT_EXEC: %s: %s | %s\n' % (
            type(e).__name__, e, ' / '.join(take_logs())[-400:]))
        return

    # Phase 2: 校验 Spider 类（对齐 iOS：未找到 Spider 类即失败）
    spider_cls = namespace.get('Spider')
    if spider_cls is None or not callable(spider_cls):
        io.write('E_NO_SPIDER: 脚本未定义可调用的 Spider 类\n')
        return

    # 就绪 → 进入请求循环
    io.write('READY\n')

    while True:
        line = sys.stdin.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        try:
            resp = _handle(line, spider_cls, take_logs)
        except Exception as e:
            resp = {
                'ok': False,
                'error': {
                    'code': 'E_RUNTIME',
                    'message': '%s: %s' % (type(e).__name__, e),
                },
                'logs': take_logs(),
            }
        try:
            io.write(json.dumps(resp, ensure_ascii=False, default=str) + '\n')
        except Exception:
            io.write(json.dumps({
                'ok': False,
                'error': {'code': 'E_RUNTIME', 'message': '响应序列化失败'},
            }) + '\n')


def _handle(line, spider_cls, take_logs):
    """处理单个 ABI 请求（对齐 iOS `callSpider:injectDict:function:args:`）。"""
    req = json.loads(line)
    op = str(req.get('op', ''))
    params = req.get('params') or {}
    if not isinstance(params, dict):
        params = {}

    fn = _FN_MAP.get(op)
    if fn is None:
        return {
            'ok': False,
            'error': {'code': 'E_UNSUPPORTED', 'message': '未知 op: %s' % op},
            'logs': take_logs(),
        }

    # Phase 2: 实例化（对齐 iOS：每次调用新建 Spider 实例）
    spider = spider_cls()

    # init("")（可选；对齐 iOS：未定义 init 跳过、init 异常 PyErr_Clear 继续）
    init_m = getattr(spider, 'init', None)
    if callable(init_m):
        try:
            init_m(*_adapt(init_m, ('',)))
        except Exception:
            pass

    # Phase 4: 调用目标方法（方法缺失 → E_RUNTIME）
    method = getattr(spider, fn, None)
    if not callable(method):
        return {
            'ok': False,
            'error': {
                'code': 'E_RUNTIME',
                'message': 'Spider.%s 不存在或不可调用' % fn,
            },
            'logs': take_logs(),
        }

    ret = method(*_build_args(op, params, method))
    return {'ok': True, 'data': _to_json_object(ret), 'logs': take_logs()}


def _adapt(method, args):
    """按 method 真实签名裁剪位置参数（对齐 iOS `adaptArgs`）。"""
    try:
        import inspect
        sig = inspect.signature(method)
        positional = 0
        has_var = False
        for p in sig.parameters.values():
            if p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD):
                positional += 1
            elif p.kind == p.VAR_POSITIONAL:
                has_var = True
        if has_var or positional >= len(args):
            return args
        return args[:positional]
    except Exception:
        return args


def _build_args(op, params, method):
    """按 TVBox 标准签名构造参数（对齐 iOS `buildArgsForFunction`）。"""
    if op == 'homeContent':
        f = params.get('filter')
        args = (f if isinstance(f, dict) else {},)
    elif op == 'homeVideoContent':
        args = ()
    elif op == 'categoryContent':
        ext_raw = params.get('extend')
        if isinstance(ext_raw, dict):
            ext = ext_raw
        else:
            try:
                ext = json.loads(ext_raw) if ext_raw else {}
            except Exception:
                ext = {}
        if not isinstance(ext, dict):
            ext = {}
        args = (str(params.get('tid', '')), str(params.get('pg', '1')), {}, ext)
    elif op == 'detailContent':
        args = ([str(params.get('ids', ''))],)
    elif op in ('searchContent', 'searchContentPage'):
        key = params.get('key') or params.get('keyword') or ''
        args = (str(key), 'false', str(params.get('pg', '1')))
    elif op == 'playerContent':
        pid = params.get('url') or params.get('id') or params.get('vodId') or ''
        args = (str(params.get('flag', '')), str(pid), {})
    else:
        args = (json.dumps(params, ensure_ascii=False),)
    return _adapt(method, args)


def _to_json_object(ret):
    """返回值 → JSON 对象（对齐 iOS：json.dumps 交上层解码 + 软解码容错）。"""
    if isinstance(ret, dict):
        return ret
    if isinstance(ret, str):
        try:
            decoded = json.loads(ret)
        except Exception:
            return {}
        return decoded if isinstance(decoded, dict) else {'list': decoded}
    if isinstance(ret, (list, tuple)):
        return {'list': list(ret)}
    if ret is None:
        return {}
    return ret


class _StdioIO:
    """宿主 stdio 适配器：把真实 stdin/stdout 适配成桥所需的 io 接口。

    必须在 run() 替换 sys.stdin/stdout **之前**构造，故缓存原始流引用，
    避免 run() 内部的 _Stdin/_LogWriter 与适配器相互递归。
    """

    def __init__(self):
        self._in = sys.stdin
        self._out = sys.stdout

    def readLine(self):
        line = self._in.readline()
        if line == '':
            return None
        if line.endswith('\n'):
            line = line[:-1]
        if line.endswith('\r'):
            line = line[:-1]
        return line

    def write(self, text):
        self._out.write(text)
        self._out.flush()


def _main():
    if len(sys.argv) < 2:
        sys.stdout.write('E_BRIDGE_USAGE: 缺少蜘蛛脚本路径参数\n')
        sys.stdout.flush()
        return
    path = sys.argv[1]
    try:
        with open(path, 'r', encoding='utf-8') as f:
            script = f.read()
    except Exception as e:
        sys.stdout.write('E_SCRIPT_READ: %s: %s\n' % (type(e).__name__, e))
        sys.stdout.flush()
        return
    run(script, _StdioIO())


if __name__ == '__main__':
    _main()
''';
