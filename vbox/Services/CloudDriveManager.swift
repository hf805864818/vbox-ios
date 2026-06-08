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
/// 百度网盘文件条目
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

    /// 保存的所有网盘 Token
    @Published private(set) var savedTokens: [DriveToken] = []

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        loadTokens()
    }
    
    /// 调试日志回调（供播放器显示悬浮日志用）
    static var onLog: ((String) -> Void)?

    private func baiduLog(_ msg: String) {
        print(msg)
        if let handler = CloudDriveManager.onLog {
            handler(msg)
        }
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
    /// 获取百度分享的文件列表（用于多文件选择）
    func baiduGetFileList(shareURL: String, bduss: String) async throws -> [BaiduFileItem] {
        let parsed = parseBaiduToken(bduss)
        let cookie = parsed.cookie
        let (shareid, shareUk, files) = try await baiduExtractShareMeta(shareURL: shareURL, cookie: cookie, returnAll: true)
        return files
    }

    /// 播百度盘指定文件
    func resolveBaiduPlayURL(shareURL: String, bduss: String) async throws -> PlayResult {
        let parsed = parseBaiduToken(bduss)
        let cookie = parsed.cookie
        let bdussOnly = parsed.bdussOnly
        let (shareid, shareUk, files) = try await baiduExtractShareMeta(shareURL: shareURL, cookie: cookie, returnAll: false)
        guard let first = files.first, !first.fsId.isEmpty else { throw DriveError.noPlayURL("百度：未从分享页提取到文件 ID") }
        
        // 双模式播放：优先尝试不转存直链模式，失败则转存
        do {
            baiduLog("[Baidu] 尝试模式 1：不转存直链模式...")
            let result = try await baiduGetDirectLink(shareid: shareid, shareUk: shareUk, fsId: first.fsId, fileName: first.name, cookie: cookie)
            baiduLog("[Baidu] ✅ 模式 1 成功，直接播放")
            return result
        } catch {
            baiduLog("[Baidu] ⚠️ 模式 1 失败，回退到模式 2：转存模式...")
            // 模式 1 失败，回退到转存模式
            let _ = try await baiduEnsureFolder(bduss: bdussOnly)
            let _ = try await baiduTransferFile(shareid: shareid, surl: shareURL.split(separator: "/").last?.split(separator: "?").first.map(String.init) ?? "", shareUk: shareUk, fsId: first.fsId, cookie: cookie)
            let result = try await baiduGetPCSPlayURL(fileName: first.name, cookie: cookie)
            baiduLog("[Baidu] ✅ 模式 2 成功，转存播放")
            return result
        }
    }

    /// 播百度盘指定 fsId 的文件（兼容多文件选择）
    func resolveBaiduPlayURL(shareURL: String, bduss: String, fsId: String) async throws -> PlayResult {
        let parsed = parseBaiduToken(bduss)
        let cookie = parsed.cookie
        let bdussOnly = parsed.bdussOnly
        let (shareid, shareUk, files) = try await baiduExtractShareMeta(shareURL: shareURL, cookie: cookie, returnAll: false)
        guard !shareid.isEmpty else { throw DriveError.noPlayURL("百度：无法获取分享信息") }
        let fileName = files.first(where: { $0.fsId == fsId })?.name ?? "未知"
        
        // 双模式播放：优先尝试不转存直链模式
        do {
            baiduLog("[Baidu] 尝试模式 1：不转存直链模式...")
            let result = try await baiduGetDirectLink(shareid: shareid, shareUk: shareUk, fsId: fsId, fileName: fileName, cookie: cookie)
            baiduLog("[Baidu] ✅ 模式 1 成功，直接播放")
            return result
        } catch {
            baiduLog("[Baidu] ⚠️ 模式 1 失败，回退到模式 2：转存模式...")
            let _ = try await baiduEnsureFolder(bduss: bdussOnly)
            let _ = try await baiduTransferFile(shareid: shareid, surl: shareURL.split(separator: "/").last?.split(separator: "?").first.map(String.init) ?? "", shareUk: shareUk, fsId: fsId, cookie: cookie)
            let result = try await baiduGetPCSPlayURL(fileName: fileName, cookie: cookie)
            baiduLog("[Baidu] ✅ 模式 2 成功，转存播放")
            return result
        }
    }

    /// 播百度盘指定fsId的文件（兼容多文件选择）
    func resolveBaiduPlayURL(shareURL: String, bduss: String, fsId: String) async throws -> PlayResult {
        let parsed = parseBaiduToken(bduss)
        let cookie = parsed.cookie
        let bdussOnly = parsed.bdussOnly
        let (shareid, shareUk, files) = try await baiduExtractShareMeta(shareURL: shareURL, cookie: cookie, returnAll: false)
        guard !shareid.isEmpty else { throw DriveError.noPlayURL("百度: 无法获取分享信息") }
        let fileName = files.first(where: { $0.fsId == fsId })?.name ?? "未知"
        let _ = try await baiduEnsureFolder(bduss: bdussOnly)
        let _ = try await baiduTransferFile(shareid: shareid, surl: shareURL.split(separator: "/").last?.split(separator: "?").first.map(String.init) ?? "", shareUk: shareUk, fsId: fsId, cookie: cookie)
        let result = try await baiduGetPCSPlayURL(fileName: fileName, cookie: cookie)
        return result
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
        
        if let pwd = pwd, (html.contains("请输入提取码") || html.contains("accessCode")) {
            baiduLog("[Baidu] 需要验证提取码...")
            guard let verifyURL = URL(string: "https://pan.baidu.com/share/verify?surl=\(surl)&t=0") else {
                throw DriveError.invalidResponse
            }
            var verifyReq = URLRequest(url: verifyURL)
            verifyReq.httpMethod = "POST"
            verifyReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            verifyReq.setValue(currentCookie, forHTTPHeaderField: "Cookie")
            verifyReq.setValue(ua, forHTTPHeaderField: "User-Agent")
            verifyReq.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            verifyReq.setValue("https://pan.baidu.com/s/1\(surl)", forHTTPHeaderField: "Referer")
            verifyReq.httpBody = "pwd=\(pwd)&vcode=&vcode_str=&channel=chunlei&web=1&app_id=250528&clienttype=0".data(using: .utf8)
            verifyReq.timeoutInterval = 10
            
            let (vData, _) = try await session.data(for: verifyReq)
            
            // 从验证响应中提取 randsk 并加入 Cookie
            // 百度网盘验证接口返回示例：{"errno":0,"msg":"succ","randsk":"..."}
            var randsk = ""
            baiduLog("[Baidu] 验证响应：\(String(data: vData, encoding: .utf8) ?? "nil")")
            
            if let vJson = try? JSONSerialization.jsonObject(with: vData) as? [String: Any] {
                if let r = vJson["randsk"] as? String { 
                    randsk = r 
                    baiduLog("[Baidu] 提取到 randsk: \(r.prefix(20))...")
                }
                if let errno = vJson["errno"] as? Int {
                    if errno == 0 {
                        baiduLog("[Baidu] ✅ 提取码验证成功")
                        // randsk 需要添加到 Cookie 中，用于后续访问
                        if !randsk.isEmpty {
                            currentCookie += "; randsk=\(randsk)"
                            baiduLog("[Baidu] randsk 已合并到 Cookie")
                        }
                        // 验证成功后，重新用新 Cookie 请求原始页面
                        var req2 = URLRequest(url: pageURL)
                        req2.setValue(currentCookie, forHTTPHeaderField: "Cookie")
                        req2.setValue(ua, forHTTPHeaderField: "User-Agent")
                        req2.timeoutInterval = 15
                        
                        baiduLog("[Baidu] 重新请求分享页（带 randsk）...")
                        let (data2, response2) = try await session.data(for: req2)
                        
                        guard let httpResp2 = response2 as? HTTPURLResponse, httpResp2.statusCode == 200 else {
                            baiduLog("[Baidu] ❌ 重新请求失败：状态码=\((response2 as? HTTPURLResponse)?.statusCode ?? -1)")
                            throw DriveError.invalidResponse
                        }
                        
                        guard let newHtml = String(data: data2, encoding: .utf8) ?? String(data: data2, encoding: .ascii) else {
                            baiduLog("[Baidu] ❌ 重新请求数据无法解码")
                            throw DriveError.invalidResponse
                        }
                        html = newHtml
                        baiduLog("[Baidu] ✅ 重新请求成功，继续解析 yunData")
                    } else if errno == -9 {
                        baiduLog("[Baidu] ❌ 提取码错误 (errno=-9)")
                        throw DriveError.noPlayURL("百度网盘：提取码错误")
                    } else if errno == 4 {
                        baiduLog("[Baidu] ❌ 需要验证码 (errno=4)")
                        throw DriveError.noPlayURL("百度网盘：需要图形验证码，请在浏览器中访问获取完整 Cookie")
                    } else {
                        let errmsg = vJson["errmsg"] as? String ?? vJson["msg"] as? String ?? "错误码：\(errno)"
                        baiduLog("[Baidu] ❌ 提取码验证失败 (errno=\(errno)): \(errmsg)")
                        throw DriveError.noPlayURL("百度网盘：提取码验证失败 (\(errmsg))")
                    }
                } else {
                    baiduLog("[Baidu] ❌ 验证响应没有 errno 字段")
                    throw DriveError.invalidResponse
                }
            } else {
                baiduLog("[Baidu] ❌ 验证响应解析失败：\(String(data: vData, encoding: .utf8).prefix(200))")
                throw DriveError.invalidResponse
            }
                    var req2 = URLRequest(url: pageURL)
                    req2.setValue(currentCookie, forHTTPHeaderField: "Cookie")
                    req2.setValue(ua, forHTTPHeaderField: "User-Agent")
                    req2.timeoutInterval = 15
                    let (data2, _) = try await session.data(for: req2)
                    guard let httpResp2 = response as? HTTPURLResponse, httpResp2.statusCode == 200,
                          let newHtml = String(data: data2, encoding: .utf8) ?? String(data: data2, encoding: .ascii) else {
                        throw DriveError.invalidResponse
                    }
                    html = newHtml
                } else {
                    let errno = vJson["errno"] as? Int ?? -1
                    baiduLog("[Baidu] ❌ 提取码验证失败(errno=\(errno))")
                    throw DriveError.noPlayURL("百度网盘：提取码验证失败")
                }
            } else {
                // JSON解析失败
                baiduLog("[Baidu] ❌ verify响应非JSON")
                throw DriveError.invalidResponse
            }
        }
        
        var shareid = ""
        var shareUk = ""
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
        
        var files: [BaiduFileItem] = []
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
                baiduLog("[Baidu] yunData文件列表: \(files.map { $0.name })")
            }
        }
        
        if files.isEmpty {
            if let fidRegex = try? NSRegularExpression(pattern: #""fs_id":\s*(\d+)"#),
               let nameRegex = try? NSRegularExpression(pattern: #""server_filename":\s*"([^"]+)"#) {
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
        
        if shareid.isEmpty || shareUk.isEmpty {
            baiduLog("[Baidu] ❌ 无法提取 shareid 或 shareUk")
            throw DriveError.noPlayURL("百度网盘：无法获取分享信息，请检查 Cookie 是否有效")
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
            baiduLog("[Baidu] ❌ 转存失败: errno=\(errno), msg=\(errmsg)")
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

    /// 用 PCS 下载接口获取百度网盘文件直链（iBox 方案）
    /// 转存到 /vbox 播放/ 后，通过文件路径获取带签名的播放地址
    private func baiduGetPCSPlayURL(fileName: String, cookie: String) async throws -> PlayResult {
        // 对文件名进行 URL 编码
        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        let filePath = "/vbox 播放/\(encodedName)"
        
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
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.noPlayURL("百度：PCS 接口返回非 JSON")
        }
        
        // 检查错误
        if let errno = json["errno"] as? Int, errno != 0 {
            baiduLog("[Baidu] ❌ PCS 错误：errno=\(errno)")
            throw DriveError.noPlayURL("百度：获取播放地址失败 (errno=\(errno))")
        }
        
        // 提取直链
        guard let urls = json["urls"] as? [[String: Any]],
              let firstURL = urls.first,
              let playURL = firstURL["url"] as? String else {
            // 也可能是其他结构
            if let url = json["url"] as? String {
                return PlayResult(
                    url: url,
                    headers: [
                        "Cookie": cookie,
                        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
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
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Referer": "https://pan.baidu.com/",
            ],
            driveType: .baidu
        )
    }

    /// 【新模式】不转存直链播放 - 通过 sharedownload API 获取直链
    /// 无需转存，直接获取下载链接
    private func baiduGetDirectLink(shareid: String, shareUk: String, fsId: String, fileName: String, cookie: String) async throws -> PlayResult {
        baiduLog("[Baidu-Direct] 调用 sharedownload API 获取直链...")
        
        // 构造 sign 参数（需要 timestamp + sign）
        let timestamp = Int(Date().timeIntervalSince1970)
        let signStr = "\(shareid)_\(shareUk)_\(fsId)_\(timestamp)"
        let signData = signStr.data(using: .utf8) ?? Data()
        let sign = signData.base64EncodedString()
        
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
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com/s/1\(shareid)", forHTTPHeaderField: "Referer")
        
        // POST body
        let bodyParams = "encodings=1&fsidlist=[\(fsId)]&primaryid=\(shareid)&uk=\(shareUk)"
        request.httpBody = bodyParams.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            baiduLog("[Baidu-Direct] ❌ sharedownload 请求失败")
            throw DriveError.invalidResponse
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            baiduLog("[Baidu-Direct] ❌ 响应非 JSON")
            throw DriveError.invalidResponse
        }
        
        // 检查 errno
        if let errno = json["errno"] as? Int {
            if errno == -6 {
                baiduLog("[Baidu-Direct] ❌ sign 验证失败，需要更精确的 sign 计算")
                throw DriveError.noPlayURL("百度：签名验证失败")
            } else if errno != 0 {
                let errmsg = json["errmsg"] as? String ?? "错误码：\(errno)"
                baiduLog("[Baidu-Direct] ❌ errno=\(errno), \(errmsg)")
                throw DriveError.noPlayURL("百度：下载链接获取失败 (\(errmsg))")
            }
        }
        
        // 提取下载链接
        guard let list = json["list"] as? [[String: Any]],
              let firstFile = list.first,
              let dlink = firstFile["dlink"] as? String else {
            baiduLog("[Baidu-Direct] ❌ 未找到 dlink")
            throw DriveError.noPlayURL("百度：sharedownload 未返回下载链接")
        }
        
        baiduLog("[Baidu-Direct] ✅ 获取到 dlink: \(dlink.prefix(80))...")
        
        // 解码 dlink（百度返回的是转义过的 URL）
        let decodedDlink = dlink.replacingOccurrences(of: "\\/", with: "/")
        
        return PlayResult(
            url: decodedDlink,
            headers: [
                "Cookie": cookie,
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Referer": "https://pan.baidu.com/",
            ],
            driveType: .baidu
        )
    }
        
        // 检查错误
        if let errno = json["errno"] as? Int, errno != 0 {
            baiduLog("[Baidu] ❌ PCS错误: errno=\(errno)")
            throw DriveError.noPlayURL("百度: 获取播放地址失败(errno=\(errno))")
        }
        
        // 提取直链
        guard let urls = json["urls"] as? [[String: Any]],
              let firstURL = urls.first,
              let playURL = firstURL["url"] as? String else {
            // 也可能是其他结构
            if let url = json["url"] as? String {
                return PlayResult(
                    url: url,
                    headers: [
                        "Cookie": cookie,
                        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                        "Referer": "https://pan.baidu.com/",
                    ],
                    driveType: .baidu
                )
            }
            throw DriveError.noPlayURL("百度: PCS未返回播放地址")
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
        scheduleCleanup(drive: .uc, fileIds: fileIds, token: cookie, delay: 180)

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
            return "未配置\(name) Token，请在设置中添加"
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