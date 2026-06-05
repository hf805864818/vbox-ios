// zhanyuan 蜘蛛引擎 - 用 cheerio 解析 HTML 视频站
// 支持 searchContent, detailContent, playerContent

(function() {
    // 等待 lib 加载
    if (typeof cheerio === 'undefined' && typeof loadLib === 'function') {
        loadLib('cheerio.min.js');
    }

    function log(msg) { if (typeof print !== 'undefined') print('[Zhanyuan] ' + msg); }

    // XPath 风格 → CSS/cheerio 选择器
    function parseXPath(xpath, html) {
        if (!xpath || !html) return [];
        var $ = cheerio.load(html);
        
        // 处理 @class=&&&xxx&&& 格式 (TVBox 自定义)
        var selector = xpath;
        // //div[@class=&&&xxx&&&] → div.xxx
        selector = selector.replace(/@class=&&&([^&]+)&&&/g, function(_, cls) {
            return '.' + cls.trim().replace(/\s+/g, '.');
        });
        // //*[@id=&&&xxx&&&] → #xxx
        selector = selector.replace(/@id=&&&([^&]+)&&&/g, function(_, id) {
            return '#' + id.trim();
        });
        // //li[@class='xxx'] → li.xxx
        selector = selector.replace(/@class='([^']+)'/g, function(_, cls) {
            return '.' + cls.trim().replace(/\s+/g, '.');
        });
        // 去掉 //
        selector = selector.replace(/\/\//g, '');
        // /text() → 取文本
        var getText = false;
        if (selector.endsWith('/text()')) {
            getText = true;
            selector = selector.replace('/text()', '');
        }
        // /@href → 取 href 属性
        var getAttr = null;
        var attrMatch = selector.match(/\/@(\w+)$/);
        if (attrMatch) {
            getAttr = attrMatch[1];
            selector = selector.replace(/\/@\w+$/, '');
        }
        // @data-dropdown-value → 取属性
        var dataAttr = null;
        var dataMatch = selector.match(/@([\w-]+)$/);
        if (dataMatch) {
            dataAttr = dataMatch[1];
            selector = selector.replace(/@[\w-]+$/, '');
        }

        var results = [];
        try {
            $(selector).each(function() {
                var el = $(this);
                if (getAttr) {
                    var val = el.attr(getAttr);
                    if (val) results.push(val);
                } else if (dataAttr) {
                    var val = el.attr(dataAttr);
                    if (val) results.push(val);
                } else if (getText) {
                    results.push(el.text().trim());
                } else {
                    results.push(el.html() || '');
                }
            });
        } catch(e) {
            log('选择器错误: ' + e + ' selector=' + selector);
        }
        return results;
    }

    // 从 zhanyuan 配置创建蜘蛛
    function createSpider(config) {
        var spider = {};
        spider.config = config;
        
        // 获取首页/推荐 (简化)
        spider.homeContent = function() {
            return JSON.stringify({ class: [{type_id:'1',type_name:'电影'},{type_id:'2',type_name:'电视剧'}], list: [] });
        };

        // 搜索
        spider.searchContent = function(keyword, pg) {
            var cfg = this.config;
            var searchUrl = cfg.websearchurl || cfg.searchUrl + '/search/-------------.html?wd=';
            if (!searchUrl) {
                return JSON.stringify({ list: [] });
            }
            var url = searchUrl.replace('**', encodeURIComponent(keyword))
                               .replace('wd=', 'wd=' + encodeURIComponent(keyword));
            // 如果 URL 没有 wd= 参数，直接拼接
            if (!url.includes('wd=')) {
                if (url.includes('?')) url += '&wd=' + encodeURIComponent(keyword);
                else url += '?wd=' + encodeURIComponent(keyword);
            }
            
            log('搜索URL: ' + url);
            try {
                var resp = http(url, {
                    method: 'GET',
                    headers: {'User-Agent': cfg.searchUA || cfg.playUA || 'Mozilla/5.0'},
                    timeout: 10
                });
                var html = typeof resp.content === 'string' ? resp.content : (resp.body || '');
                var $ = cheerio.load(html);
                var items = [];
                
                // 用 searchname/searchid/searchpic 选择器
                var nameSel = cfg.searchname || 'a.title';
                var idSel = cfg.searchid || 'a';
                var picSel = cfg.searchpic || 'img';
                var remarkSel = cfg.searchstarr || '';
                
                $(nameSel).each(function(i) {
                    if (i >= 20) return false;
                    var el = $(this);
                    var name = el.text().trim();
                    if (!name) return;
                    
                    // 提取 ID
                    var href = '';
                    if (idSel.startsWith('http')) {
                        // 固定 ID 格式: https://xxx.com/detail/id/xxx.html
                        var hrefMatch = html.match(new RegExp('href="([^"]*' + encodeURIComponent(name) + '[^"]*)"'));
                        if (hrefMatch) href = hrefMatch[1];
                        var idMatch = href.match(/(\d+)\.html/);
                        var vid = idMatch ? idMatch[1] : name;
                        items.push({vod_id: vid, vod_name: name, vod_pic: '', vod_remarks: cfg.name});
                    } else {
                        var parent = el.closest('li, div.item, div.vod_item, div.module-item');
                        var link = parent.find(idSel).first();
                        if (link.length === 0) link = el;
                        href = link.attr('href') || '';
                        var idMatch = href.match(/(\d+)\.html/);
                        var vid = idMatch ? idMatch[1] : name;
                        
                        var pic = parent.find(picSel).first().attr('src') || parent.find(picSel).first().attr('data-original') || '';
                        var remark = '';
                        if (remarkSel) {
                            remark = parent.find(remarkSel).first().text().trim();
                        }
                        items.push({vod_id: vid, vod_name: name, vod_pic: pic, vod_remarks: cfg.name + ' ' + remark});
                    }
                });
                
                log('搜索到 ' + items.length + ' 条');
                return JSON.stringify({ list: items });
            } catch(e) {
                log('搜索失败: ' + e);
                return JSON.stringify({ list: [] });
            }
        };

        // 获取详情 (含播放地址)
        spider.detailContent = function(ids) {
            var cfg = this.config;
            var baseUrl = cfg.searchUrl || cfg.searchid || '';
            // 尝试构建详情页 URL
            var detailUrl = '';
            if (cfg.searchid && cfg.searchid.includes('.html')) {
                detailUrl = cfg.searchid.replace('#', ids);
            } else if (baseUrl) {
                detailUrl = baseUrl + (baseUrl.endsWith('/') ? '' : '/') + 'detail/id/' + ids + '.html';
            }
            if (!detailUrl || detailUrl === ids) {
                return JSON.stringify({ list: [] });
            }
            
            log('详情URL: ' + detailUrl);
            try {
                var resp = http(detailUrl, JSON.stringify({
                    method: 'GET',
                    headers: {'User-Agent': cfg.playUA || cfg.searchUA || 'Mozilla/5.0'},
                    timeout: 10
                }));
                var html = resp.content || '';
                var $ = cheerio.load(html);
                
                // 提取标题
                var title = $('h1').first().text().trim() || $('title').first().text().trim() || ids;
                // 提取图片
                var img = $('img.vod_pic, img.cover, .module-item-pic img').first().attr('src') || 
                         $('img').first().attr('src') || '';
                
                // 提取剧集列表
                var playFrom = cfg.name || '线路1';
                var playUrl = '';
                
                // 用 detaillist 定位剧集容器
                var listContainers = parseXPath(cfg.detaillist || '//ul[@class=\'stui-content__playlist clearfix\']', html);
                // 处理 detailxl (线路名称) 和 detailjs/detailjsurl (剧集名称和链接)
                var fromNames = [];
                if (cfg.detailxl) {
                    fromNames = parseXPath(cfg.detailxl, html);
                }
                
                var episodes = [];
                if (cfg.detailjs && cfg.detailjsurl) {
                    var names = parseXPath(cfg.detailjs, html);
                    var urls = parseXPath(cfg.detailjsurl, html);
                    for (var i = 0; i < Math.min(names.length, urls.length); i++) {
                        var epUrl = urls[i];
                        // 补全相对路径
                        if (epUrl && !epUrl.startsWith('http')) {
                            var base = cfg.searchUrl || '';
                            if (base.endsWith('/')) base = base.slice(0, -1);
                            epUrl = base + (epUrl.startsWith('/') ? '' : '/') + epUrl;
                        }
                        episodes.push(names[i] + '$' + epUrl);
                    }
                }
                
                if (episodes.length > 0) {
                    playUrl = episodes.join('#');
                }
                
                log('详情: ' + title + ', 剧集: ' + episodes.length + ' 集');
                
                return JSON.stringify({
                    list: [{
                        vod_id: ids,
                        vod_name: title,
                        vod_pic: img,
                        vod_play_from: fromNames.length > 0 ? fromNames.join('$$$') : playFrom,
                        vod_play_url: playUrl,
                        vod_remarks: cfg.name,
                        vod_content: $('.content, .desc, .vod_content, .module-info-introduction').first().text().trim().slice(0, 200)
                    }]
                });
            } catch(e) {
                log('详情失败: ' + e);
                return JSON.stringify({ list: [] });
            }
        };

        // 播放解析
        spider.playerContent = function(vod_id, flag, url) {
            return JSON.stringify({
                parse: 0,
                playUrl: '',
                url: url,
                header: {
                    'User-Agent': this.config.playUA || 'Mozilla/5.0',
                    'Referer': this.config.searchUrl || ''
                }
            });
        };

        return spider;
    }

    // 注册工厂函数到全局
    globalThis.__createZhanyuanSpider = createSpider;
    log('zhanyuan 蜘蛛引擎就绪');
})();
