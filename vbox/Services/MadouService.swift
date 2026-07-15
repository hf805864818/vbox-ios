import Foundation

// MARK: - 麻豆免费在线播放 数据模型
// 基于 c-you.hair 站点，动态抓取分类 + 视频列表 + 播放解析
struct MadouCategory: Identifiable, Hashable {
    var id: String { cateId }
    let cateId: String    // 从 /vodtype/{cateId}.html 提取
    let name: String
}

struct MadouVideo: Identifiable {
    var id: String { vodId }
    let vodId: String      // 详情页路径，如 /voddetail/123.html
    let title: String
    let cover: String
    let remarks: String     // 如 "1234观看"
    let duration: String?
    let playPath: String?  // 播放页路径，如 /vodplay/123.html
}

// MARK: - MadouService
// 对接 c-you.hair，动态分类 + 分类视频列表 + 播放解析
class MadouService: ObservableObject {
    static let shared = MadouService()
    
    private let baseURL = "https://c-you.hair"
    
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Mobile Safari/537.36"
        ]
        return URLSession(configuration: c)
    }()
    
    // MARK: - 通用请求
    private func fetchHTML(path: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(from: url)
        guard let httpResp = response as? HTTPURLResponse,
              (200...299).contains(httpResp.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        return html
    }
    
    // MARK: - 动态分类获取（从首页导航栏解析）
    /// 从首页 HTML 中解析导航栏的分类链接
    /// HTML 结构：<li><a href="/vodtype/{id}.html">分类名</a></li>
    func fetchCategories() async -> [MadouCategory] {
        do {
            let html = try await fetchHTML(path: "/")
            return parseCategories(from: html)
        } catch {
            print("[Madou] fetchCategories error: \(error)")
            return defaultCategories
        }
    }
    
    /// 从 HTML 中提取分类（正则匹配导航栏 <li><a href="/vodtype/xx.html">）
    private func parseCategories(from html: String) -> [MadouCategory] {
        var categories: [MadouCategory] = []
        // 匹配 /vodtype/{id}.html 链接（排除首页）
        let pattern = #"<a\s+href="(/vodtype/(\d+)\.html)"[^>]*>([^<]+)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, options: [], range: range)
        
        for match in matches {
            guard match.numberOfRanges >= 4,
                  let cateIdRange = Range(match.range(at: 2), in: html),
                  let nameRange = Range(match.range(at: 3), in: html) else { continue }
            let cateId = String(html[cateIdRange])
            let name = html[nameRange].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "&nbsp;", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !categories.contains(where: { $0.cateId == cateId }) else { continue }
            categories.append(MadouCategory(cateId: cateId, name: name))
        }
        return categories.isEmpty ? defaultCategories : categories
    }
    
    /// 兜底分类（与 Python 脚本 homeContent 中的分类一致）
    private var defaultCategories: [MadouCategory] {
        [
            MadouCategory(cateId: "6", name: "国产精品"),
            MadouCategory(cateId: "7", name: "中文字幕"),
            MadouCategory(cateId: "8", name: "伦理影片"),
            MadouCategory(cateId: "9", name: "自拍偷拍"),
            MadouCategory(cateId: "10", name: "口交视频"),
            MadouCategory(cateId: "11", name: "日韩无码"),
            MadouCategory(cateId: "12", name: "制服诱惑"),
            MadouCategory(cateId: "13", name: "国产色情"),
        ]
    }
    
    // MARK: - 分类视频列表（分页）
    /// 对应 Python 脚本 categoryContent
    func fetchVideos(cateId: String, page: Int = 1) async -> [MadouVideo] {
        do {
            let path = page <= 1
                ? "/vodtype/\(cateId).html"
                : "/vodtype/\(cateId)-\(page).html"
            let html = try await fetchHTML(path: path)
            return parseVideoList(from: html)
        } catch {
            print("[Madou] fetchVideos(cateId:\(cateId), page:\(page)) error: \(error)")
            return []
        }
    }
    
    /// 从列表页 HTML 解析视频条目
    /// 结构：.col-md-3.resent-grid.recommended-grid
    private func parseVideoList(from html: String) -> [MadouVideo] {
        var videos: [MadouVideo] = []
        
        // 提取每个视频卡片的 HTML 块
        // 先找 .resent-grid 块
        let blockPattern = #"<div\s+class="col-md-3[^"]*resent-grid[^"]*"[^>]*>([\s\S]*?)</div>\s*</div>"#
        // 更可靠的方案：逐行扫描找到每个 .resent-grid-img a
        let linkPattern = #"<a\s+href="([^"]*)"[^>]*>\s*<img[^>]*data-original="([^"]*)"[^>]*>"#
        let titlePattern = #"<h5>\s*<a[^>]*class="title"[^>]*>([^<]+)</a>"#
        let viewsPattern = #"<span[^>]*class="views-info"[^>]*>\s*<span[^>]*>(\d+)</span>"#
        
        guard let blockRegex = try? NSRegularExpression(pattern: blockPattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let blockRange = NSRange(html.startIndex..., in: html)
        let blocks = blockRegex.matches(in: html, options: [], range: blockRange)
        
        for block in blocks {
            guard let blockContentRange = Range(block.range(at: 1), in: html) else { continue }
            let blockContent = String(html[blockContentRange])
            
            // 提取链接和封面
            guard let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: []),
                  let linkMatch = linkRegex.firstMatch(in: blockContent, options: [], range: NSRange(blockContent.startIndex..., in: blockContent)),
                  let hrefRange = Range(linkMatch.range(at: 1), in: blockContent),
                  let imgRange = Range(linkMatch.range(at: 2), in: blockContent) else { continue }
            
            let href = String(blockContent[hrefRange])
            let cover = String(blockContent[imgRange])
            
            // 提取标题
            var title = ""
            if let titleRegex = try? NSRegularExpression(pattern: titlePattern, options: []),
               let titleMatch = titleRegex.firstMatch(in: blockContent, options: [], range: NSRange(blockContent.startIndex..., in: blockContent)),
               let titleRange = Range(titleMatch.range(at: 1), in: blockContent) {
                title = String(blockContent[titleRange]).trimmingCharacters(in: .whitespaces)
            }
            
            // 提取观看数
            var views = ""
            if let viewsRegex = try? NSRegularExpression(pattern: viewsPattern, options: []),
               let viewsMatch = viewsRegex.firstMatch(in: blockContent, options: [], range: NSRange(blockContent.startIndex..., in: blockContent)),
               let viewsRange = Range(viewsMatch.range(at: 1), in: blockContent) {
                views = String(blockContent[viewsRange]) + "观看"
            }
            
            guard !href.isEmpty, !title.isEmpty else { continue }
            
            videos.append(MadouVideo(
                vodId: href,
                title: title,
                cover: cover,
                remarks: views,
                duration: nil,
                playPath: nil
            ))
        }
        
        return videos
    }
    
    // MARK: - 首页推荐
    /// 对应 Python 脚本 homeVideoContent
    func fetchHomeVideos() async -> [MadouVideo] {
        do {
            let html = try await fetchHTML(path: "/")
            return parseVideoList(from: html)
        } catch {
            print("[Madou] fetchHomeVideos error: \(error)")
            return []
        }
    }
    
    // MARK: - 视频详情
    /// 对应 Python 脚本 detailContent
    func fetchDetail(vodId: String) async -> (title: String, cover: String, info: String, playPath: String?) {
        do {
            let html = try await fetchHTML(path: vodId)
            // 标题
            let titlePattern = #"<h3[^>]*>([^<]+)</h3>"#
            let title = firstMatch(pattern: titlePattern, in: html) ?? ""
            // 封面
            let coverPattern = #"<img\s+src="([^"]+)"[^>]*class="[^"]*video-grid[^"]*""#
            let cover = firstMatch(pattern: coverPattern, in: html) ?? ""
            // 信息
            let infoPattern = #"<div[^>]*id="myList"[^>]*>([\s\S]*?)</div>"#
            let info = firstMatch(pattern: infoPattern, in: html) ?? ""
            // 播放链接
            let playPattern = #"<a\s+href="([^"]*/vodplay/[^"]*)"[^>]*>"#
            let playPath = firstMatch(pattern: playPattern, in: html)
            return (title: title, cover: cover, info: info, playPath: playPath)
        } catch {
            print("[Madou] fetchDetail error: \(error)")
            return (title: "", cover: "", info: "", playPath: nil)
        }
    }
    
    // MARK: - 播放地址解析（多层降级）
    /// 对应 Python 脚本 playerContent
    func fetchPlayURL(playPath: String) async -> (url: String, needParse: Bool) {
        do {
            let html = try await fetchHTML(path: playPath)
            
            // 1. 尝试提取 var player_data = {...};
            if let playerMatch = html.range(of: "var player_data", range: html.startIndex..<html.endIndex, options: .caseInsensitive),
               let startBrace = html.range(of: "=", range: playerMatch.upperBound..<html.endIndex, options: .caseInsensitive),
               let jsonStart = html.range(of: "{", range: startBrace.upperBound..<html.endIndex) {
                // 找到匹配的 }
                var depth = 0
                var jsonEnd = jsonStart.upperBound
                for (idx, ch) in html[jsonStart.upperBound...].enumerated() {
                    if ch == "{" { depth += 1 }
                    else if ch == "}" { depth -= 1 }
                    if depth == 0 {
                        jsonEnd = html.index(jsonStart.upperBound, offsetBy: idx + 1)
                        break
                    }
                }
                let jsonStr = String(html[jsonStart.upperBound..<jsonEnd])
                if let data = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let url = json["url"] as? String, !url.isEmpty {
                    return (url: url, needParse: false)
                }
            }
            
            // 2. 尝试匹配 iframe
            if let iframeURL = firstMatch(pattern: #"<iframe[^>]+src="([^"]+)""#, in: html) {
                return (url: iframeURL, needParse: true)
            }
            
            // 3. 尝试匹配 video 标签
            if let videoURL = firstMatch(pattern: #"<video[^>]+src="([^"]+)""#, in: html) {
                return (url: videoURL, needParse: false)
            }
            
            // 4. 尝试匹配 source 标签
            if let sourceURL = firstMatch(pattern: #"<source[^>]+src="([^"]+)""#, in: html) {
                return (url: sourceURL, needParse: false)
            }
            
            // 5. 兜底：嗅探模式
            return (url: "\(baseURL)\(playPath)", needParse: true)
        } catch {
            return (url: "", needParse: false)
        }
    }
    
    // MARK: - 搜索
    /// 对应 Python 脚本 searchContent
    func search(keyword: String, page: Int = 1) async -> [MadouVideo] {
        do {
            let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
            let path = page <= 1
                ? "/vodsearch/\(encoded)-------------.html"
                : "/vodsearch/\(encoded)-------------\(page)---.html"
            let html = try await fetchHTML(path: path)
            return parseVideoList(from: html)
        } catch {
            print("[Madou] search error: \(error)")
            return []
        }
    }
    
    // MARK: - 工具方法
    private func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let resultRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[resultRange]).trimmingCharacters(in: .whitespaces)
    }
    
    /// 获取总页数（从列表页解析）
    func fetchPageCount(cateId: String) async -> Int {
        do {
            let html = try await fetchHTML(path: "/vodtype/\(cateId).html")
            // 尝试从分页导航中获取总页数
            // 结构：<span class="active"><a>1/100</a></span>
            if let pageInfo = firstMatch(pattern: #"<span[^>]*class="active"[^>]*>\s*<[^>]*>(\d+)/(\d+)<"#, in: html) {
                let parts = pageInfo.split(separator: "/")
                if let total = parts.last, let count = Int(total) {
                    return count
                }
            }
            return 9999 // 兜底
        } catch {
            return 9999
        }
    }
}
