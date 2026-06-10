import SwiftUI
import Combine

/// 全局应用设置
class AppSettings: ObservableObject {
    @Published var isSpiderReady = false
    @Published var subscribedSites: [SiteConfig] = []
    @Published var selectedSiteKey: String?
    @Published var searchQuery: String = ""     // 首页搜索 → 切换到搜索Tab
    @Published var searchRequestId: Int = 0

    init() {}

    func triggerSearch(_ query: String) {
        searchQuery = query
        searchRequestId += 1
    }
}

// SpiderManager 已迁移到 Services/SpiderManager.swift
