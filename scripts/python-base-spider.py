"""base.spider 兼容模块 - vbox CPython Bridge

修复记录:
- 2026-08-10: Response 类增加 status_code / content / headers 属性
  处理 HTTPError (4xx/5xx), 返回带正确 status_code 的 Response
  修复后脚本中 r.status_code / r.content 可正常使用
- 2026-08-11: fetch 方法增加 SSL 上下文 (ssl._create_unverified_context)
  解决 iOS CPython 无系统 CA 证书导致所有 HTTPS 请求失败的问题
  此修复为统一修复，所有继承 base.spider.Spider 的脚本自动生效
  无需在各脚本中单独覆写 fetch
- 2026-08-12: 增加 Response.json / ok、Spider.post、fetch(params=...)、
  getCache / setCache，兼容更多 Python 蜘蛛脚本的 requests 风格调用
"""
import json
import ssl
import urllib.parse
import urllib.request
import urllib.error

# iOS CPython 没有 CA 证书包 → HTTPS 验证失败
# 创建不验证证书的 SSL 上下文，所有请求共用
_ssl_ctx = ssl._create_unverified_context()
_cache = {}


class Response:
    """HTTP 响应对象 — 兼容 requests 库的常用属性

    属性:
    status_code: HTTP 状态码 (int)
    text: 响应文本 (str)
    content: 响应原始字节 (bytes)
    encoding: 字符编码 (str)
    headers: 响应头 (urllib.request.HTTPMessage)
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
        return json.loads(self.text or '{}')


class Spider:
    def __init__(self):
        self.name = "BaseSpider"

    def _request(self, url, headers=None, data=None, method=None, **kw):
        headers = dict(headers or {})
        params = kw.get('params')
        if params:
            sep = '&' if '?' in url else '?'
            url += sep + urllib.parse.urlencode(params)

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
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            r = urllib.request.urlopen(req, timeout=timeout, context=_ssl_ctx)
            data_bytes = r.read()
            resp_headers = r.headers if hasattr(r, 'headers') else None
            encoding = 'utf-8'
            if resp_headers and hasattr(resp_headers, 'get_content_charset'):
                ct_encoding = resp_headers.get_content_charset()
                if ct_encoding:
                    encoding = ct_encoding
            return Response(data_bytes, status_code=r.status, encoding=encoding, headers=resp_headers)
        except urllib.error.HTTPError as e:
            data_bytes = b''
            try:
                data_bytes = e.read()
            except Exception:
                pass
            resp_headers = e.headers if hasattr(e, 'headers') else None
            encoding = 'utf-8'
            if resp_headers and hasattr(resp_headers, 'get_content_charset'):
                ct_encoding = resp_headers.get_content_charset()
                if ct_encoding:
                    encoding = ct_encoding
            return Response(data_bytes, status_code=e.code, encoding=encoding, headers=resp_headers)

    def fetch(self, url, headers=None, **kw):
        """发起 HTTP GET 请求

        Args:
        url: 请求 URL
        headers: 请求头 dict
        **kw: 其他参数 (timeout 等)

        Returns:
        Response 对象, 始终包含 status_code / text / content / headers 属性
        即使 HTTP 4xx/5xx 也返回 Response（不抛异常），与 requests 库行为一致

        注意: 使用 ssl._create_unverified_context() 跳过证书验证
        iOS CPython 无系统 CA 证书，不跳过会导致所有 HTTPS 请求失败
        """
        return self._request(url, headers=headers, method='GET', **kw)

    def post(self, url, headers=None, data=None, **kw):
        return self._request(url, headers=headers, data=data, method='POST', **kw)

    def getCache(self, key):
        return _cache.get(key)

    def setCache(self, key, value):
        _cache[key] = value
        return True

    def getName(self):
        return getattr(self, 'name', 'BaseSpider')
