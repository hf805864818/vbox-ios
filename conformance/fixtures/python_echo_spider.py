#!/usr/bin/env python3
"""Python 桥 ABI 循环脚本（一致性测试样本，对齐 contract/docs/abi_v1.md §7）。

读 stdin JSON 请求行 → 执行模拟蜘蛛 → 写 stdout JSON 响应行。
产出与 conformance/fixtures/spider_io_v1.json 对齐（homeContent / searchContent /
playerContent 返回固定样本数据）。
"""
import json
import sys

# 就绪信号（PythonBridgeEngine 等待该行）
print('READY', flush=True)

while True:
    line = sys.stdin.readline()
    if not line:
        break
    try:
        req = json.loads(line)
        op = req.get('op')
        if op == 'homeContent':
            data = {
                'class': [
                    {'type_id': '1', 'type_name': '电影'},
                    {'type_id': '2', 'type_name': '电视剧'},
                    {'type_id': '3', 'type_name': '综艺'},
                ],
                'list': [
                    {
                        'vod_id': '1001',
                        'vod_name': '示例影片',
                        'vod_pic': 'https://cdn.example.com/1001.jpg',
                        'vod_remarks': '更新至12集',
                        'vod_year': '2024',
                        'vod_area': '中国',
                        'vod_play_from': '线路1',
                        'vod_play_url': (
                            '第1集$https://cdn.example.com/ep1.m3u8'
                            '#第2集$https://cdn.example.com/ep2.m3u8'
                        ),
                    }
                ],
            }
        elif op == 'searchContent':
            keyword = (req.get('params') or {}).get('keyword', '')
            data = {
                'page': 1,
                'pagecount': 5,
                'list': [
                    {
                        'vod_id': '2001',
                        'vod_name': '测试影片',
                        'vod_pic': 'https://cdn.example.com/2001.jpg',
                    }
                ],
            }
            data['list'][0]['vod_name'] = f'{keyword}影片'
        elif op == 'categoryContent':
            data = {'page': 1, 'pagecount': 10, 'limit': 20, 'total': 200, 'list': []}
        elif op == 'detailContent':
            data = {
                'list': [
                    {
                        'vod_id': '1001',
                        'vod_name': '示例影片',
                        'vod_pic': 'https://cdn.example.com/1001.jpg',
                        'vod_content': '剧情简介...',
                        'vod_play_from': '线路1$$$线路2',
                        'vod_play_url': '第1集$url1#第2集$url2$$$第1集$url3',
                    }
                ]
            }
        elif op == 'playerContent':
            url = (req.get('params') or {}).get('url', '')
            data = {'parse': 0, 'url': url, 'urls': [url] if url else []}
        else:
            data = {'list': []}
        resp = {'ok': True, 'data': data, 'logs': [], 'elapsedMs': 1}
    except Exception as exc:  # noqa: BLE001
        resp = {
            'ok': False,
            'error': {'code': 'E_RUNTIME', 'message': str(exc)},
            'logs': [],
            'elapsedMs': 1,
        }
    sys.stdout.write(json.dumps(resp, ensure_ascii=False) + '\n')
    sys.stdout.flush()
