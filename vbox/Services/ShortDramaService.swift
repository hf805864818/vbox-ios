import Foundation
import SwiftUI

/// 短剧源信息
struct ShortDramaSource: Identifiable, Equatable {
    let id: String
    let name: String
    let api: String
    let categoryId: String
    let categoryName: String
    var totalCount: Int = 0
    let sourceType: SourceCategory       // .api 或 .jsSpider
    let engineKey: String?               // JS 蜘蛛源的引擎 key

    static func == (lhs: ShortDramaSource, rhs: ShortDramaSource) -> Bool {
        lhs.id == rhs.id
    }
}

/// 短剧聚合数据服务 - 自动识别所有VOD源中的短剧分类
@MainActor
class ShortDramaService: ObservableObject {
    
    static let shared = ShortDramaService()
    
    @Published var shortDramaSources: [ShortDramaSource] = []
    @Published var dramas: [VodItem] = []
    @Published var isLoading = false
    @Published var currentPage = 1
    @Published var hasMore = true
    @Published var selectedSourceId: String?  // nil = 全部源
    
    private let dramaKeywords = ["短剧", "剧场", "网剧", "微短剧", "爽文短剧", "擦边短剧", "短剧大全"]
    private var isInitialLoading = false
    
    private init() {}
    
    // MARK: - 扫描所有 VOD 源中的短剧分类
    
    func loadInitialIfNeeded(from sites: [SiteConfig], forceRescan: Bool = false) async {
        guard !isInitialLoading else { return }
        if !forceRescan, !shortDramaSources.isEmpty, !dramas.isEmpty { return }

        isInitialLoading = true
        defer { isInitialLoading = false }

        if forceRescan {
            currentPage = 1
            hasMore = true
            dramas = []
        }

        if forceRescan || shortDramaSources.isEmpty {
            await scanShortDramaSources(from: sites)
        }

        if forceRescan || dramas.isEmpty {
            await fetchDramas(refresh: true)
        }
    }

    func scanShortDramaSources(from sites: [SiteConfig]) async {
        shortDramaSources = []
        var seenSourceIds = Set<String>()

        // 收集所有 VOD API 站点
        var checkSites: [(name: String, api: String)] = []
        var seenAPIs = Set<String>()

        for site in sites {
            guard let api = site.api, !api.isEmpty else { continue }
            if api.contains("provide/vod") || api.contains("api.php") {
                guard !seenAPIs.contains(api) else { continue }
                seenAPIs.insert(api)
                checkSites.append((site.name, api))
            }
        }

        // 加上内置兜底源（受 bundleSourcesEnabled 开关控制）
        for fallback in SpiderManager.shared.allFallbackSites {
            guard !seenAPIs.contains(fallback.api) else { continue }
            seenAPIs.insert(fallback.api)
            checkSites.append(fallback)
        }

        let keywords = dramaKeywords
        let maxConcurrent = 12

        isLoading = true
        defer { isLoading = false }

        await withTaskGroup(of: [ShortDramaSource].self) { group in
            var running = 0

            for site in checkSites {
                if running >= maxConcurrent {
                    if let batch = await group.next() {
                        appendShortDramaSources(batch, seenSourceIds: &seenSourceIds)
                    }
                    running -= 1
                }

                running += 1
                group.addTask {
                    await Self.scanAPISource(site: site, dramaKeywords: keywords)
                }
            }

            for await batch in group {
                appendShortDramaSources(batch, seenSourceIds: &seenSourceIds)
            }
        }

        // MARK: - 扫描 JS 蜘蛛源（type:3）的短剧分类
        let spiderManager = SpiderManager.shared
        for site in sites where site.type == 3 {
            let engineKey = site.key.isEmpty ? site.name : site.key
            guard let engine = spiderManager.getEngine(forKey: engineKey) else {
                print("[ShortDrama] JS蜘蛛引擎未加载: \(site.name) (\(engineKey))")
                continue
            }

            let sourceId = "js_\(site.name)_shortdrama"
            guard !seenSourceIds.contains(sourceId) else { continue }
            seenSourceIds.insert(sourceId)

            do {
                let result = try engine.callHomeContent()
                let categories = result.class ?? []
                var batch: [ShortDramaSource] = []

                for cat in categories {
                    let catName = cat.typeName
                    guard dramaKeywords.contains(where: { catName.contains($0) }) else { continue }

                    batch.append(ShortDramaSource(
                        id: "js_\(site.name)_\(cat.typeId)",
                        name: site.name,
                        api: site.api ?? "",
                        categoryId: cat.typeId,
                        categoryName: catName,
                        totalCount: 0,
                        sourceType: .jsSpider,
                        engineKey: engineKey
                    ))
                    print("[ShortDrama] JS蜘蛛源发现短剧分类: \(site.name) → \(catName)(ID=\(cat.typeId))")
                }
                appendShortDramaSources(batch, seenSourceIds: &seenSourceIds)
            } catch {
                print("[ShortDrama] JS蜘蛛扫描失败 \(site.name): \(error.localizedDescription)")
            }
        }

        if !shortDramaSources.isEmpty {
            print("[ShortDrama] ✅ 识别到 \(shortDramaSources.count) 个短剧源:")
            for s in shortDramaSources {
                let typeTag = s.sourceType == .jsSpider ? "[JS]" : "[API]"
                print("  - \(typeTag) \(s.name): \(s.categoryName)(ID=\(s.categoryId)) \(s.totalCount)部")
            }
        }
    }

    private func appendShortDramaSources(_ batch: [ShortDramaSource], seenSourceIds: inout Set<String>) {
        guard !batch.isEmpty else { return }

        var newSources: [ShortDramaSource] = []
        for source in batch {
            guard !seenSourceIds.contains(source.id) else { continue }
            seenSourceIds.insert(source.id)
            newSources.append(source)
        }
        guard !newSources.isEmpty else { return }

        shortDramaSources.append(contentsOf: newSources)
        shortDramaSources.sort { $0.name < $1.name }
    }

    private nonisolated static func scanAPISource(
        site: (name: String, api: String),
        dramaKeywords: [String]
    ) async -> [ShortDramaSource] {
        let baseAPI = site.api.hasSuffix("/") ? String(site.api.dropLast()) : site.api
        let listUrl = "\(baseAPI)?ac=list&pg=1"

        guard let url = URL(string: listUrl) else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let classes = json["class"] as? [[String: Any]] else { return [] }

            var sources: [ShortDramaSource] = []
            for cls in classes {
                let name = cls["type_name"] as? String ?? ""
                let typeId: String
                if let idStr = cls["type_id"] as? String {
                    typeId = idStr
                } else if let idInt = cls["type_id"] as? Int {
                    typeId = "\(idInt)"
                } else {
                    continue
                }

                guard dramaKeywords.contains(where: { name.contains($0) }) else { continue }

                sources.append(ShortDramaSource(
                    id: "\(site.name)_\(typeId)",
                    name: site.name,
                    api: site.api,
                    categoryId: typeId,
                    categoryName: name,
                    totalCount: json["total"] as? Int ?? 0,
                    sourceType: .api,
                    engineKey: nil
                ))
            }
            return sources
        } catch {
            print("[ShortDrama] 扫描失败 \(site.name): \(error.localizedDescription)")
            return []
        }
    }
    
    // MARK: - 获取短剧列表（聚合所有选中源）
    
    func fetchDramas(page: Int = 1, refresh: Bool = false) async {
        let shouldReset = refresh || page <= 1
        if shouldReset {
            currentPage = 1
            hasMore = true
            dramas = []
        }
        
        isLoading = true
        defer { isLoading = false }
        
        let targets: [ShortDramaSource]
        
        if let sourceId = selectedSourceId {
            targets = shortDramaSources.filter { $0.id == sourceId }
        } else {
            targets = shortDramaSources
        }

        guard !targets.isEmpty else {
            hasMore = false
            return
        }

        var seen = Set(dramas.map { $0.vodName })
        var receivedCount = 0

        await withTaskGroup(of: [VodItem].self) { group in
            for source in targets {
                group.addTask {
                    return await self.fetchSourceDramas(source: source, page: page)
                }
            }
            
            for await items in group {
                receivedCount += items.count
                appendDramaItems(items, seenNames: &seen)
            }
        }
        
        hasMore = receivedCount >= targets.count * 20
        currentPage = page
        
        // 拉取缺失的封面图
        fetchMissingCovers()
    }

    private func appendDramaItems(_ items: [VodItem], seenNames: inout Set<String>) {
        guard !items.isEmpty else { return }

        var newItems: [VodItem] = []
        for item in items {
            let key = item.vodName
            guard !seenNames.contains(key) else { continue }
            seenNames.insert(key)
            newItems.append(item)
        }
        guard !newItems.isEmpty else { return }

        dramas.append(contentsOf: newItems)
    }
    
    // MARK: - 封面图补全
    
    private func fetchMissingCovers() {
        let itemsToFix = dramas.enumerated().filter { $0.element.vodPic.isEmpty }
        guard !itemsToFix.isEmpty else { return }
        
        let vodIds = itemsToFix.map { $0.element.vodId }
        
        Task {
            for source in shortDramaSources {
                // JS 蜘蛛源跳过封面补全（homeContent/categoryContent 已返回封面）
                guard source.sourceType != .jsSpider else { continue }

                let batchSize = 30
                for batchStart in stride(from: 0, to: vodIds.count, by: batchSize) {
                    let batch = Array(vodIds[batchStart..<min(batchStart + batchSize, vodIds.count)])
                    let ids = batch.joined(separator: ",")
                    
                    let baseAPI = source.api.hasSuffix("/") ? String(source.api.dropLast()) : source.api
                    let detailUrlStr = "\(baseAPI)?ac=detail&ids=\(ids)"
                    
                    guard let url = URL(string: detailUrlStr) else { continue }
                    
                    do {
                        let (data, _) = try await URLSession.shared.data(from: url)
                        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let list = json["list"] as? [[String: Any]] else { continue }
                        
                        await MainActor.run {
                            for detailDict in list {
                                let vid = detailDict["vod_id"] as? String ?? "\(detailDict["vod_id"] as? Int ?? 0)"
                                let pic = self.resolveImageUrl(detailDict["vod_pic"] as? String ?? "", baseApi: source.api)
                                guard !pic.isEmpty,
                                      let idx = self.dramas.firstIndex(where: { $0.vodId == vid && $0.vodPic.isEmpty }) else { continue }
                                
                                self.dramas[idx] = VodItem(
                                    vodId: self.dramas[idx].vodId,
                                    vodName: self.dramas[idx].vodName,
                                    vodPic: pic,
                                    vodRemarks: self.dramas[idx].vodRemarks,
                                    vodYear: detailDict["vod_year"] as? String ?? self.dramas[idx].vodYear,
                                    vodArea: detailDict["vod_area"] as? String ?? self.dramas[idx].vodArea,
                                    vodDirector: detailDict["vod_director"] as? String ?? self.dramas[idx].vodDirector,
                                    vodActor: detailDict["vod_actor"] as? String ?? self.dramas[idx].vodActor,
                                    vodContent: detailDict["vod_content"] as? String ?? self.dramas[idx].vodContent,
                                    vodPlayFrom: self.dramas[idx].vodPlayFrom,
                                    vodPlayUrl: self.dramas[idx].vodPlayUrl
                                )
                            }
                        }
                    } catch {
                        continue
                    }
                }
            }
        }
    }
    
    private func resolveImageUrl(_ raw: String, baseApi: String) -> String {
        guard !raw.isEmpty else { return "" }
        if let url = URL(string: raw), url.scheme != nil { return raw }
        if raw.hasPrefix("//") { return "https:\(raw)" }
        guard let baseURL = URL(string: baseApi),
              let resolved = URL(string: raw, relativeTo: baseURL) else { return raw }
        return resolved.absoluteString
    }

    private func fetchSourceDramas(source: ShortDramaSource, page: Int) async -> [VodItem] {
        // JS 蜘蛛源：通过引擎调用 categoryContent
        if source.sourceType == .jsSpider, let engineKey = source.engineKey,
           let engine = SpiderManager.shared.getEngine(forKey: engineKey) {
            do {
                let result = try engine.callCategoryContent(tid: source.categoryId, pg: page, extend: "{}")
                guard let list = result.list, !list.isEmpty else { return [] }

                return list.map { item in
                    var vod = item
                    if vod.vodRemarks == nil || vod.vodRemarks?.isEmpty == true {
                        vod.vodRemarks = "\(source.name)"
                    }
                    return vod
                }
            } catch {
                print("[ShortDrama] JS蜘蛛获取失败 \(source.name): \(error.localizedDescription)")
                return []
            }
        }

        // API 源：通过 HTTP 调用 ac=list 接口
        let api = source.api
        let baseAPI = api.hasSuffix("/") ? String(api.dropLast()) : api
        let listUrl = "\(baseAPI)?ac=list&t=\(source.categoryId)&pg=\(page)"

        guard let url = URL(string: listUrl) else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["list"] as? [[String: Any]] else { return [] }

            return list.compactMap { dict -> VodItem? in
                guard let name = dict["vod_name"] as? String else { return nil }
                let vid = dict["vod_id"] as? String ?? "\(dict["vod_id"] as? Int ?? 0)"
                let remarks = dict["vod_remarks"] as? String ?? ""
                return VodItem(
                    vodId: vid,
                    vodName: name,
                    vodPic: resolveImageUrl(dict["vod_pic"] as? String ?? "", baseApi: api),
                    vodRemarks: "\(source.name) · \(remarks)".trimmingCharacters(in: CharacterSet(charactersIn: "· ")),
                    vodYear: dict["vod_year"] as? String,
                    vodArea: dict["vod_area"] as? String,
                    vodDirector: dict["vod_director"] as? String,
                    vodActor: dict["vod_actor"] as? String,
                    vodContent: dict["vod_content"] as? String,
                    vodPlayFrom: dict["vod_play_from"] as? String,
                    vodPlayUrl: dict["vod_play_url"] as? String
                )
            }
        } catch {
            print("[ShortDrama] 获取失败 \(source.name): \(error.localizedDescription)")
            return []
        }
    }
    
    // MARK: - 搜索短剧
    
    func search(keyword: String) async -> [VodItem] {
        var allItems: [VodItem] = []
        
        let targets: [ShortDramaSource]
        if let sourceId = selectedSourceId {
            targets = shortDramaSources.filter { $0.id == sourceId }
        } else {
            targets = shortDramaSources
        }
        
        for source in targets {
            let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
            let baseAPI = source.api.hasSuffix("/") ? String(source.api.dropLast()) : source.api
            let searchUrlStr = "\(baseAPI)?ac=videolist&wd=\(encoded)"
            
            guard let url = URL(string: searchUrlStr) else { continue }
            
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let list = json["list"] as? [[String: Any]] else { continue }
                
                let items = list.compactMap { dict -> VodItem? in
                    guard let name = dict["vod_name"] as? String else { return nil }
                    let vid = dict["vod_id"] as? String ?? "\(dict["vod_id"] as? Int ?? 0)"
                    return VodItem(
                        vodId: vid,
                        vodName: name,
                        vodPic: resolveImageUrl(dict["vod_pic"] as? String ?? "", baseApi: source.api),
                        vodRemarks: "\(source.name) · \(dict["vod_remarks"] as? String ?? "")".trimmingCharacters(in: CharacterSet(charactersIn: "· ")),
                        vodYear: dict["vod_year"] as? String,
                        vodContent: dict["vod_content"] as? String,
                        vodPlayFrom: dict["vod_play_from"] as? String,
                        vodPlayUrl: dict["vod_play_url"] as? String
                    )
                }
                allItems.append(contentsOf: items)
            } catch {
                print("[ShortDrama] 搜索失败 \(source.name): \(error.localizedDescription)")
            }
        }
        
        return allItems
    }
    
    // MARK: - 获取短剧详情（播放地址）
    
    func fetchDetail(vodId: String, api: String) async -> VodItem? {
        let baseAPI = api.hasSuffix("/") ? String(api.dropLast()) : api
        let detailUrlStr = "\(baseAPI)?ac=detail&ids=\(vodId)"
        
        guard let url = URL(string: detailUrlStr) else { return nil }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["list"] as? [[String: Any]],
                  let first = list.first else { return nil }
            
            let vid = first["vod_id"] as? String ?? "\(first["vod_id"] as? Int ?? 0)"
            return VodItem(
                vodId: vid,
                vodName: first["vod_name"] as? String ?? "",
                vodPic: resolveImageUrl(first["vod_pic"] as? String ?? "", baseApi: api),
                vodRemarks: first["vod_remarks"] as? String,
                vodYear: first["vod_year"] as? String,
                vodContent: first["vod_content"] as? String,
                vodPlayFrom: first["vod_play_from"] as? String,
                vodPlayUrl: first["vod_play_url"] as? String
            )
        } catch {
            print("[ShortDrama] 详情获取失败: \(error.localizedDescription)")
            return nil
        }
    }
}
