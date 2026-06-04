import SwiftUI
import Combine

/// 全局应用设置
class AppSettings: ObservableObject {
    @Published var isSpiderReady = false
    @Published var subscribedSites: [SiteConfig] = []
    @Published var selectedSiteKey: String?
    
    init() {}
}

// SpiderManager 已迁移到 Services/SpiderManager.swift
