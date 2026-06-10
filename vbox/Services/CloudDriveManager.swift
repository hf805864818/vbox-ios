import Foundation
import Combine

struct DriveToken: Codable {
    let type: String
    let name: String
    let value: String
}

struct BaiduFileItem {
    let fsId: String
    let name: String
}

class CloudDriveManager: ObservableObject {

    static let shared = CloudDriveManager()

    enum DriveType: String, CaseIterable {
        case ali = "ali"
        case quark = "quark"
        case baidu = "baidu"
        case one15 = "115"
        case uc = "uc"

        var displayName: String {
            switch self {
            case .ali: return "阿里云盘"
            case .quark: return "夸克网盘"
            case .baidu: return "百度网盘"
            case .one15: return "115网盘"
            case .uc: return "UC网盘"
            }
        }

        var tokenLabel: String {
            switch self {
            case .ali: return "Refresh Token"
            case .quark: return "Cookie"
            case .baidu: return "BDUSS|STOKEN"
            case .one15: return "CID"
            case .uc: return "Cookie"
            }
        }
    }

    private let session: URLSession
    private let defaults = UserDefaults.standard
    private let tokenKey = "saved_drive_tokens"

    @Published private(set) var savedTokens: [DriveToken] = []

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        loadTokens()
    }

    static var onLog: ((String) -> Void)?

    private func baiduLog(_ msg: String) {
        print(msg)
        if let handler = CloudDriveManager.onLog {
            handler(msg)
        }
    }

    private func loadTokens() {
        if let data = defaults.data(forKey: tokenKey),
           let tokens = try? JSONDecoder().decode([DriveToken].self, from: data) {
            savedTokens = tokens
        }
    }

    private func saveTokens() {
        if let data = try? JSONEncoder().encode(savedTokens) {
            defaults.set(data, forKey: tokenKey)
        }
    }

    func addToken(type: DriveType, name: String, value: String) {
        savedTokens.removeAll { $0.type == type.rawValue && $0.name == name }
        savedTokens.append(DriveToken(type: type.rawValue, name: name, value: value))
        saveTokens()
    }

    func removeToken(at index: Int) {
        guard index >= 0, index < savedTokens.count else { return }
        savedTokens.remove(at: index)
        saveTokens()
    }

    private func ensureVboxFolder(drive: DriveType, token: String) async throws -> String {
        switch drive {
        case .quark:
            return try await quarkEnsureFolder(cookie: token)
        case .baidu:
            return try await baiduEnsureFolder(bduss: token)
        case .uc:
            return try await ucEnsureFolder(cookie: token)
        default:
            return ""
        }
    }

    private func scheduleCleanup(drive: DriveType, fileIds: [String], token: String, delay: TimeInterval = 180) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await cleanupFiles(drive: drive, fileIds: fileIds, token: token)
        }
    }

    private func cleanupFiles(drive: DriveType, fileIds: [String], token: String) async {
        print("[CloudDrive] 清理 \(drive.rawValue) 转存文件: \(fileIds.count) 个")
        switch drive {
        case .quark: await quarkDeleteFiles(fileIds: fileIds, cookie: token)
        case .baidu: await baiduDeleteFiles(fileIds: fileIds, bduss: token)
        case .uc: await ucDeleteFiles(fileIds: fileIds, cookie: token)
        default: break
        }
    }

    func tokens(for type: DriveType) -> [DriveToken] {
        savedTokens.filter { $0.type == type.rawValue }
    }

    static func detectDrive(from url: String) -> DriveType? {
        if url.contains("aliyundrive.com") || url.contains("alipan.com") { return .ali }
        if url.contains("pan.quark.cn") { return .quark }
        if url.contains("pan.baidu.com") { return .baidu }
        if url.contains("115.com") || url.contains("115cdn.com") { return .one15 }
        if url.contains("uc.cn") || url.contains("ucloud.cn") { return .uc }
        return nil
    }

    // MARK: - 阿里云盘

    func resolveAliPlayURL(shareURL: String, refreshToken: String) async throws -> PlayResult {
        let tokenResult = try await aliRefreshAccessToken(refreshToken: refreshToken)
        let accessToken = tokenResult.accessToken

        let shareId = extractAliShareId(from: shareURL)
        let shareToken = try await aliGetShareToken(shareId: shareId, token: accessToken)
        let fileId = try await aliGetShareFileList(shareId: shareId, shareToken: shareToken, token: accessToken)

        let playInfo = try await aliGetVideoPreviewPlayInfo(fileId: fileId, token: accessToken)

        guard let playURL = playInfo.videoPreviewPlayInfo?.liveTranscodingTaskList?.first?.url else {
            throw DriveError.noPlayURL("阿里: 未获取到转码播放地址")
        }

        return PlayResult(
            url: playURL,
            headers: ["Authorization": accessToken, "Referer": "https://www.aliyundrive.com/"],
            driveType: .ali
        )
    }

    private func aliRefreshAccessToken(refreshToken: String) async throws -> AliTokenResponse {
        var request = URLRequest(url: URL(string: "https://auth.aliyundrive.com/v2/account/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(AliTokenResponse.self, from: data)
    }

    private func aliGetShareToken(shareId: String, token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.aliyundrive.com/adrive/v3/share_file/get_share_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["share_id": shareId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        let result = try JSONDecoder().decode(AliShareTokenResponse.self, from: data)
        return result.shareToken
    }

    private func aliGetShareFileList(shareId: String, shareToken: String, token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.aliyundrive.com/adrive/v2/file/get_share_link_file_list")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "share_id": shareId,
            "share_token": shareToken,
            "parent_file_id": "root",
            "limit": 20,
            "order_by": "name",
            "order_direction": "ASC"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: request)

        let respStr = String(data: data, encoding: .utf8) ?? ""
        print("[Ali] 文件列表响应: \(respStr.prefix(500))")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[Ali] ❌ 文件列表响应非JSON")
            throw DriveError.invalidResponse
        }

        guard let items = json["items"] as? [[String: Any]] else {
            if let code = json["code"] as? String, code != "OK" {
                let message = json["message"] as? String ?? "未知错误"
                print("[Ali] ❌ API错误: \(message)")
                throw DriveError.noPlayURL("阿里: \(message)")
            }
            print("[Ali] ❌ 文件列表为空")
            throw DriveError.noPlayURL("阿里: 分享为空或已失效")
        }

        guard let first = items.first else {
            print("[Ali] ❌ 文件列表为空数组")
            throw DriveError.noPlayURL("阿里: 分享中没有文件")
        }

        if let fid = first["file_id"] as? String {
            print("[Ali] ✅ 获取到file_id: \(fid)")
            return fid
        } else if let fid = first["file_id"] as? Int {
            print("[Ali] ✅ 获取到file_id(Int): \(fid)")
            return String(fid)
        }

        print("[Ali] ❌ 无法从文件项中提取file_id")
        throw DriveError.noPlayURL("阿里: 无法获取文件ID")
    }

    private func aliGetVideoPreviewPlayInfo(fileId: String, token: String) async throws -> AliVideoPreviewResponse {
        let url = URL(string: "https://api.aliyundrive.com/adrive/v2/file/get_video_preview_play_info")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "file_id": fileId,
            "category": "live_transcoding"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)

        let respStr = String(data: data, encoding: .utf8) ?? ""
        print("[Ali] 播放信息响应: \(respStr.prefix(500))")

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let code = json["code"] as? String, code != "OK" {
                let message = json["message"] as? String ?? "获取播放地址失败"
                print("[Ali] ❌ API错误: \(message)")
                throw DriveError.noPlayURL("阿里: \(message)")
            }
        }

        do {
            let result = try JSONDecoder().decode(AliVideoPreviewResponse.self, from: data)

            guard let taskList = result.videoPreviewPlayInfo?.liveTranscodingTaskList, !taskList.isEmpty else {
                print("[Ali] ❌ 没有可用的转码任务列表")
                throw DriveError.noPlayURL("阿里: 该文件无视频播放地址")
            }

            let qualities = ["FHD", "HD", "SD", "LD"]
            for quality in qualities {
                if let task = taskList.first(where: { $0.templateId?.contains(quality) == true }), let url = task.url {
                    print("[Ali] ✅ 获取到播放地址 (\(quality))")
                    return result
                }
            }

            if taskList.first?.url != nil {
                print("[Ali] ✅ 获取到播放地址")
                return result
            }

            print("[Ali] ❌ 转码任务列表中没有有效的URL")
            throw DriveError.noPlayURL("阿里: 视频转码未完成")
        } catch {
            print("[Ali] ❌ JSON解码失败: \(error)")
            throw DriveError.invalidResponse
        }
    }

    private func extractAliShareId(from url: String) -> String {
        let pattern = #"/s/([^/?]+)"#
        if let range = url.range(of: pattern, options: .regularExpression) {
            let matched = String(url[range])
            return matched.replacingOccurrences(of: "/s/", with: "")
        }
        return url
    }

    // MARK: - 夸克网盘

    func resolveQuarkPlayURL(shareURL: String, cookie: String) async throws -> PlayResult {
        print("[Quark] 开始解析: \(shareURL)")
        let (shareId, pwdId) = try await quarkExtractShareInfo(shareURL: shareURL, cookie: cookie)
        print("[Quark] shareId=\(shareId) pwdId=\(pwdId)")

        let shareToken = try await quarkGetShareToken(shareId: shareId, pwdId: pwdId, cookie: cookie)
        print("[Quark] shareToken=\(shareToken.isEmpty ? "空" : "已获取")")

        let folderId = try await quarkEnsureFolder(cookie: cookie)
        print("[Quark] folderId=\(folderId.isEmpty ? "空" : folderId)")

        let fileIds = try await quarkSaveShare(shareId: shareId, pwdId: pwdId, shareToken: shareToken, folderId: folderId, cookie: cookie)
        print("[Quark] 转存完成 fileIds=\(fileIds)")

        guard let fileId = fileIds.first else { throw DriveError.noPlayURL("夸克: 转存后未返回文件ID") }
        let playURL = try await quarkGetPlayURL(fileId: fileId, cookie: cookie)
        print("[Quark] ✅ 播放地址: \(playURL.prefix(80))")

        scheduleCleanup(drive: .quark, fileIds: fileIds, token: cookie, delay: 180)

        return PlayResult(
            url: playURL,
            headers: ["Cookie": cookie, "Referer": "https://pan.quark.cn/"],
            driveType: .quark
        )
    }

    private func quarkExtractShareInfo(shareURL: String, cookie: String) async throws -> (String, String) {
        let shareId = shareURL.split(separator: "/").last?.split(separator: "?").first.map(String.init) ?? ""
        var pwdId = ""
        if let range = shareURL.range(of: #"pwd=([^&]+)"#, options: .regularExpression) {
            pwdId = String(shareURL[range]).replacingOccurrences(of: "pwd=", with: "")
        }
        return (shareId, pwdId)
    }

    private func quarkGetShareToken(shareId: String, pwdId: String, cookie: String) async throws -> String {
        let url = URL(string: "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let body: [String: Any] = ["share_id": shareId, "pwd_id": pwdId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let st = dataObj["share_token"] as? String else { return "" }
        return st
    }

    private func quarkEnsureFolder(cookie: String) async throws -> String {
        let listURL = URL(string: "https://drive-pc.quark.cn/1/clouddrive/file/sort")!
        var req = URLRequest(url: listURL)
        req.httpMethod = "POST"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let listBody: [String: Any] = ["pdir_fid": "", "sort_by": "file_name", "sort_order": "asc", "page": 1, "size": 100]
        req.httpBody = try JSONSerialization.data(withJSONObject: listBody)
        let (data, _) = try await session.data(for: req)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["data"] as? [String: Any],
           let files = list["list"] as? [[String: Any]] {
            for file in files {
                if let name = file["file_name"] as? String, name == "vbox播放",
                   let fid = file["fid"] as? String { return fid }
            }
        }
        let createURL = URL(string: "https://drive-pc.quark.cn/1/clouddrive/file")!
        var createReq = URLRequest(url: createURL)
        createReq.httpMethod = "POST"
        createReq.setValue(cookie, forHTTPHeaderField: "Cookie")
        createReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let createBody: [String: Any] = ["pdir_fid": "", "file_name": "vbox播放", "dir": true, "dir_path": ""]
        createReq.httpBody = try JSONSerialization.data(withJSONObject: createBody)
        let (createData, _) = try await session.data(for: createReq)
        if let createJson = try JSONSerialization.jsonObject(with: createData) as? [String: Any],
           let d = createJson["data"] as? [String: Any],
           let fid = d["fid"] as? String { return fid }
        return ""
    }

    private func quarkDeleteFiles(fileIds: [String], cookie: String) async {
        guard !fileIds.isEmpty else { return }
        let url = URL(string: "https://drive-pc.quark.cn/1/clouddrive/file/trash")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["file_ids": fileIds, "trash": true]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let _ = try? await session.data(for: req)
        print("[CloudDrive] ✅ 夸克已删除 \(fileIds.count) 个转存文件")
    }

    private func quarkSaveShare(shareId: String, pwdId: String, shareToken: String, folderId: String, cookie: String) async throws -> [String] {
        let url = URL(string: "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/save")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        var body: [String: Any] = [
            "share_id": shareId,
            "pwd_id": pwdId,
            "to_pdir_fid": folderId
        ]
        if !shareToken.isEmpty { body["share_token"] = shareToken }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)

        let respStr = String(data: data, encoding: .utf8) ?? ""
        print("[Quark] save响应: \(respStr.prefix(500))")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[Quark] ❌ 转存响应非JSON")
            throw DriveError.saveFailed
        }

        if let status = json["status"] as? Int, status != 200 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "状态码: \(status)"
            print("[Quark] ❌ 转存失败: \(message)")
            throw DriveError.noPlayURL("夸克转存失败: \(message)")
        }

        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "错误码: \(code)"
            print("[Quark] ❌ 转存失败: \(message)")
            throw DriveError.noPlayURL("夸克转存失败: \(message)")
        }

        if let d = json["data"] as? [String: Any] {
            if let fileIds = d["file_ids"] as? [String] {
                print("[Quark] ✅ 转存成功，file_ids: \(fileIds)")
                return fileIds
            }
            if let fileIds = d["file_ids"] as? [Int] {
                let stringIds = fileIds.map { String($0) }
                print("[Quark] ✅ 转存成功，file_ids(Int): \(stringIds)")
                return stringIds
            }
            if let list = d["list"] as? [[String: Any]], let first = list.first {
                if let fid = first["fid"] as? String {
                    print("[Quark] ✅ 转存成功，从list获取fid: \(fid)")
                    return [fid]
                } else if let fid = first["fid"] as? Int {
                    print("[Quark] ✅ 转存成功，从list获取fid(Int): \(fid)")
                    return [String(fid)]
                } else if let fileId = first["file_id"] as? String {
                    return [fileId]
                } else if let fileId = first["file_id"] as? Int {
                    return [String(fileId)]
                }
            }
        }

        print("[Quark] ⚠️ 转存成功但未找到file_ids，返回shareId作为fallback")
        return [shareId]
    }

    private func quarkGetPlayURL(fileId: String, cookie: String) async throws -> String {
        let url = URL(string: "https://drive-pc.quark.cn/1/clouddrive/file/v2/play")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let body: [String: Any] = ["file_id": fileId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let playURL = json["play_url"] as? String else {
            throw DriveError.noPlayURL("夸克: 未返回播放地址")
        }
        return playURL
    }

    // MARK: - 百度网盘

    private func parseBaiduToken(_ raw: String) -> (cookie: String, bdussOnly: String) {
        if raw.range(of: #"BDUSS=([^;|]+)"#, options: .regularExpression) != nil {
            var bduss = ""
            var stoken = ""
            if let r1 = raw.range(of: #"BDUSS=([^;|]+)"#, options: .regularExpression),
               let eq = raw[r1].firstIndex(of: "=") {
                let val = String(raw[raw.index(after: eq)..<r1.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                bduss = val
            }
            if let r2 = raw.range(of: #"STOKEN=([^;|]+)"#, options: .regularExpression),
               let eq = raw[r2].firstIndex(of: "=") {
                let val = String(raw[raw.index(after: eq)..<r2.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                stoken = val
            }
            if !bduss.isEmpty {
                var cookie = "BDUSS=\(bduss)"
                if !stoken.isEmpty { cookie += "; STOKEN=\(stoken)" }
                return (cookie, bduss)
            }
        }

        if raw.contains("|") {
            let cleaned = raw.replacingOccurrences(of: #"^BDUSS="#, with: "", options: .regularExpression)
            let parts = cleaned.components(separatedBy: "|")
            let bduss = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            var cookie = "BDUSS=\(bduss)"
            if parts.count >= 2 {
                let stoken = parts[1].replacingOccurrences(of: #"^STOKEN="#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                cookie += "; STOKEN=\(stoken)"
            }
            return (cookie, bduss)
        }

        let bduss = raw.replacingOccurrences(of: "BDUSS=", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ("BDUSS=\(bduss)", bduss)
    }

    func baiduGetFileList(shareURL: String, bduss: String) async throws -> [BaiduFileItem] {
        let parsed = parseBaiduToken(bduss)
        let cookie = parsed.cookie

        if let files = try? await baiduGetFileListViaWorker(shareURL: shareURL, pwd: extractBaiduPwd(from: shareURL), cookie: cookie) {
            return files
        }

        baiduLog("[Baidu-Worker] ⚠️ 文件列表代理失败，回退直连解析")
        let (_, _, files) = try await baiduExtractShareMeta(shareURL: shareURL, cookie: cookie, returnAll: true)
        return files
    }

    func resolveBaiduPlayURL(shareURL: String, bduss: String) async throws -> PlayResult {
        try await resolveBaiduPlayURLInternal(shareURL: shareURL, bduss: bduss, pwd: nil)
    }

    func resolveBaiduPlayURL(shareURL: String, bduss: String, pwd: String?) async throws -> PlayResult {
        try await resolveBaiduPlayURLInternal(shareURL: shareURL, bduss: bduss, pwd: pwd)
    }

    private func extractBaiduPwd(from shareURL: String) -> String? {
        if let match = try? NSRegularExpression(pattern: #"[?&]pwd=([^&]+)"#)
            .firstMatch(in: shareURL, range: NSRange(shareURL.startIndex..., in: shareURL)),
           let range = Range(match.range(at: 1), in: shareURL) {
            return String(shareURL[range])
        }
        return nil
    }

    /// 通过 Cloudflare Worker 代理解析文件列表，避免直连百度分享页提取码验证卡死
    private func baiduGetFileListViaWorker(shareURL: String, pwd: String?, cookie: String) async throws -> [BaiduFileItem] {
        baiduLog("[Baidu-Worker] 代理解析文件列表... Cookie=\(cookie.isEmpty ? "无" : "已传递")")

        let response = try await BaiduProxyClient.shared.parseShareLink(
            url: shareURL,
            pwd: pwd ?? "",
            cookie: cookie
        )

        guard let success = response["success"] as? Bool, success else {
            let err = response["error"] as? String ?? "未知错误"
            baiduLog("[Baidu-Worker] ❌ 文件列表解析失败：\(err)")
            throw DriveError.noPlayURL("Worker 代理解析失败：\(err)")
        }

        let data = (response["data"] as? [String: Any]) ?? response
        let rawFiles = data["files"] as? [[String: Any]]
            ?? data["file_list"] as? [[String: Any]]
            ?? data["list"] as? [[String: Any]]
            ?? []

        let files: [BaiduFileItem] = rawFiles.compactMap { item in
            let fsId = item["fs_id"] as? String
                ?? item["fsId"] as? String
                ?? (item["fs_id"] as? NSNumber)?.stringValue
                ?? (item["fsId"] as? NSNumber)?.stringValue
                ?? ""
            let path = item["path"] as? String
            let name = path
                ?? item["file_name"] as? String
                ?? item["server_filename"] as? String
                ?? item["name"] as? String
                ?? "未知文件"
            guard !fsId.isEmpty else { return nil }
            return BaiduFileItem(fsId: fsId, name: name)
        }

        guard !files.isEmpty else {
            baiduLog("[Baidu-Worker] ❌ 未解析到文件列表")
            throw DriveError.noPlayURL("Worker 代理未返回文件列表")
        }

        baiduLog("[Baidu-Worker] ✅ 文件列表：\(files.count) 个")
        return files
    }

    /// 【新增】通过 Cloudflare Worker 代理获取播放地址
    private func baiduResolveViaWorker(shareURL: String, pwd: String?, fsId: String? = nil, cookie: String = "") async throws -> PlayResult {
        baiduLog("[Baidu-Worker] 调用 Cloudflare Worker 代理... Cookie=\(cookie.isEmpty ? "无" : "已传递")")

        let response = try await BaiduProxyClient.shared.getPlayURL(
            shareURL: shareURL,
            pwd: pwd ?? "",
            fsId: fsId ?? "",
            cookie: cookie
        )

        guard let success = response["success"] as? Bool, success else {
            let err = response["error"] as? String ?? "未知错误"
            baiduLog("[Baidu-Worker] ❌ 失败：\(err)")
            throw DriveError.noPlayURL("Worker 代理：\(err)")
        }

        guard let data = response["data"] as? [String: Any],
              let playURL = data["url"] as? String, !playURL.isEmpty else {
            baiduLog("[Baidu-Worker] ❌ 未返回播放地址")
            throw DriveError.noPlayURL("Worker 代理：未返回播放地址")
        }

        let headers = (data["headers"] as? [String: String]) ?? [:]
        baiduLog("[Baidu-Worker] ✅ 成功获取播放地址：\(playURL.prefix(80))...")
        return PlayResult(url: playURL, headers: headers, driveType: .baidu)
    }

    private func resolveBaiduPlayURLInternal(shareURL: String, bduss: String, pwd: String?) async throws -> PlayResult {
        let pwdForWorker = pwd ?? extractBaiduPwd(from: shareURL)
        let parsed = parseBaiduToken(bduss)
        let cookie = parsed.cookie
        let bdussOnly = parsed.bdussOnly

        do {
            return try await baiduResolveViaWorker(shareURL: shareURL, pwd: pwdForWorker, cookie: cookie)
        } catch {
            baiduLog("[Baidu-Worker] ⚠️ 播放地址代理失败，回退直连解析：\(error.localizedDescription)")
        }

        let (shareid, shareUk, files) = try await baiduExtractShareMeta(shareURL: shareURL, cookie: cookie, returnAll: false)
        guard let first = files.first, !first.fsId.isEmpty else { throw DriveError.noPlayURL("百度：未从分享页提取到文件 ID") }

        let strategies: [(String, () async throws -> PlayResult)] = [
            ("Cloudflare Worker 代理", { try await self.baiduResolveViaWorker(shareURL: shareURL, pwd: pwdForWorker, fsId: first.fsId, cookie: cookie) }),
            ("get_video_info API", { try await self.baiduGetVideoInfoPlayURL(shareid: shareid, shareUk: shareUk, fsId: first.fsId, cookie: cookie) }),
            ("sharedownload API", { try await self.baiduGetDirectLink(shareid: shareid, shareUk: shareUk, fsId: first.fsId, fileName: first.name, cookie: cookie) }),
            ("PCS locatedownload", { try await self.baiduGetPCSPlayURL(fileName: first.name, cookie: cookie) }),
            ("WebView 提取", { try await self.baiduExtractVideoFromWebView(shareURL: shareURL, cookie: cookie) })
        ]

        for (name, strategy) in strategies {
            do {
                baiduLog("[Baidu] 尝试策略: \(name)...")
                let result = try await strategy()
                baiduLog("[Baidu] ✅ 策略 \(name) 成功")
                return result
            } catch {
                baiduLog("[Baidu] ⚠️ 策略 \(name) 失败: \(error.localizedDescription)")
                continue
            }
        }

        throw DriveError.noPlayURL("百度网盘：所有解析策略均失败")
    }

    func resolveBaiduPlayURL(shareURL: String, bduss: String, fsId: String) async throws -> PlayResult {
        let pwdForWorker = extractBaiduPwd(from: shareURL)
        let parsed = parseBaiduToken(bduss)
        let cookie = parsed.cookie
        let bdussOnly = parsed.bdussOnly

        do {
            return try await baiduResolveViaWorker(shareURL: shareURL, pwd: pwdForWorker, fsId: fsId, cookie: cookie)
        } catch {
            baiduLog("[Baidu-Worker] ⚠️ 指定文件播放代理失败，回退直连解析：\(error.localizedDescription)")
        }

        let (shareid, shareUk, files) = try await baiduExtractShareMeta(shareURL: shareURL, cookie: cookie, returnAll: false)
        guard !shareid.isEmpty else { throw DriveError.noPlayURL("百度：无法获取分享信息") }
        let fileName = files.first(where: { $0.fsId == fsId })?.name ?? "未知"

        let strategies: [(String, () async throws -> PlayResult)] = [
            ("Cloudflare Worker 代理", { try await self.baiduResolveViaWorker(shareURL: shareURL, pwd: pwdForWorker, fsId: fsId, cookie: cookie) }),
            ("get_video_info API", { try await self.baiduGetVideoInfoPlayURL(shareid: shareid, shareUk: shareUk, fsId: fsId, cookie: cookie) }),
            ("sharedownload API", { try await self.baiduGetDirectLink(shareid: shareid, shareUk: shareUk, fsId: fsId, fileName: fileName, cookie: cookie) }),
            ("PCS locatedownload", {
                let _ = try await self.baiduEnsureFolder(bduss: bdussOnly)
                let _ = try await self.baiduTransferFile(shareid: shareid, surl: shareURL.split(separator: "/").last?.split(separator: "?").first.map(String.init) ?? "", shareUk: shareUk, fsId: fsId, cookie: cookie)
                return try await self.baiduGetPCSPlayURL(fileName: fileName, cookie: cookie)
            }),
            ("WebView 提取", { try await self.baiduExtractVideoFromWebView(shareURL: shareURL, cookie: cookie) })
        ]

        for (name, strategy) in strategies {
            do {
                baiduLog("[Baidu] 尝试策略: \(name)...")
                let result = try await strategy()
                baiduLog("[Baidu] ✅ 策略 \(name) 成功")
                return result
            } catch {
                baiduLog("[Baidu] ⚠️ 策略 \(name) 失败: \(error.localizedDescription)")
                continue
            }
        }

        throw DriveError.noPlayURL("百度网盘：所有解析策略均失败")
    }

    private func baiduExtractShareMeta(shareURL: String, cookie: String, returnAll: Bool = false) async throws -> (shareid: String, shareUk: String, files: [BaiduFileItem]) {
        baiduLog("[Baidu] 提取分享信息：\(shareURL)")

        let surl: String
        if let match = try? NSRegularExpression(pattern: #"/s/1([^/?]+)"#).firstMatch(in: shareURL, range: NSRange(shareURL.startIndex..., in: shareURL)),
           let r = Range(match.range(at: 1), in: shareURL) {
            surl = "1" + String(shareURL[r])
        } else if let match = try? NSRegularExpression(pattern: #"/s/([^/?]+)"#).firstMatch(in: shareURL, range: NSRange(shareURL.startIndex..., in: shareURL)),
                  let r = Range(match.range(at: 1), in: shareURL) {
            surl = String(shareURL[r])
        } else {
            baiduLog("[Baidu] ❌ 无法提取 surl")
            throw DriveError.invalidShareURL
        }

        let pwd: String?
        if let match = try? NSRegularExpression(pattern: #"[?&]pwd=([^&]+)"#).firstMatch(in: shareURL, range: NSRange(shareURL.startIndex..., in: shareURL)),
           let r = Range(match.range(at: 1), in: shareURL) {
            pwd = String(shareURL[r])
            baiduLog("[Baidu] 检测到提取码: \(pwd!)")
        } else {
            pwd = nil
        }

        let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        var currentCookie = cookie

        guard let pageURL = URL(string: shareURL) else { throw DriveError.invalidShareURL }
        var req = URLRequest(url: pageURL)
        req.setValue(currentCookie, forHTTPHeaderField: "Cookie")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        baiduLog("[Baidu] 请求原始链接...")
        let (data, response) = try await session.data(for: req)
        guard let httpResp = response as? HTTPURLResponse else { throw DriveError.invalidResponse }

        if httpResp.statusCode != 200 {
            baiduLog("[Baidu] ❌ 返回状态码: \(httpResp.statusCode)")
            if httpResp.statusCode == 404 {
                throw DriveError.noPlayURL("百度网盘：分享链接不存在或已失效")
            }
            throw DriveError.noPlayURL("百度网盘：请求失败(\(httpResp.statusCode))")
        }

        if let sc = httpResp.allHeaderFields["Set-Cookie"] as? String { currentCookie += "; " + sc
        } else if let scs = httpResp.allHeaderFields["Set-Cookie"] as? [String] { currentCookie += "; " + scs.joined(separator: "; ") }

        guard var html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            baiduLog("[Baidu] ❌ 无法解码")
            throw DriveError.noPlayURL("百度网盘：服务器返回异常数据")
        }

        var shareid = ""
        var shareUk = ""
        var files: [BaiduFileItem] = []

        if let pwd = pwd, (html.contains("请输入提取码") || html.contains("accessCode")) {
            baiduLog("[Baidu] 需要验证提取码...")
            baiduLog("[Baidu] Cookie 片段: \(String(currentCookie.prefix(100)))...")

            var vidShareid = ""
            var vidUk = ""
            var vidFsId = ""
            var vidFileName = "未知文件"

            for pattern in ["\"shareid\"\\s*:\\s*\"?(\\d+)\"?", "\"share_id\"\\s*:\\s*\"?(\\d+)\"?", "shareid=(\\d+)", "data-shareid=\"(\\d+)\""] {
                if let r = try? NSRegularExpression(pattern: pattern).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let rr = Range(r.range(at: 1), in: html) { vidShareid = String(html[rr]); break }
            }
            for pattern in ["\"share_uk\"\\s*:\\s*\"?(\\d+)\"?", "\"uk\"\\s*:\\s*\"?(\\d+)\"?"] {
                if let r = try? NSRegularExpression(pattern: pattern).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let rr = Range(r.range(at: 1), in: html) { vidUk = String(html[rr]); break }
            }
            if let r = try? NSRegularExpression(pattern: "\"fs_id\"\\s*:\\s*\"?(\\d+)\"?").firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let rr = Range(r.range(at: 1), in: html) { vidFsId = String(html[rr]) }
            if let r = try? NSRegularExpression(pattern: "\"server_filename\"\\s*:\\s*\"([^\"]+)\"").firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let rr = Range(r.range(at: 1), in: html) { vidFileName = String(html[rr]) }

            baiduLog("[Baidu] 从初始HTML提取: shareid=\(vidShareid), uk=\(vidUk), fsId=\(vidFsId), file=\(vidFileName)")

            let verifyURLString = "https://pan.baidu.com/share/verify?surl=\(surl)&t=\(Int(Date().timeIntervalSince1970 * 1000))&channel=chunlei&web=1&app_id=250528&clienttype=0"
            let verifyBodyString = "pwd=\(pwd)&vcode=&vcode_str=&channel=chunlei&web=1&app_id=250528&clienttype=0"

            var randsk = ""
            var verifyRetryCount = 0
            var verifyOK = false
            verifyLoop: while verifyRetryCount < 3 {
                let (vData, _) = try await BaiduWebViewBridge.shared.request(
                    url: verifyURLString,
                    method: "POST",
                    headers: [
                        "Content-Type": "application/x-www-form-urlencoded",
                        "Cookie": currentCookie,
                        "User-Agent": ua,
                        "X-Requested-With": "XMLHttpRequest",
                        "Origin": "https://pan.baidu.com",
                        "Referer": "https://pan.baidu.com/s/1\(surl)",
                    ],
                    body: verifyBodyString,
                    timeout: 15
                )
                baiduLog("[Baidu-WK] 验证响应：\(String(data: vData, encoding: .utf8) ?? "nil")")

                guard let vJson = try? JSONSerialization.jsonObject(with: vData) as? [String: Any],
                      let errno = vJson["errno"] as? Int else {
                    baiduLog("[Baidu] ❌ 验证响应解析失败")
                    throw DriveError.invalidResponse
                }

                if let r = vJson["randsk"] as? String { randsk = r }

                if errno == 0 { verifyOK = true; break verifyLoop }
                else if errno == -9 { throw DriveError.noPlayURL("百度网盘：提取码错误") }
                else if errno == 4 { throw DriveError.noPlayURL("百度网盘：需要图形验证码") }
                else if errno == 105 {
                    verifyRetryCount += 1
                    if verifyRetryCount < 3 {
                        let delay = verifyRetryCount * 3
                        baiduLog("[Baidu] ❌ 风控，\(delay)秒后重试")
                        try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                        continue verifyLoop
                    }
                    baiduLog("[Baidu] ❌ 风控重试失败，回退")
                    break verifyLoop
                } else {
                    let em = vJson["errmsg"] as? String ?? "errno=\(errno)"
                    baiduLog("[Baidu] ❌ 验证失败：\(em)")
                    throw DriveError.noPlayURL("百度网盘：验证失败 (\(em))")
                }
            }

            if verifyOK {
                baiduLog("[Baidu] ✅ 提取码验证成功")
                if !randsk.isEmpty {
                    currentCookie += "; randsk=\(randsk)"
                    baiduLog("[Baidu] 已提取 randsk")
                }
                let (data2, _) = try await BaiduWebViewBridge.shared.request(
                    url: pageURL.absoluteString,
                    method: "GET",
                    headers: [
                        "Cookie": currentCookie,
                        "User-Agent": ua,
                    ],
                    timeout: 15
                )
                guard let newHtml = String(data: data2, encoding: .utf8) ?? String(data: data2, encoding: .ascii) else {
                    throw DriveError.invalidResponse
                }
                html = newHtml
                baiduLog("[Baidu] ✅ 重新请求分享页成功")
            } else {
                baiduLog("[Baidu] ⚠️ verify 失败，尝试获取文件信息...")

                if !vidShareid.isEmpty && !vidUk.isEmpty && !vidFsId.isEmpty {
                    baiduLog("[Baidu] 使用 HTML 初始提取的参数")
                    shareid = vidShareid
                    shareUk = vidUk
                    files = [BaiduFileItem(fsId: vidFsId, name: vidFileName)]
                    baiduLog("[Baidu] ✅ 使用 HTML 提取参数")
                } else if !vidShareid.isEmpty && !vidUk.isEmpty {
                    baiduLog("[Baidu] 尝试 WAP 绕过验证...")
                    do {
                        let (fsId, name) = try await baiduBypassVerify(shareid: vidShareid, uk: vidUk, surl: surl, cookie: currentCookie)
                        files = [BaiduFileItem(fsId: fsId, name: name)]
                        shareid = vidShareid
                        shareUk = vidUk
                        baiduLog("[Baidu] ✅ WAP 绕过成功")
                    } catch {
                        baiduLog("[Baidu] ❌ WAP 绕过失败")
                        throw DriveError.noPlayURL("百度网盘：验证失败")
                    }
                } else {
                    baiduLog("[Baidu] ❌ 无法提取 shareid/uk")
                    throw DriveError.noPlayURL("百度网盘：验证失败")
                }
            }
        }

        if files.isEmpty {
            if let yunDataRange = html.range(of: "window.yunData="),
               let jsonStart = html[yunDataRange.upperBound...].range(of: "{"),
               let jsonEnd = html[yunDataRange.upperBound...].range(of: "};") {
                let jStart = html.distance(from: html.startIndex, to: jsonStart.lowerBound)
                let jEnd = html.distance(from: html.startIndex, to: jsonEnd.lowerBound)
                if let jData = String(html[html.index(html.startIndex, offsetBy: jStart)..<html.index(html.startIndex, offsetBy: jEnd + 1)]).data(using: .utf8),
                   let yunData = try? JSONSerialization.jsonObject(with: jData) as? [String: Any] {
                    if let sid = yunData["shareid"] as? String { shareid = sid
                    } else if let sid = yunData["shareid"] as? Int { shareid = String(sid) }
                    if let uk = yunData["share_uk"] as? String { shareUk = uk
                    } else if let uk = yunData["share_uk"] as? Int { shareUk = String(uk)
                    } else if let uk = yunData["uk"] as? String { shareUk = uk
                    } else if let uk = yunData["uk"] as? Int { shareUk = String(uk) }
                }
            }

            if let yunDataRange = html.range(of: "window.yunData="),
               let jsonStart = html[yunDataRange.upperBound...].range(of: "{"),
               let jsonEnd = html[yunDataRange.upperBound...].range(of: "};") {
                let jStart = html.distance(from: html.startIndex, to: jsonStart.lowerBound)
                let jEnd = html.distance(from: html.startIndex, to: jsonEnd.lowerBound)
                if let jData = String(html[html.index(html.startIndex, offsetBy: jStart)..<html.index(html.startIndex, offsetBy: jEnd + 1)]).data(using: .utf8),
                   let yunData = try? JSONSerialization.jsonObject(with: jData) as? [String: Any],
                   let fileList = yunData["file_list"] as? [[String: Any]], !fileList.isEmpty {
                    for item in fileList {
                        var fsId = ""
                        if let fid = item["fs_id"] as? String { fsId = fid
                        } else if let fid = item["fs_id"] as? Int64 { fsId = String(fid)
                        } else if let fid = item["fs_id"] as? Int { fsId = String(fid) }
                        let fileName = item["server_filename"] as? String ?? "未知"
                        if !fsId.isEmpty { files.append(BaiduFileItem(fsId: fsId, name: fileName)) }
                    }
                    baiduLog("[Baidu] yunData 文件列表")
                }
            }

            if files.isEmpty {
                if let fidRegex = try? NSRegularExpression(pattern: #""fs_id":\s*(\d+)"#),
                   let nameRegex = try? NSRegularExpression(pattern: #""server_filename":\s*"([^"]+)""#) {
                    let fidMatches = fidRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                    let nameMatches = nameRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                    for i in 0..<fidMatches.count {
                        if let fidR = Range(fidMatches[i].range(at: 1), in: html) {
                            let fsId = String(html[fidR])
                            var fileName = "文件\(i+1)"
                            if i < nameMatches.count, let nameR = Range(nameMatches[i].range(at: 1), in: html) {
                                fileName = String(html[nameR])
                            }
                            files.append(BaiduFileItem(fsId: fsId, name: fileName))
                        }
                    }
                    if !files.isEmpty {
                        baiduLog("[Baidu] 正则提取到 \(files.count) 个文件")
                    }
                }
            }
        }

        if shareid.isEmpty || shareUk.isEmpty {
            baiduLog("[Baidu] ❌ 无法提取 shareid 或 shareUk")
            if pwd != nil {
                throw DriveError.noPlayURL("百度网盘：需要提取码")
            } else {
                throw DriveError.noPlayURL("百度网盘：无法获取分享信息")
            }
        }
        if files.isEmpty {
            baiduLog("[Baidu] ❌ 无法提取文件列表")
            throw DriveError.noPlayURL("百度网盘：未从分享页提取到文件 ID")
        }

        baiduLog("[Baidu] ✅ shareid=\(shareid), shareUk=\(shareUk), 文件=\(files[0].name)")
        return (shareid, shareUk, files)
    }

    private func baiduTransferFile(shareid: String, surl: String, shareUk: String, fsId: String, cookie: String) async throws -> [String] {
        let url = URL(string: "https://pan.baidu.com/share/transfer")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let params = "shareid=\(shareid)&from=\(surl)&share_uk=\(shareUk)&sekey=&pwd=&fsidlist=[\(fsId)]&path=/vbox播放/"
        request.httpBody = params.data(using: .utf8)
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.noPlayURL("百度: 转存接口返回非JSON")
        }
        guard let errno = json["errno"] as? Int, errno == 0 else {
            let errno = json["errno"] as? Int ?? -1
            let errmsg = json["errmsg"] as? String ?? json["show_msg"] as? String ?? "未知错误"
            baiduLog("[Baidu] ❌ 转存失败")
            if errno == 112 {
                throw DriveError.noPlayURL("百度: 转存需要登录验证")
            } else if errno == -9 || errno == 10 {
                throw DriveError.noPlayURL("百度: 分享文件可能需要提取码")
            }
            throw DriveError.saveFailed
        }
        return [fsId]
    }

    private func baiduBypassVerify(shareid: String, uk: String, surl: String, cookie: String) async throws -> (fsId: String, name: String) {
        baiduLog("[Baidu-Bypass] 尝试绕过验证...")

        let shareURL = "https://pan.baidu.com/s/\(surl)"
        
        do {
            let response = try await BaiduProxyClient.shared.parseShareLink(
                url: shareURL,
                pwd: "",
                cookie: cookie
            )
            if let success = response["success"] as? Bool, success,
               let data = response["data"] as? [String: Any],
               let files = data["files"] as? [[String: Any]], !files.isEmpty,
               let fsId = files[0]["fs_id"] as? String, !fsId.isEmpty,
               let fileName = files[0]["server_filename"] as? String {
                baiduLog("[Baidu-Bypass] ✅ Cloudflare Worker 代理成功")
                return (fsId, fileName)
            }
        } catch {
            baiduLog("[Baidu-Bypass] ⚠️ Cloudflare Worker 代理失败: \(error.localizedDescription)")
        }

        let userAgents = [
            "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
            "Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Mobile Safari/537.36",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Edge/120.0.0.0",
        ]

        let strategies: [(String, () async throws -> (String, String))] = [
            ("webview bridge", { try await self.bypassStrategyWebView(shareid: shareid, uk: uk, surl: surl, cookie: cookie) }),
            ("WAP wxlist", { try await self.bypassStrategyWapWxlist(shareid: shareid, uk: uk, surl: surl, cookie: cookie, ua: userAgents.randomElement()!) }),
            ("WAP shareinfo", { try await self.bypassStrategyWapShareInfo(shareid: shareid, uk: uk, surl: surl, cookie: cookie, ua: userAgents.randomElement()!) }),
            ("web page parse", { try await self.bypassStrategyWebPage(shareid: shareid, uk: uk, surl: surl, cookie: cookie, ua: userAgents.randomElement()!) }),
            ("share/list", { try await self.bypassStrategyShareList(shareid: shareid, uk: uk, surl: surl, cookie: cookie, ua: userAgents.randomElement()!) }),
        ]

        for (name, strategy) in strategies {
            do {
                baiduLog("[Baidu-Bypass] 尝试策略: \(name)")
                let (fsId, fileName) = try await strategy()
                if !fsId.isEmpty {
                    baiduLog("[Baidu-Bypass] ✅ \(name) 成功")
                    return (fsId, fileName)
                }
            } catch {
                baiduLog("[Baidu-Bypass] ❌ \(name) 失败: \(error.localizedDescription)")
                try await Task.sleep(nanoseconds: UInt64(Int.random(in: 1000...3000)) * 1_000_000)
            }
        }

        throw DriveError.noPlayURL("百度网盘：所有绕过策略均失败")
    }

    private func bypassStrategyWapWxlist(shareid: String, uk: String, surl: String, cookie: String, ua: String) async throws -> (String, String) {
        let url = URL(string: "https://pan.baidu.com/wap/share/wxlist?shareid=\(shareid)&uk=\(uk)&surl=\(surl)&dir=%2F")!
        var req = URLRequest(url: url)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://pan.baidu.com", forHTTPHeaderField: "Referer")
        req.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        let (data, _) = try await session.data(for: req)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errno = json["errno"] as? Int, errno == 0,
           let list = json["list"] as? [[String: Any]], let first = list.first {
            return Self.extractFileInfo(first)
        }
        throw DriveError.noPlayURL("WAP wxlist 失败")
    }

    private func bypassStrategyShareList(shareid: String, uk: String, surl: String, cookie: String, ua: String) async throws -> (String, String) {
        var components = URLComponents(string: "https://pan.baidu.com/share/list")!
        components.queryItems = [
            URLQueryItem(name: "shareid", value: shareid),
            URLQueryItem(name: "uk", value: uk),
            URLQueryItem(name: "surl", value: surl),
            URLQueryItem(name: "dir", value: "/"),
            URLQueryItem(name: "order", value: "time"),
            URLQueryItem(name: "desc", value: "1"),
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "clienttype", value: "0"),
            URLQueryItem(name: "web", value: "1"),
        ]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://pan.baidu.com/s/1\(surl)", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 15

        let (data, _) = try await session.data(for: req)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errno = json["errno"] as? Int, errno == 0,
           let list = json["list"] as? [[String: Any]], let first = list.first {
            return Self.extractFileInfo(first)
        }
        throw DriveError.noPlayURL("share/list 失败")
    }

    private func bypassStrategyWapShareInfo(shareid: String, uk: String, surl: String, cookie: String, ua: String) async throws -> (String, String) {
        let url = URL(string: "https://pan.baidu.com/wap/share/info?shareid=\(shareid)&uk=\(uk)&surl=\(surl)")!
        var req = URLRequest(url: url)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://pan.baidu.com", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 15

        let (data, _) = try await session.data(for: req)
        let html = String(data: data, encoding: .utf8) ?? ""

        for pattern in ["\"fs_id\"\\s*:\\s*\"?(\\d+)\"?", "fs_id=(\\d+)", "\"fs_id\"\\s*:\\s*(\\d+)"] {
            if let r = try? NSRegularExpression(pattern: pattern).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let rr = Range(r.range(at: 1), in: html) {
                let fsId = String(html[rr])
                var name = "未知"
                if let rn = try? NSRegularExpression(pattern: "\"server_filename\"\\s*:\\s*\"([^\"]+)\"").firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let rrN = Range(rn.range(at: 1), in: html) { name = String(html[rrN]) }
                return (fsId, name)
            }
        }
        throw DriveError.noPlayURL("WAP shareinfo 失败")
    }

    private func bypassStrategyWebPage(shareid: String, uk: String, surl: String, cookie: String, ua: String) async throws -> (String, String) {
        let url = URL(string: "https://pan.baidu.com/s/1\(surl)")!
        var req = URLRequest(url: url)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://pan.baidu.com", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 20

        let (data, _) = try await session.data(for: req)
        let html = String(data: data, encoding: .utf8) ?? ""

        if let match = html.range(of: #"window\.yunData\s*=\s*\{[\s\S]*?\};"#, options: .caseInsensitive),
           let jsonStr = html[match].split(separator: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines).dropLast() {
            if let jsonData = String(jsonStr).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let list = json["file_list"] as? [[String: Any]], let first = list.first {
                return Self.extractFileInfo(first)
            }
        }

        for pattern in ["\"fs_id\"\\s*:\\s*\"?(\\d+)\"?", "fs_id=(\\d+)", "\"fs_id\"\\s*:\\s*(\\d+)"] {
            if let r = try? NSRegularExpression(pattern: pattern).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let rr = Range(r.range(at: 1), in: html) {
                let fsId = String(html[rr])
                var name = "未知"
                if let rn = try? NSRegularExpression(pattern: "\"server_filename\"\\s*:\\s*\"([^\"]+)\"").firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let rrN = Range(rn.range(at: 1), in: html) { name = String(html[rrN]) }
                return (fsId, name)
            }
        }
        throw DriveError.noPlayURL("web page parse 失败")
    }

    private func bypassStrategyWebView(shareid: String, uk: String, surl: String, cookie: String) async throws -> (String, String) {
        baiduLog("[Baidu-Bypass] 尝试 WebView Bridge...")
        let shareURL = "https://pan.baidu.com/s/1\(surl)"

        let (data, _) = try await BaiduWebViewBridge.shared.request(
            url: shareURL,
            method: "GET",
            headers: [
                "Cookie": cookie,
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Referer": "https://pan.baidu.com/",
            ],
            timeout: 25
        )

        let html = String(data: data, encoding: .utf8) ?? ""

        if let match = html.range(of: #"window\.yunData\s*=\s*\{[\s\S]*?\};"#, options: .caseInsensitive),
           let jsonStr = html[match].split(separator: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines).dropLast() {
            if let jsonData = String(jsonStr).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let list = json["file_list"] as? [[String: Any]], let first = list.first {
                return Self.extractFileInfo(first)
            }
        }

        for pattern in ["\"fs_id\"\\s*:\\s*\"?(\\d+)\"?", "fs_id=(\\d+)", "\"fs_id\"\\s*:\\s*(\\d+)"] {
            if let r = try? NSRegularExpression(pattern: pattern).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let rr = Range(r.range(at: 1), in: html) {
                let fsId = String(html[rr])
                var name = "未知"
                if let rn = try? NSRegularExpression(pattern: "\"server_filename\"\\s*:\\s*\"([^\"]+)\"").firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let rrN = Range(rn.range(at: 1), in: html) { name = String(html[rrN]) }
                return (fsId, name)
            }
        }
        throw DriveError.noPlayURL("webview bridge 失败")
    }

    private static func extractFileInfo(_ item: [String: Any]) -> (String, String) {
        var fsId = ""
        if let fid = item["fs_id"] as? String { fsId = fid }
        else if let fid = item["fs_id"] as? Int64 { fsId = String(fid) }
        else if let fid = item["fs_id"] as? Int { fsId = String(fid) }
        let name = item["server_filename"] as? String ?? item["filename"] as? String ?? "未知"
        return (fsId, name)
    }

    private func baiduGetPCSPlayURL(fileName: String, cookie: String) async throws -> PlayResult {
        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        let filePath = "/vbox播放/\(encodedName)"

        var components = URLComponents(string: "https://d.pcs.baidu.com/rest/2.0/pcs/file")!
        components.queryItems = [
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "method", value: "locatedownload"),
            URLQueryItem(name: "check_blue", value: "1"),
            URLQueryItem(name: "path", value: filePath),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.noPlayURL("百度：PCS 接口返回非 JSON")
        }

        if let errno = json["errno"] as? Int, errno != 0 {
            baiduLog("[Baidu] ❌ PCS 错误")
            throw DriveError.noPlayURL("百度：获取播放地址失败")
        }

        guard let urls = json["urls"] as? [[String: Any]],
              let firstURL = urls.first,
              let playURL = firstURL["url"] as? String else {
            if let url = json["url"] as? String {
                return PlayResult(
                    url: url,
                    headers: [
                        "Cookie": cookie,
                        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                        "Referer": "https://pan.baidu.com/",
                    ],
                    driveType: .baidu
                )
            }
            throw DriveError.noPlayURL("百度：PCS 未返回播放地址")
        }

        return PlayResult(
            url: playURL,
            headers: [
                "Cookie": cookie,
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                "Referer": "https://pan.baidu.com/",
            ],
            driveType: .baidu
        )
    }

    /// 【新增】使用 get_video_info API 获取 m3u8 播放地址
    private func baiduGetVideoInfoPlayURL(shareid: String, shareUk: String, fsId: String, cookie: String) async throws -> PlayResult {
        baiduLog("[Baidu-VideoInfo] 调用 get_video_info API...")

        let timestamp = Int(Date().timeIntervalSince1970)
        let sign = generateBaiduSign(shareid: shareid, shareUk: shareUk, fsId: fsId, timestamp: timestamp)

        var components = URLComponents(string: "https://pan.baidu.com/api/get_video_info")!
        components.queryItems = [
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "clienttype", value: "0"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "sign", value: sign),
            URLQueryItem(name: "timestamp", value: String(timestamp)),
            URLQueryItem(name: "shareid", value: shareid),
            URLQueryItem(name: "share_uk", value: shareUk),
            URLQueryItem(name: "fsid", value: fsId),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com/s/1\(shareid)", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }

        if let errno = json["errno"] as? Int, errno != 0 {
            let errmsg = json["errmsg"] as? String ?? "错误码：\(errno)"
            baiduLog("[Baidu-VideoInfo] ❌ errno=\(errno), \(errmsg)")
            throw DriveError.noPlayURL("百度：\(errmsg)")
        }

        if let videoInfo = json["video_info"] as? [String: Any] {
            if let m3u8Url = videoInfo["m3u8_url"] as? String, !m3u8Url.isEmpty {
                baiduLog("[Baidu-VideoInfo] ✅ 获取到 m3u8 地址")
                return PlayResult(
                    url: m3u8Url,
                    headers: [
                        "Cookie": cookie,
                        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                        "Referer": "https://pan.baidu.com/",
                    ],
                    driveType: .baidu
                )
            }
            if let mp4Url = videoInfo["mp4_url"] as? String, !mp4Url.isEmpty {
                baiduLog("[Baidu-VideoInfo] ✅ 获取到 mp4 地址")
                return PlayResult(
                    url: mp4Url,
                    headers: [
                        "Cookie": cookie,
                        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                        "Referer": "https://pan.baidu.com/",
                    ],
                    driveType: .baidu
                )
            }
        }

        throw DriveError.noPlayURL("百度：get_video_info 未返回播放地址")
    }

    /// 生成百度网盘 API 签名
    private func generateBaiduSign(shareid: String, shareUk: String, fsId: String, timestamp: Int) -> String {
        let rawString = "\(shareid)-\(shareUk)-\(fsId)-\(timestamp)"
        return rawString.md5()
    }

    private func baiduGetDirectLink(shareid: String, shareUk: String, fsId: String, fileName: String, cookie: String) async throws -> PlayResult {
        baiduLog("[Baidu-Direct] 调用 sharedownload API...")

        let timestamp = Int(Date().timeIntervalSince1970)
        let sign = generateBaiduSign(shareid: shareid, shareUk: shareUk, fsId: fsId, timestamp: timestamp)

        var components = URLComponents(string: "https://pan.baidu.com/api/sharedownload")!
        components.queryItems = [
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "clienttype", value: "0"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "sign", value: sign),
            URLQueryItem(name: "timestamp", value: String(timestamp)),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com/s/1\(shareid)", forHTTPHeaderField: "Referer")

        let bodyParams = "encodings=1&fsidlist=[\(fsId)]&primaryid=\(shareid)&uk=\(shareUk)"
        request.httpBody = bodyParams.data(using: .utf8)

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }

        if let errno = json["errno"] as? Int {
            if errno != 0 {
                let errmsg = json["errmsg"] as? String ?? "错误码：\(errno)"
                baiduLog("[Baidu-Direct] ❌ errno=\(errno), \(errmsg)")
                throw DriveError.noPlayURL("百度：\(errmsg)")
            }
        }

        guard let list = json["list"] as? [[String: Any]],
              let firstFile = list.first,
              let dlink = firstFile["dlink"] as? String else {
            throw DriveError.noPlayURL("百度：sharedownload 未返回下载链接")
        }

        let decodedDlink = dlink.replacingOccurrences(of: "\\/", with: "/")

        return PlayResult(
            url: decodedDlink,
            headers: [
                "Cookie": cookie,
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                "Referer": "https://pan.baidu.com/",
            ],
            driveType: .baidu
        )
    }

    /// 【新增】通过 WebView 提取视频播放地址（兜底方案）
    private func baiduExtractVideoFromWebView(shareURL: String, cookie: String) async throws -> PlayResult {
        baiduLog("[Baidu-WebView] 尝试通过 WebView 提取视频地址...")

        let (data, _) = try await BaiduWebViewBridge.shared.request(
            url: shareURL,
            method: "GET",
            headers: [
                "Cookie": cookie,
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                "Referer": "https://pan.baidu.com/",
            ],
            timeout: 20
        )

        guard let html = String(data: data, encoding: .utf8) else {
            throw DriveError.invalidResponse
        }

        let patterns = [
            #"videoUrl.*?["']([^"']+\.m3u8[^"']*)["']"#,
            #"playUrl.*?["']([^"']+\.m3u8[^"']*)["']"#,
            #"url.*?["']([^"']+\.m3u8[^"']*)["']"#,
            #"src.*?["']([^"']+\.m3u8[^"']*)["']"#,
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let m3u8Url = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                baiduLog("[Baidu-WebView] ✅ 提取到 m3u8 地址")
                return PlayResult(
                    url: m3u8Url,
                    headers: [
                        "Cookie": cookie,
                        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                        "Referer": "https://pan.baidu.com/",
                    ],
                    driveType: .baidu
                )
            }
        }

        throw DriveError.noPlayURL("百度：WebView 未提取到播放地址")
    }

    private func baiduEnsureFolder(bduss: String) async throws -> String {
        let listURL = URL(string: "https://pan.baidu.com/api/list?dir=/&order=time&desc=1&num=100&page=1&bdstoken=&channel=chunlei&web=1&app_id=250528&clienttype=0")!
        var req = URLRequest(url: listURL)
        req.setValue("BDUSS=\(bduss)", forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        if let (data, _) = try? await session.data(for: req),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["list"] as? [[String: Any]] {
            for item in list {
                if let name = item["server_filename"] as? String, name == "vbox播放" { return "/vbox播放/" }
            }
        }
        let createURL = URL(string: "https://pan.baidu.com/api/create?a=commit&bdstoken=&channel=chunlei&web=1&app_id=250528&clienttype=0")!
        var createReq = URLRequest(url: createURL)
        createReq.httpMethod = "POST"
        createReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        createReq.setValue("BDUSS=\(bduss)", forHTTPHeaderField: "Cookie")
        createReq.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let params = "path=/vbox播放&isdir=1&block_list=[]"
        createReq.httpBody = params.data(using: .utf8)
        let _ = try? await session.data(for: createReq)
        return "/vbox播放/"
    }

    private func baiduDeleteFiles(fileIds: [String], bduss: String) async {
        guard !fileIds.isEmpty else { return }
        let url = URL(string: "https://pan.baidu.com/api/filemanager?a=delete&bdstoken=&channel=chunlei&web=1&app_id=250528&clienttype=0")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("BDUSS=\(bduss)", forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let params = "filelist=[\"\(fileIds.first!)\"]&path=/vbox播放/"
        req.httpBody = params.data(using: .utf8)
        let _ = try? await session.data(for: req)
        print("[CloudDrive] ✅ 百度已删除转存文件")
    }

    // MARK: - 115 网盘

    func resolve115PlayURL(shareURL: String, cid: String) async throws -> PlayResult {
        let (shareCode, receiveCode) = try await extract115ShareCode(from: shareURL)

        let snapResult = try await one15Snap(shareCode: shareCode, receiveCode: receiveCode, cid: cid)

        guard let fileId = snapResult.fileId else { throw DriveError.noPlayURL("115: snap未返回文件ID") }
        let downloadURL = try await one15GetDownloadURL(fileId: fileId, cid: cid)

        return PlayResult(
            url: downloadURL,
            headers: ["Cookie": "CID=\(cid)", "User-Agent": "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36"],
            driveType: .one15
        )
    }

    private func extract115ShareCode(from url: String) async throws -> (shareCode: String, receiveCode: String) {
        var shareCode = ""
        var receiveCode = ""

        if let range = url.range(of: #"/s/([^/?]+)"#, options: .regularExpression) {
            shareCode = String(url[range]).replacingOccurrences(of: "/s/", with: "")
        }
        if let range = url.range(of: #"password=([^&]+)"#, options: .regularExpression) {
            receiveCode = String(url[range]).replacingOccurrences(of: "password=", with: "")
        }

        guard !shareCode.isEmpty else { throw DriveError.invalidShareURL }
        return (shareCode, receiveCode)
    }

    private struct One15SnapResult {
        let fileId: String?
        let fileName: String?
    }

    private func one15Snap(shareCode: String, receiveCode: String, cid: String) async throws -> One15SnapResult {
        var components = URLComponents(string: "https://webapi.115.com/share/snap")!
        components.queryItems = [
            URLQueryItem(name: "share_code", value: shareCode),
            URLQueryItem(name: "receive_code", value: receiveCode),
            URLQueryItem(name: "cid", value: "0"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "20")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("CID=\(cid)", forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["state"] as? Bool, state == true,
              let dataDict = json["data"] as? [String: Any] else {
            throw DriveError.invalidResponse
        }

        var fileId: String?
        if let list = dataDict["list"] as? [[String: Any]], let first = list.first {
            fileId = String(describing: first["file_id"] ?? first["id"] ?? "")
        } else if let pickCode = dataDict["pick_code"] as? String {
            fileId = pickCode
        }

        return One15SnapResult(fileId: fileId, fileName: dataDict["file_name"] as? String)
    }

    private func one15GetDownloadURL(fileId: String, cid: String) async throws -> String {
        var components = URLComponents(string: "https://proapi.115.com/app/chrome/downurl")!
        components.queryItems = [URLQueryItem(name: "pickcode", value: fileId)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("CID=\(cid)", forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["state"] as? Bool, state == true else {
            throw DriveError.invalidResponse
        }

        if let dataObj = json["data"] as? [String: Any] {
            for (_, value) in dataObj {
                if let fileInfo = value as? [String: Any],
                   let url = fileInfo["url"] as? String {
                    return url
                }
            }
        }

        throw DriveError.noPlayURL("115: 未获取到下载地址")
    }

    // MARK: - UC 网盘

    func resolveUCPlayURL(shareURL: String, cookie: String) async throws -> PlayResult {
        let shareId = extractUCShareId(from: shareURL)

        let folderId = try await ucEnsureFolder(cookie: cookie)

        let fileIds = try await ucSaveShare(shareId: shareId, folderId: folderId, cookie: cookie)

        guard let fileId = fileIds.first else { throw DriveError.noPlayURL("UC: 转存后未返回文件ID") }
        let playURL = try await ucGetPlayURL(fileId: fileId, cookie: cookie)

        scheduleCleanup(drive: .uc, fileIds: fileIds, token: cookie, delay: 180)

        return PlayResult(
            url: playURL,
            headers: ["Cookie": cookie, "Referer": "https://drive.uc.cn/", "User-Agent": "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36"],
            driveType: .uc
        )
    }

    private func extractUCShareId(from url: String) -> String {
        if let range = url.range(of: #"/s/([^/?]+)"#, options: .regularExpression) {
            return String(url[range]).replacingOccurrences(of: "/s/", with: "")
        }
        return url
    }

    private func ucSaveShare(shareId: String, folderId: String, cookie: String) async throws -> [String] {
        let shareToken = try await ucGetShareToken(shareId: shareId, cookie: cookie)

        var request = URLRequest(url: URL(string: "https://drive.uc.cn/1/clouddrive/share/sharepage/save")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        var body: [String: Any] = [
            "share_id": shareId,
            "to_pdir_fid": folderId
        ]
        if !shareToken.isEmpty { body["share_token"] = shareToken }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)

        let respStr = String(data: data, encoding: .utf8) ?? ""
        print("[UC] save 响应：\(respStr.prefix(800))")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.saveFailed
        }

        if let status = json["status"] as? Int, status != 200 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "状态码：\(status)"
            throw DriveError.noPlayURL("UC 转存失败：\(message)")
        }

        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "错误码：\(code)"
            throw DriveError.noPlayURL("UC 转存失败：\(message)")
        }

        if let dataObj = json["data"] as? [String: Any] {
            if let list = dataObj["list"] as? [[String: Any]], let first = list.first {
                if let fid = first["fid"] as? String { return [fid] }
                else if let fid = first["fid"] as? Int { return [String(fid)] }
                else if let fileId = first["file_id"] as? String { return [fileId] }
                else if let fileId = first["file_id"] as? Int { return [String(fileId)] }
            }
            if let fileIds = dataObj["file_ids"] as? [String] { return fileIds }
            if let fileIds = dataObj["file_ids"] as? [Int] { return fileIds.map { String($0) } }
        }

        return [shareId]
    }

    private func ucGetShareToken(shareId: String, cookie: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://drive.uc.cn/1/clouddrive/share/sharepage/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = ["share_id": shareId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let stoken = dataObj["stoken"] as? String else {
            return ""
        }
        return stoken
    }

    private func ucEnsureFolder(cookie: String) async throws -> String {
        let listURL = URL(string: "https://drive.uc.cn/1/clouddrive/file/sort")!
        var req = URLRequest(url: listURL)
        req.httpMethod = "POST"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = ["pdir_fid": "", "sort_by": "file_name", "sort_order": "asc", "page": 1, "size": 100]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        if let (data, _) = try? await session.data(for: req),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["data"] as? [String: Any],
           let files = list["list"] as? [[String: Any]] {
            for f in files {
                if let name = f["file_name"] as? String, name == "vbox播放",
                   let fid = f["fid"] as? String { return fid }
            }
        }
        let createURL = URL(string: "https://drive.uc.cn/1/clouddrive/file")!
        var createReq = URLRequest(url: createURL)
        createReq.httpMethod = "POST"
        createReq.setValue(cookie, forHTTPHeaderField: "Cookie")
        createReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createReq.setValue("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let createBody: [String: Any] = ["pdir_fid": "", "file_name": "vbox播放", "dir": true, "dir_path": ""]
        createReq.httpBody = try JSONSerialization.data(withJSONObject: createBody)
        if let (createData, _) = try? await session.data(for: createReq),
           let createJson = try? JSONSerialization.jsonObject(with: createData) as? [String: Any],
           let d = createJson["data"] as? [String: Any],
           let fid = d["fid"] as? String { return fid }
        return ""
    }

    private func ucDeleteFiles(fileIds: [String], cookie: String) async {
        guard !fileIds.isEmpty else { return }
        let url = URL(string: "https://drive.uc.cn/1/clouddrive/file/trash")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = ["file_ids": fileIds, "trash": true]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let _ = try? await session.data(for: req)
        print("[CloudDrive] ✅ UC 已删除 \(fileIds.count) 个转存文件")
    }

    private func ucGetPlayURL(fileId: String, cookie: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://drive.uc.cn/1/clouddrive/file/v2/play")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = ["file_id": fileId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let playURL = dataObj["play_url"] as? String else {
            throw DriveError.noPlayURL("UC: 未返回播放地址")
        }
        return playURL
    }

    // MARK: - 统一解析入口

    func resolvePlayURL(from shareURL: String) async throws -> PlayResult {
        let cleanURL = shareURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        print("[CloudDrive] resolvePlayURL 输入: \(cleanURL.prefix(80))")
        guard let driveType = Self.detectDrive(from: cleanURL) else {
            print("[CloudDrive] ❌ detectDrive 返回 nil")
            throw DriveError.invalidShareURL
        }
        print("[CloudDrive] ✅ detectDrive: \(driveType.rawValue)")

        let tokens = tokens(for: driveType)
        guard !tokens.isEmpty else {
            throw DriveError.tokenNotConfigured(driveType.displayName)
        }

        var lastError: Error?
        for (index, token) in tokens.enumerated() {
            let label = tokens.count > 1 ? " [\(index + 1)/\(tokens.count)]" : ""
            print("[CloudDrive] 🔄 尝试 \(driveType.displayName) Token\(label): \(token.name)")
            do {
                let result: PlayResult
                switch driveType {
                case .ali:
                    result = try await resolveAliPlayURL(shareURL: shareURL, refreshToken: token.value)
                case .quark:
                    result = try await resolveQuarkPlayURL(shareURL: shareURL, cookie: token.value)
                case .baidu:
                    result = try await resolveBaiduPlayURL(shareURL: shareURL, bduss: token.value)
                case .one15:
                    result = try await resolve115PlayURL(shareURL: shareURL, cid: token.value)
                case .uc:
                    result = try await resolveUCPlayURL(shareURL: shareURL, cookie: token.value)
                }
                print("[CloudDrive] ✅ \(driveType.displayName) Token \"\(token.name)\" 成功")
                return result
            } catch {
                lastError = error
                print("[CloudDrive] ⚠️ \(driveType.displayName) Token \"\(token.name)\" 失败: \(error.localizedDescription)")
                continue
            }
        }

        let count = tokens.count
        print("[CloudDrive] ❌ 所有 \(count) 个 \(driveType.displayName) Token 均失败")
        throw lastError ?? DriveError.tokenNotConfigured(driveType.displayName)
    }
}

// MARK: - 数据结构

struct PlayResult {
    let url: String
    let headers: [String: String]
    let driveType: DriveTypeAlias
}

enum DriveTypeAlias: String {
    case ali = "阿里云盘"
    case quark = "夸克"
    case baidu = "百度"
    case one15 = "115"
    case uc = "UC"
}

enum DriveError: LocalizedError {
    case noPlayURL(String)
    case invalidResponse
    case invalidShareURL
    case saveFailed
    case notImplemented
    case tokenNotConfigured(String)

    var errorDescription: String? {
        switch self {
        case .noPlayURL(let reason):
            return "无法获取播放地址：\(reason)"
        case .invalidResponse:
            return "服务器响应无效"
        case .invalidShareURL:
            return "无效的分享链接"
        case .saveFailed:
            return "转存失败"
        case .notImplemented:
            return "该网盘暂不支持"
        case .tokenNotConfigured(let name):
            return "未配置\(name) Token"
        }
    }
}

// MARK: - 阿里云盘 API 响应模型

private struct AliTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private struct AliShareTokenResponse: Codable {
    let shareToken: String

    enum CodingKeys: String, CodingKey {
        case shareToken = "share_token"
    }
}

private struct AliVideoPreviewResponse: Codable {
    let videoPreviewPlayInfo: AliVideoPreviewInfo?

    enum CodingKeys: String, CodingKey {
        case videoPreviewPlayInfo = "video_preview_play_info"
    }
}

private struct AliVideoPreviewInfo: Codable {
    let liveTranscodingTaskList: [AliTranscodeTask]?

    enum CodingKeys: String, CodingKey {
        case liveTranscodingTaskList = "live_transcoding_task_list"
    }
}

private struct AliTranscodeTask: Codable {
    let url: String?
    let templateId: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case url
        case templateId = "template_id"
        case status
    }
}

// MARK: - MD5 扩展
extension String {
    func md5() -> String {
        let messageData = self.data(using: .utf8)!
        var digestData = Data(count: Int(CC_MD5_DIGEST_LENGTH))
        
        _ = digestData.withUnsafeMutableBytes { digestBytes in
            messageData.withUnsafeBytes { messageBytes in
                CC_MD5(messageBytes.baseAddress, CC_LONG(messageData.count), digestBytes.baseAddress)
            }
        }
        
        return digestData.map { String(format: "%02hhx", $0) }.joined()
    }
}
