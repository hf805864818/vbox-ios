"""base.spider 兼容模块 - vbox CPython Bridge"""
import urllib.request

class Spider:
    def __init__(self):
        self.name = "BaseSpider"

    def fetch(self, url, headers=None, **kw):
        req = urllib.request.Request(url, headers=headers or {})
        r = urllib.request.urlopen(req, timeout=15)
        class Response:
            def __init__(self, text, encoding='utf-8'):
                self.text = text
                self.encoding = encoding
        return Response(r.read().decode('utf-8', errors='replace'))

    def getName(self):
        return getattr(self, 'name', 'BaseSpider')
