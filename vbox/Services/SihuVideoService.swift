import Foundation
import Kanna

// MARK: - 四虎视频服务
// 对应 Python 四虎视频脚本
// baseUrl: https://www.sihuhu.xyz
// 分类页面: /vod/type/id/{tid}/page/{pg}.html
// 详情页面: /vod/detail/id/{tid}.html
// 播放页面: /vod/play/id/{tid}/sid/{sid}/nid/{nid}.html

// MARK: - 数据模型

struct SihuCategory: Identifiable {
    var id: String { typeId }
    let name: String
    let typeId: String
}

struct SihuVideo: Identifiable, Equatable {
    var id: String { vodId }
    let vodId: String
    let title: String
    let cover: String
    let remarks: String
}

struct SihuPlaySource {
    let name: String      // 播放源名称（如 "默认"）
    let episodes: [SihuEpisode]
}

struct SihuEpisode: Identifiable {
    var id: String { name }
    let name: String
    let playPath: String   // 播放页面路径，如 /vod/play/id/123/sid/1/nid/1.html
}

// MARK: - 服务

class SihuVideoService: ObservableObject {
    static let shared = SihuVideoService()

    private let defaultBaseURL = "https://www.sihuhu.xyz"

    /// 当前生效的 baseURL
    var currentBaseURL: String {
        let customs = WelfareDomainStore.shared.domains(for: "四虎视频")
        return customs.first ?? defaultBaseURL
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.110 Safari/537.36"
        ]
        return URLSession(configuration: c)
    }()

    /// 获取请求（带 Referer）
    private func request(url: String) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue(currentBaseURL, forHTTPHeaderField: "Referer")
        return req
    }

    // MARK: - 分类列表（Python homeContent）

    let categories: [SihuCategory] = [
        SihuCategory(name: "传媒厂商", typeId: "20"),
        SihuCategory(name: "麻豆传媒", typeId: "21"),
        SihuCategory(name: "91制片", typeId: "22"),
        SihuCategory(name: "蜜桃传媒", typeId: "23"),
        SihuCategory(name: "天美传媒", typeId: "24"),
        SihuCategory(name: "精东影片", typeId: "25"),
        SihuCategory(name: "星空传媒", typeId: "26"),
        SihuCategory(name: "葫芦影业", typeId: "27"),
        SihuCategory(name: "糖心VLOG", typeId: "28"),
        SihuCategory(name: "精品推荐", typeId: "29"),
        SihuCategory(name: "日本无码", typeId: "30"),
        SihuCategory(name: "日本有码", typeId: "31"),
        SihuCategory(name: "AV解说", typeId: "32"),
        SihuCategory(name: "中文有码", typeId: "33"),
        SihuCategory(name: "中文无码", typeId: "34"),
        SihuCategory(name: "日韩极品", typeId: "35"),
        SihuCategory(name: "日韩无码", typeId: "36"),
        SihuCategory(name: "少女萝莉", typeId: "37"),
        SihuCategory(name: "水嫩萝莉", typeId: "38"),
        SihuCategory(name: "国产大作", typeId: "39"),
        SihuCategory(name: "极品主播", typeId: "40"),
        SihuCategory(name: "欧美萝莉", typeId: "41"),
        SihuCategory(name: "嫩逼乌鸡", typeId: "42"),
        SihuCategory(name: "卡通动漫", typeId: "43"),
        SihuCategory(name: "SM调教", typeId: "44"),
        SihuCategory(name: "三级伦理", typeId: "45"),
        SihuCategory(name: "萝莉互口", typeId: "46"),
        SihuCategory(name: "嫩女网爆", typeId: "47"),
        SihuCategory(name: "黑料网爆", typeId: "48"),
        SihuCategory(name: "热门事件", typeId: "49"),
        SihuCategory(name: "探花合集", typeId: "50"),
        SihuCategory(name: "91大神", typeId: "51"),
        SihuCategory(name: "野战车震", typeId: "52"),
        SihuCategory(name: "萝莉黑瓜", typeId: "53"),
        SihuCategory(name: "台湾萝莉", typeId: "54"),
        SihuCategory(name: "萝莉传媒", typeId: "55"),
        SihuCategory(name: "萝莉抠逼", typeId: "56"),
        SihuCategory(name: "白虎口爆", typeId: "57"),
        SihuCategory(name: "萝莉巨乳", typeId: "58"),
        SihuCategory(name: "少女3P", typeId: "59"),
        SihuCategory(name: "偷拍萝莉", typeId: "60"),
        SihuCategory(name: "强奸少女", typeId: "61"),
        SihuCategory(name: "重口猎奇", typeId: "62"),
        SihuCategory(name: "制服萝控", typeId: "63"),
        SihuCategory(name: "极品少女", typeId: "64"),
        SihuCategory(name: "明星爆料", typeId: "65"),
        SihuCategory(name: "X短视频", typeId: "66"),
        SihuCategory(name: "AV明星", typeId: "67"),
        SihuCategory(name: "极品萝莉", typeId: "68"),
        SihuCategory(name: "人妻艹妈", typeId: "69"),
        SihuCategory(name: "VR视角", typeId: "70"),
        SihuCategory(name: "角色扮演", typeId: "71"),
        SihuCategory(name: "男同男娘", typeId: "72"),
        SihuCategory(name: "明星换脸", typeId: "73"),
    ]

    // MARK: - 分类视频列表（Python categoryContent）

    func fetchCategory(typeId: String, page: Int = 1) async -> [SihuVideo] {
        let baseURL = currentBaseURL
        let url = "\(baseURL)/vod/type/id/\(typeId)/page/\(page).html"
        do {
            let (data, response) = try await session.data(for: request(url: url))
            guard let httpResp = response as? HTTPURLResponse,
                  (200...299).contains(httpResp.statusCode),
                  let html = String(data: data, encoding: .utf8),
                  let doc = try? HTML(html: html, encoding: .utf8) else {
                print("[SihuVideo] fetchCategory HTTP error or parse error")
                return []
            }

            var videos: [SihuVideo] = []
            for li in doc.xpath("//ul[@class='thumbnail-group clearfix']/li") {
                guard let title = li.xpath(".//h5/a/text()").first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty else { continue }

                let cover = li.xpath(".//img/@data-original").first?.text ?? ""
                let fullCover = cover.hasPrefix("http") ? cover : "\(baseURL)\(cover)"

                let href = li.xpath(".//a[@class='thumbnail']/@href").first?.text ?? ""
                let vodId = href.components(separatedBy: "/").last?.replacingOccurrences(of: ".html", with: "") ?? ""

                let remark = li.xpath(".//span[@class='title']/text()").first?.text ?? ""

                videos.append(SihuVideo(vodId: vodId, title: title, cover: fullCover, remarks: remark))
            }
            print("[SihuVideo] fetchCategory(\(typeId), p\(page)): \(videos.count) 个视频")
            return videos
        } catch {
            print("[SihuVideo] fetchCategory error: \(error)")
            return []
        }
    }

    // MARK: - 详情页播放源（Python detailContent）

    func fetchDetail(vodId: String) async -> [SihuPlaySource] {
        let baseURL = currentBaseURL
        let url = "\(baseURL)/vod/detail/id/\(vodId).html"
        do {
            let (data, response) = try await session.data(for: request(url: url))
            guard let httpResp = response as? HTTPURLResponse,
                  (200...299).contains(httpResp.statusCode),
                  let html = String(data: data, encoding: .utf8),
                  let doc = try? HTML(html: html, encoding: .utf8) else {
                print("[SihuVideo] fetchDetail parse error")
                return []
            }

            var sources: [SihuPlaySource] = []

            // 方式1：从 module-play-list 提取
            let playDivs = doc.xpath("//div[@class='module-play-list']/div")
            for div in playDivs {
                let sourceName = div.xpath(".//span/text()").first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "默认"
                var episodes: [SihuEpisode] = []
                for a in div.xpath(".//a") {
                    let epName = a.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let epHref = a["href"] ?? ""
                    if !epName.isEmpty && !epHref.isEmpty {
                        episodes.append(SihuEpisode(name: epName, playPath: epHref))
                    }
                }
                if !episodes.isEmpty {
                    sources.append(SihuPlaySource(name: sourceName, episodes: episodes))
                }
            }

            // 方式2：如果没找到，用默认播放路径
            if sources.isEmpty {
                sources.append(SihuPlaySource(name: "默认", episodes: [
                    SihuEpisode(name: "第1集", playPath: "/vod/play/id/\(vodId)/sid/1/nid/1.html")
                ]))
            }

            print("[SihuVideo] fetchDetail(\(vodId)): \(sources.count) 个播放源")
            return sources
        } catch {
            print("[SihuVideo] fetchDetail error: \(error)")
            return []
        }
    }

    // MARK: - 播放地址解析（Python playerContent）

    func fetchPlayURL(playPath: String) async -> String? {
        let baseURL = currentBaseURL
        let fullURL = playPath.hasPrefix("http") ? playPath : "\(baseURL)\(playPath)"

        // 如果已经是 m3u8/mp4 直接返回
        if fullURL.hasSuffix(".m3u8") || fullURL.hasSuffix(".mp4") {
            return fullURL
        }

        do {
            let (data, response) = try await session.data(for: request(url: fullURL))
            guard let httpResp = response as? HTTPURLResponse,
                  (200...299).contains(httpResp.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                print("[SihuVideo] fetchPlayURL HTTP error")
                return nil
            }

            // 方法1：提取 var player_aaaa = {...}
            let pattern1 = "var\\s+player_aaaa\\s*=\\s*(\\{.*?\\});"
            if let regex = try? NSRegularExpression(pattern: pattern1, options: [.dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)),
               let range = Range(match.range(at: 1), in: html) {
                let jsonStr = String(html[range])
                if let jsonData = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let videoURL = json["url"] as? String {
                    let cleaned = videoURL.replacingOccurrences(of: "\\/", with: "/")
                    print("[SihuVideo] fetchPlayURL from player_aaaa: \(cleaned.prefix(80))...")
                    return cleaned
                }
            }

            // 方法2：提取 "url":"..." 模式
            let patterns = [
                "\"url\"\\s*:\\s*\"([^\"]+)\"",
                "'url'\\s*:\\s*'([^']+)'",
                "\"video_url\"\\s*:\\s*\"([^\"]+)\""
            ]
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: []),
                   let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)),
                   let range = Range(match.range(at: 1), in: html) {
                    let videoURL = String(html[range]).replacingOccurrences(of: "\\/", with: "/")
                    if videoURL.contains("m3u8") || videoURL.contains("mp4") {
                        print("[SihuVideo] fetchPlayURL from regex: \(videoURL.prefix(80))...")
                        return videoURL
                    }
                }
            }

            // 方法3：提取 iframe src 并递归
            let iframePattern = "<iframe[^>]+src=\"([^\"]+)\""
            if let regex = try? NSRegularExpression(pattern: iframePattern, options: []),
               let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)),
               let range = Range(match.range(at: 1), in: html) {
                var iframeSrc = String(html[range])
                if iframeSrc.hasPrefix("//") { iframeSrc = "https:" + iframeSrc }
                else if iframeSrc.hasPrefix("/") { iframeSrc = baseURL + iframeSrc }
                print("[SihuVideo] fetchPlayURL iframe: \(iframeSrc)")
                return await fetchPlayURL(playPath: iframeSrc)
            }

            // 方法4：暴力查找所有 m3u8/mp4 URL
            let m3u8Pattern = ##"https?://[^"'\s]+\.(?:m3u8|mp4)[^"'\s]*"##
            if let regex = try? NSRegularExpression(pattern: m3u8Pattern, options: []),
               let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)),
               let range = Range(match.range, in: html) {
                let url = String(html[range])
                print("[SihuVideo] fetchPlayURL brute force: \(url.prefix(80))...")
                return url
            }

            // 方法5：从 script 标签中提取 m3u8
            let scriptPattern = "<script[^>]*>([\\s\\S]*?)</script>"
            if let regex = try? NSRegularExpression(pattern: scriptPattern, options: [.dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)),
               let range = Range(match.range(at: 1), in: html) {
                let scriptContent = String(html[range])
                let m3u8InScript = ##"https?://[^"'\s]*\.m3u8[^"'\s]*"##
                if let r2 = try? NSRegularExpression(pattern: m3u8InScript, options: []),
                   let m2 = r2.firstMatch(in: scriptContent, range: NSRange(location: 0, length: scriptContent.utf16.count)),
                   let ur = Range(m2.range, in: scriptContent) {
                    let url = String(scriptContent[ur])
                    print("[SihuVideo] fetchPlayURL from script: \(url.prefix(80))...")
                    return url
                }
            }

            print("[SihuVideo] fetchPlayURL: 所有方法均未找到播放地址")
            return nil
        } catch {
            print("[SihuVideo] fetchPlayURL error: \(error)")
            return nil
        }
    }
}