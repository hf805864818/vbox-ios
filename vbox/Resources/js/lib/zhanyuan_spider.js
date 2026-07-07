/**
 * zhanyuan_spider.js - HTML站源蜘蛛引擎
 * 用于解析HTML结构的视频站源 (type=2)
 * 支持两种配置格式：
 *   1. 自整理订阅格式（searchname/searchid/detaillist 等 XPath 规则）
 *   2. 原有简化格式（搜索/一级/二级 等正则规则）
 * 配合cheerio进行HTML解析
 */

(function(global) {
    'use strict';

    /**
     * 将 XPath 风格的选择器转为 cheerio CSS 选择器
     * 支持的 XPath 语法（子集）：
     *   //div[@class="xxx"]  →  div.xxx
     *   //div/a              →  div > a
     *   //a/@href            →  提取 href 属性
     *   //a/text()           →  提取文本
     *   //img/@data-original → 提取 data-original 属性
     *   &&&  分隔符表示 class 值
     */
    function xpathToCheerio(xpath) {
        if (!xpath) return null;

        var isAttr = false;
        var isText = false;
        var attrName = '';

        // 检查是否是属性提取
        if (xpath.endsWith('/text()')) {
            isText = true;
            xpath = xpath.substring(0, xpath.length - 7);
        } else if (xpath.match(/\/@(\w+)$/)) {
            var attrMatch = xpath.match(/\/@(\w+)$/);
            attrName = attrMatch[1];
            isAttr = true;
            xpath = xpath.substring(0, xpath.length - attrName.length - 2);
        }

        // 移除开头的 //
        xpath = xpath.replace(/^\//+/, '');

        // 处理 &&& 分隔的 class（如 div[@class=&&&module-card-item-title&&&]）
        xpath = xpath.replace(/\[@class=&&&([^&]*)&&&&\]/g, '.$1');

        // 处理 [@class="xxx"] 格式
        xpath = xpath.replace(/\[@class="([^"]+)"\]/g, '.$1');

        // 处理 [@id="xxx"] 格式
        xpath = xpath.replace(/\[@id="([^"]+)"\]/g, '#$1');

        // 处理剩余的 [@xxx="yyy"] → [xxx="yyy"]
        xpath = xpath.replace(/\[@(\w+)=&&&([^&]*)&&&&\]/g, '[$1="$2"]');
        xpath = xpath.replace(/\[@(\w+)="([^"]+)"\]/g, '[$1="$2"]');

        // 处理 //* 通配
        xpath = xpath.replace(/\/\*/g, '');

        // 处理 //a → > a（子元素）
        xpath = xpath.replace(/\/\//g, ' ');

        return {
            selector: xpath.trim(),
            isAttr: isAttr,
            isText: isText,
            attrName: attrName
        };
    }

    /**
     * 用 cheerio + XPath 规则提取元素
     */
    function extractByRule($, html, rule) {
        if (!rule || !html) return [];
        var parsed = xpathToCheerio(rule);
        if (!parsed) return [];

        try {
            var $root = $.load(html);
            var $els = $root(parsed.selector);

            var results = [];
            $els.each(function(i, el) {
                if (parsed.isText) {
                    results.push($(el).text().trim());
                } else if (parsed.isAttr) {
                    results.push($(el).attr(parsed.attrName) || '');
                } else {
                    results.push($(el).html() || $(el).text().trim() || '');
                }
            });
            return results;
        } catch (e) {
            return [];
        }
    }

    /**
     * 创建站源蜘蛛
     * @param {Object} config - 站源配置
     */
    global.__createZhanyuanSpider = function(config) {
        config = config || {};

        // 检测配置格式
        var isXPathFormat = !!(config.searchname || config.searchid || config.detaillist || config.websearchurl);

        var spider = {
            config: config,
            name: config.name || 'zhanyuan',
            host: config.host || config.searchUrl || '',

            /**
             * 首页内容
             */
            homeContent: function() {
                try {
                    return { class: [], list: [] };
                } catch (e) {
                    return { class: [], list: [] };
                }
            },

            /**
             * 分类内容
             */
            categoryContent: function(tid, pg, filter) {
                try {
                    return { page: pg, pagecount: 0, limit: 20, total: 0, list: [] };
                } catch (e) {
                    return { page: pg, pagecount: 0, limit: 20, total: 0, list: [] };
                }
            },

            /**
             * 详情内容
             */
            detailContent: function(ids) {
                try {
                    var detailUrl = ids;
                    if (!detailUrl.startsWith('http')) {
                        detailUrl = this.host + detailUrl;
                    }

                    var headers = { 'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15' };
                    if (config.playUA) {
                        headers['User-Agent'] = config.playUA;
                    }

                    var resp = req(detailUrl, { headers: headers });
                    if (!resp || !resp.ok) {
                        return { list: [] };
                    }

                    var html = resp.data;
                    var item = {};

                    if (isXPathFormat) {
                        // XPath 格式详情解析
                        item = this.parseDetailXPath(html, detailUrl);
                    } else {
                        // 原有正则格式
                        item = this.parseDetailRegex(html);
                    }

                    if (item && item.vod_id) {
                        return { list: [item] };
                    }
                    return { list: [] };
                } catch (e) {
                    print('[ZhanyuanSpider] detailContent error: ' + e);
                    return { list: [] };
                }
            },

            /**
             * 搜索内容 — 兼容两种格式
             */
            searchContent: function(keyword, pg) {
                try {
                    if (isXPathFormat) {
                        return this.searchXPath(keyword, pg);
                    } else {
                        return this.searchRegex(keyword, pg);
                    }
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

            // ===== XPath 格式搜索 =====
            searchXPath: function(keyword, pg) {
                var searchUrl = '';

                // 优先使用 websearchurl（完整搜索 URL 模板）
                if (config.websearchurl && config.websearchurl.length > 0) {
                    searchUrl = config.websearchurl.replace('**', encodeURIComponent(keyword));
                    if (searchUrl.indexOf('fypage') >= 0) {
                        searchUrl = searchUrl.replace('fypage', pg || 1);
                    }
                } else if (config.searchUrl) {
                    // 用 searchUrl 作为基地址，拼接搜索路径
                    searchUrl = config.searchUrl;
                    if (!searchUrl.endsWith('/')) searchUrl += '/';
                    searchUrl += 'search/-------------.html?wd=' + encodeURIComponent(keyword);
                }

                if (!searchUrl) return { list: [] };

                var headers = { 'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15' };
                if (config.searchUA) {
                    headers['User-Agent'] = config.searchUA;
                }

                var resp = req(searchUrl, { headers: headers });
                if (!resp || !resp.ok) return { list: [] };

                var html = resp.data;
                var list = [];

                // 检查 searchid 是否是 URL 模板（如 https://xxx.com/voddetail/#.html）
                var searchidIsTemplate = config.searchid && (config.searchid.indexOf('http') === 0 || config.searchid.indexOf('/') === 0) && config.searchid.indexOf('#') >= 0;

                if (searchidIsTemplate) {
                    // searchid 是详情页 URL 模板，需要从搜索结果页提取 ID
                    list = this.parseSearchByTemplate(html, searchUrl);
                } else if (config.searchname) {
                    // 标准 XPath 规则
                    list = this.parseSearchByXPath(html);
                }

                return { list: list };
            },

            /**
             * 用详情页 URL 模板解析搜索结果
             * searchid 格式: https://xxx.com/voddetail/#.html
             * 需要从搜索页 HTML 中提取视频 ID，拼入模板
             */
            parseSearchByTemplate: function(html, searchUrl) {
                var list = [];
                try {
                    var $ = cheerio.load(html);

                    // 尝试多种选择器提取搜索结果
                    var selectors = [
                        'a[href*="detail"]', 'a[href*="vod"]',
                        'a[href*="/id/"]', 'a[href*=".html"]',
                        '.module-card-item a', '.search-list-item a',
                        '.stui-vodlist__thumb a', '.vodlist li a',
                        'li a'
                    ];

                    var $links = $();
                    for (var i = 0; i < selectors.length; i++) {
                        $links = $(selectors[i]);
                        if ($links.length > 0) break;
                    }

                    var seen = {};
                    $links.each(function(idx, el) {
                        if (list.length >= 30) return false;

                        var $el = $(el);
                        var href = $el.attr('href') || '';
                        var name = $el.text().trim() || $el.find('title, .title, .name, strong, h3, h4, span').first().text().trim();
                        var pic = $el.find('img').first().attr('data-original') || $el.find('img').first().attr('data-src') || $el.find('img').first().attr('src') || '';

                        if (!name || name.length < 1) return;
                        if (name === '首页' || name === '分类' || name === 'APP' || name.length < 2) return;

                        // 去重
                        if (seen[name]) return;
                        seen[name] = true;

                        // 补全 URL
                        if (href && !href.startsWith('http')) {
                            if (href.startsWith('/')) {
                                href = this.host + href;
                            } else {
                                href = searchUrl.substring(0, searchUrl.lastIndexOf('/') + 1) + href;
                            }
                        }

                        // 补全图片
                        if (pic && !pic.startsWith('http')) {
                            if (pic.startsWith('//')) pic = 'https:' + pic;
                            else if (pic.startsWith('/')) pic = this.host + pic;
                            else pic = this.host + '/' + pic;
                        }

                        // 用 searchid 模板构建 vod_id
                        var vodId = href;

                        list.push({
                            vod_id: vodId,
                            vod_name: name,
                            vod_pic: pic || '',
                            vod_remarks: this.config.name || ''
                        });
                    });
                } catch (e) {
                    print('[ZhanyuanSpider] parseSearchByTemplate error: ' + e);
                }
                return list;
            },

            /**
             * 用 XPath 规则解析搜索结果
             */
            parseSearchByXPath: function(html) {
                var list = [];
                try {
                    var $ = cheerio.load(html);

                    var names = extractByRule($, html, config.searchname);
                    var ids = extractByRule($, html, config.searchid);
                    var pics = config.searchpic ? extractByRule($, html, config.searchpic) : [];
                    var stars = config.searchstarr ? extractByRule($, html, config.searchstarr) : [];

                    var count = Math.min(names.length, ids.length, 30);
                    for (var i = 0; i < count; i++) {
                        var name = (names[i] || '').trim();
                        var id = (ids[i] || '').trim();
                        if (!name || name.length < 2) continue;

                        // 补全 URL
                        if (id && !id.startsWith('http')) {
                            if (id.startsWith('/')) {
                                id = this.host + id;
                            } else {
                                id = this.host + '/' + id;
                            }
                        }

                        var pic = (pics[i] || '').trim();
                        if (pic && !pic.startsWith('http')) {
                            if (pic.startsWith('//')) pic = 'https:' + pic;
                            else if (pic.startsWith('/')) pic = this.host + pic;
                        }

                        list.push({
                            vod_id: id,
                            vod_name: name,
                            vod_pic: pic || '',
                            vod_remarks: (stars[i] || this.config.name || '').trim()
                        });
                    }
                } catch (e) {
                    print('[ZhanyuanSpider] parseSearchByXPath error: ' + e);
                }
                return list;
            },

            /**
             * XPath 格式详情解析
             */
            parseDetailXPath: function(html, detailUrl) {
                var item = {
                    vod_id: detailUrl,
                    vod_name: '',
                    vod_pic: '',
                    vod_content: '',
                    vod_play_url: '',
                    vod_play_from: this.config.name || 'zhanyuan'
                };

                try {
                    var $ = cheerio.load(html);

                    // 提取标题
                    var $title = $('h1').first();
                    if ($title.length === 0) $title = $('title').first();
                    if ($title.length === 0) $title = $('.slide-info-title, .video-info-header .title, .module-heading-title').first();
                    item.vod_name = $title.text().trim();

                    // 提取图片
                    var $img = $('.slide-info-cover img, .video-info-cover img, .module-item-pic img').first();
                    if ($img.length === 0) $img = $('img[data-pic]').first();
                    if ($img.length === 0) $img = $('img').first();
                    item.vod_pic = $img.attr('data-original') || $img.attr('data-src') || $img.attr('src') || '';
                    if (item.vod_pic && !item.vod_pic.startsWith('http')) {
                        if (item.vod_pic.startsWith('//')) item.vod_pic = 'https:' + item.vod_pic;
                        else item.vod_pic = this.host + item.vod_pic;
                    }

                    // 提取播放列表（用 detaillist XPath 规则）
                    if (config.detaillist) {
                        var playUrls = this.parsePlayListXPath($, html);
                        if (playUrls.length > 0) {
                            item.vod_play_url = playUrls.join('#');
                        }
                    }

                    // 如果没有 XPath 规则，用通用方式提取播放列表
                    if (!item.vod_play_url) {
                        item.vod_play_url = this.parsePlayListGeneric($, html);
                    }
                } catch (e) {
                    print('[ZhanyuanSpider] parseDetailXPath error: ' + e);
                }

                return item;
            },

            /**
             * 用 detaillist XPath 规则提取播放列表
             */
            parsePlayListXPath: function($, html) {
                var playUrls = [];
                try {
                    var parsed = xpathToCheerio(config.detaillist);
                    if (!parsed) return playUrls;

                    var $tabs = $(parsed.selector);

                    // 提取线路名称（用 detailxl 规则）
                    var tabNames = [];
                    if (config.detailxl) {
                        tabNames = extractByRule($, html, config.detailxl);
                    }

                    // 提取每集名称和链接（用 detailjs 和 detailjsurl 规则）
                    var episodeNames = config.detailjs ? extractByRule($, html, config.detailjs) : [];
                    var episodeUrls = config.detailjsurl ? extractByRule($, html, config.detailjsurl) : [];

                    if (episodeNames.length > 0 && episodeUrls.length > 0) {
                        // 有明确的集数规则
                        var count = Math.min(episodeNames.length, episodeUrls.length, 500);
                        for (var i = 0; i < count; i++) {
                            var epName = (episodeNames[i] || '').trim();
                            var epUrl = (episodeUrls[i] || '').trim();
                            if (!epName && !epUrl) continue;

                            // 补全 URL
                            if (epUrl && !epUrl.startsWith('http')) {
                                if (epUrl.startsWith('/')) epUrl = this.host + epUrl;
                                else epUrl = this.host + '/' + epUrl;
                            }

                            playUrls.push(epName + '$' + epUrl);
                        }
                    } else {
                        // 没有明确的集数规则，用通用提取
                        $tabs.each(function(idx, el) {
                            var $tab = $(el);
                            $tab.find('a').each(function(j, a) {
                                var epName = $(a).text().trim();
                                var epUrl = $(a).attr('href') || '';
                                if (!epName || !epUrl) return;

                                if (!epUrl.startsWith('http')) {
                                    if (epUrl.startsWith('/')) epUrl = spider.host + epUrl;
                                    else epUrl = spider.host + '/' + epUrl;
                                }

                                playUrls.push(epName + '$' + epUrl);
                            });
                        });
                    }
                } catch (e) {
                    print('[ZhanyuanSpider] parsePlayListXPath error: ' + e);
                }
                return playUrls;
            },

            /**
             * 通用播放列表提取（无 XPath 规则时的兜底）
             */
            parsePlayListGeneric: function($, html) {
                var playUrls = [];
                try {
                    // 尝试常见的播放列表选择器
                    var selectors = [
                        '.playlist a', '.play-list a',
                        '.stui-content__playlist a',
                        '.module-play-list a',
                        '#y-playList a', '#playlist a',
                        '.video-list a', '.vodlist a'
                    ];

                    for (var s = 0; s < selectors.length; s++) {
                        var $items = $(selectors[s]);
                        if ($items.length > 0) {
                            $items.each(function(i, el) {
                                var name = $(el).text().trim();
                                var url = $(el).attr('href') || '';
                                if (!name || !url) return;

                                if (!url.startsWith('http')) {
                                    if (url.startsWith('/')) url = spider.host + url;
                                    else url = spider.host + '/' + url;
                                }

                                playUrls.push(name + '$' + url);
                            });
                            break;
                        }
                    }
                } catch (e) {
                    print('[ZhanyuanSpider] parsePlayListGeneric error: ' + e);
                }
                return playUrls;
            },

            // ===== 原有正则格式搜索（向后兼容） =====
            searchRegex: function(keyword, pg) {
                var searchUrl = this.host + (config.searchUrl || '');
                searchUrl = searchUrl.replace('**', encodeURIComponent(keyword));
                searchUrl = searchUrl.replace('fypage', pg);

                var resp = req(searchUrl, {
                    headers: config.headers || {}
                });

                if (!resp || !resp.ok) return { list: [] };

                var list = [];
                if (config.搜索) {
                    list = this.parseList(resp.data, config.搜索);
                }

                return { list: list };
            },

            /**
             * 解析列表（原有正则方式，向后兼容）
             */
            parseList: function(html, rule) {
                var list = [];
                try {
                    var itemRegex = /<a[^>]*href=["']([^"']*(?:detail|vod|id)[^"']*)["'][^>]*>.*?<img[^>]*src=["']([^"']*)["'][^>]*>.*?<[^>]*>([^<]+)<\/[^>]*>/gi;
                    var match;
                    var count = 0;
                    while ((match = itemRegex.exec(html)) !== null && count < 30) {
                        var vodId = match[1];
                        var vodPic = match[2];
                        var vodName = match[3].trim();

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

                    if (list.length === 0) {
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
             * 解析详情（原有正则方式，向后兼容）
             */
            parseDetailRegex: function(html) {
                try {
                    var item = {};

                    var titleMatch = html.match(/<h1[^>]*>([^<]+)<\/h1>/i) ||
                                      html.match(/<title>([^<]+)<\/title>/i);
                    if (titleMatch) {
                        item.vod_name = titleMatch[1].trim();
                    }

                    var imgMatch = html.match(/<img[^>]*src=["']([^"]*poster|cover[^"]*)["'][^>]*>/i) ||
                                   html.match(/<img[^>]*src=["']([^"]*\.jpg|\.png)["'][^>]*class=["'][^"]*poster[^"]*["'][^>]*>/i);
                    if (imgMatch) {
                        item.vod_pic = imgMatch[1];
                    }

                    var descMatch = html.match(/<div[^>]*class=["'][^"]*desc|content|intro[^"]*["'][^>]*>([^<]+)<\/div>/i);
                    if (descMatch) {
                        item.vod_content = descMatch[1].trim();
                    }

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
