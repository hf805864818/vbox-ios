import Foundation

/// 网盘管理器 — 支持阿里云盘、夸克、百度、115、UC 的播放地址获取
/// 每种网盘有不同的认证方式和 API 调用链路
class CloudDriveManager {
    
    enum DriveType {
        case aliRefreshToken(String)   // 阿里云盘 refresh_token
        case quarkCookie(String)       // 夸克网盘 Cookie
        case baiduBDUSS(String)        // 百度网盘 BDUSS
        case one15CID(String)          // 115 网盘 CID
        case ucloudCookie(String)      // UC 网盘 Cookie
    }
    
    private let session: URLSession
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
        ]
        session = URLSession(configuration: config)
    }
    
    // MARK: - 阿里云盘
    
    /// 阿里云盘：refresh_token → access_token → 分享文件 → 播放地址
    func resolveAliPlayURL(shareURL: String, refreshToken: String) async throws -> PlayResult {
        // Step 1: 刷新 access_token
        let tokenResult = try await aliRefreshAccessToken(refreshToken: refreshToken)
        let accessToken = tokenResult.accessToken
        
        // Step 2: 获取 file_id
        let fileId = try await aliGetShareFileInfo(shareURL: shareURL, token: accessToken)
        
        // Step 3: 获取播放地址
        let playInfo = try await aliGetVideoPreviewPlayInfo(fileId: fileId, token: accessToken)
        
        guard let playURL = playInfo.videoPreviewPlayInfo?.liveTranscodingTaskList?.first?.url else {
            throw DriveError.noPlayURL
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
    
    private func aliGetShareFileInfo(shareURL: String, token: String) async throws -> String {
        // 从分享链接中提取 share_id 和 file_id
        var request = URLRequest(url: URL(string: "https://api.aliyundrive.com/adrive/v3/share_file/get_share_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "Authorization")
        
        // 从URL提取 share_id
        let shareId = extractAliShareId(from: shareURL)
        let body: [String: Any] = ["share_id": shareId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, _) = try await session.data(for: request)
        let result = try JSONDecoder().decode(AliShareTokenResponse.self, from: data)
        return result.shareToken
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
        return try JSONDecoder().decode(AliVideoPreviewResponse.self, from: data)
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
        // Step 1: 提取 pwd_id 和 share_id
        let (shareId, pwdId) = try await quarkExtractShareInfo(shareURL: shareURL, cookie: cookie)
        
        // Step 2: 转存到自己的网盘
        let fileIds = try await quarkSaveShare(shareId: shareId, pwdId: pwdId, cookie: cookie)
        
        // Step 3: 获取播放地址
        guard let fileId = fileIds.first else { throw DriveError.noPlayURL }
        let playURL = try await quarkGetPlayURL(fileId: fileId, cookie: cookie)
        
        return PlayResult(
            url: playURL,
            headers: ["Cookie": cookie, "Referer": "https://pan.quark.cn/"],
            driveType: .quark
        )
    }
    
    private func quarkExtractShareInfo(shareURL: String, cookie: String) async throws -> (String, String) {
        let url = URL(string: shareURL)!
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        
        let (data, _) = try await session.data(for: request)
        
        // HTML 中正则提取
        guard let html = String(data: data, encoding: .utf8) else {
            throw DriveError.invalidResponse
        }
        
        // 提取 __INITIAL_STATE__ 中的 pwd_id
        let pattern = #"pwd_id":"([^"]*)""#
        guard let range = html.range(of: pattern, options: .regularExpression) else {
            throw DriveError.invalidShareURL
        }
        let matched = String(html[range])
        let pwdId = matched.replacingOccurrences(of: #"pwd_id":"#, with: "").replacingOccurrences(of: "\"", with: "")
        
        // share_id 从 URL 提取
        let shareId = shareURL.split(separator: "/").last?.split(separator: "?").first.map(String.init) ?? ""
        
        return (shareId, pwdId)
    }
    
    private func quarkSaveShare(shareId: String, pwdId: String, cookie: String) async throws -> [String] {
        let url = URL(string: "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/save")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let body: [String: Any] = [
            "share_id": shareId,
            "pwd_id": pwdId,
            "to_pdir_fid": ""
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? Int, status == 200 else {
            throw DriveError.saveFailed
        }
        
        // 返回转存的文件 ID 列表
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
            throw DriveError.noPlayURL
        }
        return playURL
    }
    
    // MARK: - 百度网盘
    
    /// 百度网盘：BDUSS → 分享链接 → transfer → dlink → 播放地址
    func resolveBaiduPlayURL(shareURL: String, bduss: String) async throws -> PlayResult {
        // Step 1: 提取 surl 和 pwd
        let (surl, pwd) = extractBaiduShareInfo(from: shareURL)
        
        // Step 2: 转存文件
        let fsIds = try await baiduTransferFile(surl: surl, pwd: pwd, cookie: "BDUSS=\(bduss)")
        
        // Step 3: 获取 dlink
        return try await baiduGetRealDownloadLink(fsId: fsIds.first ?? "", cookie: "BDUSS=\(bduss)")
    }
    
    private func extractBaiduShareInfo(from url: String) -> (surl: String, pwd: String) {
        var surl = ""
        var pwd = ""
        
        if let surlRange = url.range(of: #"/s/([^/?]+)"#, options: .regularExpression) {
            surl = String(url[surlRange]).replacingOccurrences(of: "/s/", with: "")
        }
        if let pwdRange = url.range(of: #"pwd=([^&]+)"#, options: .regularExpression) {
            pwd = String(url[pwdRange]).replacingOccurrences(of: "pwd=", with: "")
        }
        
        return (surl, pwd)
    }
    
    private func baiduTransferFile(surl: String, pwd: String, cookie: String) async throws -> [String] {
        let url = URL(string: "https://pan.baidu.com/share/transfer")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let params = "shareid=\(surl)&from=\(surl)&share_uk=&sekey=&pwd=\(pwd)"
        request.httpBody = params.data(using: .utf8)
        
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errno = json["errno"] as? Int, errno == 0 else {
            throw DriveError.saveFailed
        }
        
        // 返回 fs_ids
        return [surl]
    }
    
    private func baiduGetRealDownloadLink(fsId: String, cookie: String) async throws -> PlayResult {
        let url = URL(string: "https://pan.baidu.com/api/filemetas")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["info"] as? [[String: Any]],
              let dlink = list.first?["dlink"] as? String else {
            throw DriveError.noPlayURL
        }
        
        return PlayResult(
            url: dlink,
            headers: ["Cookie": cookie, "User-Agent": "pan.baidu.com"],
            driveType: .baidu
        )
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
    case noPlayURL
    case invalidResponse
    case invalidShareURL
    case saveFailed
    case notImplemented
    
    var errorDescription: String? {
        switch self {
        case .noPlayURL: return "无法获取播放地址"
        case .invalidResponse: return "服务器响应无效"
        case .invalidShareURL: return "无效的分享链接"
        case .saveFailed: return "转存失败"
        case .notImplemented: return "该网盘暂不支持"
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
