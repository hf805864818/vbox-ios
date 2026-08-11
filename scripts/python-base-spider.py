"""base.spider 兼容模块 - vbox CPython Bridge

修复记录:
- 2026-08-10: Response 类增加 status_code / content / headers 属性
 处理 HTTPError (4xx/5xx), 返回带正确 status_code 的 Response
 修复后脚本中 r.status_code / r.content 可正常使用
"""
import urllib.request
import urllib.error


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
        try:
            self.text = content_bytes.decode(encoding, errors='replace')
        except Exception:
            self.text = ''


class Spider:
    def __init__(self):
        self.name = "BaseSpider"

    def fetch(self, url, headers=None, **kw):
        """发起 HTTP GET 请求

        Args:
        url: 请求 URL
        headers: 请求头 dict
        **kw: 其他参数 (timeout 等)

        Returns:
        Response 对象, 始终包含 status_code / text / content / headers 属性
        即使 HTTP 4xx/5xx 也返回 Response（不抛异常），与 requests 库行为一致
        """
        timeout = kw.get('timeout', 15)
        req = urllib.request.Request(url, headers=headers or {})
        try:
            r = urllib.request.urlopen(req, timeout=timeout)
            data = r.read()
            # 获取响应头
            resp_headers = r.headers if hasattr(r, 'headers') else None
            # 尝试从 Content-Type 获取编码
            encoding = 'utf-8'
            if resp_headers and hasattr(resp_headers, 'get_content_charset'):
                ct_encoding = resp_headers.get_content_charset()
                if ct_encoding:
                    encoding = ct_encoding
            return Response(data, status_code=r.status, encoding=encoding, headers=resp_headers)
        except urllib.error.HTTPError as e:
            # HTTP 错误 (4xx/5xx) — 仍然返回 Response 对象, 与 requests 行为一致
            data = b''
            try:
                data = e.read()
            except Exception:
                pass
            resp_headers = e.headers if hasattr(e, 'headers') else None
            encoding = 'utf-8'
            if resp_headers and hasattr(resp_headers, 'get_content_charset'):
                ct_encoding = resp_headers.get_content_charset()
                if ct_encoding:
                    encoding = ct_encoding
            return Response(data, status_code=e.code, encoding=encoding, headers=resp_headers)
        except Exception:
            # 其他异常 (网络错误等) — 重新抛出, 由调用方处理
            raise

    def getName(self):
        return getattr(self, 'name', 'BaseSpider')
