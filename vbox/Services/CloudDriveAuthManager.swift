import Foundation
import Combine
import UIKit
import WebKit

enum CloudDriveAuthType: String, Codable {
    case manual
    case qr
    case webView
    case oauth
}

enum CloudDriveAuthState: String, Codable {
    case notAuthorized
    case valid
    case expiringSoon
    case expired
    case invalid
    case unknown

    var displayText: String {
        switch self {
        case .notAuthorized: return "未授权"
        case .valid: return "正常"
        case .expiringSoon: return "即将过期"
        case .expired: return "已过期"
        case .invalid: return "授权失效"
        case .unknown: return "未检测"
        }
    }
}

struct CloudDriveCredential: Codable, Identifiable {
    var id: String { driveType }
    let driveType: String
    var authType: CloudDriveAuthType
    var accessToken: String?
    var refreshToken: String?
    var cookie: String?
    var driveId: String?
    var userId: String?
    var userName: String?
    var avatar: String?
    var expiresAt: Date?
    var updatedAt: Date
    var lastCheckedAt: Date?
    var state: CloudDriveAuthState
    var statusMessage: String?
    var extra: [String: String]

    var displayName: String {
        if let userName, !userName.isEmpty { return userName }
        switch driveType {
        case CloudDriveManager.DriveType.ali.rawValue: return "已授权账号"
        case CloudDriveManager.DriveType.quark.rawValue: return "已授权账号"
        case CloudDriveManager.DriveType.baidu.rawValue: return "已授权账号"
        case CloudDriveManager.DriveType.one15.rawValue: return "已授权账号"
        case CloudDriveManager.DriveType.uc.rawValue: return "已授权账号"
        default: return "已授权账号"
        }
    }

    var primarySecret: String? {
        if let refreshToken, !refreshToken.isEmpty { return refreshToken }
        if let cookie, !cookie.isEmpty { return cookie }
        if let accessToken, !accessToken.isEmpty { return accessToken }
        return nil
    }
}

final class CloudDriveAuthManager: ObservableObject {
    static let shared = CloudDriveAuthManager()

    @Published private(set) var credentials: [String: CloudDriveCredential] = [:]

    private let defaults = UserDefaults.standard
    private let storageKey = "cloud_drive_credentials_v1"
    private let baiduVerifyCooldownKey = "baidu_verify_cooldowns_v1"
    private let session: URLSession
    private let ucSession: URLSession
    private let aliOAuthClientId = "25dzX3vbRqA4f1D1ma2M"
    private let aliOAuthRedirectURI = "https://alist.nn.ci/tool/aliyundrive/callback"

    // MARK: - 阿里云盘配置（便于远程/热更新与切换 QR 源）
    private struct AliPassportConfig {
        static let baseURL = "https://passport.alipan.com/newlogin/qrcode"
        static let appName = "aliyun_drive"
        static let fromSite = "52"
        static let appEntrance = "web"
        static let isMobile = "false"
        static let lang = "zh_CN"
        static let bxVersion = "2.2.5"
        static let origin = "https://www.alipan.com"
        static let referer = "https://www.alipan.com/"
    }

    private struct AliOAuthConfig {
        static let qrcodeURL = "https://openapi.alipan.com/oauth/authorize/qrcode"
        static let statusURLPrefix = "https://openapi.alipan.com/oauth/qrcode"
        static let scopes = ["user:base", "file:all:read"]
        static let width = 500
        static let height = 500
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        let ucConfig = URLSessionConfiguration.default
        ucConfig.timeoutIntervalForRequest = 30
        // 移除全信任证书 Delegate，恢复系统默认证书校验
        ucSession = URLSession(configuration: ucConfig)
        load()
        syncLegacyTokensIfNeeded()
    }

    // MARK: - 阿里 OAuth

    func exchangeAliOAuthCode(_ code: String) async throws {
        var request = URLRequest(url: URL(string: "https://openapi.alipan.com/oauth/access_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "client_id": aliOAuthClientId,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": aliOAuthRedirectURI
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse("阿里 OAuth 返回无法解析")
        }
        if let code = json["code"] as? String, code != "OK" && code != "ok" && code != "0" {
            throw AuthError.remoteError(json["message"] as? String ?? code)
        }

        let refreshToken = json["refresh_token"] as? String
        let accessToken = json["access_token"] as? String
        let expiresIn = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? Int ?? 0)
        let driveId = json["default_drive_id"] as? String
            ?? json["drive_id"] as? String
            ?? json["resource_drive_id"] as? String
        let userName = json["user_name"] as? String
            ?? json["nick_name"] as? String
            ?? json["name"] as? String

        guard let refreshToken, !refreshToken.isEmpty else {
            throw AuthError.remoteError("阿里 OAuth 未返回 refresh_token")
        }

        let credential = CloudDriveCredential(
            driveType: CloudDriveManager.DriveType.ali.rawValue,
            authType: .oauth,
            accessToken: accessToken,
            refreshToken: refreshToken,
            cookie: nil,
            driveId: driveId,
            userId: json["user_id"] as? String,
            userName: userName,
            avatar: json["avatar"] as? String,
            expiresAt: expiresIn > 0 ? Date(timeIntervalSinceNow: expiresIn) : nil,
            updatedAt: Date(),
            lastCheckedAt: Date(),
            state: .valid,
            statusMessage: "阿里 OAuth 授权成功",
            extra: json.compactMapValues { value in
                if let text = value as? String { return text }
                if let number = value as? NSNumber { return number.stringValue }
                return nil
            }
        )
        saveCredential(credential)
    }

    func refreshAliAccessTokenIfNeeded() async throws -> CloudDriveCredential {
        guard var credential = credential(for: .ali),
              let refreshToken = credential.refreshToken,
              !refreshToken.isEmpty else {
            throw AuthError.notAuthorized("阿里云盘未授权")
        }
        if let expiresAt = credential.expiresAt,
           expiresAt.timeIntervalSinceNow > 5 * 60,
           credential.accessToken?.isEmpty == false {
            return credential
        }

        var request = URLRequest(url: URL(string: "https://api.alipan.com/v2/account/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": aliOAuthClientId
        ])
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse("阿里刷新 token 返回无法解析")
        }
        if let code = json["code"] as? String, code != "0" && code != "OK" && code != "ok" {
            print("[Ali Token] refresh 返回错误: code=\(code), message=\(json["message"] as? String ?? "nil"), 完整: \(json)")
            markInvalid(.ali, reason: json["message"] as? String ?? code)
            throw AuthError.remoteError(json["message"] as? String ?? code)
        }
        print("[Ali Token] refresh 成功, expired_in=\(json["expires_in"] ?? "nil")")
        credential.accessToken = json["access_token"] as? String ?? credential.accessToken
        credential.refreshToken = json["refresh_token"] as? String ?? credential.refreshToken
        credential.driveId = json["default_drive_id"] as? String ?? json["drive_id"] as? String ?? credential.driveId
        let expiresIn = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? Int ?? 0)
        if expiresIn > 0 { credential.expiresAt = Date(timeIntervalSinceNow: expiresIn) }
        credential.state = .valid
        credential.statusMessage = "阿里 token 已刷新"
        credential.lastCheckedAt = Date()
        credential.updatedAt = Date()
        saveCredential(credential)
        return credential
    }

    // MARK: - 阿里 Passport 原生扫码

    struct AliPassportQrToken {
        let t: String
        let ck: String
        let codeContent: String
    }

    enum AliPassportQrPollResult {
        case pending
        case scanned
        case success(refreshToken: String, userInfo: [String: Any])
        case expired
        case canceled
        case failed(message: String)
    }

    func aliPassportCreateQrToken() async throws -> AliPassportQrToken {
        // 使用 AliPassportConfig 中的常量，便于统一升级与远程配置
        var components = URLComponents(string: AliPassportConfig.baseURL + "/generate.do")!
        components.queryItems = [
            URLQueryItem(name: "appName", value: AliPassportConfig.appName),
            URLQueryItem(name: "fromSite", value: AliPassportConfig.fromSite),
            URLQueryItem(name: "appEntrance", value: AliPassportConfig.appEntrance),
            URLQueryItem(name: "isMobile", value: AliPassportConfig.isMobile),
            URLQueryItem(name: "lang", value: AliPassportConfig.lang),
            URLQueryItem(name: "returnUrl", value: ""),
            URLQueryItem(name: "bizParams", value: ""),
            URLQueryItem(name: "_bx-v", value: AliPassportConfig.bxVersion)
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(AliPassportConfig.origin, forHTTPHeaderField: "Origin")
        request.setValue(AliPassportConfig.referer, forHTTPHeaderField: "Referer")
        request.setValue(aliUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let httpStatusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("[Ali Passport] QR generate HTTP \(httpStatusCode)")
        
        let json = try parseJSON(data)
        print("[Ali Passport] QR generate response keys: \(json.keys)")
        guard let content = json["content"] as? [String: Any],
              let dataObj = content["data"] as? [String: Any],
              let tValue = dataObj["t"],
              let ck = dataObj["ck"] as? String,
              let codeContent = dataObj["codeContent"] as? String else {
            // 尝试检查是否有错误信息
            if let msg = json["message"] as? String {
                throw AuthError.invalidResponse("阿里 Passport: \(msg)")
            }
            throw AuthError.invalidResponse("阿里 Passport 未返回二维码参数")
        }
        // t 可能是 Int 或 String，统一转为 String
        let t: String
        if let tInt = tValue as? Int {
            t = String(tInt)
        } else if let tStr = tValue as? String {
            t = tStr
        } else {
            throw AuthError.invalidResponse("阿里 Passport t 字段类型异常")
        }
        print("[Ali Passport] QR token created, t=\(t.prefix(10))..., codeContent length=\(codeContent.count)")
        return AliPassportQrToken(t: t, ck: ck, codeContent: codeContent)
    }

    func aliPassportPollQrStatus(token: AliPassportQrToken) async throws -> AliPassportQrPollResult {
        var components = URLComponents(string: AliPassportConfig.baseURL + "/query.do")!
        components.queryItems = [
            URLQueryItem(name: "appName", value: AliPassportConfig.appName),
            URLQueryItem(name: "fromSite", value: AliPassportConfig.fromSite),
            URLQueryItem(name: "appEntrance", value: AliPassportConfig.appEntrance),
            URLQueryItem(name: "isMobile", value: AliPassportConfig.isMobile),
            URLQueryItem(name: "lang", value: AliPassportConfig.lang),
            URLQueryItem(name: "t", value: token.t),
            URLQueryItem(name: "ck", value: token.ck)
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(AliPassportConfig.origin, forHTTPHeaderField: "Origin")
        request.setValue(AliPassportConfig.referer, forHTTPHeaderField: "Referer")
        request.setValue(aliUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        if httpStatus != 200 {
            print("[Ali Passport] poll HTTP status: \(httpStatus)")
        }
        
        let json = try parseJSON(data)
        guard let content = json["content"] as? [String: Any],
              let dataObj = content["data"] as? [String: Any] else {
            print("[Ali Passport] poll unexpected response: \(json.keys)")
            return .failed(message: "阿里 Passport 轮询返回格式异常")
        }
        let status = dataObj["qrCodeStatus"] as? String ?? ""
        let rawStatus = status.uppercased()
        print("[Ali Passport] poll status: \(rawStatus), poll attempt")
        
        switch rawStatus {
        case "NEW":
            return .pending
        case "SCANED", "SCANNED":
            return .scanned
        case "CONFIRMED":
            guard let bizExt = dataObj["bizExt"] as? String else {
                print("[Ali Passport] CONFIRMED 但未返回 bizExt，dataObj keys: \(dataObj.keys)")
                return .failed(message: "扫码确认成功但未返回 bizExt")
            }
            print("[Ali Passport] bizExt raw (first 100): \(String(bizExt.prefix(100)))")
            let normalized = bizExt
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: " ", with: "")
            var bizData: Data?
            if let data = Data(base64Encoded: normalized) {
                bizData = data
            } else if let data = Data(base64Encoded: normalized + "=") {
                bizData = data
            } else if let data = Data(base64Encoded: normalized + "==") {
                bizData = data
            } else {
                // 尝试 URL-safe base64 完整填充
                let padded = normalized
                    .replacingOccurrences(of: "-", with: "+")
                    .replacingOccurrences(of: "_", with: "/")
                let remainder = padded.count % 4
                let fullPadded = remainder > 0 ? padded + String(repeating: "=", count: 4 - remainder) : padded
                bizData = Data(base64Encoded: fullPadded)
            }
            guard let finalData = bizData else {
                print("[Ali Passport] bizExt base64 解码失败，normalized: \(String(normalized.prefix(100)))")
                return .failed(message: "扫码确认成功但 bizExt 解码失败")
            }
            print("[Ali Passport] bizExt decoded: \(String(data: finalData, encoding: .utf8) ?? "non-utf8")")
            guard let bizJson = try? JSONSerialization.jsonObject(with: finalData) as? [String: Any] else {
                print("[Ali Passport] bizExt JSON 解析失败")
                return .failed(message: "扫码确认成功但 bizExt JSON 解析失败")
            }
            print("[Ali Passport] bizJson keys: \(bizJson.keys)")
            let pdsResult = bizJson["pds_login_result"] as? [String: Any]
            let refreshToken = pdsResult?["refreshToken"] as? String
            if let token = refreshToken, !token.isEmpty {
                return .success(refreshToken: token, userInfo: pdsResult ?? [:])
            }
            if let topLevelToken = bizJson["refresh_token"] as? String, !topLevelToken.isEmpty {
                return .success(refreshToken: topLevelToken, userInfo: bizJson)
            }
            print("[Ali Passport] bizExt 中未找到 refreshToken，完整 JSON: \(bizJson)")
            return .failed(message: "扫码确认成功但 bizExt 解析失败")
        case "EXPIRED":
            print("[Ali Passport] QR code expired, t=\(token.t.prefix(10))...")
            return .expired
        case "CANCELED", "CANCELLED":
            return .canceled
        default:
            print("[Ali Passport] unknown status: \(rawStatus)")
            return .failed(message: "未知状态: \(status)")
        }
    }

    func aliPassportSaveCredential(refreshToken: String, userInfo: [String: Any]) {
        let accessToken = userInfo["token"] as? String
            ?? userInfo["accessToken"] as? String
            ?? userInfo["access_token"] as? String
        let expiresIn = (userInfo["expiresIn"] as? Double) ?? Double(userInfo["expiresIn"] as? Int ?? 0)
        let driveId = userInfo["default_drive_id"] as? String
            ?? userInfo["drive_id"] as? String
            ?? userInfo["resource_drive_id"] as? String
        let resourceDriveId = userInfo["resource_drive_id"] as? String
        let userName = userInfo["nickName"] as? String
            ?? userInfo["userName"] as? String
            ?? userInfo["name"] as? String

        var extra: [String: String] = [:]
        if let resourceDriveId = resourceDriveId { extra["resource_drive_id"] = resourceDriveId }
        if let avatar = userInfo["avatar"] as? String { extra["avatar"] = avatar }
        if let userId = userInfo["userId"] as? String { extra["user_id"] = userId }

        let credential = CloudDriveCredential(
            driveType: CloudDriveManager.DriveType.ali.rawValue,
            authType: .qr,
            accessToken: accessToken,
            refreshToken: refreshToken,
            cookie: nil,
            driveId: driveId,
            userId: userInfo["userId"] as? String,
            userName: userName,
            avatar: userInfo["avatar"] as? String,
            expiresAt: expiresIn > 0 ? Date(timeIntervalSinceNow: expiresIn) : nil,
            updatedAt: Date(),
            lastCheckedAt: Date(),
            state: .valid,
            statusMessage: "阿里 Passport 扫码登录成功",
            extra: extra
        )
        saveCredential(credential)

        // 创建设备 session，避免后续 API 403
        Task {
            do {
                try await aliCreateSession(accessToken: accessToken)
            } catch {
                print("[Ali] create_session 失败（非阻断）: \(error)")
            }
        }
    }

    private func aliCreateSession(accessToken: String?) async throws {
        guard let accessToken = accessToken, !accessToken.isEmpty else { return }
        var request = URLRequest(url: URL(string: "https://api.alipan.com/users/v1/users/device/create_session")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "device_name": "VBox",
            "model_name": "iOS",
            "pub_key": ""
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.remoteError("create_session HTTP 失败")
        }
    }

    // MARK: - 阿里 OAuth QR（Passport QR 的兜底/替代方案）

    struct AliOAuthQrToken {
        let sid: String
        let qrData: String
    }

    enum AliOAuthQrPollResult {
        case pending
        case scanned
        case success(authCode: String)
        case expired
        case failed(message: String)
    }

    func aliOAuthCreateQrToken() async throws -> AliOAuthQrToken {
        var request = URLRequest(url: URL(string: AliOAuthConfig.qrcodeURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(aliUserAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "client_id": aliOAuthClientId,
            "client_secret": "",
            "scopes": AliOAuthConfig.scopes,
            "width": AliOAuthConfig.width,
            "height": AliOAuthConfig.height
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse("阿里 OAuth QR 生成返回无法解析")
        }
        if let code = json["code"] as? String, code != "OK" && code != "ok" && code != "0" {
            throw AuthError.remoteError(json["message"] as? String ?? code)
        }
        if let code = json["code"] as? Int, code != 0 && code != 200 {
            throw AuthError.remoteError(json["message"] as? String ?? "code=\(code)")
        }
        let dataObj = json["data"] as? [String: Any] ?? json
        guard let sid = dataObj["sid"] as? String,
              let qrData = dataObj["qrCodeUrl"] as? String ?? dataObj["qr_data"] as? String,
              !sid.isEmpty, !qrData.isEmpty else {
            throw AuthError.invalidResponse("阿里 OAuth QR 生成未返回 sid/qrData")
        }
        return AliOAuthQrToken(sid: sid, qrData: qrData)
    }

    func aliOAuthPollQrStatus(token: AliOAuthQrToken) async throws -> AliOAuthQrPollResult {
        let url = URL(string: "\(AliOAuthConfig.statusURLPrefix)/\(token.sid)/status")!
        var request = URLRequest(url: url)
        request.setValue(aliUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed(message: "阿里 OAuth QR 轮询返回格式异常")
        }
        if let code = json["code"] as? String, code != "OK" && code != "ok" && code != "0" {
            return .failed(message: json["message"] as? String ?? code)
        }
        let dataObj = json["data"] as? [String: Any] ?? json
        let rawStatus = (dataObj["status"] as? String ?? "").lowercased()
        switch rawStatus {
        case "waitlogin", "new", "waiting", "":
            return .pending
        case "scansuccess", "scaned", "scanned", "scan_success":
            return .scanned
        case "loginfailed", "canceled", "cancelled", "cancel", "expired":
            return .expired
        case "loginsuccess", "confirmed", "login_success", "success":
            guard let authCode = dataObj["authCode"] as? String
                    ?? dataObj["auth_code"] as? String
                    ?? dataObj["code"] as? String, !authCode.isEmpty else {
                return .failed(message: "登录成功但未返回 authCode")
            }
            return .success(authCode: authCode)
        default:
            return .failed(message: "未知状态 \(rawStatus)")
        }
    }

    func aliOAuthSaveCredential(authCode: String) async throws {
        try await exchangeAliOAuthCode(authCode)
    }

    // MARK: - UC 原生扫码

    struct UCQrLoginToken {
        let token: String
        let clientId: String
        let pollClientId: String
        let requestId: String
        let qrPayload: String
    }

    enum UCQrPollResult {
        case pending
        case scanned
        case success(serviceTicket: String)
        case expired
        case failed(message: String)
    }

    // 对齐 iBox 实测：UC 扫码登录 web 端 client_id 为 381，请求为 POST + form body
    private static let ucWebClientId = "381"

    func ucCreateQrToken(clientId: String = ucWebClientId, pollClientId: String = ucWebClientId) async throws -> UCQrLoginToken {
        let ts = timestampMS()
        var components = URLComponents(string: "https://api.open.uc.cn/cas/ajax/getTokenForQrcodeLogin")!
        components.queryItems = [
            URLQueryItem(name: "__dt", value: "2951"),
            URLQueryItem(name: "__t", value: ts)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://broccoli.uc.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://broccoli.uc.cn/", forHTTPHeaderField: "Referer")
        request.setValue(ucUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.httpBody = "client_id=\(clientId)&request_id=\(ts)&v=1.2".data(using: .utf8)

        let (data, response) = try await ucSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.remoteError("UC 获取扫码 token HTTP 失败")
        }
        let json = try parseJSON(data)
        let rawBody = String(data: data, encoding: .utf8) ?? "nil"
        print("[VBox UC CreateToken] raw: \(rawBody)")
        let apiStatus = (json["status"] as? Int) ?? -1
        if apiStatus != 2000000 && apiStatus != -1 {
            let msg = json["message"] as? String ?? "未知错误"
            print("[VBox UC CreateToken] API status: \(apiStatus) message: \(msg)")
        }
        guard let token = extractString(json, keys: ["token", "qrcode_token"])
                ?? extractNestedString(json, path: ["data", "members", "token"])
                ?? extractNestedString(json, path: ["data", "token"])
                ?? extractNestedString(json, path: ["result", "token"]) else {
            throw AuthError.invalidResponse("UC 未返回二维码 token")
        }
        print("[VBox UC CreateToken] token: \(token) clientId: \(clientId) requestId: \(ts)")
        return UCQrLoginToken(token: token, clientId: clientId, pollClientId: pollClientId, requestId: ts, qrPayload: ucQRCodePayload(token: token, clientId: pollClientId))
    }

    func ucPollQrStatus(token: UCQrLoginToken) async throws -> UCQrPollResult {
        let ts = timestampMS()
        var components = URLComponents(string: "https://api.open.uc.cn/cas/ajax/getServiceTicketByQrcodeToken")!
        components.queryItems = [
            URLQueryItem(name: "__dt", value: "10314"),
            URLQueryItem(name: "__t", value: ts)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://broccoli.uc.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://broccoli.uc.cn/", forHTTPHeaderField: "Referer")
        request.setValue(ucUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.httpBody = "client_id=\(token.pollClientId)&request_id=\(ts)&token=\(token.token)&v=1.2".data(using: .utf8)

        let (data, response) = try await ucSession.data(for: request)
        let json = try parseJSON(data)
        let rawBody = String(data: data, encoding: .utf8) ?? "nil"
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("[VBox UC Poll] HTTP \(httpStatus) raw: \(rawBody)")

        let ticket = extractNestedString(json, path: ["data", "members", "service_ticket"])
            ?? extractNestedString(json, path: ["data", "service_ticket"])
            ?? extractNestedString(json, path: ["result", "service_ticket"])
            ?? extractString(json, keys: ["service_ticket", "ticket"])
        if let ticket, !ticket.isEmpty {
            print("[VBox UC Poll] 获取到 service_ticket: \(ticket)")
            return .success(serviceTicket: ticket)
        }

        var status = json["status"] as? Int
            ?? json["code"] as? Int
            ?? json["status"] as? NSNumber as? Int
            ?? json["code"] as? NSNumber as? Int
            ?? extractNestedInt(json, path: ["data", "members", "status"])
            ?? extractNestedInt(json, path: ["data", "status"])
            ?? -1
        if status == -1 {
            if let s = json["status"] as? String ?? json["code"] as? String {
                status = Int(s) ?? -1
                if status == -1, s == "SUCCESS" || s.caseInsensitiveCompare("ok") == .orderedSame { status = 0 }
            }
        }
        print("[VBox UC Poll] parsed status: \(status)")

        // 已知状态码映射
        if [50004002, 50004003, 50004004, 50004005, 50004006, 50004007].contains(status) { return .expired }
        if status == 50004000 { return .scanned }
        // 50004001 = 等待扫码 / 50000000 = 服务器繁忙（token 尚未就绪，继续轮询）
        if status == 50004001 || status == 50000000 { return .pending }
        if status == 0 || status == 2000000 { return .pending }
        if status != -1 { print("[VBox UC Poll] unknown status: \(status), treating as pending") }
        return .pending
    }

    func ucExchangeServiceTicket(_ serviceTicket: String) async throws {
        // 对齐 iBox：使用 account/mobileinfo 而非 account/info（UC 体系专用端点）
        // 使用 ucSession（共享）而非独立 oneShot，确保 Cookie 从轮询步骤贯通
        var components = URLComponents(string: "https://drive.uc.cn/account/mobileinfo")!
        components.queryItems = [
            URLQueryItem(name: "pr", value: "UCBrowser"),
            URLQueryItem(name: "fr", value: "h5"),
            URLQueryItem(name: "__t", value: timestampMS())
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("https://drive.uc.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://drive.uc.cn/", forHTTPHeaderField: "Referer")
        request.setValue(ucUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await ucSession.data(for: request)
        let rawBody = String(data: data, encoding: .utf8) ?? "nil"
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("[VBox UC Exchange] HTTP \(httpStatus): \(rawBody.prefix(300))")

        // 收集 ucSession 中积累的全部 Cookie（来自 getToken + 轮询 + 本次 exchange）
        let allCookies = collectAllCookiesFromSession(ucSession, for: URL(string: "https://drive.uc.cn")!)
        let headerCookie = collectCookies(from: (response as? HTTPURLResponse) ?? HTTPURLResponse(), storage: ucSession.configuration.httpCookieStorage, url: URL(string: "https://drive.uc.cn")!)
        let cookie = mergeCookieStrings([allCookies, headerCookie])
        print("[VBox UC Exchange] session cookies: \(allCookies.isEmpty ? "none" : allCookies.prefix(100))...")
        print("[VBox UC Exchange] merged cookie: \(cookie.isEmpty ? "none" : cookie.prefix(100))...")

        // 如果手机端已确认登录，ucSession 中应已有 _UP_xxx Cookie
        let cookieLower = cookie.lowercased()
        let hasUCLogin = cookieLower.contains("_up_") || cookieLower.contains("__pus=") || cookieLower.contains("__kps=") || cookieLower.contains("__uid=")
        if hasUCLogin {
            print("[VBox UC Exchange] ✅ 获取到 UC 登录态 Cookie")
            try await ucSaveCredentialFromCookie(cookie: cookie, data: data, source: "UC mobileinfo")
            return
        }

        // 回退：尝试 pan.quark.cn account/info（兼容旧版 CAS）
        print("[VBox UC Exchange] mobileinfo 未返回登录态 Cookie，回退 pan.quark.cn")
        let fallbackUrl = URL(string: "https://pan.quark.cn/account/info?st=\(serviceTicket)&fr=pc&platform=pc")!
        var fbRequest = URLRequest(url: fallbackUrl)
        fbRequest.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        fbRequest.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        fbRequest.setValue(ucUserAgent, forHTTPHeaderField: "User-Agent")
        fbRequest.setValue("*/*", forHTTPHeaderField: "Accept")

        let (fbData, fbResponse) = try await ucSession.data(for: fbRequest)
        let fbBody = String(data: fbData, encoding: .utf8) ?? "nil"
        let fbHttpStatus = (fbResponse as? HTTPURLResponse)?.statusCode ?? 0
        print("[VBox UC Exchange] fallback HTTP \(fbHttpStatus): \(fbBody.prefix(300))")

        let fbAllCookies = collectAllCookiesFromSession(ucSession, for: URL(string: "https://pan.quark.cn")!)
        let fbHeaderCookie = collectCookies(from: (fbResponse as? HTTPURLResponse) ?? HTTPURLResponse(), storage: ucSession.configuration.httpCookieStorage, url: URL(string: "https://pan.quark.cn")!)
        let fbCookie = mergeCookieStrings([fbAllCookies, fbHeaderCookie, allCookies])
        print("[VBox UC Exchange] fallback merged cookie: \(fbCookie.isEmpty ? "none" : fbCookie.prefix(100))...")

        let fbCookieLower = fbCookie.lowercased()
        guard fbCookieLower.contains("__pus=") || fbCookieLower.contains("__kps=") || fbCookieLower.contains("__uid=") || fbCookieLower.contains("_up_") else {
            throw AuthError.invalidResponse("UC Cookie 缺少必须字段，登录可能无效")
        }
        try await ucSaveCredentialFromCookie(cookie: fbCookie, data: fbData, source: "UC pan.quark.cn fallback")
    }

    private func collectAllCookiesFromSession(_ session: URLSession, for url: URL) -> String {
        guard let storage = session.configuration.httpCookieStorage else { return "" }
        let cookies = storage.cookies(for: url) ?? []
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func ucSaveCredentialFromCookie(cookie: String, data: Data, source: String) async throws {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let userName = extractNestedString(json ?? [:], path: ["data", "nickname"])
            ?? extractString(json ?? [:], keys: ["nickname", "nick_name", "user_name"])

        let credential = CloudDriveCredential(
            driveType: CloudDriveManager.DriveType.uc.rawValue,
            authType: .qr,
            accessToken: nil,
            refreshToken: nil,
            cookie: cookie,
            driveId: nil,
            userId: extractNestedString(json ?? [:], path: ["data", "uid"]) ?? extractString(json ?? [:], keys: ["uid", "user_id"]),
            userName: userName,
            avatar: extractNestedString(json ?? [:], path: ["data", "avatar"]) ?? extractString(json ?? [:], keys: ["avatar"]),
            expiresAt: nil,
            updatedAt: Date(),
            lastCheckedAt: Date(),
            state: .valid,
            statusMessage: "UC 扫码登录成功",
            extra: [:]
        )
        saveCredential(credential)
        print("[VBox UC Exchange] ✅ 已保存 UC Cookie (source: \(source)): \(cookie)")

        // 异步兑换 UCTV Token，不影响登录成功返回
        Task {
            do {
                let tvToken = try await self.ucExchangeTVToken(cookie: cookie)
                await MainActor.run {
                    guard var cred = self.credentials[CloudDriveManager.DriveType.uc.rawValue] else { return }
                    var extra = cred.extra
                    extra["uc_tv_token"] = tvToken
                    cred.extra = extra
                    cred.statusMessage = "UC 扫码登录成功（已获取 UCTV Token）"
                    self.credentials[CloudDriveManager.DriveType.uc.rawValue] = cred
                    self.persist()
                    CloudDriveAuthManager.logSensitive("[VBox UC] UCTV Token 已保存", value: tvToken)
                }
            } catch {
                print("[VBox UC] UCTV Token 兑换失败（非阻断）: \(error)")
            }
        }
    }

    func ucExchangeTVToken(cookie: String) async throws -> String {
        // 优先 HTTPS，失败再回退 HTTP（HTTP 需要 Info.plist 配置 ATS 例外）
        let endpoints = ["https://api.extscreen.com/ucdrive/token", "http://api.extscreen.com/ucdrive/token"]
        let body: [String: Any] = [
            "token": "",
            "device_type": "ios",
            "app_version": "1.0.0"
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var lastError: Error?
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.httpBody = bodyData
            do {
                let (data, _) = try await session.data(for: request)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw AuthError.invalidResponse("UCTV Token 返回无法解析")
                }
                if let code = json["code"] as? String, code != "OK" && code != "ok" && code != "0" {
                    throw AuthError.remoteError(json["message"] as? String ?? code)
                }
                if let code = json["code"] as? Int, code != 0 && code != 200 {
                    throw AuthError.remoteError(json["message"] as? String ?? "code=\(code)")
                }
                let dataObj = json["data"] as? [String: Any] ?? json
                guard let token = dataObj["token"] as? String ?? dataObj["uc_tv_token"] as? String ?? dataObj["access_token"] as? String, !token.isEmpty else {
                    throw AuthError.invalidResponse("UCTV Token 返回为空")
                }
                return token
            } catch {
                lastError = error
                print("[VBox UC] UCTV Token 端点 \(endpoint) 失败: \(error)")
            }
        }
        throw lastError ?? AuthError.remoteError("UCTV Token 兑换失败")
    }

    // MARK: - 百度原生扫码

    struct BaiduQrLoginToken {
        let sign: String
        let channelId: String
        let qrURL: String
    }

    enum BaiduQrPollResult {
        case pending
        case scanned
        case success(bdussURL: String?)
        case expired
        case failed(message: String)
    }

    func baiduCreateQrToken() async throws -> BaiduQrLoginToken {
        var components = URLComponents(string: "https://passport.baidu.com/v2/api/getqrcode")!
        components.queryItems = [
            URLQueryItem(name: "lp", value: "pc"),
            URLQueryItem(name: "qrloginfrom", value: "pc"),
            URLQueryItem(name: "gid", value: UUID().uuidString.replacingOccurrences(of: "-", with: "")),
            URLQueryItem(name: "apiver", value: "v3"),
            URLQueryItem(name: "tt", value: timestampMS())
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(baiduUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        let json = try parseJSON(data)
        let sign = extractString(json, keys: ["sign"]) ?? extractNestedString(json, path: ["data", "sign"]) ?? ""
        let channelId = extractString(json, keys: ["channel_id"]) ?? extractNestedString(json, path: ["data", "channel_id"]) ?? sign
        let imgurl = extractString(json, keys: ["imgurl"]) ?? extractNestedString(json, path: ["data", "imgurl"]) ?? ""
        guard !sign.isEmpty, !imgurl.isEmpty else {
            throw AuthError.invalidResponse("百度未返回二维码 sign/imgurl")
        }
        let qrURL = imgurl.hasPrefix("http") ? imgurl : "https://\(imgurl.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        return BaiduQrLoginToken(sign: sign, channelId: channelId, qrURL: qrURL)
    }

    func baiduPollQrStatus(token: BaiduQrLoginToken) async throws -> BaiduQrPollResult {
        var components = URLComponents(string: "https://passport.baidu.com/channel/unicast")!
        components.queryItems = [
            URLQueryItem(name: "channel_id", value: token.channelId),
            URLQueryItem(name: "tpl", value: "netdisk"),
            URLQueryItem(name: "apiver", value: "v3"),
            URLQueryItem(name: "tt", value: timestampMS())
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(baiduUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        let json = try parseJSON(data)
        let errno = json["errno"] as? Int ?? -1
        if errno == 1 || errno == 2 { return .pending }
        if errno == 0 {
            var payload: [String: Any] = json
            if let raw = json["channel_v"] as? String,
               let rawData = raw.data(using: .utf8),
               let nested = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] {
                payload = nested
            }
            let status = payload["status"] as? Int ?? -1
            if status == 2 || payload["bduss"] != nil || payload["v"] != nil {
                return .success(bdussURL: payload["bduss"] as? String ?? payload["v"] as? String)
            }
            if status == 0 || status == 1 { return .scanned }
            return .pending
        }
        if errno == 3 || errno == 4 { return .expired }
        return .failed(message: json["errmsg"] as? String ?? "百度轮询 errno=\(errno)")
    }

    func baiduExchangeQrLogin(token: BaiduQrLoginToken, bdussURL: String?) async throws {
        var components = URLComponents(string: "https://passport.baidu.com/v3/login/main/qrbdusslogin")!
        let bdussParam = normalizeBaiduQrBDUSSParam(bdussURL) ?? token.sign
        components.queryItems = [
            URLQueryItem(name: "v", value: timestampMS()),
            URLQueryItem(name: "bduss", value: bdussParam),
            URLQueryItem(name: "u", value: "https://pan.baidu.com/disk/main"),
            URLQueryItem(name: "loginVersion", value: "v4"),
            URLQueryItem(name: "qrcode", value: "1"),
            URLQueryItem(name: "tpl", value: "netdisk")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(baiduUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")

        let cookieCollector = RedirectCookieCollector()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        let oneShot = URLSession(configuration: config, delegate: cookieCollector, delegateQueue: nil)
        defer { oneShot.finishTasksAndInvalidate() }
        let (_, response) = try await oneShot.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse("百度登录无响应") }
        let responseCookie = collectCookies(from: http, storage: oneShot.configuration.httpCookieStorage, url: URL(string: "https://pan.baidu.com")!)
        let initialCookie = mergeCookieStrings([cookieCollector.cookieString(), responseCookie])
        let cookie = await baiduEnrichAccountCookie(initialCookie)
        guard isBaiduAccountCookie(cookie) else {
            throw AuthError.invalidResponse("百度扫码未返回完整 BDUSS/STOKEN")
        }
        print("✅ 百度扫码 Cookie 字段：\(baiduCookieNames(in: cookie).joined(separator: ","))")
        let vars = try? await baiduFetchTemplateVariables(cookie: cookie)
        var credential = CloudDriveCredential(
            driveType: CloudDriveManager.DriveType.baidu.rawValue,
            authType: .qr,
            accessToken: nil,
            refreshToken: nil,
            cookie: cookie,
            driveId: nil,
            userId: vars?["uk"],
            userName: vars?["username"] ?? "百度扫码账号",
            avatar: nil,
            expiresAt: nil,
            updatedAt: Date(),
            lastCheckedAt: Date(),
            state: .valid,
            statusMessage: "百度扫码登录成功",
            extra: vars ?? [:]
        )
        saveCredential(credential)

        credential.statusMessage = "百度扫码登录成功，已保存 BDUSS/STOKEN"
        credential.extra["cookie_mode"] = "BDUSS_STOKEN"
        saveCredential(credential, syncLegacyToken: false)
        CloudDriveManager.shared.cleanupInvalidBaiduTokens()
    }

    private func baiduEnrichAccountCookie(_ cookie: String) async -> String {
        let normalizedCookie = mergeCookieStrings([cookie])
        guard !normalizedCookie.isEmpty else { return normalizedCookie }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        let storage = config.httpCookieStorage ?? HTTPCookieStorage.shared
        config.httpCookieStorage = storage
        seedBaiduCookies(normalizedCookie, into: storage)

        let oneShot = URLSession(configuration: config)
        defer { oneShot.finishTasksAndInvalidate() }

        var collected = normalizedCookie
        // 扫码完成后强制访问下列五条「只读、不改账号、不写网盘」的端点，
        // 让百度服务端通过 Set-Cookie 把 BFESS 系列字段补齐：
        //   1. www.baidu.com         → BAIDUID / BAIDUID_BFESS / BDORZ / PSTM
        //   2. passport.baidu.com    → STOKEN_BFESS / BDUSS_BFESS / HOSUPPORT
        //   3. pan.baidu.com/disk/main           → 网盘域本地化 cookie
        //   4. pan.baidu.com/api/gettemplatevariable → bdstoken / uk
        //   5. pan.baidu.com/api/getuinfo        → 用户基础信息附带 cookie
        // 全部 GET、单次串行、失败静默回退，不会改账号资料、不会触发风控、不会动网盘文件。
        let endpoints = [
            "https://www.baidu.com/",
            "https://passport.baidu.com/center",
            "https://pan.baidu.com/disk/main",
            "https://pan.baidu.com/api/gettemplatevariable?clienttype=0&app_id=250528&web=1&fields=[%22bdstoken%22,%22uk%22,%22username%22]",
            "https://pan.baidu.com/api/getuinfo?clienttype=0&app_id=250528&web=1"
        ]

        for urlString in endpoints {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.setValue(collected, forHTTPHeaderField: "Cookie")
            request.setValue(baiduUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
            do {
                let (_, response) = try await oneShot.data(for: request)
                if let http = response as? HTTPURLResponse {
                    let responseCookie = collectCookies(from: http, storage: storage, url: url)
                    let storageCookie = CloudDriveAuthManager.cookieString(from: storage.cookies ?? [])
                    collected = mergeCookieStrings([collected, responseCookie, storageCookie])
                }
            } catch {
                continue
            }
        }

        // 只打字段名，不打 cookie 值；用于诊断 BFESS 是否补齐。
        print("ℹ️ 百度扫码 Cookie 补全后字段：\(baiduCookieNames(in: collected).joined(separator: ","))")
        return collected
    }
    
    private func baiduIsVerifyCoolingDown(_ key: String) -> Bool {
        let cooldowns = baiduVerifyCooldownCache()
        return (cooldowns[key] ?? .distantPast) > Date()
    }
    
    private func baiduMarkVerifyCooldown(_ key: String, seconds: TimeInterval = 10 * 60) {
        var cache = baiduVerifyCooldownCache()
        cache[key] = Date().addingTimeInterval(seconds)
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: baiduVerifyCooldownKey)
        }
    }
    
    private func baiduVerifyCooldownCache() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: baiduVerifyCooldownKey),
              let cache = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return [:]
        }
        return cache
    }

    // MARK: - 139云盘原生扫码

    @MainActor
    final class Pan139QrLoginHelper: NSObject, WKNavigationDelegate, ObservableObject {
        @Published var statusText = "正在加载..."
        @Published var isLoggedIn = false
        @Published var errorText = ""

        let webView: WKWebView
        private var pollTask: Task<Void, Never>?

        override init() {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            webView = WKWebView(frame: frame, configuration: config)
            super.init()
            webView.navigationDelegate = self
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        }

        func startLogin() {
            statusText = "正在加载139云盘页面..."
            // 139云盘移动端登录页面
            guard let url = URL(string: "https://yun.139.com/w/") else { return }
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                // 等待页面完全加载后再尝试切换扫码标签
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await switchToQRCodeTab()
                startPolling()
            }
        }

        private func switchToQRCodeTab() async {
            // 增强版 JS：多策略查找并点击扫码/二维码入口
            let js = #"""
            (function() {
                // 策略1: 精确查找包含"扫码"/"二维码"的文字元素
                var elems = document.querySelectorAll('div, span, button, a, li, p, label, input[type="button"], input[type="submit"], .tab-item, .login-tab, [class*="tab"], [class*="Tab"], [class*="login"], [class*="Login"]');
                for (var i = 0; i < elems.length; i++) {
                    var el = elems[i];
                    var txt = (el.textContent || '').trim();
                    var cls = ((el.className||'') + ' ' + (el.id||'') + ' ' + (el.getAttribute('data-type')||'')).toLowerCase();
                    if ((txt.indexOf('扫码') !== -1 || txt.indexOf('二维码') !== -1 ||
                         txt.indexOf('QR') !== -1 || txt.indexOf('qr') !== -1) &&
                        el.offsetWidth > 0 && el.offsetHeight > 0) {
                        el.click();
                        return 'clicked:' + txt.substring(0, 10);
                    }
                    if ((cls.indexOf('qr') !== -1 || cls.indexOf('scan') !== -1 ||
                         cls.indexOf('扫码') !== -1 || cls.indexOf('qrcode') !== -1) &&
                        el.offsetWidth > 0 && el.offsetHeight > 0) {
                        el.click();
                        return 'clicked_by_class';
                    }
                }
                // 策略2: 尝试通过 URL hash 或路由切换到扫码模式
                if (window.location.hash.indexOf('qrcode') === -1 &&
                    window.location.hash.indexOf('scan') === -1) {
                    try {
                        var newHash = window.location.hash + '#qrcode';
                        window.location.hash = 'qrcode';
                        return 'hash_changed';
                    } catch(e) {}
                }
                // 策略3: 查找所有可见的可点击元素，尝试匹配登录方式切换
                var allClicks = document.querySelectorAll('[onclick], [data-action], [data-type]');
                for (var j = 0; j < allClicks.length; j++) {
                    var cel = allClicks[j];
                    var attr = (cel.getAttribute('onclick')||'') + (cel.getAttribute('data-action')||'') + (cel.getAttribute('data-type')||'');
                    if ((attr.indexOf('qr') !== -1 || attr.indexOf('scan') !== -1 || attr.indexOf('扫码') !== -1) &&
                        cel.offsetWidth > 0 && cel.offsetHeight > 0) {
                        cel.click();
                        return 'clicked_by_attr';
                    }
                }
                return 'notfound';
            })()
            """#
            do {
                let result = try await webView.evaluateJavaScript(js)
                if let r = result as? String {
                    if r.hasPrefix("clicked") {
                        statusText = "已切换到扫码登录，请使用中国移动云盘 APP 扫描二维码"
                    } else if r == "hash_changed" {
                        statusText = "尝试切换扫码模式，请使用中国移动云盘 APP 扫码"
                    } else {
                        statusText = "未找到扫码入口，请在页面中手动切换到扫码登录"
                    }
                } else {
                    statusText = "请使用中国移动云盘 APP 扫码登录"
                }
                print("[Pan139] switchToQRCodeTab result: \(result ?? "nil")")
            } catch {
                statusText = "请使用中国移动云盘 APP 扫码登录"
                print("[Pan139] switchToQRCodeTab error: \(error)")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == -999 { return }
            self.errorText = "页面加载失败"
            self.statusText = "请检查网络后重试"
            print("[Pan139] didFail navigation: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.errorText = "链接失败: \(error.localizedDescription)"
            self.statusText = "加载失败"
            print("[Pan139] didFailProvisionalNavigation: \(error)")
        }

        private func startPolling() {
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                guard let self = self else { return }
                for _ in 1...120 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }

                    let cookies = await self.getAllCookies()
                    let cookieStr = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    
                    print("[Pan139] polling cookies count: \(cookies.count), names: \(cookies.map { $0.name }.joined(separator: ", "))")

                    // 检测多个可能的登录成功标志
                    let hasLoginCookie = cookies.contains { cookie in
                        let name = cookie.name.lowercased()
                        let value = cookie.value
                        // 139云盘可能的认证 Cookie 名称
                        return (name == "ssotoken" || name == "sso_token" ||
                                name == "aSSOToken" || name == "mcloud_sso" ||
                                name.contains("sso") || name.contains("SSO") ||
                                name.contains("token") && value.count > 20) &&
                               cookie.value.count > 10
                    }

                    if hasLoginCookie {
                        // 检查更具体的认证字段
                        let hasSSO = cookies.contains { $0.name.lowercased().contains("sso") }
                        let hasSession = cookies.contains { $0.name.lowercased().contains("session") }
                        let hasToken = cookies.contains { $0.name.lowercased().contains("token") && $0.value.count > 20 }
                        
                        if hasSSO || hasSession || hasToken {
                            await MainActor.run {
                                self.isLoggedIn = true
                                self.statusText = "登录成功"
                                print("[Pan139] login success, cookieStr length: \(cookieStr.count)")
                                CloudDriveAuthManager.shared.saveWebViewCookie(type: .pan139, cookie: cookieStr)
                            }
                            return
                        }
                    }
                    
                    // 额外检测：URL 是否已重定向到登录后的页面
                    if let currentURL = self.webView.url?.absoluteString,
                       (currentURL.contains("yun.139.com/w/main") ||
                        currentURL.contains("yun.139.com/w/home") ||
                        currentURL.contains("yun.139.com/main")) {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功（检测到页面跳转）"
                            print("[Pan139] login success via URL redirect: \(currentURL)")
                            CloudDriveAuthManager.shared.saveWebViewCookie(type: .pan139, cookie: cookieStr)
                        }
                        return
                    }
                }
                await MainActor.run {
                    self.errorText = "登录超时，请重试"
                    self.statusText = "二维码已过期"
                }
            }
        }

        private func getAllCookies() async -> [HTTPCookie] {
            return await withCheckedContinuation { cont in
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    cont.resume(returning: cookies)
                }
            }
        }

        func cleanup() {
            pollTask?.cancel()
            pollTask = nil
            webView.stopLoading()
            statusText = "正在加载..."
            isLoggedIn = false
            errorText = ""
        }
    }

    // MARK: - 天翼云盘网页登录

    @MainActor
    final class Pan189LoginHelper: NSObject, WKNavigationDelegate, ObservableObject {
        @Published var statusText = "正在加载..."
        @Published var isLoggedIn = false
        @Published var errorText = ""

        let webView: WKWebView
        private var pollTask: Task<Void, Never>?

        override init() {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            webView = WKWebView(frame: frame, configuration: config)
            super.init()
            webView.navigationDelegate = self
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        }

        func startLogin() {
            statusText = "正在加载天翼云盘页面..."
            guard let url = URL(string: "https://cloud.189.cn/web/login.html") else { return }
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                startPolling()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == -999 { return }
            self.errorText = "页面加载失败"
            self.statusText = "请检查网络后重试"
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.errorText = "链接失败: \(error.localizedDescription)"
            self.statusText = "加载失败"
        }

        private func startPolling() {
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                guard let self = self else { return }
                self.statusText = "请在页面中登录天翼云盘账号（手机号+密码或扫码）"
                for _ in 1...180 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }

                    let cookies = await self.getAllCookies()
                    let cookieStr = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

                    // 检测是否已登录：检查是否有 SSOToken 或 userSession 相关 Cookie
                    let hasLoginCookie = cookies.contains { cookie in
                        let name = cookie.name.lowercased()
                        // 天翼云盘登录成功的标志性 Cookie
                        return (name.contains("ssotoken") || name.contains("sso_token") ||
                                name.contains("usersession") || name.contains("ec_session") ||
                                name == "CASTGC" || name == "isLogin") && cookie.value.count > 10
                    }

                    if hasLoginCookie {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功，正在保存 Cookie..."
                            CloudDriveAuthManager.shared.saveWebViewCookie(type: .pan189, cookie: cookieStr)
                        }
                        return
                    }

                    // 也尝试检测页面 URL 是否已跳转到主页（登录成功后的跳转）
                    if let currentURL = self.webView.url?.absoluteString,
                       (currentURL.contains("cloud.189.cn/web/main") ||
                        currentURL.contains("cloud.189.cn/main")) {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功，正在保存 Cookie..."
                            CloudDriveAuthManager.shared.saveWebViewCookie(type: .pan189, cookie: cookieStr)
                        }
                        return
                    }
                }
                await MainActor.run {
                    self.errorText = "登录超时（6分钟），请重试"
                    self.statusText = "登录超时"
                }
            }
        }

        private func getAllCookies() async -> [HTTPCookie] {
            return await withCheckedContinuation { cont in
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    cont.resume(returning: cookies)
                }
            }
        }

        func cleanup() {
            pollTask?.cancel()
            pollTask = nil
            webView.stopLoading()
            statusText = "正在加载..."
            isLoggedIn = false
            errorText = ""
        }
    }

    // MARK: - 123云盘网页登录

    @MainActor
    final class Pan123LoginHelper: NSObject, WKNavigationDelegate, ObservableObject {
        @Published var statusText = "正在加载..."
        @Published var isLoggedIn = false
        @Published var errorText = ""

        let webView: WKWebView
        private var pollTask: Task<Void, Never>?

        override init() {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            webView = WKWebView(frame: frame, configuration: config)
            super.init()
            webView.navigationDelegate = self
            webView.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        }

        func startLogin() {
            statusText = "正在加载123云盘登录页面..."
            guard let url = URL(string: "https://www.123pan.com/login") else { return }
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                startPolling()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == -999 { return }
            self.errorText = "页面加载失败"
            self.statusText = "请检查网络后重试"
            print("[Pan123] didFail navigation: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.errorText = "链接失败: \(error.localizedDescription)"
            self.statusText = "加载失败"
            print("[Pan123] didFailProvisionalNavigation: \(error)")
        }

        private func startPolling() {
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                guard let self = self else { return }
                self.statusText = "请在页面中登录123云盘（手机号/微信扫码）"
                for _ in 1...180 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }

                    let cookies = await self.getAllCookies()
                    let cookieStr = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    let bearerToken = self.extractBearerToken(from: cookies)
                    let localToken = await self.evaluateLocalStorageToken()
                    let accessToken = (bearerToken ?? localToken)?.trimmingCharacters(in: .whitespacesAndNewlines)

                    print("[Pan123] polling cookies count: \(cookies.count), names: \(cookies.map { $0.name }.joined(separator: ", "))")

                    // 检测登录成功的标志：精确 Cookie 或 JS Token
                    let hasLoginCookie = cookies.contains { cookie in
                        let name = cookie.name.lowercased()
                        let value = cookie.value
                        return (name == "authorization" ||
                                name == "token" ||
                                name == "userid" ||
                                name == "uid" ||
                                name.contains("passport") ||
                                name.contains("login")) && value.count > 10
                    } || (accessToken?.count ?? 0 > 10)

                    if hasLoginCookie {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功，正在保存 Token..."
                            print("[Pan123] login success, cookieStr length: \(cookieStr.count), token length: \(accessToken?.count ?? 0)")
                            CloudDriveAuthManager.shared.saveWebViewCookie(type: .pan123, cookie: cookieStr, accessToken: accessToken)
                        }
                        return
                    }

                    // 额外检测：URL 是否跳转到用户首页
                    if let currentURL = self.webView.url?.absoluteString,
                       (currentURL.contains("123pan.com/home") ||
                        currentURL.contains("123pan.com/dashboard") ||
                        currentURL.contains("123pan.com/disk") ||
                        currentURL.contains("123684.com/home")) {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功（检测到页面跳转），正在保存 Token..."
                            print("[Pan123] login success via URL redirect: \(currentURL)")
                            CloudDriveAuthManager.shared.saveWebViewCookie(type: .pan123, cookie: cookieStr, accessToken: accessToken)
                        }
                        return
                    }
                }
                await MainActor.run {
                    self.errorText = "登录超时（6分钟），请重试"
                    self.statusText = "登录超时"
                }
            }
        }

        /// 从 Cookie 中提取 Bearer Token（优先 authorization 或 token 字段）
        private func extractBearerToken(from cookies: [HTTPCookie]) -> String? {
            for cookie in cookies {
                let name = cookie.name.lowercased()
                let value = cookie.value
                if name == "authorization" || name == "token" {
                    if value.hasPrefix("Bearer ") {
                        return String(value.dropFirst(7))
                    }
                    if value.count > 10 {
                        return value
                    }
                }
            }
            return nil
        }

        /// 通过 JS 读取 123pan 的 localStorage / sessionStorage token
        private func evaluateLocalStorageToken() async -> String? {
            let scripts = [
                "localStorage.getItem('token')",
                "sessionStorage.getItem('token')",
                "localStorage.getItem('Authorization')",
                "sessionStorage.getItem('Authorization')"
            ]
            for script in scripts {
                let result: Any? = await withCheckedContinuation { continuation in
                    DispatchQueue.main.async {
                        self.webView.evaluateJavaScript(script) { value, _ in
                            continuation.resume(returning: value)
                        }
                    }
                }
                guard let token = result as? String, !token.isEmpty else { continue }
                if token.hasPrefix("Bearer ") {
                    return String(token.dropFirst(7))
                }
                return token
            }
            return nil
        }

        private func getAllCookies() async -> [HTTPCookie] {
            return await withCheckedContinuation { cont in
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    cont.resume(returning: cookies)
                }
            }
        }

        func cleanup() {
            pollTask?.cancel()
            pollTask = nil
            webView.stopLoading()
            statusText = "正在加载..."
            isLoggedIn = false
            errorText = ""
        }
    }

    // MARK: - UC 网盘网页登录兜底

    @MainActor
    final class UCWebLoginHelper: NSObject, WKNavigationDelegate, ObservableObject {
        @Published var statusText = "正在加载..."
        @Published var isLoggedIn = false
        @Published var errorText = ""

        let webView: WKWebView
        private var pollTask: Task<Void, Never>?

        override init() {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            webView = WKWebView(frame: frame, configuration: config)
            super.init()
            webView.navigationDelegate = self
            webView.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        }

        func startLogin() {
            statusText = "正在加载 UC 网盘登录页面..."
            guard let url = URL(string: "https://drive.uc.cn/") else { return }
            var req = URLRequest(url: url)
            req.setValue("https://drive.uc.cn/", forHTTPHeaderField: "Referer")
            webView.load(req)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                startPolling()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == -999 { return }
            self.errorText = "页面加载失败"
            self.statusText = "请检查网络后重试"
            print("[UC Web] didFail navigation: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.errorText = "链接失败: \(error.localizedDescription)"
            self.statusText = "加载失败"
            print("[UC Web] didFailProvisionalNavigation: \(error)")
        }

        private func startPolling() {
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                guard let self = self else { return }
                self.statusText = "请在页面中登录 UC 网盘（短信/账号/扫码）"
                for _ in 1...180 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }

                    let cookies = await self.getAllCookies()
                    let cookieStr = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    print("[UC Web] polling cookies count: \(cookies.count), names: \(cookies.map { $0.name }.joined(separator: ", "))")

                    let lower = cookieStr.lowercased()
                    let hasLoginCookie = lower.contains("__pus=") || lower.contains("__kps=") || lower.contains("__uid=") || lower.contains("_up_")

                    if hasLoginCookie {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功，正在保存 Cookie..."
                            print("[UC Web] login success, cookieStr length: \(cookieStr.count)")
                            CloudDriveAuthManager.shared.saveWebViewCookie(type: .uc, cookie: cookieStr)
                        }
                        return
                    }
                }
                await MainActor.run {
                    self.errorText = "登录超时（6分钟），请重试"
                    self.statusText = "登录超时"
                }
            }
        }

        private func getAllCookies() async -> [HTTPCookie] {
            return await withCheckedContinuation { cont in
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    cont.resume(returning: cookies)
                }
            }
        }

        func cleanup() {
            pollTask?.cancel()
            pollTask = nil
            webView.stopLoading()
            statusText = "正在加载..."
            isLoggedIn = false
            errorText = ""
        }
    }

    // MARK: - 115网盘网页登录

    @MainActor
    final class Pan115LoginHelper: NSObject, WKNavigationDelegate, ObservableObject {
        @Published var statusText = "正在加载..."
        @Published var isLoggedIn = false
        @Published var errorText = ""

        let webView: WKWebView
        private var pollTask: Task<Void, Never>?

        override init() {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            webView = WKWebView(frame: frame, configuration: config)
            super.init()
            webView.navigationDelegate = self
            webView.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        }

        func startLogin() {
            statusText = "正在加载115网盘登录页面..."
            guard let url = URL(string: "https://115.com/?ct=login") else { return }
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                startPolling()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == -999 { return }
            self.errorText = "页面加载失败"
            self.statusText = "请检查网络后重试"
            print("[Pan115] didFail navigation: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.errorText = "链接失败: \(error.localizedDescription)"
            self.statusText = "加载失败"
            print("[Pan115] didFailProvisionalNavigation: \(error)")
        }

        private func startPolling() {
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                guard let self = self else { return }
                self.statusText = "请在页面中登录115网盘（扫码或账号密码）"
                for _ in 1...180 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }

                    let cookies = await self.getAllCookies()
                    let cookieStr = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    
                    print("[Pan115] polling cookies count: \(cookies.count), names: \(cookies.map { $0.name }.joined(separator: ", "))")

                    // 115网盘登录成功的标志性 Cookie
                    let hasLoginCookie = cookies.contains { cookie in
                        let name = cookie.name.lowercased()
                        let value = cookie.value
                        return (name == "uid" || name == "cid" || name == "seid" ||
                                name.contains("user_id") || name.contains("userid") ||
                                name.contains("passport") || name.contains("uc_115")) && value.count > 5
                    }

                    if hasLoginCookie {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功，正在保存 Cookie..."
                            print("[Pan115] login success, cookieStr length: \(cookieStr.count)")
                            CloudDriveAuthManager.shared.saveWebViewCookie(type: .one15, cookie: cookieStr)
                        }
                        return
                    }

                    // 额外检测：URL 跳转到用户首页
                    if let currentURL = self.webView.url?.absoluteString,
                       (currentURL.contains("115.com/?ct=file") ||
                        currentURL.contains("115.com/?ct=disk") ||
                        currentURL.contains("115.com/?ac=space") ||
                        currentURL.contains("115.com/?ct=index") ||
                        currentURL.contains("/main") || currentURL.contains("/home")) {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功（检测到页面跳转），正在保存 Cookie..."
                            print("[Pan115] login success via URL redirect: \(currentURL)")
                            CloudDriveAuthManager.shared.saveWebViewCookie(type: .one15, cookie: cookieStr)
                        }
                        return
                    }
                }
                await MainActor.run {
                    self.errorText = "登录超时（6分钟），请重试"
                    self.statusText = "登录超时"
                }
            }
        }

        private func getAllCookies() async -> [HTTPCookie] {
            return await withCheckedContinuation { cont in
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    cont.resume(returning: cookies)
                }
            }
        }

        func cleanup() {
            pollTask?.cancel()
            pollTask = nil
            webView.stopLoading()
            statusText = "正在加载..."
            isLoggedIn = false
            errorText = ""
        }
    }

    // MARK: - 授权有效性测试

    @discardableResult
    func validateCredential(for driveType: CloudDriveManager.DriveType) async -> Bool {
        guard let credential = credential(for: driveType) else { return false }
        do {
            switch driveType {
            case .ali:
                _ = try await refreshAliAccessTokenIfNeeded()
            case .one15:
                try await validateCookie(url: "https://webapi.115.com/files?cid=0&limit=1", cookie: credential.cookie ?? "", referer: "https://115.com/")
            case .quark:
                try await validateCookie(url: "https://drive-pc.quark.cn/1/clouddrive/member?pr=ucpro&fr=pc&sys=darwin&ve=3.19.0", cookie: credential.cookie ?? "", referer: "https://pan.quark.cn/")
            case .uc:
                try await validateCookie(url: "https://pc-api.uc.cn/1/clouddrive/file/sort?pr=UCBrowser&fr=pc", cookie: credential.cookie ?? "", referer: "https://drive.uc.cn/")
            case .baidu:
                _ = try await baiduFetchTemplateVariables(cookie: credential.cookie ?? "")
            case .pan123:
                // 优先使用 Bearer Token + Cookie 校验；旧版本只有 Cookie 的也能继续校验
                try await validatePan123Credential(credential: credential)
            case .pan139:
                try await validateCookie(url: "https://yun.139.com/", cookie: credential.cookie ?? "", referer: "https://yun.139.com/")
            case .pan189:
                try await validateCookie(url: "https://cloud.189.cn/", cookie: credential.cookie ?? "", referer: "https://cloud.189.cn/")
            }
            markValid(driveType, message: "授权检测正常")
            return true
        } catch {
            markInvalid(driveType, reason: error.localizedDescription)
            return false
        }
    }

    func credential(for driveType: CloudDriveManager.DriveType) -> CloudDriveCredential? {
        credentials[driveType.rawValue]
    }

    func displayName(for driveType: CloudDriveManager.DriveType) -> String {
        credential(for: driveType)?.displayName ?? "未授权"
    }

    func statusText(for driveType: CloudDriveManager.DriveType) -> String {
        guard let credential = credential(for: driveType) else { return CloudDriveAuthState.notAuthorized.displayText }
        if let expiresAt = credential.expiresAt {
            if expiresAt < Date() { return CloudDriveAuthState.expired.displayText }
            if expiresAt.timeIntervalSinceNow < 30 * 60 { return CloudDriveAuthState.expiringSoon.displayText }
        }
        if let checked = credential.lastCheckedAt {
            return "\(credential.state.displayText) · \(Self.shortTime(checked))检测"
        }
        return credential.state.displayText
    }

    func isAuthorized(_ driveType: CloudDriveManager.DriveType) -> Bool {
        guard let credential = credential(for: driveType) else { return false }
        if driveType == .baidu, let cookie = credential.cookie {
            return credential.state != .invalid && isBaiduAccountCookie(cookie)
        }
        return credential.state != .invalid && credential.primarySecret?.isEmpty == false
    }

    func saveCredential(_ credential: CloudDriveCredential, syncLegacyToken: Bool = true) {
        credentials[credential.driveType] = credential
        persist()

        guard syncLegacyToken,
              let driveType = CloudDriveManager.DriveType(rawValue: credential.driveType),
              let value = credential.primarySecret,
              !value.isEmpty else { return }

        if driveType == .baidu, !isBaiduAccountCookie(value) {
            return
        }

        let tokenName = credential.userName?.isEmpty == false
            ? "\(driveType.displayName)-\(credential.userName!)"
            : "\(driveType.displayName)-\(credential.authType.rawValue)"
        CloudDriveManager.shared.addOrReplaceToken(type: driveType, name: tokenName, value: value)
    }

    func saveManualCredential(type: CloudDriveManager.DriveType, name: String, value: String) {
        let normalized = normalizedSecret(type: type, value: value)
        var credential = CloudDriveCredential(
            driveType: type.rawValue,
            authType: .manual,
            accessToken: type == .ali ? normalized : nil,
            refreshToken: type == .ali ? normalized : nil,
            cookie: type == .ali ? nil : normalized,
            driveId: nil,
            userId: nil,
            userName: name.isEmpty ? nil : name,
            avatar: nil,
            expiresAt: nil,
            updatedAt: Date(),
            lastCheckedAt: nil,
            state: .unknown,
            statusMessage: nil,
            extra: [:]
        )
        if type == .baidu {
            credential.cookie = normalized
            credential.refreshToken = nil
            credential.accessToken = nil
        }
        saveCredential(credential, syncLegacyToken: false)
    }

    func markInvalid(_ driveType: CloudDriveManager.DriveType, reason: String) {
        guard var credential = credentials[driveType.rawValue] else { return }
        credential.state = .invalid
        credential.statusMessage = reason
        credential.lastCheckedAt = Date()
        credential.updatedAt = Date()
        credentials[driveType.rawValue] = credential
        persist()
    }

    func markValid(_ driveType: CloudDriveManager.DriveType, message: String? = nil) {
        guard var credential = credentials[driveType.rawValue] else { return }
        credential.state = .valid
        credential.statusMessage = message
        credential.lastCheckedAt = Date()
        credential.updatedAt = Date()
        credentials[driveType.rawValue] = credential
        persist()
    }

    func removeCredential(for driveType: CloudDriveManager.DriveType) {
        credentials.removeValue(forKey: driveType.rawValue)
        persist()
    }

    func bestTokenValue(for driveType: CloudDriveManager.DriveType) -> String? {
        guard let value = credential(for: driveType)?.primarySecret else { return nil }
        if driveType == .baidu, !isBaiduAccountCookie(value) {
            return nil
        }
        return value
    }

    func saveQuarkLogin(cookie: String, nickName: String?, avatarURL: String?) {
        let credential = CloudDriveCredential(
            driveType: CloudDriveManager.DriveType.quark.rawValue,
            authType: .qr,
            accessToken: nil,
            refreshToken: nil,
            cookie: cookie,
            driveId: nil,
            userId: nil,
            userName: nickName,
            avatar: avatarURL,
            expiresAt: nil,
            updatedAt: Date(),
            lastCheckedAt: Date(),
            state: .valid,
            statusMessage: "夸克扫码登录成功",
            extra: [:]
        )
        saveCredential(credential)
    }

    @discardableResult
    func saveWebViewCookie(type: CloudDriveManager.DriveType, cookie: String, userName: String? = nil, accessToken: String? = nil) -> Bool {
        if type == .baidu, !isBaiduAccountCookie(cookie) {
            var credential = credentials[type.rawValue]
            credential?.statusMessage = "已捕获百度 Cookie，但未包含完整 BDUSS/STOKEN，未覆盖账号 Cookie"
            credential?.lastCheckedAt = Date()
            credential?.updatedAt = Date()
            if let credential {
                credentials[type.rawValue] = credential
                persist()
            }
            return false
        }
        let credential = CloudDriveCredential(
            driveType: type.rawValue,
            authType: .webView,
            accessToken: accessToken,
            refreshToken: type == .ali ? cookie : nil,
            cookie: type == .ali ? nil : cookie,
            driveId: nil,
            userId: nil,
            userName: userName,
            avatar: nil,
            expiresAt: nil,
            updatedAt: Date(),
            lastCheckedAt: nil,
            state: .unknown,
            statusMessage: accessToken != nil ? "WebView 已保存授权（含 Bearer Token）" : "WebView 已保存授权",
            extra: [:]
        )
        saveCredential(credential)
        if type == .baidu {
            CloudDriveManager.shared.cleanupInvalidBaiduTokens()
        }
        return true
    }

    nonisolated static func cookieString(from cookies: [HTTPCookie]) -> String {
        cookies
            .filter { !$0.name.isEmpty && !$0.value.isEmpty }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private func normalizedSecret(type: CloudDriveManager.DriveType, value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .one15:
            if trimmed.lowercased().hasPrefix("cookie:") {
                return String(trimmed.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if trimmed.contains("=") { return trimmed }
            return "CID=\(trimmed)"
        default:
            return trimmed
        }
    }

    private func isBaiduAccountCookie(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("bduss=") && lower.contains("stoken=")
    }

    private var ucUserAgent: String {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/1.8.5 Chrome/100.0.4896.160 Electron/18.3.5.16-b62cf9c50d Safari/537.36 Channel/ucpan_other_ch"
    }

    private var aliUserAgent: String {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }

    private var baiduUserAgent: String {
        // 使用更接近真实浏览器的 UA，减少风控风险
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }

    private var baiduPCSUserAgent: String {
        "netdisk;1.4.2;22021211RC;android-android;12;JSbridge4.4.0;jointBridge;1.1.0;"
    }

    private func seedBaiduCookies(_ cookie: String, into storage: HTTPCookieStorage) {
        let domains = [".baidu.com", "pan.baidu.com", "passport.baidu.com", "d.pcs.baidu.com"]
        for domain in domains {
            for piece in cookie.components(separatedBy: ";") {
                let kv = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let eq = kv.firstIndex(of: "=") else { continue }
                let name = String(kv[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(kv[kv.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !value.isEmpty else { continue }
                guard let httpCookie = HTTPCookie(properties: [
                    .domain: domain,
                    .path: "/",
                    .name: name,
                    .value: value,
                    .secure: "TRUE",
                    .expires: Date(timeIntervalSinceNow: 30 * 24 * 3600)
                ]) else { continue }
                storage.setCookie(httpCookie)
            }
        }
    }

    private func extractBaiduPCSCookie(from cookie: String) -> String? {
        let pcsNames = Set(["panpsc", "ptoken", "ptoken_bfess", "ndut_fmt", "nd_ftid"])
        var fields: [String] = []
        var used = Set<String>()
        for piece in cookie.components(separatedBy: ";") {
            let kv = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = kv.firstIndex(of: "=") else { continue }
            let name = String(kv[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(kv[kv.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = name.lowercased()
            guard !name.isEmpty, !value.isEmpty, pcsNames.contains(lower), !used.contains(lower) else { continue }
            used.insert(lower)
            fields.append("\(name)=\(value)")
        }
        return fields.isEmpty ? nil : fields.joined(separator: "; ")
    }

    private func baiduCookieNames(in cookie: String) -> [String] {
        cookie.components(separatedBy: ";").compactMap { piece in
            let kv = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = kv.firstIndex(of: "=") else { return nil }
            let name = String(kv[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
    }

    private func ucQRCodePayload(token: String, clientId: String) -> String {
        // 对齐 iBox 实测 payload：su.uc.cn/1_n0ZCv 后带完整 UC 浏览器参数
        // 这些参数让 UC 浏览器识别为内部页面，从而调用正确的原生确认流程
        var components = URLComponents(string: "https://su.uc.cn/1_n0ZCv")!
        let ucParams: [(String, String)] = [
            ("uc_param_str", "dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt"),
            ("ds", ucEncodedDeviceId()),
            ("dn", "76728740306-3c26d777"),
            ("fr", "iphone"),
            ("pf", "44"),
            ("bi", "997"),
            ("ve", "18.9.8.2995"),
            ("ss", "393x852"),
            ("gi", ucEncodedDeviceId()),
            ("mi", "iPhone15,2"),
            ("bt", "UC"),
            ("bm", "WWW"),
            ("ni", ucEncodedDeviceId()),
            ("jb", "2"),
            ("la", "zh-cn"),
            ("up", "s:iP6.x|f:iphone|m:iPhone 5|b:apple"),
            ("ut", ucEncodedDeviceId()),
            ("og", "GR"),
            ("pi", "1179x2556"),
            ("nt", "2"),
            ("nw", "WIFI"),
            ("pr", "UCBrowser"),
            ("ch", "2148612848"),
            ("mt", ucEncodedDeviceId()),
            ("pc", ucEncodedDeviceId()),
            ("token", token),
            ("client_id", clientId),
            ("uc_biz_str", "S:custom|C:titlebar_fix")
        ]
        components.queryItems = ucParams.map { URLQueryItem(name: $0.0, value: $0.1) }
        let payload = components.url?.absoluteString ?? "https://su.uc.cn/1_n0ZCv?uc_param_str=dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt&token=\(token)&client_id=\(clientId)"
        print("[VBox UC Payload] QR payload: \(payload)")
        return payload
    }

    /// 生成一个看起来像 UC 浏览器设备标识的 base64 字符串
    private func ucEncodedDeviceId() -> String {
        let data = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32).data(using: .utf8) ?? Data()
        return data.base64EncodedString()
    }

    private func timestampMS() -> String {
        String(Int(Date().timeIntervalSince1970 * 1000))
    }

    private func parseJSON(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse("返回不是 JSON 对象")
        }
        return json
    }

    private func extractString(_ json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String, !value.isEmpty { return value }
            if let value = json[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private func extractNestedString(_ json: [String: Any], path: [String]) -> String? {
        var current: Any = json
        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        if let value = current as? String, !value.isEmpty { return value }
        if let value = current as? NSNumber { return value.stringValue }
        return nil
    }

    private func extractNestedInt(_ json: [String: Any], path: [String]) -> Int? {
        var current: Any = json
        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        if let value = current as? Int { return value }
        if let value = current as? NSNumber { return value.intValue }
        return nil
    }

    private func collectCookies(from http: HTTPURLResponse, storage: HTTPCookieStorage?, url: URL) -> String {
        var cookieDict: [String: String] = [:]
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers["\(key)"] = "\(value)" }
        
        // 优先从 HTTPURLResponse 中解析 Set-Cookie（支持 iOS 15+ 多值 header）
        if #available(iOS 15.0, *) {
            for (key, value) in http.allHeaderFields {
                guard let lowerKey = key as? String, lowerKey.lowercased() == "set-cookie" else { continue }
                if let cookieValues = value as? [String] {
                    for cookieValue in cookieValues {
                        processSetCookieHeader(cookieValue, into: &cookieDict, for: url)
                    }
                } else if let singleValue = value as? String {
                    processSetCookieHeader(singleValue, into: &cookieDict, for: url)
                }
            }
        } else {
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
                if !cookie.name.isEmpty, !cookie.value.isEmpty {
                    cookieDict[cookie.name] = cookie.value
                }
            }
            if let raw = http.allHeaderFields["Set-Cookie"] as? String {
                processSetCookieHeader(raw, into: &cookieDict, for: url)
            }
        }
        
        if let cookies = storage?.cookies(for: url) {
            for cookie in cookies {
                if !cookie.name.isEmpty, !cookie.value.isEmpty {
                    cookieDict[cookie.name] = cookie.value
                }
            }
        }
        if url.host?.contains("baidu.com") == true, let cookies = storage?.cookies {
            for cookie in cookies where cookie.domain.contains("baidu.com") {
                if !cookie.name.isEmpty, !cookie.value.isEmpty {
                    cookieDict[cookie.name] = cookie.value
                }
            }
        }
        
        return cookieDict.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }
    
    private func processSetCookieHeader(_ header: String, into dict: inout [String: String], for url: URL) {
        for cookieHeader in splitSetCookieHeader(header) {
            processSingleSetCookie(cookieHeader, into: &dict, for: url)
        }
    }

    private func splitSetCookieHeader(_ header: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var index = header.startIndex
        while index < header.endIndex {
            let ch = header[index]
            if ch == "," {
                let nextIndex = header.index(after: index)
                let rest = header[nextIndex...]
                if rest.range(of: #"^\s*[A-Za-z0-9_\-]+="#, options: .regularExpression) != nil {
                    parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                    index = nextIndex
                    continue
                }
            }
            current.append(ch)
            index = header.index(after: index)
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(tail) }
        return parts
    }

    // 解析单个 Set-Cookie header 的辅助方法，正确处理包含逗号的时间格式
    private func processSingleSetCookie(_ cookieHeader: String, into dict: inout [String: String], for url: URL) {
        let components = cookieHeader.components(separatedBy: "; ")
        guard let mainCookie = components.first, let eqIndex = mainCookie.firstIndex(of: "=") else { return }
        
        let name = String(mainCookie[..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(mainCookie[mainCookie.index(after: eqIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !name.isEmpty, !value.isEmpty {
            dict[name] = value
        }
    }

    private func mergeCookieStrings(_ values: [String]) -> String {
        var dict: [String: String] = [:]
        for value in values {
            for piece in value.components(separatedBy: ";") {
                let kv = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let eq = kv.firstIndex(of: "=") else { continue }
                let key = String(kv[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
                let val = String(kv[kv.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty, !val.isEmpty { dict[key] = val }
            }
        }
        return dict.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private func normalizeBaiduQrBDUSSParam(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        value = value.removingPercentEncoding ?? value
        if let url = URL(string: value),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let bduss = components.queryItems?.first(where: { $0.name.lowercased() == "bduss" })?.value,
           !bduss.isEmpty {
            return bduss
        }
        if let match = try? NSRegularExpression(pattern: #"(?:^|[?&])bduss=([^&\s]+)"#, options: [.caseInsensitive])
            .firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
           let range = Range(match.range(at: 1), in: value) {
            return String(value[range])
        }
        return value
    }

    private func baiduFetchTemplateVariables(cookie: String) async throws -> [String: String] {
        guard !cookie.isEmpty else { throw AuthError.notAuthorized("百度 Cookie 为空") }
        var components = URLComponents(string: "https://pan.baidu.com/api/gettemplatevariable")!
        components.queryItems = [
            URLQueryItem(name: "clienttype", value: "0"),
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "fields", value: "[\"bdstoken\",\"token\",\"uk\",\"username\",\"servertime\"]")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(baiduUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
        let (data, _) = try await session.data(for: request)
        let json = try parseJSON(data)
        if let errno = json["errno"] as? Int, errno != 0 {
            throw AuthError.remoteError("百度登录态异常 errno=\(errno)")
        }
        let result = (json["result"] as? [String: Any]) ?? json
        var output: [String: String] = [:]
        for key in ["bdstoken", "token", "uk", "username", "servertime"] {
            if let value = result[key] as? String { output[key] = value }
            if let value = result[key] as? NSNumber { output[key] = value.stringValue }
        }
        guard output["bdstoken"] != nil || output["uk"] != nil else {
            throw AuthError.invalidResponse("百度未返回 bdstoken/uk")
        }
        return output
    }

    private func validatePan123Credential(credential: CloudDriveCredential) async throws {
        let cookie = credential.cookie ?? ""
        let token = credential.accessToken ?? ""
        guard !cookie.isEmpty || !token.isEmpty else { throw AuthError.notAuthorized("123云盘 Cookie 与 Token 均为空") }

        // 与 iBox 对齐：123pan Web 版文件列表接口；优先 GET，失败再尝试 POST
        let base = "https://www.123pan.com/api/file/list/new"
        let query = "driveId=0&limit=1&next=1&orderBy=filename&orderDirection=asc&parentFileId=0&trashed=false&operateType=4"
        let methods = ["GET", "POST"]
        var lastHTTPStatus = 0
        var lastRawBody = ""
        for method in methods {
            var components = URLComponents(string: base)!
            if method == "GET" {
                components.query = query
            }
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.setValue("https://www.123pan.com/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            if !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if method == "POST" {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "driveId": 0, "limit": 1, "next": 1, "orderBy": "filename",
                    "orderDirection": "asc", "parentFileId": 0, "trashed": false, "operateType": 4
                ])
            }
            let (data, response) = try await session.data(for: request)
            lastHTTPStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            lastRawBody = String(data: data, encoding: .utf8) ?? ""
            if lastHTTPStatus == 401 || lastHTTPStatus == 403 {
                // 继续尝试下一个 method，若全部尝试完仍无效则最后统一抛错
                continue
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // 123pan 的 code 可能是 Int 或 String，统一处理
                let codeInt = json["code"] as? Int
                let codeString = json["code"] as? String
                let isSuccess = (codeInt == 0 || codeInt == 200) || (codeString == "0" || codeString == "200" || codeString?.lowercased() == "ok")
                if isSuccess {
                    return // 校验通过
                }
                if let state = json["state"] as? Bool, state == false {
                    let msg = json["error"] as? String ?? json["message"] as? String ?? "123云盘登录态无效"
                    // 业务明确失败时，若还有其他 method 未尝试则继续
                    if method != methods.last {
                        print("[Pan123] 校验返回失败，尝试下一 method: \(msg)")
                        continue
                    }
                    throw AuthError.remoteError(msg)
                }
                let isUnauthorized: Bool = {
                    if let code = codeInt { return code == 401 || code == 403 || code == 40001 }
                    if let code = codeString { return code == "401" || code == "403" || code == "40001" }
                    return false
                }()
                if isUnauthorized {
                    let msg = json["message"] as? String ?? "123云盘登录态无效 code=\(json["code"] ?? "")"
                    if method != methods.last {
                        print("[Pan123] 校验返回 \(json["code"] ?? ""), 尝试下一 method: \(msg)")
                        continue
                    }
                    throw AuthError.remoteError(msg)
                }
            }
        }
        // 把最后尝试的 HTTP 状态码和原始响应体带出来，方便定位问题
        let detail = lastHTTPStatus != 0 ? "HTTP \(lastHTTPStatus)" : "无响应"
        let preview = String(lastRawBody.prefix(200))
        throw AuthError.remoteError("123云盘登录态校验失败 (\(detail)): \(preview)")
    }

    private func validateCookie(url: String, cookie: String, referer: String, authorization: String? = nil) async throws {
        guard !cookie.isEmpty else { throw AuthError.notAuthorized("Cookie 为空") }
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = url.contains("/file/sort") ? "POST" : "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        if let auth = authorization, !auth.isEmpty {
            request.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")
        }
        if request.httpMethod == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["pdir_fid": "0", "page": 1, "size": 1])
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw AuthError.remoteError("HTTP \(http.statusCode)")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let state = json["state"] as? Bool, state == false {
                throw AuthError.remoteError(json["error"] as? String ?? json["message"] as? String ?? "Cookie 无效")
            }
            if let code = json["code"] as? Int, code == 401 || code == 403 || code == 40001 {
                throw AuthError.remoteError(json["message"] as? String ?? "Cookie 无效 code=\(code)")
            }
        }
    }

    private func load() {
        do {
            if let decoded = try SecureCredentialStore.loadCredentials() {
                credentials = decoded
                return
            }
        } catch {
            print("[Auth] Keychain 读取失败: \(error)")
        }

        // 从旧版 UserDefaults 迁移一次，随后删除旧数据
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: CloudDriveCredential].self, from: data) {
            credentials = decoded
            do {
                try SecureCredentialStore.save(credentials: decoded)
                print("[Auth] 已从 UserDefaults 迁移到 Keychain")
            } catch {
                print("[Auth] 迁移到 Keychain 失败: \(error)")
            }
            defaults.removeObject(forKey: storageKey)
        } else {
            credentials = [:]
        }
    }

    private func persist() {
        do {
            try SecureCredentialStore.save(credentials: credentials)
        } catch {
            print("[Auth] Keychain 保存失败: \(error)")
        }
    }

    private func syncLegacyTokensIfNeeded() {
        for token in CloudDriveManager.shared.savedTokens {
            guard let type = CloudDriveManager.DriveType(rawValue: token.type),
                  credentials[type.rawValue] == nil else { continue }
            saveManualCredential(type: type, name: token.name, value: token.value)
        }
    }

    /// 启动时批量校验所有已保存凭证，将失效凭证标记为 invalid
    func validateAllCredentials() async {
        for credential in credentials.values {
            guard let type = CloudDriveManager.DriveType(rawValue: credential.driveType) else { continue }
            _ = try? await validateCredential(for: type)
        }
    }

    /// 敏感字段日志脱敏（保留前 6 后 4，中间用 ... 替代）
    static func logSensitive(_ message: String, value: String?) {
        guard let value = value, !value.isEmpty else { return }
        let head = min(6, value.count)
        let tail = min(4, max(0, value.count - head))
        let prefix = String(value.prefix(head))
        let suffix = tail > 0 ? String(value.suffix(tail)) : ""
        print("\(message): \(prefix)...\(suffix) (length=\(value.count))")
    }

    private static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private final class RedirectCookieCollector: NSObject, URLSessionTaskDelegate {
    private var cookies: [String: HTTPCookie] = [:]
    private let lock = NSLock()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        collect(from: response, url: response.url ?? request.url)
        completionHandler(request)
    }

    func cookieString() -> String {
        lock.lock()
        defer { lock.unlock() }
        return CloudDriveAuthManager.cookieString(from: Array(cookies.values))
    }

    private func collect(from response: HTTPURLResponse, url: URL?) {
        guard let url else { return }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers["\(key)"] = "\(value)"
        }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        guard !parsed.isEmpty else { return }
        lock.lock()
        for cookie in parsed {
            cookies[cookie.name] = cookie
        }
        lock.unlock()
    }
}

enum AuthError: LocalizedError {
    case invalidResponse(String)
    case remoteError(String)
    case notAuthorized(String)
    case keychainError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message): return message
        case .remoteError(let message): return message
        case .notAuthorized(let message): return message
        case .keychainError(let message): return "Keychain 错误: \(message)"
        }
    }
}
