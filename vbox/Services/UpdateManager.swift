import Foundation
import SwiftUI

/// 自动更新管理器 — 检查GitHub Releases版本更新
@MainActor
class UpdateManager: ObservableObject {

    static let shared = UpdateManager()

    @Published var isChecking = false
    @Published var hasUpdate = false
    @Published var latestVersion = ""
    @Published var latestBuild = ""
    @Published var downloadURL: String?
    @Published var releaseNotes = ""
    @Published var updateError: String?

    // B 仓库配置 — APP 从这里检查更新和下载 IPA
    private let repoOwner = "B账号用户名"  // 替换为 B 仓库的 GitHub 用户名
    private let repoName = "B仓库名"       // 替换为 B 仓库的名称

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3"
    }

    private var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    private init() {}

    /// 检查更新
    func checkForUpdate() async {
        isChecking = true
        updateError = nil

        do {
            // 使用 /releases 列表API（包含pre-release），取第一个（最新）的 release
            // 注意：/releases/latest 会忽略 pre-release，而我们所有版本都是 pre-release
            let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases?per_page=1")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

            let (data, _) = try await URLSession.shared.data(for: request)

            if let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let json = releases.first {
                let tagName = json["tag_name"] as? String ?? ""
                let body = json["body"] as? String ?? ""
                let assets = json["assets"] as? [[String: Any]] ?? []

                // 找第一个IPA下载链接
                var ipaURL: String?
                for asset in assets {
                    if (asset["name"] as? String)?.hasSuffix(".ipa") == true {
                        ipaURL = asset["browser_download_url"] as? String
                        break
                    }
                }

                // 解析版本号：去掉 v 前缀，eg: v1.0-fixed-build -> 1.0
                let remoteVersion = tagName.replacingOccurrences(of: "v", with: "")
                    .components(separatedBy: "-").first ?? tagName

                latestVersion = remoteVersion
                releaseNotes = body
                downloadURL = ipaURL

                // 比较版本：如果当前版本小于远程版本则有更新
                if currentVersion.compare(remoteVersion, options: .numeric) == .orderedAscending {
                    hasUpdate = true
                    print("[UpdateManager] 发现新版本: v\(remoteVersion)，当前: v\(currentVersion)")
                } else {
                    hasUpdate = false
                    print("[UpdateManager] 已是最新版: v\(currentVersion)，远程: v\(remoteVersion)")
                }
            }
        } catch {
            updateError = "检查更新失败: \(error.localizedDescription)"
            print("[UpdateManager] \(updateError!)")
        }

        isChecking = false
    }

    /// 打开下载链接
    func openDownload() {
        guard let url = downloadURL, let urlObj = URL(string: url) else { return }
        UIApplication.shared.open(urlObj)
    }
}
