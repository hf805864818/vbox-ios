import Foundation
import Kanna

// MARK: - 香肠派对服务
// 对应 Python 香肠派对脚本
// host: https://xiang512.xiang.party/xcpd
// 分类: /vodtype/{tid}-{page}.html
// 详情: /voddetail/{vid}.html
// 播放: /vodplay/{vid}.html
// 播放地址从 player_aaaa JSON 或 iframe 中提取

// MARK: - 数据模型

struct XCPCategory: Identifiable {
    var id: String { typeId }
    let name: String
    let typeId: String
}

struct XCPVideo: Identifiable, Equatable {
    var id: String { vodId }
    let vodId: String
    let title: String
    let cover: String
    let remarks: String
}

struct XCPPlaySource {
    let name: String
    let episodes: [XCPEpisode]
}

struct XCPEpisode: Identifiable {
    var id: String { name }
    let name: String
    let playURL: String  // 直接的播放页面 URL（非播放地址）
}

// MARK: - 服务

class XCPService: ObservableObject {
    static let shared = XCPService()

    private let defaultHost = "https://xiang512.xiang.party/xcpd"

    private var currentHost: String {
        let customs = WelfareDomainStore.shared.domains(for: "香肠派对")
        return customs.first ?? defaultHost
    }

    let categories: [XCPCategory] = [
        XCPCategory(name: "在线看片", typeId: "1"),
        XCPCategory(name: "无需等待", typeId: "2"),
        XCPCategory(name: "不用下载", typeId: "3"),
        XCPCategory(name: "全部免费", typeId: "4"),
    ]

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"
        ]
        return URLSession(configuration: c)
    }()

    private func request(url: String) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue(currentHost, forHTTPHeaderField: "Referer")
        return req
    }

    // MARK: - 分类视频列表（Python categoryContent）

    func fetchCategory(typeId: String, page: Int = 1) async -> (videos: [XCPVideo], pageCount: Int) {
        let host = currentHost
        let url = "\(host)/vodtype/\(typeId)-\(page).html"
        do {
            let (data, response) = try await session.data(for: request(url: url))
            guard let httpResp = response as? HTTPURLResponse,
                  (200...299).contains(httpResp.statusCode),
                  let html = String(data: data, encoding: .utf8),
                  let doc = try? HTML(html: html, encoding: .utf8) else {
                return ([], 1)
            }

            // 提取总页数
            var pageCount = page
            if let fullHTML = doc.toHTML ?? doc.text,
               let pageInfo = fullHTML.range(of: "/(\\d+)页", options: .regularExpression) {
                let pageStr = String(fullHTML[pageInfo]).replacingOccurrences(of: "页", with: "")
                if let num = Int(pageStr.replacingOccurrences(of: "/", with: "")) {
                    pageCount = num
                }
            }

            var videos: [XCPVideo] = []
            for li in doc.xpath("//ul[@class='thumbnail-group clearfix']/li") {
                guard let a = li.xpath(".//a[@class='thumbnail']").first,
                      let href = a["href"],
                      !href.isEmpty else { continue }

                let vodId = extractVodId(from: href)
                guard !vodId.isEmpty else { continue }

                let img = li.xpath(".//img").first
                let pic = img?["src"] ?? ""

                let title: String
                let remarks: String
                if let info = li.xpath(".//div[@class='video-info']").first {
                    let h5 = info.xpath(".//h5/a").first
                    title = h5?["title"] ?? (h5?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if title.isEmpty { title = a["title"] ?? "" }
                    let p = info.xpath(".//p").first
                    remarks = (p?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    title = a["title"] ?? ""
                    remarks = ""
                }

                videos.append(XCPVideo(vodId: vodId, title: title, cover: pic, remarks: remarks))
            }
            print("[XCP] fetchCategory(\(typeId), p\(page)): \(videos.count) videos, pageCount=\(pageCount)")
            return (videos, pageCount)
        } catch {
            print("[XCP] fetchCategory error: \(error)")
            return ([], 1)
        }
    }

    // MARK: - 详情页播放源（Python detailContent）

    func fetchDetail(vodId: String) async -> (title: String, cover: String, sources: [XCPPlaySource]) {
        let host = currentHost
        let url = "\(host)/voddetail/\(vodId).html"
        do {
            let (data, response) = try await session.data(for: request(url: url))
            guard let httpResp = response as? HTTPURLResponse,
                  (200...299).contains(httpResp.statusCode),
                  let html = String(data: data, encoding: .utf8),
                  let doc = try? HTML(html: html, encoding: .utf8) else {
                return ("", "", [])
            }

            // 标题
            let title: String
            if let h1 = doc.xpath("//h1[@class='appel-title']").first, let t = h1.text {
                title = t.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                title = "视频详情"
            }

            // 封面
            let cover = doc.xpath("//img[@class='appel-img']").first?["src"]
                ?? doc.xpath("//div[@class='detail-poster']//img").first?["src"]
                ?? ""

            // 播放列表
            var sources: [XCPPlaySource] = []

            let tabs = doc.xpath("//div[@class='detail-tab']//li//a")
            let playBlocks = doc.xpath("//ul[@class='detail-play-list']")

            for (i, block) in playBlocks.enumerated() {
                let lineName = i < tabs.count
                    ? (tabs[i].text ?? "线路\(i+1)").trimmingCharacters(in: .whitespacesAndNewlines)
                    : "线路\(i+1)"
                var episodes: [XCPEpisode] = []
                for a in block.xpath(".//a") {
                    let epName = (a.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let epHref = a["href"] ?? ""
                    if !epHref.isEmpty {
                        let fullURL = epHref.hasPrefix("http") ? epHref : "\(host)\(epHref)"
                        episodes.append(XCPEpisode(name: epName.isEmpty ? "第\(episodes.count+1)集" : epName, playURL: fullURL))
                    }
                }
                if !episodes.isEmpty {
                    sources.append(XCPPlaySource(name: lineName, episodes: episodes))
                }
            }

            // 备用选择器
            if sources.isEmpty {
                let altTabs = doc.xpath("//div[@class='ff-playurl-tab']//li//a")
                let altPanes = doc.xpath("//div[@class='ff-playurl-tab-pane']")
                for (i, pane) in altPanes.enumerated() {
                    let lineName = i < altTabs.count
                        ? (altTabs[i].text ?? "线路\(i+1)").trimmingCharacters(in: .whitespacesAndNewlines)
                        : "线路\(i+1)"
                    var episodes: [XCPEpisode] = []
                    for a in pane.xpath(".//a") {
                        let epName = (a.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let epHref = a["href"] ?? ""
                        if !epHref.isEmpty {
                            let fullURL = epHref.hasPrefix("http") ? epHref : "\(host)\(epHref)"
                            episodes.append(XCPEpisode(name: epName.isEmpty ? "第\(episodes.count+1)集" : epName, playURL: fullURL))
                        }
                    }
                    if !episodes.isEmpty {
                        sources.append(XCPPlaySource(name: lineName, episodes: episodes))
                    }
                }
            }

            if sources.isEmpty {
                sources.append(XCPPlaySource(name: "默认", episodes: [
                    XCPEpisode(name: "第1集", playURL: "\(host)/vodplay/\(vodId).html")
                ]))
            }

            print("[XCP] fetchDetail(\(vodId)): title=\(title), \(sources.count) sources")
            return (title, cover, sources)
        } catch {
            print("[XCP] fetchDetail error: \(error)")
            return ("", "", [])
        }
    }

    // MARK: - 播放地址解析（Python playerContent）

    func fetchPlayURL(playPageURL: String) async -> String? {
        let host = currentHost
        do {
            let (data, response) = try await session.data(for: request(url: playPageURL))
            guard let httpResp = response as? HTTPURLResponse,
                  (200...299).contains(httpResp.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                return nil
            }

            // 方法1：var player_aaaa = {...}
            let p1 = "var\\s+player_aaaa\\s*=\\s*(\\{.*?\\});"
            if let regex = try? NSRegularExpression(pattern: p1, options: [.dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)),
               let range = Range(match.range(at: 1), in: html) {
                var jsonStr = String(html[range])
                // 修复 JS 属性名（无引号 key）
                jsonStr = jsonStr.replacingOccurrences(of: "(\", with: "\"")
                if let jsonData = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let videoURL = json["url"] as? String {
                    let cleaned = videoURL.replacingOccurrences(of: "\\/", with: "/")
                    print("[XCP] fetchPlayURL from player_aaaa: \(cleaned.prefix(80))...")
                    return cleaned
                }
            }

            // 方法2：iframe #playleft 中的 url 参数
            let p2 = "<td[^>]*id=\"playleft\"[^>]*>.*?<iframe[^>]+src=\"([^\"]+)\""
            if let regex = try? NSRegularExpression(pattern: p2, options: [.dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)),
               let range = Range(match.range(at: 1), in: html) {
                let iframeSrc = String(html[range])
                let m3u8 = extractM3U8(from: iframeSrc)
                if !m3u8.isEmpty { return m3u8 }
            }

            // 方法3：直接 iframe
            let p3 = "<iframe[^>]+src=\"([^\"]+)\""
            if let regex = try? NSRegularExpression(pattern: p3, options: []),
               let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)),
               let range = Range(match.range(at: 1), in: html) {
                let iframeSrc = String(html[range])
                let m3u8 = extractM3U8(from: iframeSrc)
                if !m3u8.isEmpty { return m3u8 }
            }

            // 方法4：直接查找 m3u8
            let p4 = "https?://[^\"'\\s]+\\.m3u8[^\"'\\s]*"
            if let regex = try? NSRegularExpression(pattern: p4, options: []),
               let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)),
               let range = Range(match.range, in: html) {
                let m3u8 = String(html[range])
                print("[XCP] fetchPlayURL direct m3u8: \(m3u8.prefix(80))...")
                return m3u8
            }

            print("[XCP] fetchPlayURL: 未找到播放地址")
            return nil
        } catch {
            print("[XCP] fetchPlayURL error: \(error)")
            return nil
        }
    }

    // MARK: - 辅助方法

    private func extractVodId(from href: String) -> String {
        // 匹配 /voddetail/123 或 /vodplay/123
        let pattern = "/vod(?:detail|play)/(\\d+)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: href, range: NSRange(location: 0, length: href.utf16.count)),
           let range = Range(match.range(at: 1), in: href) {
            return String(href[range])
        }
        return ""
    }

    private func extractM3U8(from iframeSrc: String) -> String {
        // 提取 ?url=xxx 或 &url=xxx 参数
        let urlPattern = "[?&]url=([^&]+)"
        if let regex = try? NSRegularExpression(pattern: urlPattern, options: []),
           let match = regex.firstMatch(in: iframeSrc, range: NSRange(location: 0, length: iframeSrc.utf16.count)),
           let range = Range(match.range(at: 1), in: iframeSrc) {
            let encoded = String(iframeSrc[range])
            if let decoded = encoded.removingPercentEncoding {
                print("[XCP] fetchPlayURL from iframe url param: \(decoded.prefix(80))...")
                return decoded
            }
            return encoded
        }
        // iframe 本身就是 m3u8
        if iframeSrc.contains(".m3u8") {
            print("[XCP] fetchPlayURL iframe is m3u8: \(iframeSrc.prefix(80))...")
            return iframeSrc
        }
        return ""
    }
}