import Foundation
import Combine

// MARK: - 网盘存储模型
struct DriveToken: Codable {
    let type: String      // ali/quark/baidu/one15/uc
    let name: String      // 用户备注名
    let value: String     // token/cookie 值
}

/// 网盘管理器 — 支持阿里云盘、夸克、百度、115、UC 的播放地址获取
/// 每种网盘有不同的认证方式和 API 调用链路
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

    /// 保存的所有网盘 Token
    @Published private(set) var savedTokens: [DriveToken] = []

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
        ]
        session = URLSession(configuration: config)
        loadTokens()
    }

    /// 加载已保存的 Token
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

    /// 添加/更新 Token
    func addToken(type: DriveType, name: String, value: String) {
        savedTokens.removeAll { $0.type == type.rawValue && $0.name == name }
        savedTokens.append(DriveToken(type: type.rawValue, name: name, value: value))
        saveTokens()
    }

    /// 删除 Token
    func removeToken(at index: Int) {
        guard index >= 0, index < savedTokens.count else { return }
        savedTokens.remove(at: index)
        saveTokens()
    }

    // MARK: - 转存文件夹管理
    /// 获取或创建"vbox播放"文件夹的 file_id
    private func ensureVboxFolder(drive: DriveType, token: String) async throws -> String {
        switch drive {
        case .quark:
            return try await quarkEnsureFolder(cookie: token)
        case .baidu:
            return try await baiduEnsureFolder(bduss: token)
        case .uc:
            return try await ucEnsureFolder(cookie: token)
        default:
            return "" // 阿里/115 不需要转存
        }
    }

    // 转存完成后，异步清理转存的文件
    private func scheduleCleanup(drive: DriveType, fileIds: [String], token: String, delay: TimeInterval = 30) {
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

    /// 获取某种类型的所有 Token
    func tokens(for type: DriveType) -> [DriveToken] {
        savedTokens.filter { $0.type == type.rawValue }
    }

    /// 识别分享链接的网盘类型
    static func detectDrive(from url: String) -> DriveType? {
        if url.contains("aliyundrive.com") || url.contains("alipan.com") { return .ali }
        if url.contains("pan.quark.cn") { return .quark }
        if url.contains("pan.baidu.com") { return .baidu }
        if url.contains("115.com") || url.contains("115cdn.com") { return .one15 }
        if url.contains("uc.cn") || url.contains("ucloud.cn") { return .uc }
        return nil
    }

    // MARK: - 阿里云盘

    /// 阿里云盘：refresh_token → access_token → 分享文件 → 播放地址
    func resolveAliPlayURL(shareURL: String, refreshToken: String) async throws -> PlayResult {
        // Step 1: 刷新 access_token
        let tokenResult = try await aliRefreshAccessToken(refreshToken: refreshToken)
        let accessToken = tokenResult.accessToken

        // Step 2: 获取 file_id
        let shareId = extractAliShareId(from: shareURL)
        let shareToken = try await aliGetShareToken(shareId: shareId, token: accessToken)
        let fileId = try await aliGetShareFileList(shareId: shareId, shareToken: shareToken, token: accessToken)

        // Step 3: 获取播放地址
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
        let (data, response) = try await session.data(for: request)
        
        // 打印响应用于调试
        let respStr = String(data: data, encoding: .utf8) ?? ""
        print("[Ali] 文件列表响应: \(respStr.prefix(500))")
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[Ali] ❌ 文件列表响应非JSON")
            throw DriveError.invalidResponse
        }
        
        // 检查 items
        guard let items = json["items"] as? [[String: Any]] else {
            // 检查是否有错误信息
            if let code = json["code"] as? String, code != "OK" {
                let message = json["message"] as? String ?? "未知错误"
                print("[Ali] ❌ API错误: \(message)")
                throw DriveError.noPlayURL("阿里: \(message)")
            }
            print("[Ali] ❌ 文件列表为空 (items字段缺失或格式错误)")
            throw DriveError.noPlayURL("阿里: 分享为空或已失效")
        }
        
        guard let first = items.first else {
            print("[Ali] ❌ 文件列表为空数组")
            throw DriveError.noPlayURL("阿里: 分享中没有文件")
        }
        
        // 尝试获取 file_id
        if let fid = first["file_id"] as? String {
            print("[Ali] ✅ 获取到file_id: \(fid)")
            return fid
        } else if let fid = first["file_id"] as? Int {
            print("[Ali] ✅ 获取到file_id(Int): \(fid)")
            return String(fid)
        }
        
        print("[Ali] ❌ 无法从文件项中提取file_id，可用字段: \(first.keys)")
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

        let (data, response) = try await session.data(for: request)
        
        // 打印响应用于调试
        let respStr = String(data: data, encoding: .utf8) ?? ""
        print("[Ali] 播放信息响应: \(respStr.prefix(500))")

        // 先检查是否是错误响应
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let code = json["code"] as? String, code != "OK" {
                let message = json["message"] as? String ?? "获取播放地址失败"
                print("[Ali] ❌ API错误: \(message)")
                throw DriveError.noPlayURL("阿里: \(message)")
            }
        }

        do {
            let result = try JSONDecoder().decode(AliVideoPreviewResponse.self, from: data)
            
            // 检查是否有播放地址
            guard let taskList = result.videoPreviewPlayInfo?.liveTranscodingTaskList, !taskList.isEmpty else {
                print("[Ali] ❌ 没有可用的转码任务列表")
                throw DriveError.noPlayURL("阿里: 该文件无视频播放地址")
            }
            
            // 尝试找到最佳清晰度
            let qualities = ["FHD", "HD", "SD", "LD"]
            for quality in qualities {
                if let task = taskList.first(where: { $0.templateId?.contains(quality) == true }), let url = task.url {
                    print("[Ali] ✅ 获取到播放地址 (\(quality))")
                    return result
                }
            }
            
            // 如果没有匹配到指定清晰度，使用第一个可用的
            if taskList.first?.url != nil {
                print("[Ali] ✅ 获取到播放地址 (默认)")
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
        // 从 https://www.aliyundrive.com/s/xxx 提取 xxx
        let pattern = #"/s/([^/?]+)"#
        if let range = url.range(of: pattern, options: .regularExpression) {
            let matched = String(url[range])
            return matched.replacingOccurrences(of: "/s/", with: "")
        }
        return url
    }

    // MARK: - 夸克网盘

    /// 夸克网盘：分享链接 → 转存 → file/v2/play → 播放地址
    func resolveQuarkPlayURL(shareURL: String, cookie: String) async throws -> PlayResult {
        print("[Quark] 开始解析: \(shareURL)")
        // Step 1: 提取 pwd_id 和 share_id
        let (shareId, pwdId) = try await quarkExtractShareInfo(shareURL: shareURL, cookie: cookie)
        print("[Quark] shareId=\(shareId) pwdId=\(pwdId)")

        // Step 2: 获取 share_token（夸克新版需要）
        let shareToken = try await quarkGetShareToken(shareId: shareId, pwdId: pwdId, cookie: cookie)
        print("[Quark] shareToken=\(shareToken.isEmpty ? "空" : "已获取")")

        // Step 3: 获取 vbox 文件夹 ID
        let folderId = try await quarkEnsureFolder(cookie: cookie)
        print("[Quark] folderId=\(folderId.isEmpty ? "空" : folderId)")

        // Step 4: 转存到 vbox 文件夹（带 share_token）
        let fileIds = try await quarkSaveShare(shareId: shareId, pwdId: pwdId, shareToken: shareToken, folderId: folderId, cookie: cookie)
        print("[Quark] 转存完成 fileIds=\(fileIds)")

        guard let fileId = fileIds.first else { throw DriveError.noPlayURL("夸克: 转存后未返回文件ID") }
        let playURL = try await quarkGetPlayURL(fileId: fileId, cookie: cookie)
        print("[Quark] ✅ 播放地址: \(playURL.prefix(80))")

        scheduleCleanup(drive: .quark, fileIds: fileIds, token: cookie, delay: 4800)

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
        // 创建文件夹
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

        let (data, response) = try await session.data(for: request)
        
        // 打印响应用于调试
        let respStr = String(data: data, encoding: .utf8) ?? ""
        print("[Quark] save响应: \(respStr.prefix(500))")
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[Quark] ❌ 转存响应非JSON")
            throw DriveError.saveFailed
        }
        
        // 检查status
        if let status = json["status"] as? Int, status != 200 {
            // 尝试提取错误消息
            let message = json["message"] as? String ?? json["msg"] as? String ?? "状态码: \(status)"
            print("[Quark] ❌ 转存失败: \(message)")
            throw DriveError.noPlayURL("夸克转存失败: \(message)")
        }
        
        // 检查code
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "错误码: \(code)"
            print("[Quark] ❌ 转存失败: \(message)")
            throw DriveError.noPlayURL("夸克转存失败: \(message)")
        }

        // 返回真实 file_ids
        if let d = json["data"] as? [String: Any] {
            // 尝试多种可能的字段名
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
            throw DriveError.noPlayURL("夸克: 未返回播放地址(play_url为空)")
        }
        return playURL
    }

    // MARK: - 百度网盘

    /// 将用户填写的百度 Token 标准化为完整 Cookie 字符串
    /// 支持三种输入格式：
    ///   1. "BDUSS=xxx; STOKEN=yyy;" - 完整 Cookie 格式
    ///   2. "BDUSS=xxx|STOKEN=yyy" - 竖线分隔格式
    ///   3. "BDUSS=xxx" 或纯 BDUSS 值 - 仅 BDUSS 兼容
    /// 返回: (cookie: String, bdussOnly: String) 供需要纯BDUSS的场景使用
    private func parseBaiduToken(_ raw: String) -> (cookie: String, bdussOnly: String) {
        // 情况1: 完整 Cookie 格式 "BDUSS=xxx; STOKEN=yyy;"
        if raw.range(of: #"BDUSS=([^;|]+)"#, options: .regularExpression) != nil {
            var bduss = ""
            var stoken = ""
            // 提取 BDUSS 值
            if let r1 = raw.range(of: #"BDUSS=([^;|]+)"#, options: .regularExpression),
               let eq = raw[r1].firstIndex(of: "=") {
                let val = String(raw[raw.index(after: eq)..<r1.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                bduss = val
            }
            // 提取 STOKEN 值
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
        
        // 情况2: 竖线分隔格式 "BDUSS=xxx|STOKEN=yyy" 或 "xxx|yyy"
        if raw.contains("|") {
            var parts: [String]
            // BDUSS= 前缀存在则去掉
            let cleaned = raw.replacingOccurrences(of: #"^BDUSS="#, with: "", options: .regularExpression)
            parts = cleaned.components(separatedBy: "|")
            let bduss = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            var cookie = "BDUSS=\(bduss)"
            if parts.count >= 2 {
                let stoken = parts[1].replacingOccurrences(of: #"^STOKEN="#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                cookie += "; STOKEN=\(stoken)"
            }
            return (cookie, bduss)
        }
        
        // 情况3: 纯 BDUSS 值或 "BDUSS=值"
        let bduss = raw.replacingOccurrences(of: "BDUSS=", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ("BDUSS=\(bduss)", bduss)
    }

    /// 百度网盘：BDUSS → 分享链接 → transfer → dlink → 播放地址
    func resolveBaiduPlayURL(shareURL: String, bduss: String) async throws -> PlayResult {
        let parsed = parseBaiduToken(bduss)
        let cookie = parsed.cookie
        let bdussOnly = parsed.bdussOnly
        let (shareid, shareUk, fsId) = try await baiduExtractShareMeta(shareURL: shareURL, cookie: cookie)
        guard !fsId.isEmpty else { throw DriveError.noPlayURL("百度: 未从分享页提取到文件ID(fsId为空)") }
        let _ = try await baiduEnsureFolder(bduss: bdussOnly)
        let fsIds = try await baiduTransferFile(shareid: shareid, surl: shareURL.split(separator: "/").last?.split(separator: "?").first.map(String.init) ?? "", shareUk: shareUk, fsId: fsId, cookie: cookie)
        let result = try await baiduGetRealDownloadLink(fsId: fsIds.first ?? fsId, cookie: cookie)
        scheduleCleanup(drive: .baidu, fileIds: fsIds, token: bdussOnly, delay: 4800)
        return result
    }

    private func baiduExtractShareMeta(shareURL: String, cookie: String) async throws -> (shareid: String, shareUk: String, fsId: String) {
        print("[Baidu] 提取分享信息：\(shareURL)")

        // Step 1: 构建分享页 URL（带 pwd）
        var sharePageURL = shareURL
        if let pwdRange = shareURL.range(of: #"[?&]pwd=([^&]+)"#, options: .regularExpression),
           let match = try? NSRegularExpression(pattern: #"[?&]pwd=([^&]+)"#).firstMatch(in: shareURL, range: NSRange(shareURL.startIndex..., in: shareURL)),
           let r = Range(match.range(at: 1), in: shareURL) {
            let pwd = String(shareURL[r])
            print("[Baidu] 检测到提取码: \(pwd)")
        }

        // Step 2: 请求分享页 HTML 并提取 yunData
        guard let pageUrl = URL(string: shareURL) else { throw DriveError.invalidShareURL }
        var req = URLRequest(url: pageUrl)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let (data, _) = try await session.data(for: req)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            print("[Baidu] ❌ 分享页内容非文本")
            throw DriveError.invalidResponse
        }

        // 从 HTML 中提取 yunData JSON
        // 格式: window.yunData={...}
        guard let yunDataRange = html.range(of: "window.yunData="),
              let jsonStart = html[yunDataRange.upperBound...].range(of: "{"),
              let jsonEnd = html[yunDataRange.upperBound...].range(of: "};") else {
            print("[Baidu] ❌ 未找到 yunData")
            // 尝试检查页面是否包含错误信息
            if html.contains("errno") || html.contains("error") {
                throw DriveError.noPlayURL("百度网盘：分享链接可能已失效")
            }
            throw DriveError.noPlayURL("百度网盘：无法解析分享页，请确认链接有效")
        }

        let jsonRawStart = yunDataRange.upperBound
        let jsonContentStart = html.distance(from: html.startIndex, to: jsonStart.lowerBound)
        let jsonContentEnd = html.distance(from: html.startIndex, to: jsonEnd.lowerBound)
        let jsonStartIndex = html.index(html.startIndex, offsetBy: jsonContentStart)
        let jsonEndIndex = html.index(html.startIndex, offsetBy: jsonContentEnd + 1)
        let jsonStr = String(html[jsonStartIndex..<jsonEndIndex])
        
        guard let jsonData = jsonStr.data(using: .utf8),
              let yunData = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            print("[Baidu] ❌ yunData JSON 解析失败")
            throw DriveError.invalidResponse
        }

        print("[Baidu] ✅ 分享页解析成功")

        // 提取 shareid
        var shareid = ""
        if let sid = yunData["shareid"] as? String { shareid = sid
        } else if let sid = yunData["shareid"] as? Int { shareid = String(sid) }

        // 提取 share_uk
        var shareUk = ""
        if let uk = yunData["share_uk"] as? String { shareUk = uk
        } else if let uk = yunData["share_uk"] as? Int { shareUk = String(uk)
        } else if let uk = yunData["uk"] as? String { shareUk = uk
        } else if let uk = yunData["uk"] as? Int { shareUk = String(uk) }

        // 提取文件列表中的 fsId
        var fsId = ""
        if let fileList = yunData["file_list"] as? [[String: Any]], !fileList.isEmpty {
            let first = fileList[0]
            if let fid = first["fs_id"] as? String { fsId = fid
            } else if let fid = first["fs_id"] as? Int64 { fsId = String(fid)
            } else if let fid = first["fs_id"] as? Int { fsId = String(fid) }
            let fileName = first["server_filename"] as? String ?? "未知"
            print("[Baidu] 文件名=\(fileName), fs_id=\(fsId), 共\(fileList.count)个文件")
        } else {
            print("[Baidu] ❌ 文件列表为空")
        }

        if shareid.isEmpty || shareUk.isEmpty {
            print("[Baidu] ❌ 无法提取 shareid 或 shareUk")
            throw DriveError.noPlayURL("百度网盘：无法获取分享信息，请检查 Cookie 是否有效")
        }
        if fsId.isEmpty {
            print("[Baidu] ❌ 无法提取 fs_id")
            throw DriveError.noPlayURL("百度网盘：未从分享页提取到文件 ID，请确认分享链接有效")
        }

        print("[Baidu] ✅ 提取成功：shareid=\(shareid), shareUk=\(shareUk), fsId=\(fsId)")
        return (shareid, shareUk, fsId)
    }

    private func baiduTransferFile(shareid: String, surl: String, shareUk: String, fsId: String, cookie: String) async throws -> [String] {
        let url = URL(string: "https://pan.baidu.com/share/transfer")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let params = "shareid=\(shareid)&from=\(surl)&share_uk=\(shareUk)&sekey=&pwd=&fsidlist=[\(fsId)]&path=/vbox播放/"
        request.httpBody = params.data(using: .utf8)
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.noPlayURL("百度: 转存接口返回非JSON")
        }
        guard let errno = json["errno"] as? Int, errno == 0 else {
            let errno = json["errno"] as? Int ?? -1
            let errmsg = json["errmsg"] as? String ?? json["show_msg"] as? String ?? "未知错误(\(errno))"
            print("[Baidu] ❌ 转存失败: errno=\(errno), msg=\(errmsg)")
            if errno == 112 {
                throw DriveError.noPlayURL("百度: 转存需要登录验证(STOKEN)，请在设置中配置BDUSS|STOKEN格式的Token")
            } else if errno == -9 || errno == 10 {
                throw DriveError.noPlayURL("百度: 分享文件可能需要提取码或已失效")
            } else if errno == 2 {
                throw DriveError.noPlayURL("百度: 转存路径错误或网盘空间不足")
            }
            throw DriveError.saveFailed
        }
        return [fsId]
    }

    private func baiduGetRealDownloadLink(fsId: String, cookie: String) async throws -> PlayResult {
        var components = URLComponents(string: "https://pan.baidu.com/api/filemetas")!
        components.queryItems = [
            URLQueryItem(name: "fsids", value: "[\(fsId)]"),
            URLQueryItem(name: "dlink", value: "1"),
            URLQueryItem(name: "bdstoken", value: ""),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "clienttype", value: "0"),
        ]
        
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["info"] as? [[String: Any]],
              let first = list.first,
              let dlink = first["dlink"] as? String else {
            throw DriveError.noPlayURL("百度: 未获取到下载链接(dlink为空)")
        }
        
        // 组装完整的播放URL：dlink + sign + timestamp + ua等参数
        var playURL = dlink
        
        // 提取 sign 和 timestamp（百度盘 filemetas 返回的同级字段）
        if let sign = first["sign"] as? String {
            let ts = first["timestamp"] as? Int64 ?? first["ts"] as? Int64 ?? 0
            let separator = playURL.contains("?") ? "&" : "?"
            playURL += "\(separator)sign=\(sign)&timestamp=\(ts)"
        }

        return PlayResult(
            url: playURL,
            headers: [
                "Cookie": cookie,
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Referer": "https://pan.baidu.com/",
            ],
            driveType: .baidu
        )
    }

    private func baiduEnsureFolder(bduss: String) async throws -> String {
        let listURL = URL(string: "https://pan.baidu.com/api/list?dir=/&order=time&desc=1&num=100&page=1&bdstoken=&channel=chunlei&web=1&app_id=250528&clienttype=0")!
        var req = URLRequest(url: listURL)
        req.setValue("BDUSS=\(bduss)", forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
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
        createReq.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
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
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let params = "filelist=[\"\(fileIds.first!)\"]&path=/vbox播放/"
        req.httpBody = params.data(using: .utf8)
        let _ = try? await session.data(for: req)
        print("[CloudDrive] ✅ 百度已删除转存文件")
    }


    // MARK: - 115 网盘

    /// 115 网盘：分享链接 → snap → files/download → 播放地址
    /// Token 格式：CID=xxx
    func resolve115PlayURL(shareURL: String, cid: String) async throws -> PlayResult {
        let (shareCode, receiveCode) = try await extract115ShareCode(from: shareURL)

        // Step 1: snap 获取文件信息
        let snapResult = try await one15Snap(shareCode: shareCode, receiveCode: receiveCode, cid: cid)

        // Step 2: 获取下载地址
        guard let fileId = snapResult.fileId else { throw DriveError.noPlayURL("115: snap未返回文件ID") }
        let downloadURL = try await one15GetDownloadURL(fileId: fileId, cid: cid)

        return PlayResult(
            url: downloadURL,
            headers: ["Cookie": "CID=\(cid)", "User-Agent": "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36"],
            driveType: .one15
        )
    }

    /// 从 115 分享链接提取 share_code 和 receive_code
    private func extract115ShareCode(from url: String) async throws -> (shareCode: String, receiveCode: String) {
        // 格式: https://115.com/s/xxxxxx?password=xxx
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

    /// 115 snap API — 获取分享文件信息
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

        // 尝试取文件 ID
        var fileId: String?
        if let list = dataDict["list"] as? [[String: Any]], let first = list.first {
            fileId = String(describing: first["file_id"] ?? first["id"] ?? "")
        } else if let pickCode = dataDict["pick_code"] as? String {
            // 需要提取码
            fileId = pickCode
        }

        return One15SnapResult(fileId: fileId, fileName: dataDict["file_name"] as? String)
    }

    /// 115 获取下载地址
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

        // 从返回中提取下载 URL
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

    /// UC 网盘：与夸克架构类似，share_token → save → file/v2/play
    /// Token 格式：完整 Cookie
    func resolveUCPlayURL(shareURL: String, cookie: String) async throws -> PlayResult {
        // Step 1: 提取 share_id
        let shareId = extractUCShareId(from: shareURL)

        // Step 2: 获取 vbox 文件夹 ID
        let folderId = try await ucEnsureFolder(cookie: cookie)

        // Step 3: 转存
        let fileIds = try await ucSaveShare(shareId: shareId, folderId: folderId, cookie: cookie)

        // Step 4: 获取播放地址
        guard let fileId = fileIds.first else { throw DriveError.noPlayURL("UC: 转存后未返回文件ID") }
        let playURL = try await ucGetPlayURL(fileId: fileId, cookie: cookie)

        // Step 5: 30秒后清理
        scheduleCleanup(drive: .uc, fileIds: fileIds, token: cookie, delay: 4800)

        return PlayResult(
            url: playURL,
            headers: ["Cookie": cookie, "Referer": "https://drive.uc.cn/", "User-Agent": "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36"],
            driveType: .uc
        )
    }

    private func extractUCShareId(from url: String) -> String {
        // 格式: https://drive.uc.cn/s/xxxxxx 或 https://pc.uc.cn/s/xxxxxx
        if let range = url.range(of: #"/s/([^/?]+)"#, options: .regularExpression) {
            return String(url[range]).replacingOccurrences(of: "/s/", with: "")
        }
        return url
    }

    /// UC 转存分享文件
    private func ucSaveShare(shareId: String, folderId: String, cookie: String) async throws -> [String] {
        // Step 1: 先获取分享 token
        let shareToken = try await ucGetShareToken(shareId: shareId, cookie: cookie)
        print("[UC] shareToken=\(shareToken.isEmpty ? "空" : "已获取")")
        
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

        let (data, response) = try await session.data(for: request)
        
        // 打印响应用于调试
        let respStr = String(data: data, encoding: .utf8) ?? ""
        print("[UC] save 响应：\(respStr.prefix(800))")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[UC] ❌ 转存响应非 JSON")
            throw DriveError.saveFailed
        }
        
        // 检查 status
        if let status = json["status"] as? Int, status != 200 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "状态码：\(status)"
            print("[UC] ❌ 转存失败：\(message)")
            throw DriveError.noPlayURL("UC 转存失败：\(message)")
        }
        
        // 检查 code
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "错误码：\(code)"
            print("[UC] ❌ 转存失败：\(message)")
            throw DriveError.noPlayURL("UC 转存失败：\(message)")
        }

        // 返回转存后的文件 ID - 尝试多种可能的字段
        if let dataObj = json["data"] as? [String: Any] {
            if let list = dataObj["list"] as? [[String: Any]], let first = list.first {
                if let fid = first["fid"] as? String {
                    print("[UC] ✅ 转存成功，fid: \(fid)")
                    return [fid]
                } else if let fid = first["fid"] as? Int {
                    print("[UC] ✅ 转存成功，fid(Int): \(fid)")
                    return [String(fid)]
                } else if let fileId = first["file_id"] as? String {
                    return [fileId]
                } else if let fileId = first["file_id"] as? Int {
                    return [String(fileId)]
                }
            }
            if let fileIds = dataObj["file_ids"] as? [String] {
                print("[UC] ✅ 转存成功，file_ids: \(fileIds)")
                return fileIds
            }
            if let fileIds = dataObj["file_ids"] as? [Int] {
                let stringIds = fileIds.map { String($0) }
                print("[UC] ✅ 转存成功，file_ids(Int): \(stringIds)")
                return stringIds
            }
        }

        print("[UC] ⚠️ 转存成功但未找到 fileId，返回 shareId 作为 fallback")
        return [shareId]
    }
    
    /// UC 获取分享 token
    private func ucGetShareToken(shareId: String, cookie: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://drive.uc.cn/1/clouddrive/share/sharepage/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        
        let body: [String: Any] = ["share_id": shareId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, _) = try await session.data(for: request)
        let respStr = String(data: data, encoding: .utf8) ?? ""
        print("[UC] token 响应：\(respStr.prefix(300))")
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let stoken = dataObj["stoken"] as? String else {
            return ""
        }
        return stoken
    }

    /// UC 确保 vbox 文件夹存在
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

    /// UC 清理转存文件
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

    /// UC 获取播放地址
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

    /// 自动识别网盘类型并解析播放地址
    func resolvePlayURL(from shareURL: String) async throws -> PlayResult {
        // 清理URL：去掉首尾空白和不可见字符
        let cleanURL = shareURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{200B}", with: "") // zero-width space
            .replacingOccurrences(of: "\u{FEFF}", with: "") // BOM
        print("[CloudDrive] resolvePlayURL 输入: \(cleanURL.prefix(80))")
        guard let driveType = Self.detectDrive(from: cleanURL) else {
            print("[CloudDrive] ❌ detectDrive 返回 nil，URL: \(cleanURL)")
            throw DriveError.invalidShareURL
        }
        print("[CloudDrive] ✅ detectDrive: \(driveType.rawValue)")

        let tokens = tokens(for: driveType)
        guard let token = tokens.first else {
            throw DriveError.tokenNotConfigured(driveType.displayName)
        }

        switch driveType {
        case .ali:
            return try await resolveAliPlayURL(shareURL: shareURL, refreshToken: token.value)
        case .quark:
            return try await resolveQuarkPlayURL(shareURL: shareURL, cookie: token.value)
        case .baidu:
            return try await resolveBaiduPlayURL(shareURL: shareURL, bduss: token.value)
        case .one15:
            return try await resolve115PlayURL(shareURL: shareURL, cid: token.value)
        case .uc:
            return try await resolveUCPlayURL(shareURL: shareURL, cookie: token.value)
        }
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
        case .noPlayURL(let reason): return "无法获取播放地址: \(reason)"
        case .invalidResponse: return "服务器响应无效"
        case .invalidShareURL: return "无效的分享链接"
        case .saveFailed: return "转存失败"
        case .notImplemented: return "该网盘暂不支持"
        case .tokenNotConfigured(let name): return "未配置\(name) Token，请在设置中添加"
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