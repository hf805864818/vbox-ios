"""base.spider 兼容模块 - vbox CPython Bridge

通用兼容层 + 受控代理桥接，为 iOS CPython 环境提供完整的 Spider 基类。

修复记录:
- 2026-08-10: Response 类增加 status_code / content / headers 属性
  处理 HTTPError (4xx/5xx), 返回带正确 status_code 的 Response
- 2026-08-11: fetch 方法增加 SSL 上下文 (ssl._create_unverified_context)
  解决 iOS CPython 无系统 CA 证书导致所有 HTTPS 请求失败的问题
- 2026-08-12: 增加 Response.json / ok、Spider.post、fetch(params=...)、
  getCache / setCache，兼容更多 Python 蜘蛛脚本的 requests 风格调用
- 2026-08-12 (v2): 通用兼容层补齐 — delCache / config / retry / cookies /
  verify / stream / cleanText / removeHtmlTags / regStr / getCookie /
  getProxyUrl / localProxy 受控代理桥接
  不含 lxml 和 subprocess (iOS 安全限制)
- 2026-08-13 (v3): 福利专区自适应 — _vbox_effective_hosts 域名注入、
  _vbox_proxy_enabled / _vbox_proxy_url 代理注入
  福利 Python 平台自动享用自定义域名和代理设置，脚本无需修改
- 2026-08-13 (v4): requests 模块自动拦截 — 通过 __init_subclass__ + threading.local
  自动包装子类接口方法，patch requests.get/post/Session.get/Session.post
  脚本用 requests 发请求也能自动走域名替换和代理注入
  普通资源（非福利）不受影响：无注入属性 → _apply() 直接返回原始 URL
- 2026-08-13 (v5): threading/functools 降级兼容 — iOS CPython 可能缺少这两个模块
  导致 import base.spider 失败 → 脚本回退到 fallback 类 → 域名注入失效
  改为 try/except 导入，缺失时用简易替代实现
"""
import json
import re
import ssl
import urllib.parse
import urllib.request
import urllib.error
import http.cookiejar

# ──────────────────────────────────────────────
# 降级兼容：iOS CPython 可能缺少 threading / functools
# 缺失时用简易替代，确保 base.spider 能正常导入
# ──────────────────────────────────────────────
try:
    import threading as _threading_mod
    _active_spider = _threading_mod.local()
except ImportError:
    _threading_mod = None
    _active_spider = None

try:
    from functools import wraps as _functools_wraps
except ImportError:
    _functools_wraps = None

# iOS CPython 没有 CA 证书包 → HTTPS 验证失败
# 创建不验证证书的 SSL 上下文，所有请求共用
_ssl_ctx = ssl._create_unverified_context()
_cache = {}

# 默认请求头
_DEFAULT_HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
}

# 受控代理本地端口 (与 vbox 原生 proxy 一致)
_PROXY_PORT = 9978

# ──────────────────────────────────────────────
# requests 模块自动拦截基础设施
# ──────────────────────────────────────────────
# 线程本地存储：当前正在执行的 Spider 实例
# 每个线程独立，100+ 平台并发不会串
# iOS CPython 无 threading 时降级为全局变量（单线程安全）


def _get_active_spider():
    """获取当前线程的活跃 Spider 实例（接口方法执行期间非 None）"""
    if _active_spider is not None:
        return getattr(_active_spider, 'spider', None)
    return getattr(_active_spider_fallback, 'spider', None)


def _set_active_spider(spider):
    """设置当前活跃 Spider 实例"""
    if _active_spider is not None:
        _active_spider.spider = spider
    else:
        _active_spider_fallback.spider = spider


class _FallbackLocal:
    """threading.local 降级替代（单线程安全）"""
    def __init__(self):
        self.spider = None


_active_spider_fallback = _FallbackLocal()


def _spider_method_wrap(func):
    """装饰器：在 Spider 接口方法执行前设置活跃 Spider，执行后清除

    确保接口方法（homeContent / categoryContent 等）执行期间，
    _get_active_spider() 返回当前 Spider 实例，
    使得 requests patch 能读取注入的域名和代理配置。

    同时在方法执行前刷新注入域名（仅福利平台有注入属性时），
    确保脚本 init() 覆盖 self.host 后，下一个接口方法能恢复注入域名。
    """
    if _functools_wraps is not None:
        wrapper = _functools_wraps(func)
    else:
        wrapper = lambda f: f  # 无 functools 时直接返回原函数

    @wrapper
    def wrapped(self, *args, **kwargs):
        _set_active_spider(self)
        # 福利平台：每次接口方法调用前刷新注入域名
        # （脚本的 init() 可能覆盖了 self.host，需要恢复）
        if hasattr(self, '_vbox_effective_hosts'):
            self._apply_injected_hosts()
        try:
            return func(self, *args, **kwargs)
        finally:
            _set_active_spider(None)
    return wrapped


def _patch_requests():
    """一次性 patch requests 模块，自动应用域名替换和代理

    当脚本直接使用 requests.get/post 而非 self.fetch/post 时，
    通过 _active_spider 获取当前 Spider 实例的注入配置，
    自动替换 URL 中的原始域名并应用代理。

    安全性：
    - 普通资源（非福利）不注入 _vbox_effective_hosts，
      _apply() 返回原始 URL 和 None proxies，行为不变
    - 有 threading 时用 threading.local（并发安全）
    - 无 threading 时用全局变量（单线程安全，iOS CPython 默认单线程）
    - 仅 patch get/post/Session.get/Session.post，不改变其他行为
    """
    try:
        import requests as _req
    except ImportError:
        return

    if getattr(_req, '_vbox_patched', False):
        return
    _req._vbox_patched = True

    _orig_get = _req.get
    _orig_post = _req.post
    _orig_s_get = _req.Session.get
    _orig_s_post = _req.Session.post

    def _apply(url):
        """返回 (修正后的url, proxies字典)"""
        spider = _get_active_spider()
        if not spider:
            return url, None

        proxies = None
        # 代理注入
        if getattr(spider, '_vbox_proxy_enabled', False):
            proxy_url = getattr(spider, '_vbox_proxy_url', '')
            if proxy_url:
                proxies = {'http': proxy_url, 'https': proxy_url}

        # 域名替换：将脚本原始域名替换为注入的有效域名
        injected = getattr(spider, '_vbox_effective_hosts', None)
        if injected and isinstance(injected, list) and len(injected) > 0:
            target_host = str(injected[0]).rstrip('/')
            original_host = getattr(spider, '_vbox_original_host', '')
            if original_host and original_host in url:
                url = url.replace(original_host, target_host)

        return url, proxies

    def _patched_get(url, **kw):
        url, proxies = _apply(url)
        if proxies:
            kw.setdefault('proxies', proxies)
        return _orig_get(url, **kw)

    def _patched_post(url, **kw):
        url, proxies = _apply(url)
        if proxies:
            kw.setdefault('proxies', proxies)
        return _orig_post(url, **kw)

    def _patched_s_get(self_s, url, **kw):
        url, proxies = _apply(url)
        if proxies:
            kw.setdefault('proxies', proxies)
        return _orig_s_get(self_s, url, **kw)

    def _patched_s_post(self_s, url, **kw):
        url, proxies = _apply(url)
        if proxies:
            kw.setdefault('proxies', proxies)
        return _orig_s_post(self_s, url, **kw)

    _req.get = _patched_get
    _req.post = _patched_post
    _req.Session.get = _patched_s_get
    _req.Session.post = _patched_s_post


class Response:
    """HTTP 响应对象 — 兼容 requests 库的常用属性

    属性:
        status_code: HTTP 状态码 (int)
        text: 响应文本 (str)
        content: 响应原始字节 (bytes)
        encoding: 字符编码 (str)
        headers: 响应头 (urllib.request.HTTPMessage)
        ok: 是否成功 (bool, 2xx/3xx 为 True)
    """

    def __init__(self, content_bytes, status_code=200, encoding='utf-8', headers=None):
        self.content = content_bytes
        self.status_code = status_code
        self.encoding = encoding
        self.headers = headers
        self.ok = 200 <= status_code < 400
        try:
            self.text = content_bytes.decode(encoding, errors='replace')
        except Exception:
            self.text = ''

    def json(self):
        """解析响应为 JSON，失败返回空 dict"""
        try:
            return json.loads(self.text or '{}')
        except Exception:
            return {}

    @property
    def url(self):
        """最终请求 URL（urllib 不直接提供，返回空字符串兜底）"""
        return getattr(self, '_url', '')


class Spider:
    """Spider 基类 — 所有 Python 蜘蛛脚本的父类

    提供以下通用能力:
    - HTTP 请求: fetch (GET) / post (POST)，支持 headers / cookies / params / json / data / timeout / verify / stream
    - 缓存管理: getCache / setCache / delCache
    - 文本处理: cleanText / removeHtmlTags / regStr
    - Cookie 处理: getCookie
    - 受控代理: getProxyUrl / localProxy
    - 默认属性: config / retry / header / name

    自动拦截 (v4):
    - __init_subclass__ 自动包装子类的 TVBox 接口方法
    - 包装后，接口方法执行期间 _get_active_spider() 返回当前实例
    - requests patch 据此自动应用域名替换和代理注入
    - 普通资源无注入属性，包装无副作用
    """

    # TVBox 接口方法名 — 子类覆写时自动包装
    _SPIDER_INTERFACE_METHODS = frozenset({
        'init', 'homeContent', 'homeVideoContent',
        'categoryContent', 'detailContent',
        'searchContent', 'searchContentPage', 'playerContent'
    })

    def __init_subclass__(cls, **kwargs):
        """子类定义时自动包装其接口方法

        当脚本 `class MySpider(Spider):` 定义时触发，
        自动将子类覆写的接口方法用 _spider_method_wrap 包装，
        确保执行期间 _active_spider 指向当前实例。

        同时确保 requests 已被 patch（脚本可能在 import base.spider
        之后再 import requests，此处二次调用 _patch_requests 做兜底）。
        """
        super().__init_subclass__(**kwargs)
        _patch_requests()  # 兜底：确保 requests 已 patch（幂等操作）
        for name in Spider._SPIDER_INTERFACE_METHODS:
            if name in cls.__dict__:
                original = cls.__dict__[name]
                if callable(original) and not hasattr(original, '_vbox_spider_wrapped'):
                    wrapped = _spider_method_wrap(original)
                    wrapped._vbox_spider_wrapped = True
                    setattr(cls, name, wrapped)

    def __init__(self):
        self.name = "BaseSpider"
        self.config = {}          # 默认配置（壳会注入 filter 等键）
        self.retry = 0            # 重试计数器
        self.header = dict(_DEFAULT_HEADERS)
        # iOS 注入的有效域名列表（用户自定义 + defaultHosts），
        # 由 vbox Swift 层通过 globals 注入 _vbox_effective_hosts。
        # 普通资源（非福利）不注入，self.host 由脚本自身 init() 设置。
        self._apply_injected_hosts()

    def _apply_injected_hosts(self):
        """读取 Swift 注入的 _vbox_effective_hosts 并应用为 self.host

        优先级：实例属性（PythonBridge 注入，实例级隔离）> 模块 globals > 脚本自身
        实例属性注入确保 100+ 平台并发时不会串域名。
        普通资源（非福利）不注入，保持原有行为。

        _vbox_original_host：延迟捕获脚本原始域名（init() 设置的 host），
        供 requests patch 做域名替换。只在 host 非空且与目标不同时捕获，
        避免 Phase 3.5（init 之前）误存空值。
        """
        injected = getattr(self, '_vbox_effective_hosts', None) \
                or globals().get('_vbox_effective_hosts')
        if injected and isinstance(injected, list) and len(injected) > 0:
            target_host = str(injected[0]).rstrip('/')
            # 延迟捕获原始域名：只在未捕获/为空、且当前 host 非空且≠目标时捕获
            current_host = getattr(self, 'host', '')
            if not getattr(self, '_vbox_original_host', '') \
                    and current_host and current_host != target_host:
                self._vbox_original_host = current_host
            self.host = target_host
            self._backup_hosts = [str(h).rstrip('/') for h in injected[1:]]

    def _proxy_enabled(self):
        """是否启用代理（优先从实例属性读取，实例级隔离）"""
        return bool(getattr(self, '_vbox_proxy_enabled', None) \
                or globals().get('_vbox_proxy_enabled', False))

    def _proxy_url_template(self):
        """代理 URL 模板（优先从实例属性读取，实例级隔离）

        支持两种格式：
        - https://proxy.com/?url={url}  （含 {url} 占位符，推荐）
        - https://proxy.com/?url=        （无占位符，自动追加）
        """
        return str(getattr(self, '_vbox_proxy_url', None) \
                or globals().get('_vbox_proxy_url', '') or '')

    def _apply_proxy(self, url):
        """对 URL 应用代理转发（如果启用了代理）"""
        if not self._proxy_enabled():
            return url
        tpl = self._proxy_url_template()
        if not tpl:
            return url
        if '{url}' in tpl:
            return tpl.replace('{url}', urllib.parse.quote(url, safe=''))
        # 兜底：按 ?url= 或 &url= 追加
        sep = '&' if '?' in tpl else '?'
        return f"{tpl}{sep}url={urllib.parse.quote(url, safe='')}"

    # ──────────────────────────────────────────────
    # HTTP 请求
    # ──────────────────────────────────────────────

    def _request(self, url, headers=None, data=None, method=None, **kw):
        """内部统一请求方法

        每次请求前都会检查注入的 _vbox_effective_hosts 并更新 self.host，
        确保用户在设置里修改域名后能立即生效。

        备用域名回退：当主域名请求失败（连接错误/超时）且存在 _backup_hosts 时，
        自动切换到备用域名重试，直到成功或全部失败。

        兼容参数:
            headers: 请求头 dict
            data: POST 数据 (str/bytes/dict)
            json: JSON body (dict → 自动序列化 + Content-Type)
            params: URL 查询参数 (dict)
            cookies: Cookie (str/dict/CookieJar)
            timeout: 超时秒数 (默认 15)
            verify: SSL 验证 (忽略，始终跳过 — iOS 无 CA 证书)
            stream: 流式响应 (忽略，返回完整 Response)
            allow_redirects: 跟随重定向 (默认 True)
        """
        # 每次请求前刷新注入的域名（用户可能在设置里改了）
        self._apply_injected_hosts()

        # 收集所有待尝试的域名：主域名 + 备用域名
        hosts_to_try = []
        try:
            parsed = urllib.parse.urlparse(url)
            original_host = f"{parsed.scheme}://{parsed.netloc}"
            hosts_to_try.append(original_host)
            backup_hosts = getattr(self, '_backup_hosts', None) or []
            for bh in backup_hosts:
                if bh and bh != original_host:
                    hosts_to_try.append(bh)
        except Exception:
            hosts_to_try = [url]

        last_resp = None
        for i, host in enumerate(hosts_to_try):
            # 替换 URL 中的 host 部分
            try:
                parsed = urllib.parse.urlparse(url)
                target_url = urllib.parse.urlunparse((
                    parsed.scheme,
                    urllib.parse.urlparse(host).netloc if '://' in host else host,
                    parsed.path,
                    parsed.params,
                    parsed.query,
                    parsed.fragment
                ))
            except Exception:
                target_url = url

            resp = self._do_request(target_url, headers, data, method, **kw)
            # HTTP 错误（4xx/5xx）不重试 —— 服务器可达只是业务错误
            # 只有连接失败（status_code == 599）才切换备用域名
            if resp.status_code != 599:
                return resp
            last_resp = resp

        return last_resp or Response(b'', status_code=599, encoding='utf-8', headers=None)

    def _do_request(self, url, headers=None, data=None, method=None, **kw):
        """单次请求实现（不含备用域名回退）"""
        headers = dict(headers or self.header)

        # 处理 URL 查询参数
        params = kw.get('params')
        if params:
            sep = '&' if '?' in url else '?'
            url += sep + urllib.parse.urlencode(params)

        # 处理 Cookie
        cookies = kw.get('cookies')
        if cookies:
            cookie_str = self._cookies_to_string(cookies)
            if cookie_str:
                existing = headers.get('Cookie', '')
                if existing:
                    headers['Cookie'] = existing + '; ' + cookie_str
                else:
                    headers['Cookie'] = cookie_str

        # 处理请求体
        body = None
        if 'json' in kw and kw.get('json') is not None:
            body = json.dumps(kw.get('json'), ensure_ascii=False).encode('utf-8')
            headers.setdefault('Content-Type', 'application/json')
        elif data is not None:
            if isinstance(data, bytes):
                body = data
            elif isinstance(data, str):
                body = data.encode('utf-8')
            else:
                body = urllib.parse.urlencode(data).encode('utf-8')
                headers.setdefault('Content-Type', 'application/x-www-form-urlencoded')

        timeout = kw.get('timeout', 15)
        allow_redirects = kw.get('allow_redirects', True)

        # 构建请求
        req = urllib.request.Request(url, data=body, headers=headers, method=method)

        # 处理重定向
        if not allow_redirects:
            req.redirect_handler = False

        try:
            # 始终使用不验证证书的 SSL 上下文 (iOS 无 CA 证书)
            if not allow_redirects:
                # 自定义 opener 禁止重定向
                class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
                    def redirect_request(self, req, fp, code, msg, headers, newurl):
                        return None
                opener = urllib.request.build_opener(NoRedirectHandler, urllib.request.HTTPSHandler(context=_ssl_ctx))
                r = opener.open(req, timeout=timeout)
            else:
                r = urllib.request.urlopen(req, timeout=timeout, context=_ssl_ctx)

            data_bytes = r.read()
            resp_headers = r.headers if hasattr(r, 'headers') else None
            encoding = self._detect_encoding(resp_headers, data_bytes)
            resp = Response(data_bytes, status_code=r.status, encoding=encoding, headers=resp_headers)
            resp._url = r.url if hasattr(r, 'url') else url
            return resp

        except urllib.error.HTTPError as e:
            data_bytes = b''
            try:
                data_bytes = e.read()
            except Exception:
                pass
            resp_headers = e.headers if hasattr(e, 'headers') else None
            encoding = self._detect_encoding(resp_headers, data_bytes)
            resp = Response(data_bytes, status_code=e.code, encoding=encoding, headers=resp_headers)
            resp._url = url
            return resp

        except urllib.error.URLError as e:
            # 网络错误返回 599 (自定义码，表示请求失败)
            resp = Response(b'', status_code=599, encoding='utf-8', headers=None)
            resp._url = url
            return resp

        except Exception:
            # 其他异常返回 599
            resp = Response(b'', status_code=599, encoding='utf-8', headers=None)
            resp._url = url
            return resp

    def fetch(self, url, headers=None, **kw):
        """发起 HTTP GET 请求

        兼容 requests 风格参数:
            fetch(url, headers=..., cookies=..., params=..., timeout=..., verify=..., stream=...)

        返回 Response 对象，即使 HTTP 4xx/5xx 也返回 Response（不抛异常）

        代理：如果 _vbox_proxy_enabled 为 True，自动走代理 URL 转发。
        """
        final_url = self._apply_proxy(url)
        return self._request(final_url, headers=headers, method='GET', **kw)

    def post(self, url, headers=None, data=None, **kw):
        """发起 HTTP POST 请求

        兼容 requests 风格参数:
            post(url, data=..., json=..., headers=..., cookies=..., timeout=..., verify=...)

        代理：如果 _vbox_proxy_enabled 为 True，自动走代理 URL 转发。
        """
        final_url = self._apply_proxy(url)
        return self._request(final_url, headers=headers, data=data, method='POST', **kw)

    # ──────────────────────────────────────────────
    # 缓存管理
    # ──────────────────────────────────────────────

    def getCache(self, key):
        """获取缓存值，不存在返回 None"""
        return _cache.get(key)

    def setCache(self, key, value):
        """设置缓存值"""
        _cache[key] = value
        return True

    def delCache(self, key):
        """删除缓存值，不存在时静默返回"""
        if key in _cache:
            del _cache[key]
        return True

    # ──────────────────────────────────────────────
    # 文本处理工具
    # ──────────────────────────────────────────────

    def cleanText(self, text):
        """清理文本：去除 BOM、多余空白、控制字符"""
        if not text:
            return ''
        if isinstance(text, bytes):
            text = text.decode('utf-8', errors='replace')
        # 去除 BOM
        text = text.replace('\ufeff', '')
        # 去除零宽字符
        text = text.replace('\u200b', '').replace('\u200c', '').replace('\u200d', '')
        # 去除多余空白
        text = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '', text)
        return text.strip()

    def removeHtmlTags(self, text):
        """移除 HTML 标签，保留纯文本"""
        if not text:
            return ''
        text = str(text)
        # 替换常见 HTML 实体
        entities = {
            '&nbsp;': ' ', '&amp;': '&', '&lt;': '<', '&gt;': '>',
            '&quot;': '"', '&#39;': "'", '&apos;': "'",
        }
        for entity, char in entities.items():
            text = text.replace(entity, char)
        # 处理数字实体
        text = re.sub(r'&#(\d+);', lambda m: chr(int(m.group(1))), text)
        text = re.sub(r'&#x([0-9a-fA-F]+);', lambda m: chr(int(m.group(1), 16)), text)
        # 移除 HTML 标签
        text = re.sub(r'<[^>]+>', '', text)
        return text.strip()

    def regStr(self, reg=None, src=None, group=1):
        """正则匹配并返回指定分组

        Args:
            reg: 正则表达式字符串
            src: 源文本
            group: 返回的分组序号 (默认 1)

        Returns:
            匹配的分组内容 (str) 或 None
        """
        if not reg or not src:
            return None
        try:
            m = re.search(reg, src)
            if m:
                return m.group(group) if group <= len(m.groups()) + 1 else m.group(0)
        except Exception:
            pass
        return None

    # ──────────────────────────────────────────────
    # Cookie 处理
    # ──────────────────────────────────────────────

    def getCookie(self, cookie):
        """解析 Cookie 为 dict

        兼容多种输入:
            - JSON 字符串: '{"key":"value"}'
            - Cookie 字符串: 'key1=val1; key2=val2'
            - dict: 原样返回
            - 空字符串: 返回空 dict

        Returns:
            (dict, str, str) — (cookies_dict, cookie_str, user_agent)
        """
        cookies_dict = {}
        if not cookie:
            return cookies_dict, '', ''

        # 如果是 dict，直接用
        if isinstance(cookie, dict):
            return cookie, '; '.join(f'{k}={v}' for k, v in cookie.items()), ''

        cookie = str(cookie).strip()

        # 尝试 JSON 解析
        if cookie.startswith('{'):
            try:
                cookies_dict = json.loads(cookie)
                cookie_str = '; '.join(f'{k}={v}' for k, v in cookies_dict.items())
                return cookies_dict, cookie_str, ''
            except Exception:
                pass

        # 解析 Cookie 字符串: 'key1=val1; key2=val2'
        for item in cookie.split(';'):
            item = item.strip()
            if '=' in item:
                k, v = item.split('=', 1)
                cookies_dict[k.strip()] = v.strip()

        cookie_str = '; '.join(f'{k}={v}' for k, v in cookies_dict.items())
        return cookies_dict, cookie_str, ''

    # ──────────────────────────────────────────────
    # 受控代理桥接
    # ──────────────────────────────────────────────

    def getProxyUrl(self):
        """获取本地受控代理 URL

        脚本通过此 URL 将请求路由到 vbox 原生代理，
        vbox 会拦截 127.0.0.1:9978/proxy?do=py 请求并调用 localProxy()

        Returns:
            str: 代理基础 URL
        """
        return f'http://127.0.0.1:{_PROXY_PORT}/proxy?do=py'

    def localProxy(self, params):
        """本地代理处理 — 默认返回 None (不处理)

        子类可覆写此方法实现自定义代理逻辑:
            def localProxy(self, params):
                if params['type'] == 'mpd':
                    return [200, 'application/dash+xml', content]
                return None

        Args:
            params: 代理参数 dict

        Returns:
            [status_code, content_type, body] 或 None
        """
        return None

    # ──────────────────────────────────────────────
    # 工具方法
    # ──────────────────────────────────────────────

    def getName(self):
        """获取蜘蛛名称"""
        return getattr(self, 'name', 'BaseSpider')

    def _cookies_to_string(self, cookies):
        """将各种格式的 Cookie 转为字符串"""
        if not cookies:
            return ''
        if isinstance(cookies, str):
            return cookies
        if isinstance(cookies, dict):
            return '; '.join(f'{k}={v}' for k, v in cookies.items())
        if isinstance(cookies, http.cookiejar.CookieJar):
            parts = []
            for c in cookies:
                parts.append(f'{c.name}={c.value}')
            return '; '.join(parts)
        return str(cookies)

    def _detect_encoding(self, headers, content_bytes):
        """从响应头或内容检测编码"""
        encoding = 'utf-8'
        if headers and hasattr(headers, 'get_content_charset'):
            ct_encoding = headers.get_content_charset()
            if ct_encoding:
                encoding = ct_encoding
        # 尝试从内容检测
        if content_bytes:
            try:
                content_bytes.decode('utf-8')
            except Exception:
                try:
                    content_bytes.decode('gbk')
                    encoding = 'gbk'
                except Exception:
                    pass
        return encoding

    # ──────────────────────────────────────────────
    # 默认空实现 (子类按需覆写)
    # ──────────────────────────────────────────────

    def init(self, extend=''):
        """初始化 — 子类可覆写

        Args:
            extend: 扩展配置 (JSON 字符串)
        """
        pass

    def destroy(self):
        """销毁 — 子类可覆写"""
        pass

    def isVideoFormat(self, url):
        """判断 URL 是否为视频格式 — 子类可覆写"""
        return False

    def manualVideoCheck(self):
        """是否需要手动视频检测 — 子类可覆写"""
        return False

    def homeContent(self, filter):
        """首页内容 — 子类必须实现"""
        return {}

    def homeVideoContent(self):
        """首页推荐视频 — 子类可覆写"""
        return {'list': []}

    def categoryContent(self, cid, page, filter, ext):
        """分类内容 — 子类必须实现"""
        return {'list': []}

    def detailContent(self, did):
        """详情内容 — 子类必须实现"""
        return {'list': []}

    def searchContent(self, key, quick):
        """搜索内容 — 子类必须实现"""
        return {'list': []}

    def searchContentPage(self, key, quick, page):
        """分页搜索 — 子类可覆写"""
        return self.searchContent(key, quick)

    def playerContent(self, flag, pid, vipFlags):
        """播放内容 — 子类必须实现"""
        return {'url': '', 'parse': 0, 'header': {}}


# ──────────────────────────────────────────────
# 模块加载时执行：patch requests 模块
# ──────────────────────────────────────────────
# 确保脚本用 requests.get/post 也能自动走域名替换和代理注入
# 普通资源无注入属性，patch 无副作用
_patch_requests()
