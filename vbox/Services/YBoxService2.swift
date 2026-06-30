import Foundation

// MARK: - 数据模型（保留原名避免冲突）
struct YBoxCategory2: Identifiable {
    var id: String { name }
    let name: String
    let platforms: [YBoxPlatform2]
}

struct YBoxPlatform2: Identifiable {
    var id: String { name }
    let name: String
    let icon: String
    let type: PlatformType2
    let baseURL: String
    let desc: String

    enum PlatformType2: String {
        case video, live, comic, audio
    }
}

struct YBoxVideoItem2: Identifiable {
    var id: String { vodId }
    let vodId: String
    let title: String
    let cover: String
    let duration: String?
    let score: String?
    let playUrl: String?
    let category: String?
}

struct YBoxLiveItem2: Identifiable {
    var id: String { title }
    let title: String
    let img: String
    let number: String
    let channels: [YBoxLiveChannel2]
}

struct YBoxLiveChannel2: Identifiable {
    var id: String { title }
    let title: String
    let address: String
    let img: String
}

struct YBoxComicItem2: Identifiable {
    var id: String { title }
    let title: String
    let cover: String
    let href: String?
}

// MARK: - YBox 服务 (2)
class YBoxService2: ObservableObject {
    static let shared = YBoxService2()

    @Published var categories: [YBoxCategory2] = []
    @Published var liveSources: [YBoxLiveItem2] = []
    @Published var isLiveLoaded = false

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    init() { buildCategories() }

    private func buildCategories() {
        categories = [
            YBoxCategory2(name: "视频", platforms: [
                YBoxPlatform2(name: "香蕉秀", icon: "leaf.fill", type: .video,
                             baseURL: "https://zfvwi8.ipajx0.cc", desc: "短视频/长视频"),
                YBoxPlatform2(name: "幻想次元", icon: "sparkles", type: .video,
                             baseURL: "https://zfvwi8.ipajx0.cc", desc: "二次元角色扮演"),
                YBoxPlatform2(name: "午夜寻欢", icon: "moon.stars.fill", type: .video,
                             baseURL: "https://zfvwi8.ipajx0.cc", desc: "夜间精彩"),
                YBoxPlatform2(name: "绿帽淫妻", icon: "heart.slash.fill", type: .video,
                             baseURL: "https://zfvwi8.ipajx0.cc", desc: "专题视频"),
                YBoxPlatform2(name: "1080视频", icon: "play.rectangle.fill", type: .video,
                             baseURL: "https://1080.hlkjsm.com", desc: "综合视频站"),
                YBoxPlatform2(name: "BYFM有声", icon: "headphones", type: .audio,
                             baseURL: "https://api.byfm2.app", desc: "有声小说50类"),
            ]),
            YBoxCategory2(name: "直播", platforms: [
                YBoxPlatform2(name: "卫视直播", icon: "tv.fill", type: .live,
                             baseURL: "http://api.hclyz.com:81/mf", desc: "CCTV/卫视/广播"),
                YBoxPlatform2(name: "蜜桃直播", icon: "flame.fill", type: .live,
                             baseURL: "http://api.hclyz.com:81/mf", desc: "娱乐直播"),
                YBoxPlatform2(name: "卡哇伊", icon: "suit.heart.fill", type: .live,
                             baseURL: "http://api.hclyz.com:81/mf", desc: "才艺互动"),
                YBoxPlatform2(name: "番茄社区", icon: "person.2.fill", type: .live,
                             baseURL: "http://api.hclyz.com:81/mf", desc: "社区直播"),
                YBoxPlatform2(name: "更多直播", icon: "ellipsis.circle.fill", type: .live,
                             baseURL: "http://api.hclyz.com:81/mf", desc: "共136个源"),
            ]),
            YBoxCategory2(name: "漫画", platforms: [
                YBoxPlatform2(name: "18禁漫画", icon: "book.fill", type: .comic,
                             baseURL: "https://www.18akmanhua.com", desc: "日漫/韩漫/同人"),
                YBoxPlatform2(name: "ComicBox", icon: "books.vertical.fill", type: .comic,
                             baseURL: "https://www.comicbox.xyz", desc: "综合漫画站"),
            ]),
        ]
    }

    // MARK: - 香蕉秀
    func fetchBananaSpecials() async -> [YBoxVideoItem2] {
        guard let url = URL(string: "https://zfvwi8.ipajx0.cc/special/listing-0-0-1") else { return [] }
        return await fetchBananaData(url: url, isSpecial: true)
    }

    func fetchBananaMiniVods(page: Int = 1) async -> [YBoxVideoItem2] {
        guard let url = URL(string: "https://zfvwi8.ipajx0.cc/minivod/reqlist?page=\(page)") else { return [] }
        return await fetchBananaData(url: url, isSpecial: false)
    }

    func fetchBananaPlayURL(playPath: String) async -> String? {
        guard let url = URL(string: "https://zfvwi8.ipajx0.cc" + playPath) else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = json["data"] as? [String: Any],
               let u = d["httpurl"] as? String { return u }
        } catch { print("[YBox] 播放地址失败: \(error)") }
        return nil
    }

    private func fetchBananaData(url: URL, isSpecial: Bool) async -> [YBoxVideoItem2] {
        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any] else { return [] }
            var items: [YBoxVideoItem2] = []

            if isSpecial {
                let rows = dataObj["rows"] as? [[String: Any]] ?? []
                for row in rows {
                    for vod in (row["vodrows"] as? [[String: Any]] ?? []) {
                        items.append(YBoxVideoItem2(
                            vodId: String(vod["vodid"] as? Int ?? 0),
                            title: vod["title"] as? String ?? "",
                            cover: vod["coverpic"] as? String ?? "",
                            duration: vod["duration"] as? String,
                            score: vod["scorenum"] as? String,
                            playUrl: vod["play_url"] as? String,
                            category: row["spname"] as? String
                        ))
                    }
                }
            } else {
                for row in (dataObj["rows"] as? [[String: Any]] ?? []) {
                    let vod = row["vodrow"] as? [String: Any] ?? row
                    items.append(YBoxVideoItem2(
                        vodId: String(vod["vodid"] as? Int ?? 0),
                        title: vod["title"] as? String ?? "",
                        cover: vod["coverpic"] as? String ?? "",
                        duration: vod["duration"] as? String,
                        score: vod["scorenum"] as? String,
                        playUrl: vod["play_url"] as? String,
                        category: nil
                    ))
                }
            }
            return items
        } catch { return [] }
    }

    // MARK: - 直播
    func loadLiveSources() async {
        guard !isLiveLoaded else { return }
        do {
            guard let url = URL(string: "http://api.hclyz.com:81/mf/json.txt") else { return }
            let (data, _) = try await session.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pt = json["pingtai"] as? [[String: Any]] else { return }
            var sources: [YBoxLiveItem2] = []
            for item in pt {
                let addr = item["address"] as? String ?? ""
                let channels = await fetchLiveChannels(address: addr)
                sources.append(YBoxLiveItem2(
                    title: item["title"] as? String ?? "",
                    img: item["xinimg"] as? String ?? "",
                    number: item["Number"] as? String ?? "0",
                    channels: channels
                ))
            }
            await MainActor.run { self.liveSources = sources; self.isLiveLoaded = true }
        } catch { print("[YBox] 直播加载失败: \(error)") }
    }

    func fetchLiveChannels(address: String) async -> [YBoxLiveChannel2] {
        guard let url = URL(string: "http://api.hclyz.com:81/mf/" + address) else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            if let zhubo = json["zhubo"] as? [[String: Any]] {
                return zhubo.map { YBoxLiveChannel2(title: $0["title"] as? String ?? "",
                                                     address: $0["address"] as? String ?? "",
                                                     img: $0["img"] as? String ?? "") }
            }
            var chs: [YBoxLiveChannel2] = []
            for (k, v) in json {
                if let s = v as? String, s.hasPrefix("http") {
                    chs.append(YBoxLiveChannel2(title: k, address: s, img: ""))
                }
            }
            return chs
        } catch { return [] }
    }

    // MARK: - 18禁漫画
    func fetch18Comics() async -> [YBoxComicItem2] {
        guard let url = URL(string: "https://www.18akmanhua.com") else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            guard let html = String(data: data, encoding: .utf8) else { return [] }
            var items: [YBoxComicItem2] = []
            // 尝试从HTML提取漫画封面和链接
            let pattern = #"<a[^>]*href="([^"]*)"[^>]*>.*?<img[^>]*src="([^"]*)"[^>]*alt="([^"]*)"#"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                let nsRange = NSRange(html.startIndex..., in: html)
                let matches = regex.matches(in: html, range: nsRange)
                for m in matches.prefix(50) {
                    let href = Range(m.range(at: 1), in: html).map { String(html[$0]) } ?? ""
                    let src = Range(m.range(at: 2), in: html).map { String(html[$0]) } ?? ""
                    let alt = Range(m.range(at: 3), in: html).map { String(html[$0]) } ?? ""
                    if !alt.isEmpty {
                        let cover = src.hasPrefix("http") ? src : "https://www.18akmanhua.com" + src
                        items.append(YBoxComicItem2(title: alt, cover: cover, href: href))
                    }
                }
            }
            return items
        } catch { return [] }
    }
}
