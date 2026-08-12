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
"""
import json
import re
import ssl
import urllib.parse
import urllib.request
import urllib.error
import http.cookiejar

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
    """

    def __init__(self):
        self.name = "BaseSpider"
        self.config = {}          # 默认配置（壳会注入 filter 等键）
        self.retry = 0            # 重试计数器
        self.header = dict(_DEFAULT_HEADERS)

    # ──────────────────────────────────────────────
    # HTTP 请求
    # ──────────────────────────────────────────────

    def _request(self, url, headers=None, data=None, method=None, **kw):
        """内部统一请求方法

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
        """
        return self._request(url, headers=headers, method='GET', **kw)

    def post(self, url, headers=None, data=None, **kw):
        """发起 HTTP POST 请求

        兼容 requests 风格参数:
            post(url, data=..., json=..., headers=..., cookies=..., timeout=..., verify=...)
        """
        return self._request(url, headers=headers, data=data, method='POST', **kw)

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
