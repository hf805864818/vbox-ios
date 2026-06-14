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

    init() {
        let rawSkin = UserDefaults.standard.string(forKey: Self.skinModeKey)
        skinMode = AppSkinMode(rawValue: rawSkin ?? "") ?? .light
        skinFollowsSystem = UserDefaults.standard.object(forKey: Self.skinFollowsSystemKey) as? Bool ?? false
    }

    var preferredColorScheme: ColorScheme? {
        if skinMode == .liquid { return .dark }
        if skinMode == .frosted { return nil }
        return skinFollowsSystem ? nil : skinMode.preferredColorScheme
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
        skinMode = mode
    }

    func triggerSearch(_ query: String) {
        searchQuery = query
        searchRequestId += 1
    }
}

// SpiderManager 已迁移到 Services/SpiderManager.swift
