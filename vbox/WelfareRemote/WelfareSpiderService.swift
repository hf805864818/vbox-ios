//
//  WelfareSpiderService.swift
//  vbox
//
//  福利专区专用远程 Spider 服务。
//
//  当前阶段只负责校验、下载、缓存和暴露脚本状态，不把脚本注册到普通 SpiderManager。
//  iOS 项目目前没有通用 Python 解释器，因此真正执行 Python Spider 需要后续单独接入运行时。
//

import Foundation

final class WelfareSpiderService: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(WelfareSpiderScript)
        case failed(String)

        var title: String {
            switch self {
            case .idle:
                return "未加载"
            case .loading:
                return "正在加载脚本"
            case .loaded:
                return "脚本已缓存"
            case .failed:
                return "脚本加载失败"
            }
        }
    }

    let platform: WelfarePlatform

    @Published private(set) var state: LoadState = .idle

    init(platform: WelfarePlatform) {
        self.platform = platform
        if let cached = WelfareSpiderLoader.shared.cachedScript(for: platform) {
            self.state = .loaded(cached)
        }
    }

    var currentDomain: String {
        if let custom = WelfareDomainStore.shared.domains(for: platform.name).first {
            return custom
        }
        return platform.primaryHost
    }

    var scriptPreview: String? {
        guard case .loaded(let script) = state else { return nil }
        let lines = script.content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(28)
        return lines.joined(separator: "\n")
    }

    var localScriptPath: String? {
        guard case .loaded(let script) = state else { return nil }
        return script.localURL.lastPathComponent
    }

    func reload() {
        state = .loading
        Task {
            do {
                let script = try await WelfareSpiderLoader.shared.loadScript(for: platform)
                await MainActor.run {
                    self.state = .loaded(script)
                }
            } catch {
                await MainActor.run {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }
}
