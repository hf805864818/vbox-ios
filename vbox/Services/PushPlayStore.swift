import Foundation

// MARK: - 推送播放链接类型
enum PushPlayLinkType: String, Codable, CaseIterable {
    case cloudDrive = "cloud"      // 网盘链接
    case directPlay = "direct"     // 直链播放（m3u8/mp4等）
    case webParse = "web"          // 网页解析链接
    
    var displayName: String {
        switch self {
        case .cloudDrive: return "网盘资源"
        case .directPlay: return "直链播放"
        case .webParse: return "网页解析"
        }
    }
    
    var iconName: String {
        switch self {
        case .cloudDrive: return "cloud.fill"
        case .directPlay: return "play.rectangle.fill"
        case .webParse: return "globe"
        }
    }
}

// MARK: - 推送播放条目
struct PushPlayItem: Codable, Identifiable, Hashable {
    var id: String { url }
    let title: String
    let url: String
    let type: PushPlayLinkType
    let createdAt: Date
    var episodes: [PushPlayEpisode]?  // 解析后的剧集列表
    
    init(title: String, url: String, type: PushPlayLinkType, episodes: [PushPlayEpisode]? = nil) {
        self.title = title
        self.url = url
        self.type = type
        self.createdAt = Date()
        self.episodes = episodes
    }
}

// MARK: - 剧集条目
struct PushPlayEpisode: Codable, Identifiable, Hashable {
    var id: String { name + url }
    let name: String
    let url: String
}

// MARK: - 推送播放存储管理
class PushPlayStore: ObservableObject {
    static let shared = PushPlayStore()
    
    private let key = "push_play_items_v1"
    
    @Published var items: [PushPlayItem] = []
    
    init() {
        load()
    }
    
    // MARK: - CRUD
    
    func addItem(title: String, url: String, type: PushPlayLinkType) {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }
        
        let finalTitle = trimmedTitle.isEmpty ? defaultTitle(for: trimmedURL, type: type) : trimmedTitle
        let item = PushPlayItem(title: finalTitle, url: trimmedURL, type: type)
        
        // 避免重复
        if !items.contains(where: { $0.url == trimmedURL }) {
            items.insert(item, at: 0)
            save()
        }
    }
    
    func updateItem(_ item: PushPlayItem, withEpisodes episodes: [PushPlayEpisode]) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].episodes = episodes
            save()
        }
    }
    
    func removeItem(_ item: PushPlayItem) {
        items.removeAll { $0.id == item.id }
        save()
    }
    
    func removeAll() {
        items.removeAll()
        save()
    }
    
    // MARK: - 自动识别链接类型
    
    static func detectType(for url: String) -> PushPlayLinkType {
        let lower = url.lowercased()
        
        // 网盘链接识别
        let cloudPatterns = [
            "alipan.com", "aliyundrive.com", "aliyun.com",
            "pan.quark.cn", "quark.cn",
            "pan.baidu.com", "yun.baidu.com", "baidu.com",
            "115.com", "115cdn.com",
            "drive.uc.cn", "uc.cn",
            "www.123pan.com", "123pan.com",
            "caiyun.139.com", "139.com",
            "cloud.189.cn", "189.cn"
        ]
        
        if cloudPatterns.contains(where: { lower.contains($0) }) {
            return .cloudDrive
        }
        
        // 直链识别
        if lower.contains(".m3u8") || lower.contains(".mp4") || lower.contains(".flv") ||
           lower.contains(".ts") || lower.contains(".mkv") || lower.contains(".avi") {
            return .directPlay
        }
        
        // 默认网页解析
        return .webParse
    }
    
    // MARK: - Private
    
    private func defaultTitle(for url: String, type: PushPlayLinkType) -> String {
        switch type {
        case .cloudDrive:
            if let host = URL(string: url)?.host {
                return "网盘 - \(host)"
            }
            return "网盘资源"
        case .directPlay:
            return "直链视频"
        case .webParse:
            if let host = URL(string: url)?.host {
                return "网页 - \(host)"
            }
            return "网页资源"
        }
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([PushPlayItem].self, from: data) {
            items = decoded
        }
    }
    
    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
