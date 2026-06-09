import SwiftUI
import Combine

/// 全局应用设置
class AppSettings: ObservableObject {
    @Published var isSpiderReady = false
    @Published var subscribedSites: [SiteConfig] = []
    @Published var selectedSiteKey: String?
    @Published var searchQuery: String = ""     // 首页搜索 → 切换到搜索Tab

    init() {}

    func triggerSearch(_ query: String) {
        searchQuery = query
    }
}

// SpiderManager 已迁移到 Services/SpiderManager.swift
