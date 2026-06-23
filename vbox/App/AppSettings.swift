import SwiftUI
import Combine

enum AppSkinMode: String, CaseIterable, Identifiable {
    case dark
    case light
    case liquid
    case frosted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "黑暗模式"
        case .light: return "浅色模式"
        case .liquid: return "液态模式"
        case .frosted: return "磨砂模式"
        }
    }

    var subtitle: String {
        switch self {
        case .dark: return "全局深色界面"
        case .light: return "保持当前浅色风格"
        case .liquid: return "流动渐变与毛玻璃"
        case .frosted: return "全局磨砂玻璃质感"
        }
    }

    var icon: String {
        switch self {
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        case .liquid: return "drop.fill"
        case .frosted: return "sparkles"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .dark, .liquid: return .dark
        case .light: return .light
        case .frosted: return nil
        }
    }
}

/// 全局应用设置
class AppSettings: ObservableObject {
    private static let skinModeKey = "app_skin_mode"
    private static let skinFollowsSystemKey = "app_skin_follows_system"
    private static let enableTMDBKey = "app_enable_tmdb"
    private static let tmdbProxyURLKey = "app_tmdb_proxy_url"
    private static let tmdbUseTokenKey = "app_tmdb_use_token"
    private static let tmdbProxyTokenKey = "app_tmdb_proxy_token"

    @Published var isSpiderReady = false
    @Published var subscribedSites: [SiteConfig] = []
    @Published var selectedSiteKey: String?
    @Published var searchQuery: String = ""     // 首页搜索 → 切换到搜索Tab
    @Published var searchRequestId: Int = 0
    @Published var skinMode: AppSkinMode {
        didSet {
            UserDefaults.standard.set(skinMode.rawValue, forKey: Self.skinModeKey)
        }
    }
    @Published var skinFollowsSystem: Bool {
        didSet {
            UserDefaults.standard.set(skinFollowsSystem, forKey: Self.skinFollowsSystemKey)
        }
    }
    @Published var showSettings = false
    @Published var enableTMDB: Bool {
        didSet {
            UserDefaults.standard.set(enableTMDB, forKey: Self.enableTMDBKey)
        }
    }
    @Published var tmdbProxyURL: String {
        didSet {
            UserDefaults.standard.set(tmdbProxyURL, forKey: Self.tmdbProxyURLKey)
        }
    }
    @Published var tmdbUseToken: Bool {
        didSet {
            UserDefaults.standard.set(tmdbUseToken, forKey: Self.tmdbUseTokenKey)
        }
    }
    @Published var tmdbProxyToken: String {
        didSet {
            UserDefaults.standard.set(tmdbProxyToken, forKey: Self.tmdbProxyTokenKey)
        }
    }

    init() {
        let rawSkin = UserDefaults.standard.string(forKey: Self.skinModeKey)
        skinMode = AppSkinMode(rawValue: rawSkin ?? "") ?? .light
        skinFollowsSystem = UserDefaults.standard.object(forKey: Self.skinFollowsSystemKey) as? Bool ?? false
        enableTMDB = UserDefaults.standard.object(forKey: Self.enableTMDBKey) as? Bool ?? true
        tmdbProxyURL = UserDefaults.standard.string(forKey: Self.tmdbProxyURLKey) ?? ""
        tmdbUseToken = UserDefaults.standard.object(forKey: Self.tmdbUseTokenKey) as? Bool ?? false
        tmdbProxyToken = UserDefaults.standard.string(forKey: Self.tmdbProxyTokenKey) ?? ""
    }

    var preferredColorScheme: ColorScheme? {
        if skinFollowsSystem {
            return skinMode == .liquid ? .dark : nil
        }
        if skinMode == .liquid { return .dark }
        if skinMode == .frosted { return nil }
        return skinMode.preferredColorScheme
    }

    var usesLiquidSkin: Bool {
        skinMode == .liquid
    }

    var usesFrostedSkin: Bool {
        skinMode == .frosted
    }

    var usesVisualSkin: Bool {
        skinMode == .liquid || skinMode == .frosted
    }

    func selectSkin(_ mode: AppSkinMode) {
        skinFollowsSystem = false
        skinMode = mode
    }

    func triggerSearch(_ query: String) {
        searchQuery = query
        searchRequestId += 1
    }
}

// SpiderManager 已迁移到 Services/SpiderManager.swift
