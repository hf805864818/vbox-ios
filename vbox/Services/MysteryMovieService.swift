import Foundation
import Kanna

// MARK: - 神秘电影 HTML 抓取服务
// Python Spider → Swift 原生实现，基于 Kanna HTML 解析
// 站点: h4ivs.sm431.vip，视频源: 38.je m3u8

// MARK: - 数据模型

struct MysteryMovieCategory: Identifiable, Codable {
    let id: String
    let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

struct MysteryMovieVideo: Identifiable, Codable {
    let id = UUID()
    let vodId: String
    let title: String
    let cover: String
    let remarks: String
}

struct MysteryMovieDetail {
    let playFrom: String
    let playUrl: String   // m3u8 地址
    let content: String
}

// MARK: - 服务

@MainActor
class MysteryMovieService: ObservableObject {
    static let shared = MysteryMovieService()

    private let host = "https://h4ivs.sm431.vip"
    private let videoHost = "https://38.je:38"
    private let imageHost = "https://38.je:36"
    let siteName = "神秘电影"

    private let headers: [String: String] = [
        "User-Agent": "Mozilla/5.0 (Linux; Android 13; 22127RK46C Build/TKQ1.220905.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/104.0.5112.97 Mobile Safari/537.36",
        "Referer": "https://h4ivs.sm431.vip",
        "Accept-Language": "zh-CN,zh;q=0.9"
    ]

    /// 分类（硬编码，与 Python spider 一致）
    let categories: [MysteryMovieCategory] = [
        MysteryMovieCategory(id: "1", name: "国产"),
        MysteryMovieCategory(id: "2", name: "日本"),
        MysteryMovieCategory(id: "3", name: "韩国"),
        MysteryMovieCategory(id: "4", name: "欧美"),
        MysteryMovieCategory(id: "5", name: "三级"),
        MysteryMovieCategory(id: "6", name: "动漫"),
    ]

    /// 标题缓存 (vid → title)
    private var titleCache: [String: String] = [:]

    // MARK: - XOR 128 解密

    static func decrypt(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        return String(text.unicodeScalars.map { Character(UnicodeScalar(128 ^ $0.value)!) })
    }

    /// 从 JS document.write(l('...')) 中提取并解密标题
    static func decryptFromJS(_ js: String) -> String {
        // 匹配 document.write(l('BASE64_OR_ENCODED'))
        let patterns = [
            #"document\.write\(l\('([^']+)'\)\)"#,
            #"document\.write\(l\("([^"]+)"\)\)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
                  let r = Range(match.range(at: 1), in: js) else { continue }
            return decrypt(String(js[r]))
        }
        return ""
    }

    // MARK: - 图片 URL 格式化

    func imageURL(_ url: String) -> String {
        guard !url.isEmpty else { return "" }
        var u = url
        if u.hasPrefix("//") { u = "https:" + u }
        else if u.hasPrefix("/") { u = imageHost + u }
        // 追加 UA & Referer 作为查询参数供图片代理解析
        return "\(u)@User-Agent=\(headers["User-Agent"] ?? "")@Referer=\(host)/"
    }

    // MARK: - 站点存活探测

    func probeHost() async -> String {
        do {
            let (_, response) = try await session.data(for: request(url: host))
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                print("[MysteryMovie] ✅ 站点可达: \(host)")
                return host
            }
        } catch {
            print("[MysteryMovie] ⚠️ 站点不可达: \(error.localizedDescription)")
        }
        return host
    }

    // MARK: - 首页：返回视频列表（分类已硬编码）

    func fetchHome() async -> [MysteryMovieVideo] {
        do {
            let html = try await fetchHTML(url: host)
            guard let doc = try? HTML(html: html, encoding: .utf8) else { return [] }
            return parseVideos(doc: doc)
        } catch {
            print("[MysteryMovie] fetchHome error: \(error)")
            return []
        }
    }

    // MARK: - 分类列表（分页）

    func fetchCategoryList(tid: String, page: Int) async -> [MysteryMovieVideo] {
        do {
            let url: String
            if page == 1 {
                url = "\(host)/list/\(tid).html"
            } else {
                url = "\(host)/list/\(tid)/\(page).html"
            }
            let html = try await fetchHTML(url: url)
            guard let doc = try? HTML(html: html, encoding: .utf8) else { return [] }
            return parseVideos(doc: doc)
        } catch {
            print("[MysteryMovie] fetchCategoryList(tid:\(tid), p:\(page)) error: \(error)")
            return []
        }
    }

    // MARK: - 详情 → M3U8 播放地址

    func fetchDetail(vodId: String) async -> MysteryMovieDetail {
        do {
            let url = (vodId.hasPrefix("http") ? vodId : "\(host)/vid/\(vodId).html")
            let html = try await fetchHTML(url: url)
            guard let doc = try? HTML(html: html, encoding: .utf8) else {
                return MysteryMovieDetail(playFrom: "神秘线路", playUrl: "",
                                          content: "解析失败")
            }

            // 提取 vid
            let vid: String
            if let m = firstMatch(pattern: #"/vid/(\d+)"#, in: url) {
                vid = m
            } else {
                vid = vodId
            }

            // 标题
            var title = titleCache[vid]
            if title == nil {
                if let titleTag = doc.css("title").first?.text {
                    title = re.sub(#"\s*[-_|]\s*.{0,20}$"#, with: "",
                                  in: titleTag.trimmingCharacters(in: .whitespaces))
                }
                if title == nil || (title?.count ?? 0) < 5 {
                    for sel in ["h1", "h2", ".video-title", ".title"] {
                        if let el = doc.css(sel).first,
                           let txt = el.text?.trimmingCharacters(in: .whitespaces),
                           txt.count > 5 {
                            title = txt
                            break
                        }
                    }
                }
                title = title ?? "视频\(vid)"
                titleCache[vid] = title
            }

            // 简介
            var content = ""
            for sel in [".vodinfo", ".video-info", ".content", ".intro", ".description"] {
                if let el = doc.css(sel).first, let txt = el.text?.trimmingCharacters(in: .whitespaces), !txt.isEmpty {
                    content = txt
                    break
                }
            }

            // M3U8 播放地址
            let playUrl = "\(videoHost)/\(vid)/hls/index.m3u8"

            return MysteryMovieDetail(playFrom: "神秘线路", playUrl: playUrl,
                                      content: content)
        } catch {
            print("[MysteryMovie] fetchDetail(\(vodId)) error: \(error)")
            return MysteryMovieDetail(playFrom: "神秘线路", playUrl: "",
                                      content: "获取失败")
        }
    }

    // MARK: - 搜索

    func search(keyword: String, page: Int = 1) async -> [MysteryMovieVideo] {
        let searchURL = "\(host)/so.html"
        do {
            let enc = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
            let urlWithParams = page == 1
                ? "\(searchURL)?wd=\(enc)"
                : "\(searchURL)?wd=\(enc)&page=\(page)"
            let html = try await fetchHTML(url: urlWithParams)
            guard let doc = try? HTML(html: html, encoding: .utf8) else { return [] }
            return parseVideos(doc: doc)
        } catch {
            // 尝试 POST
            do {
                var req = request(url: searchURL)
                req.httpMethod = "POST"
                let bodyStr = "wd=\(keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword)"
                if page > 1 { /* 有些站点不支持 page post */ }
                req.httpBody = bodyStr.data(using: .utf8)
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                let (data, _) = try await session.data(for: req)
                guard let html = String(data: data, encoding: .utf8),
                      let doc = try? HTML(html: html, encoding: .utf8) else { return [] }
                return parseVideos(doc: doc)
            } catch {
                print("[MysteryMovie] search(\(keyword), p\(page)) error: \(error)")
                return []
            }
        }
    }

    // MARK: - 私有工具

    private var session: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }

    private func request(url: String) -> URLRequest {
        guard let u = URL(string: url) else {
            fatalError("Invalid URL: \(url)")
        }
        var req = URLRequest(url: u)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    private func fetchHTML(url: String) async throws -> String {
        let (data, response) = try await session.data(for: request(url: url))
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            throw NSError(domain: "MysteryMovie", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \( (response as? HTTPURLResponse)?.statusCode ?? -1)"])
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "MysteryMovie", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "编码错误"])
        }
        return html
    }

    // MARK: - 视频列表解析

    private func parseVideos(doc: HTMLDocument) -> [MysteryMovieVideo] {
        var videos: [MysteryMovieVideo] = []
        let selectors = [".vodbox", ".stui-vodlist__box", ".vodlist__box", ".video-card", ".item"]

        for sel in selectors {
            let items = doc.css(sel)
            if !items.isEmpty {
                for el in items {
                    if let video = parseCard(el) {
                        videos.append(video)
                    }
                }
                break
            }
        }

        // 回退：直接用正则从 HTML 中提取 /vid/ 链接
        if videos.isEmpty {
            if let html = doc.toHTML {
                let pattern = #"/vid/(\d+)\.html"#
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let nsRange = NSRange(html.startIndex..., in: html)
                    regex.enumerateMatches(in: html, range: nsRange) { match, _, stop in
                        guard let match = match,
                              let r = Range(match.range(at: 1), in: html) else { return }
                        let vid = String(html[r])
                        if !videos.contains(where: { $0.vodId == vid }) {
                            videos.append(MysteryMovieVideo(
                                vodId: vid, title: "未知标题",
                                cover: imageURL("\(imageHost)/\(vid).jpg"),
                                remarks: ""
                            ))
                        }
                        if videos.count >= 30 { stop.pointee = true }
                    }
                }
            }
        }

        return videos
    }

    /// 解析单个视频卡片
    private func parseCard(_ el: XMLElement) -> MysteryMovieVideo? {
        // 找 <a> 链接
        let anchor: XMLElement?
        if el.tagName == "a" {
            anchor = el
        } else {
            anchor = el.css("a").first
        }
        guard let a = anchor, let href = a["href"], !href.isEmpty else { return nil }

        // 提取 vid
        guard let vid = firstMatch(pattern: #"/vid/(\d+)"#, in: href) else { return nil }

        let fullHref = href.hasPrefix("/") ? "\(host)\(href)" : href

        // 标题解密
        var title = ""
        if let p = el.css("p").first {
            if let script = p.css("script").first, let js = script.text {
                title = Self.decryptFromJS(js)
            }
            if title.isEmpty {
                title = p.text?.trimmingCharacters(in: .whitespaces) ?? ""
            }
        }

        // 尝试 data- 属性解密
        if title.isEmpty {
            for attr in ["data-title", "data-name", "title"] {
                if let val = el[attr], !val.isEmpty {
                    let dec = Self.decrypt(val)
                    if dec.count > 3 {
                        title = dec
                        break
                    }
                }
            }
        }

        title = title.isEmpty ? "未知标题" : title
        if title != "未知标题" {
            titleCache[vid] = title
        }

        // 图片
        var img = ""
        if let imgNode = el.css("img").first {
            img = imgNode["data-src"] ?? imgNode["src"] ?? ""
        }
        if img.isEmpty {
            img = "\(imageHost)/\(vid).jpg"
        }

        // 备注
        var remarks = ""
        for sel in [".pic-text", ".remarks", ".duration", "time", ".score"] {
            if let t = el.css(sel).first?.text?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
                remarks = t
                break
            }
        }

        return MysteryMovieVideo(
            vodId: vid,
            title: title,
            cover: imageURL(img),
            remarks: remarks
        )
    }

    /// 返回图片代理 URL（用于 AsyncImage 加载，绕过被墙域名）
    func proxyImageURL(_ url: String) -> String {
        guard !url.isEmpty, !url.hasPrefix("data:") else { return url }
        // ybox.vip 图片代理
        return "https://ybox.vip/image?url=\(url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url)"
    }

    // MARK: - 正则工具

    private func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}

// MARK: - 简易 re.sub 辅助（标题清洗）

private struct re {
    static func sub(_ pattern: String, with replacement: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
