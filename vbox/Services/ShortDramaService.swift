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
    let sourceType: SourceCategory       // .api 或 .jsSpider（JS/Python 蜘蛛统一走引擎）
    let engineKey: String?               // 蜘蛛源的引擎 key

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
    
    private let dramaKeywords = ["短剧", "剧场", "网剧", "微短剧", "爽文短剧", "擦边短剧", "短剧大全", "竖屏剧", "小剧场", "迷你剧", "微剧", "短视频剧", "短片剧"]
    private var isInitialLoading = false
    /// 标记扫描期间收到了重新扫描请求（如 Python 引擎就绪通知），当前扫描完成后自动重扫
    private var pendingRescan = false
    
    private init() {}
    
    // MARK: - 扫描所有 VOD 源中的短剧分类
    
    func loadInitialIfNeeded(from sites: [SiteConfig], forceRescan: Bool = false) async {
        guard !isInitialLoading else {
            // 扫描进行中时收到重新扫描请求（如 Python 引擎就绪），标记待重扫
            if forceRescan { pendingRescan = true }
            return
        }
        if !forceRescan, !shortDramaSources.isEmpty, !dramas.isEmpty { return }

        isInitialLoading = true

        if forceRescan {
            currentPage = 1
            hasMore = true
            dramas = []
        }

        if forceRescan || shortDramaSources.isEmpty {
            await scanShortDramaSources(from: sites)
        }

        // scanShortDramaSources 内部会在第一个源出现时自动触发 fetchDramas
        // 这里仅在扫描未触发加载时补充（如已缓存源但无数据的情况）
        if dramas.isEmpty, !shortDramaSources.isEmpty {
            if selectedSourceId == nil {
                selectedSourceId = shortDramaSources.first?.id
            }
            await fetchDramas(refresh: true)
        }

        isInitialLoading = false

        // 扫描期间收到了重新扫描请求（如 Python 引擎延迟就绪），自动重扫一次
        if pendingRescan {
            pendingRescan = false
            await loadInitialIfNeeded(from: sites, forceRescan: true)
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

        // 收集已就绪的蜘蛛源（type:3），与 API 源并行扫描
        let spiderManager = SpiderManager.shared
        var spiderEngines: [(site: SiteConfig, engineKey: String, engine: any SpiderEngineProtocol)] = []
        for site in sites where site.type == 3 {
            let engineKey = site.key.isEmpty ? site.name : site.key
            guard let engine = spiderManager.getEngine(forKey: engineKey) else {
                print("[ShortDrama] 蜘蛛引擎未加载: \(site.name) (\(engineKey))")
                continue
            }
            if !engine.isSpiderReady {
                print("[ShortDrama] 蜘蛛引擎未就绪: \(site.name) (\(engineKey))，跳过（等待就绪通知后重扫）")
                continue
            }
            spiderEngines.append((site, engineKey, engine))
        }

        let keywords = dramaKeywords
        let maxConcurrent = 12

        isLoading = true
        defer { isLoading = false }

        // 标记是否已自动触发首批数据加载
        var hasTriggeredFirstLoad = false

        // ★ 优化: API 源和蜘蛛源在同一个 TaskGroup 中并行扫描
        // 之前: 先扫描完所有 API 源，再逐一扫描蜘蛛源（串行等待）
        // 现在: 蜘蛛源和 API 源同时开始扫描，大幅缩短总等待时间
        await withTaskGroup(of: [ShortDramaSource].self) { group in
            var running = 0

            // 添加 API 源扫描任务
            for site in checkSites {
                if running >= maxConcurrent {
                    if let batch = await group.next() {
                        appendShortDramaSources(batch, seenSourceIds: &seenSourceIds)
                        if !hasTriggeredFirstLoad, let firstSource = shortDramaSources.first {
                            hasTriggeredFirstLoad = true
                            selectedSourceId = firstSource.id
                            Task { await fetchDramas(refresh: true) }
                        }
                    }
                    running -= 1
                }

                running += 1
                group.addTask {
                    await Self.scanAPISource(site: site, dramaKeywords: keywords)
                }
            }

            // 添加蜘蛛源扫描任务（与 API 源并行）
            for (site, engineKey, engine) in spiderEngines {
                if running >= maxConcurrent {
                    if let batch = await group.next() {
                        appendShortDramaSources(batch, seenSourceIds: &seenSourceIds)
                        if !hasTriggeredFirstLoad, let firstSource = shortDramaSources.first {
                            hasTriggeredFirstLoad = true
                            selectedSourceId = firstSource.id
                            Task { await fetchDramas(refresh: true) }
                        }
                    }
                    running -= 1
                }

                running += 1
                let sourceId = "spider_\(engineKey)_shortdrama"
                if seenSourceIds.contains(sourceId) { continue }
                seenSourceIds.insert(sourceId)

                let dramaKw = self.dramaKeywords
                group.addTask {
                    await Self.scanSpiderSource(site: site, engineKey: engineKey, engine: engine, dramaKeywords: dramaKw)
                }
            }

            for await batch in group {
                appendShortDramaSources(batch, seenSourceIds: &seenSourceIds)
                if !hasTriggeredFirstLoad, let firstSource = shortDramaSources.first {
                    hasTriggeredFirstLoad = true
                    selectedSourceId = firstSource.id
                    Task { await fetchDramas(refresh: true) }
                }
            }
        }

        if !shortDramaSources.isEmpty {
            print("[ShortDrama] ✅ 识别到 \(shortDramaSources.count) 个短剧源:")
            for s in shortDramaSources {
                let typeTag = s.sourceType == .jsSpider ? "[蜘蛛]" : "[API]"
                print("  - \(typeTag) \(s.name): \(s.categoryName)(ID=\(s.categoryId)) \(s.totalCount)部")
            }
        }
    }

    // MARK: - 并行扫描单个蜘蛛源
    private nonisolated static func scanSpiderSource(
        site: SiteConfig, engineKey: String, engine: any SpiderEngineProtocol, dramaKeywords: [String]
    ) async -> [ShortDramaSource] {
        // 后台线程执行 callHomeContent，带 10 秒超时
        let scanResult: [ShortDramaSource] = await withCheckedContinuation { continuation in
            let lock = NSLock()
            var hasResumed = false

            func resumeOnce(_ result: [ShortDramaSource]) {
                lock.lock()
                if !hasResumed {
                    hasResumed = true
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    lock.unlock()
                }
            }

            // 超时保护 (10 秒)
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                resumeOnce([])
            }

            DispatchQueue.global().async {
                do {
                    let result = try engine.callHomeContent()
                    let categories = result.class ?? []
                    var batch: [ShortDramaSource] = []

                    for cat in categories {
                        let catName = cat.typeName
                        guard dramaKeywords.contains(where: { catName.contains($0) }) else { continue }

                        batch.append(ShortDramaSource(
                            id: "spider_\(engineKey)_\(cat.typeId)",
                            name: site.name,
                            api: site.api ?? "",
                            categoryId: cat.typeId,
                            categoryName: catName,
                            totalCount: 0,
                            sourceType: .jsSpider,
                            engineKey: engineKey
                        ))
                        print("[ShortDrama] 蜘蛛源发现短剧分类: \(site.name) → \(catName)(ID=\(cat.typeId))")
                    }
                    resumeOnce(batch)
                } catch {
                    print("[ShortDrama] 蜘蛛扫描失败 \(site.name): \(error.localizedDescription)")
                    resumeOnce([])
                }
            }
        }
        return scanResult
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
                // 让主线程有机会刷新 UI，实现"先加载先显示"的增量展示
                await Task.yield()
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
                // 蜘蛛源跳过封面补全（homeContent/categoryContent 已返回封面；详情需走引擎）
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
    
    private nonisolated func resolveImageUrl(_ raw: String, baseApi: String) -> String {
        guard !raw.isEmpty else { return "" }
        if let url = URL(string: raw), url.scheme != nil { return raw }
        if raw.hasPrefix("//") { return "https:\(raw)" }
        guard let baseURL = URL(string: baseApi),
              let resolved = URL(string: raw, relativeTo: baseURL) else { return raw }
        return resolved.absoluteString
    }

    private nonisolated func fetchSourceDramas(source: ShortDramaSource, page: Int) async -> [VodItem] {
        // 蜘蛛源：通过引擎调用 categoryContent（JS/Python 都走这里）
        if source.sourceType == .jsSpider {
            guard let engineKey = source.engineKey,
                  let engine = await SpiderManager.shared.getEngine(forKey: engineKey) else {
                print("[ShortDrama] 蜘蛛引擎不可用，跳过列表: \(source.name)")
                return []
            }
            do {
                let result = try engine.callCategoryContent(tid: source.categoryId, pg: page, extend: "{}")
                guard let list = result.list, !list.isEmpty else { return [] }

                return list.map { item in
                    var vod = item
                    if vod.vodRemarks == nil || vod.vodRemarks?.isEmpty == true {
                        vod.vodRemarks = "\(source.name)"
                    }
                    vod.engineKey = engineKey
                    return vod
                }
            } catch {
                print("[ShortDrama] 蜘蛛获取失败 \(source.name): \(error.localizedDescription)")
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
            if source.sourceType == .jsSpider {
                guard let engineKey = source.engineKey,
                      let engine = SpiderManager.shared.getEngine(forKey: engineKey) else {
                    print("[ShortDrama] 蜘蛛引擎不可用，跳过搜索: \(source.name)")
                    continue
                }
                // ★ 修复: 在后台线程执行 callSearchContent, 带超时保护
                // 原实现: 同步调用 engine.callSearchContent() → Python 脚本网络请求阻塞主线程
                let searchResult: [VodItem] = await withCheckedContinuation { continuation in
                    let lock = NSLock()
                    var hasResumed = false

                    func resumeOnce(_ result: [VodItem]) {
                        lock.lock()
                        if !hasResumed {
                            hasResumed = true
                            lock.unlock()
                            continuation.resume(returning: result)
                        } else {
                            lock.unlock()
                        }
                    }

                    // 超时保护 (15 秒)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                        resumeOnce([])
                    }

                    // 实际执行 (后台线程)
                    DispatchQueue.global().async {
                        do {
                            let result = try engine.callSearchContent(keyword: keyword, pg: 1)
                            let items = (result.list ?? []).map { item -> VodItem in
                                var vod = item
                                if vod.vodRemarks == nil || vod.vodRemarks?.isEmpty == true {
                                    vod.vodRemarks = source.name
                                }
                                vod.engineKey = engineKey
                                return vod
                            }
                            resumeOnce(items)
                        } catch {
                            print("[ShortDrama] 蜘蛛搜索失败 \(source.name): \(error.localizedDescription)")
                            resumeOnce([])
                        }
                    }
                }
                allItems.append(contentsOf: searchResult)
                continue
            }

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
    
    func fetchDetail(vodId: String, api: String, engineKey: String? = nil) async -> VodItem? {
        if let engineKey {
            return await SpiderManager.shared.getDetail(ids: vodId, engineKey: engineKey)
        }

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
