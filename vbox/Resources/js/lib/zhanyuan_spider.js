/**
 * zhanyuan_spider.js - HTML站源蜘蛛引擎
 * 用于解析HTML结构的视频站源 (type=2)
 * 配合cheerio进行HTML解析
 */

(function(global) {
    'use strict';

    /**
     * 创建站源蜘蛛
     * @param {Object} config - 站源配置
     */
    global.__createZhanyuanSpider = function(config) {
        config = config || {};
        
        var spider = {
            config: config,
            name: config.name || 'zhanyuan',
            host: config.host || '',
            
            /**
             * 首页内容
             */
            homeContent: function() {
                try {
                    var url = this.host + (config.homeUrl || '/');
                    var resp = req(url, {
                        headers: config.headers || { 'User-Agent': 'Mozilla/5.0' }
                    });
                    
                    if (!resp.ok) {
                        return { class: [], list: [] };
                    }
                    
                    // 解析分类
                    var classes = [];
                    if (config.class_parse) {
                        classes = this.parseClass(resp.data, config.class_parse);
                    }
                    
                    // 解析推荐视频
                    var list = [];
                    if (config.推荐) {
                        list = this.parseList(resp.data, config.推荐);
                    }
                    
                    return { class: classes, list: list };
                } catch (e) {
                    print('[ZhanyuanSpider] homeContent error: ' + e);
                    return { class: [], list: [] };
                }
            },
            
            /**
             * 分类内容
             */
            categoryContent: function(tid, pg, filter) {
                try {
                    var url = this.host + (config.url || '');
                    url = url.replace('fyclass', tid).replace('fypage', pg);
                    
                    var resp = req(url, {
                        headers: config.headers || {}
                    });
                    
                    if (!resp.ok) {
                        return { page: pg, pagecount: 0, limit: 20, total: 0, list: [] };
                    }
                    
                    var list = [];
                    if (config.一级) {
                        list = this.parseList(resp.data, config.一级);
                    }
                    
                    return {
                        page: pg,
                        pagecount: pg + 1,
                        limit: 20,
                        total: list.length,
                        list: list
                    };
                } catch (e) {
                    print('[ZhanyuanSpider] categoryContent error: ' + e);
                    return { page: pg, pagecount: 0, limit: 20, total: 0, list: [] };
                }
            },
            
            /**
             * 详情内容
             */
            detailContent: function(ids) {
                try {
                    var url = this.host + ids;
                    var resp = req(url, {
                        headers: config.headers || {}
                    });
                    
                    if (!resp.ok) {
                        return { list: [] };
                    }
                    
                    var item = this.parseDetail(resp.data, config.二级);
                    if (item) {
                        item.vod_id = ids;
                    }
                    
                    return { list: item ? [item] : [] };
                } catch (e) {
                    print('[ZhanyuanSpider] detailContent error: ' + e);
                    return { list: [] };
                }
            },
            
            /**
             * 搜索内容
             */
            searchContent: function(keyword, pg) {
                try {
                    var searchUrl = this.host + (config.searchUrl || '');
                    searchUrl = searchUrl.replace('**', encodeURIComponent(keyword));
                    searchUrl = searchUrl.replace('fypage', pg);
                    
                    var resp = req(searchUrl, {
                        headers: config.headers || {}
                    });
                    
                    if (!resp.ok) {
                        return { list: [] };
                    }
                    
                    var list = [];
                    if (config.搜索) {
                        list = this.parseList(resp.data, config.搜索);
                    }
                    
                    return { list: list };
                } catch (e) {
                    print('[ZhanyuanSpider] searchContent error: ' + e);
                    return { list: [] };
                }
            },
            
            /**
             * 播放器内容
             */
            playerContent: function(vodId, flag, url) {
                return {
                    parse: 0,
                    url: url,
                    header: config.headers || {}
                };
            },
            
            /**
             * 解析分类
             */
            parseClass: function(html, rule) {
                var classes = [];
                try {
                    // 简单的解析规则: selector;text;href;regex
                    var parts = rule.split(';');
                    if (parts.length < 2) return classes;
                    
                    // 使用基本的正则提取
                    var regex = /<a[^>]*href=["']([^"']*\/list\/[^"']*|[0-9]+)["'][^>]*>([^<]+)<\/a>/gi;
                    var match;
                    while ((match = regex.exec(html)) !== null) {
                        var typeName = match[2].trim();
                        var typeId = match[1];
                        
                        // 排除特定分类
                        if (config.cate_exclude && config.cate_exclude.includes(typeName)) {
                            continue;
                        }
                        
                        classes.push({
                            type_id: typeId,
                            type_name: typeName
                        });
                    }
                } catch (e) {
                    print('[ZhanyuanSpider] parseClass error: ' + e);
                }
                return classes;
            },
            
            /**
             * 解析列表
             */
            parseList: function(html, rule) {
                var list = [];
                try {
                    // 提取视频项
                    // 匹配常见的视频卡片格式
                    var itemRegex = /<a[^>]*href=["']([^"']*(?:detail|vod|id)[^"']*)["'][^>]*>.*?<img[^>]*src=["']([^"']*)["'][^>]*>.*?<[^>]*>([^<]+)<\/[^>]*>/gi;
                    
                    var match;
                    var count = 0;
                    while ((match = itemRegex.exec(html)) !== null && count < 30) {
                        var vodId = match[1];
                        var vodPic = match[2];
                        var vodName = match[3].trim();
                        
                        // 修复相对URL
                        if (vodId && !vodId.startsWith('http')) {
                            vodId = this.host + vodId;
                        }
                        if (vodPic && !vodPic.startsWith('http')) {
                            vodPic = this.host + vodPic;
                        }
                        
                        if (vodName && vodId) {
                            list.push({
                                vod_id: vodId,
                                vod_name: vodName,
                                vod_pic: vodPic,
                                vod_remarks: this.config.name || ''
                            });
                            count++;
                        }
                    }
                    
                    // 如果没匹配到，尝试其他格式
                    if (list.length === 0) {
                        // 尝试匹配更简单的格式
                        var simpleRegex = /<a[^>]*href=["']([^"']*\d+\.html)["'][^>]*>([^<]+)<\/a>/gi;
                        while ((match = simpleRegex.exec(html)) !== null && count < 20) {
                            var name = match[2].trim();
                            if (name && name.length > 1 && !name.includes('首页') && !name.includes('分类')) {
                                list.push({
                                    vod_id: match[1],
                                    vod_name: name,
                                    vod_pic: '',
                                    vod_remarks: this.config.name || ''
                                });
                                count++;
                            }
                        }
                    }
                } catch (e) {
                    print('[ZhanyuanSpider] parseList error: ' + e);
                }
                return list;
            },
            
            /**
             * 解析详情
             */
            parseDetail: function(html, rule) {
                try {
                    var item = {};
                    
                    // 提取标题
                    var titleMatch = html.match(/<h1[^>]*>([^<]+)<\/h1>/i) ||
                                      html.match(/<title>([^<]+)<\/title>/i);
                    if (titleMatch) {
                        item.vod_name = titleMatch[1].trim();
                    }
                    
                    // 提取图片
                    var imgMatch = html.match(/<img[^>]*src=["']([^"]*poster|cover[^"]*)["'][^>]*>/i) ||
                                   html.match(/<img[^>]*src=["']([^"]*\.jpg|\.png)["'][^>]*class=["'][^"]*poster[^"]*["'][^>]*>/i);
                    if (imgMatch) {
                        item.vod_pic = imgMatch[1];
                    }
                    
                    // 提取简介
                    var descMatch = html.match(/<div[^>]*class=["'][^"]*desc|content|intro[^"]*["'][^>]*>([^<]+)<\/div>/i);
                    if (descMatch) {
                        item.vod_content = descMatch[1].trim();
                    }
                    
                    // 提取播放地址
                    var playUrls = [];
                    var playRegex = /<a[^>]*href=["']([^"']*play[^"']*)["'][^>]*>([^<]+)<\/a>/gi;
                    var match;
                    while ((match = playRegex.exec(html)) !== null) {
                        playUrls.push(match[2].trim() + '$' + match[1]);
                    }
                    
                    if (playUrls.length > 0) {
                        item.vod_play_url = playUrls.join('#');
                        item.vod_play_from = config.name || 'zhanyuan';
                    }
                    
                    return item;
                } catch (e) {
                    print('[ZhanyuanSpider] parseDetail error: ' + e);
                    return null;
                }
            }
        };
        
        return spider;
    };

    // 注册到全局
    global.zhanyuan = {
        createSpider: global.__createZhanyuanSpider
    };

})(this);
