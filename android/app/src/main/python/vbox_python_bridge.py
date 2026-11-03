"""Chaquopy 侧 Python 桥 v2 —— 对齐 iOS `PythonBridge.m` 的对象调用模型。

历史（Wave G · RT-运1）：v1 按 stdio ABI 复刻——要求蜘蛛脚本自身实现
`print('READY')` + 逐行读请求/写响应的循环。而真实 TVBox py 源（真不错4K /
瓜子APP 等 8 个）是标准 `Spider` 类定义脚本，没有 ABI 循环 → 宿主 launch 永远
等不到 READY → 分类数据「暂无数据」。iOS 端正常，因为它走
`vbox/Libraries/PythonBridge.m` 的 callSpider 对象调用，与 stdio 无关。

v2 模型（与 iOS 逐阶段对齐）：
  1. exec 蜘蛛脚本 → globals（含 Spider 类定义；对齐 iOS `PyRun_File`）；
  2. 校验 `Spider` 类存在（缺失 → 输出 `E_NO_SPIDER` 错误行，宿主 launch
     以「首个输出非 READY」失败，错误信息直接可见）；
  3. 输出 `READY`，进入请求循环（ABI 形态对 Dart 层不变）；
  4. 每个请求（`{op, params}` JSON 行）：实例化 Spider → 调 `init("")`
     （可选，失败不阻断）→ 按 TVBox 标准签名构造参数调用目标方法 →
     json 序列化 → `{ok, data, logs}` ABI 响应行。

与 iOS 的等价性说明：
  - iOS 缓存 PyRun_File globals（NSCache + mtime）；此处每次 launch 重新
    exec（一个引擎只跑一个脚本，切源会重新 launch），语义等价；
  - iOS `adaptArgs` 经 C API 读签名裁剪参数；此处用 `inspect.signature`
    达成同一裁剪语义；
  - iOS 把 `json.dumps(返回值)` 交给上层解码；此处同样序列化，且对脚本直接
    返回 JSON 字符串的情况做二次解码（对齐 Dart `AbiResponse` 软解码语义）；
  - 脚本 print()/stderr 输出进 `logs`（iOS 走 NSLog），不污染协议通道。
"""

import json

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

    :param script: 蜘蛛脚本源码（TVBox `Spider` 类定义，如 `js/zhenbucuo4k.py`）
    :param io: Kotlin `PythonPlugin.StdioBridge`（`readLine()` / `write(s)`）
    """
    import sys

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
        """`sys.stdout` / `sys.stderr` 替身：脚本输出进日志缓冲，不进协议。

        v1 把脚本 stdout 直通协议（脚本自实现 ABI 循环时这是协议本体）；
        v2 的循环由本模块承担，脚本 `print()` 若直通协议会把 ABI 响应打乱，
        故统一捕获，随下一次响应的 `logs` 字段回传（对齐 iOS NSLog 语义）。
        """

        def __init__(self):
            self.buffer = []

        def write(self, text):
            if text:
                self.buffer.append(str(text))
                # 环形上限：超长脚本的刷屏日志只保留最近 64 段
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
    # __name__ 必须非 '__main__'：部分脚本（真不错4K 等）尾部有
    # `if __name__ == "__main__": self_test()` 自测代码，加载时执行会阻塞
    # launch。iOS 的 CPython 3.14 在 globals 无 __name__ 时自动填 'builtins'
    # （守卫判 False）；此处显式等价设置，不依赖解释器版本行为。
    namespace = {'__name__': 'vbox_spider', '__file__': '<vbox_spider>'}
    try:
        exec(compile(script, '<vbox_spider>', 'exec'), namespace)
    except Exception as e:
        # 无 READY 输出 → 宿主 launch 以「首个输出非 READY」失败，信息可见
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
    """按 method 真实签名裁剪位置参数（对齐 iOS `adaptArgs`）。

    只改变参数数量，不改变含义；读不到签名时保持原参数，交给 Python 报错。
    """
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
        # categoryContent(tid, pg, filter, extend) — extend JSON 串 → dict
        # （对齐 iOS 修复记录：extend 始终传空 dict 会导致筛选器不生效）
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
        # detailContent(array) — vod_id 包成单元素列表（对齐 iOS `["\(ids)"]`）
        args = ([str(params.get('ids', ''))],)
    elif op in ('searchContent', 'searchContentPage'):
        # searchContent(key, quick, pg) — key 兼容 Dart 的 keyword 命名
        key = params.get('key') or params.get('keyword') or ''
        args = (str(key), 'false', str(params.get('pg', '1')))
    elif op == 'playerContent':
        # playerContent(flag, id, vipFlags) — id 兼容 Dart 的 url/vodId 命名
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
        # 脚本直接返回 JSON 字符串：解码取对象形态（对齐 Dart 软解码语义）
        try:
            decoded = json.loads(ret)
        except Exception:
            return {}
        return decoded if isinstance(decoded, dict) else {'list': decoded}
    if isinstance(ret, (list, tuple)):
        return {'list': list(ret)}
    if ret is None:
        return {}
    return ret  # 其余类型交给 json.dumps(default=str) 兜底
