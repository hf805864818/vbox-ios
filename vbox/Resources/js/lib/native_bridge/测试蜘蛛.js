var spider = {};

spider.init = function(config) {
    print("蜘蛛初始化: " + JSON.stringify(config));
    return true;
};

spider.homeContent = function() {
    return JSON.stringify({
        "class": [
            {"type_id": "1", "type_name": "电影"},
            {"type_id": "2", "type_name": "电视剧"},
            {"type_id": "3", "type_name": "综艺"},
            {"type_id": "4", "type_name": "动漫"}
        ],
        "list": [
            {
                "vod_id": "test_001",
                "vod_name": "测试电影1",
                "vod_pic": "https://example.com/poster1.jpg",
                "vod_remarks": "更新至2026",
                "vod_year": "2026",
                "vod_area": "中国",
                "vod_content": "这是一部测试电影"
            },
            {
                "vod_id": "test_002",
                "vod_name": "测试电视剧1",
                "vod_pic": "https://example.com/poster2.jpg",
                "vod_remarks": "全12集",
                "vod_year": "2025",
                "vod_area": "韩国",
                "vod_content": "这是一部测试电视剧"
            }
        ]
    });
};

spider.categoryContent = function(tid, pg, extend) {
    return JSON.stringify({
        "page": parseInt(pg),
        "pagecount": 5,
        "limit": 20,
        "total": 100,
        "list": [
            {
                "vod_id": "test_00" + pg,
                "vod_name": "分类测试-" + pg,
                "vod_pic": "https://example.com/poster.jpg",
                "vod_remarks": "测试中",
                "vod_year": "2026"
            }
        ]
    });
};

spider.detailContent = function(ids) {
    return JSON.stringify({
        "list": [{
            "vod_id": ids,
            "vod_name": "测试详情",
            "vod_pic": "https://example.com/detail.jpg",
            "vod_year": "2026",
            "vod_area": "中国",
            "vod_director": "测试导演",
            "vod_actor": "测试演员1,测试演员2",
            "vod_content": "这是测试视频的详细介绍内容",
            "vod_play_from": "qnq,hdm3u8",
            "vod_play_url": "第01集$https://test.com/play/01.m3u8#第02集$https://test.com/play/02.m3u8"
        }]
    });
};

spider.searchContent = function(keyword, pg) {
    return JSON.stringify({
        "list": [{
            "vod_id": "search_001",
            "vod_name": "搜索结果-" + keyword,
            "vod_pic": "https://example.com/search.jpg",
            "vod_remarks": "搜索命中",
            "vod_year": "2026"
        }]
    });
};

spider.playerContent = function(vod_id, flag, url) {
    return JSON.stringify({
        "parse": 0,
        "playUrl": "",
        "url": url.replace("#", ""),
        "header": {
            "User-Agent": "Mozilla/5.0",
            "Referer": "https://example.com/"
        }
    });
};
