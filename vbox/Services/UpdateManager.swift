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
    @Published var releasePageURL: String?
    @Published var releaseNotes = ""
    @Published var updateError: String?

    // B 仓库配置 — APP 从这里检查更新和下载 IPA
    private let repoOwner = "hfkj520"  // 替换为 B 仓库的 GitHub 用户名
    private let repoName = "vbox-release"       // 替换为 B 仓库的名称

    private var currentVersion: String {
        let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3"
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentBuild: String {
        let raw = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把 tag/版本字符串清理成纯数字+点，例如 "v3.700-beta" -> "3.700"
    private func cleanVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉常见的 v 前缀
        var cleaned = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        // 取第一个 "-" 之前的部分，避免 "3.700-beta" 干扰比较
        cleaned = cleaned.components(separatedBy: "-").first ?? cleaned
        // 去掉所有非数字和非点的字符
        cleaned = cleaned.filter { $0.isNumber || $0 == "." }
        return cleaned
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
                let htmlURL = json["html_url"] as? String
                let assets = json["assets"] as? [[String: Any]] ?? []

                // 找第一个IPA下载链接
                var ipaURL: String?
                for asset in assets {
                    if (asset["name"] as? String)?.hasSuffix(".ipa") == true {
                        ipaURL = asset["browser_download_url"] as? String
                        break
                    }
                }

                // 解析版本号并清理
                let remoteVersion = cleanVersion(tagName)
                let localVersion = cleanVersion(currentVersion)

                latestVersion = remoteVersion
                releaseNotes = body
                downloadURL = ipaURL
                releasePageURL = htmlURL

                // 比较版本：如果当前版本小于远程版本则有更新
                if localVersion.compare(remoteVersion, options: .numeric) == .orderedAscending {
                    hasUpdate = true
                    print("[UpdateManager] 发现新版本: v\(remoteVersion)，当前: v\(localVersion)")
                } else {
                    hasUpdate = false
                    print("[UpdateManager] 已是最新版: v\(localVersion)，远程: v\(remoteVersion)")
                }
            }
        } catch {
            updateError = "检查更新失败: \(error.localizedDescription)"
            print("[UpdateManager] \(updateError!)")
        }

        isChecking = false
    }

    /// 打开 Release 页面
    func openReleasePage() {
        guard let url = releasePageURL ?? downloadURL, let urlObj = URL(string: url) else { return }
        UIApplication.shared.open(urlObj)
    }
}
