#!/usr/bin/env python3
"""标准 TVBox `Spider` 类脚本（一致性测试样本 · 桌面桥接模型）。

与 `python_echo_spider.py` 的区别（这正是 G2 的决定性差异）：
  - `python_echo_spider.py` 是**原始 stdio ABI 循环**脚本（顶层 `print('READY')`
    + `while True` 读请求），仅适配「脚本自身即 ABI 宿主」的旧模型；
  - 本文件是**真实 TVBox py 源**的形态：只定义 `Spider` 类、无 ABI 循环，
    由桥接层（`python_bridge_script.dart` / Android `vbox_python_bridge.py`）
    `exec` 后以**对象调用**驱动（对齐 iOS `PythonBridge.m`）。

产出数据与 `spider_io_v1.json` / `python_echo_spider.py` 对齐，供
`test/platform/spider/python_bridge_engine_test.dart` 校验桥接全链路。
"""
import json


class Spider:
    """最小 TVBox 蜘蛛：各方法返回固定样本数据。"""

    def init(self, extend=""):
        self.extend = extend

    def homeContent(self, filter):
        return {
            "class": [
                {"type_id": "1", "type_name": "电影"},
                {"type_id": "2", "type_name": "电视剧"},
                {"type_id": "3", "type_name": "综艺"},
            ],
            "list": [
                {
                    "vod_id": "1001",
                    "vod_name": "示例影片",
                    "vod_pic": "https://cdn.example.com/1001.jpg",
                    "vod_remarks": "更新至12集",
                    "vod_year": "2024",
                    "vod_area": "中国",
                    "vod_play_from": "线路1",
                    "vod_play_url": (
                        "第1集$https://cdn.example.com/ep1.m3u8"
                        "#第2集$https://cdn.example.com/ep2.m3u8"
                    ),
                }
            ],
        }

    def searchContent(self, key, quick, pg="1"):
        return {
            "page": 1,
            "pagecount": 5,
            "list": [
                {
                    "vod_id": "2001",
                    "vod_name": f"{key}影片",
                    "vod_pic": "https://cdn.example.com/2001.jpg",
                }
            ],
        }

    def categoryContent(self, tid, pg, filter, extend):
        return {
            "page": int(pg) if str(pg).isdigit() else 1,
            "pagecount": 10,
            "limit": 20,
            "total": 200,
            "list": [],
        }

    def detailContent(self, ids):
        return {
            "list": [
                {
                    "vod_id": "1001",
                    "vod_name": "示例影片",
                    "vod_pic": "https://cdn.example.com/1001.jpg",
                    "vod_content": "剧情简介...",
                    "vod_play_from": "线路1$$$线路2",
                    "vod_play_url": "第1集$url1#第2集$url2$$$第1集$url3",
                }
            ]
        }

    def playerContent(self, flag, id, vipFlags):
        return {"parse": 0, "url": id, "urls": [id] if id else []}


if __name__ == "__main__":
    # 自测入口：真实源常见写法；桥接层以 __name__='vbox_spider' exec，不触发此块。
    print(json.dumps(Spider().homeContent({}), ensure_ascii=False))
