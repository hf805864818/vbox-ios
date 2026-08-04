import Foundation

// MARK: - 艾旦福利套图
/// 对应远端 welfare_platforms.json 中 platformKey = aidan_comic。
/// 基于 CMS V10 API，自适应分类，只展示无 vod_play_url 的图片/套图类条目。
class AidanComicService: FuliBaseService {
    static let shared = AidanComicService()

    private let helper = CMSV10Helper.shared
    private let contentType: CMSV10ContentType = .comic

    init() {
        super.init(
            platformName: "艾旦福利套图",
            defaultHosts: ["https://www.lovedan.net"]
        )
    }

    // MARK: - 内容类型
    override var contentCategory: FuliContentCategory { .comic }

    // MARK: - 请求头
    func defaultHeaders(host: String) -> [String: String] {
        [
            "User-Agent": "Mozilla/5.0",
            "Referer": "\(host)/"
        ]
    }

    // MARK: - API 地址
    private var apiBase: String { "\(currentHost)/api.php/provide/vod/" }

    // MARK: - 首页分类 + 推荐
    override func fetchHomeContent() async -> FuliHomeResult {
        await ensureHostReady()
        do {
            let data = try await fetchJSON("\(apiBase)?ac=list")
            let categories = helper.parseClasses(from: data)

            var videos: [FuliVideo] = []
            if let first = categories.first {
                let listData = try await fetchJSON("\(apiBase)?ac=detail&t=\(first.typeId)&pg=1")
                videos = parseComicList(from: listData)
            }
            return FuliHomeResult(categories: categories, videos: videos)
        } catch {
            print("[艾旦福利套图] 首页失败: \(error)")
            return .empty
        }
    }

    // MARK: - 分类内容
    override func fetchCategoryContent(category: FuliCategory, subCategory: FuliCategory?, page: Int) async -> FuliCategoryResult {
        await ensureHostReady()
        let tid = subCategory?.typeId ?? category.typeId
        do {
            let data = try await fetchJSON("\(apiBase)?ac=detail&t=\(tid)&pg=\(page)")
            let videos = parseComicList(from: data)
            return FuliCategoryResult(videos: videos, page: page, hasMore: videos.count >= 20)
        } catch {
            print("[艾旦福利套图] 分类失败: \(error)")
            return FuliCategoryResult(videos: [], page: page, hasMore: false)
        }
    }

    // MARK: - 详情
    override func fetchDetail(vodId: String) async -> FuliDetail {
        await ensureHostReady()
        do {
            let data = try await fetchJSON("\(apiBase)?ac=detail&ids=\(vodId)")
            if let list = data["list"] as? [[String: Any]],
               let item = list.first,
               let detail = helper.parseDetail(item, host: currentHost, contentType: contentType) {
                return detail
            }
        } catch {
            print("[艾旦福利套图] 详情失败: \(error)")
        }
        return FuliDetail(vodId: vodId, vodName: "", vodPic: "", vodContent: nil, playFrom: platformName, episodes: [])
    }

    // MARK: - 搜索
    override func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        await ensureHostReady()
        do {
            let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let data = try await fetchJSON("\(apiBase)?ac=detail&wd=\(encoded)&pg=\(page)")
            let videos = parseComicList(from: data)
            return FuliSearchResult(videos: videos, page: page, hasMore: videos.count >= 20)
        } catch {
            print("[艾旦福利套图] 搜索失败: \(error)")
            return FuliSearchResult(videos: [], page: page, hasMore: false)
        }
    }

    // MARK: - 播放地址（漫画不需要，直接返回空）
    override func fetchPlayerURL(episode: FuliEpisode) async -> FuliPlayerResult {
        FuliPlayerResult(url: "", headers: [:], parse: 0)
    }

    // MARK: - 私有辅助
    private func parseComicList(from json: [String: Any]) -> [FuliVideo] {
        guard let list = json["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard helper.isItemAllowed(item),
                  helper.matchesContentType(item, type: contentType) else { return nil }
            return helper.parseVideoItem(item, host: currentHost)
        }
    }

    private func fetchJSON(_ urlString: String) async throws -> [String: Any] {
        let data = try await fetchData(urlString)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return json
    }
}
