import Foundation
import Combine
import UIKit
import WebKit

private final class UCTrustSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

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
    private let aliOAuthClientId = "76917ccccd4441c39457a04f6084fb2f"
    private let aliOAuthRedirectURI = "https://alist.nn.ci/tool/aliyundrive/callback"

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        let ucConfig = URLSessionConfiguration.default
        ucConfig.timeoutIntervalForRequest = 30
        ucSession = URLSession(configuration: ucConfig, delegate: UCTrustSessionDelegate(), delegateQueue: nil)
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
        if let code = json["code"] as? String, code != "OK" {
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
            "refresh_token": refreshToken
        ])
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse("阿里刷新 token 返回无法解析")
        }
        if let code = json["code"] as? String {
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
        var components = URLComponents(string: "https://passport.alipan.com/newlogin/qrcode/generate.do")!
        components.queryItems = [
            URLQueryItem(name: "appName", value: "aliyun_drive"),
            URLQueryItem(name: "fromSite", value: "52"),
            URLQueryItem(name: "appEntrance", value: "web"),
            URLQueryItem(name: "isMobile", value: "false"),
            URLQueryItem(name: "lang", value: "zh_CN"),
            URLQueryItem(name: "returnUrl", value: ""),
            URLQueryItem(name: "bizParams", value: ""),
            URLQueryItem(name: "_bx-v", value: "2.0.31")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("https://www.alipan.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.alipan.com/", forHTTPHeaderField: "Referer")
        request.setValue(aliUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, _) = try await session.data(for: request)
        let json = try parseJSON(data)
        print("[Ali Passport] QR generate response keys: \(json.keys)")
        guard let content = json["content"] as? [String: Any],
              let dataObj = content["data"] as? [String: Any],
              let tValue = dataObj["t"],
              let ck = dataObj["ck"] as? String,
              let codeContent = dataObj["codeContent"] as? String else {
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
        return AliPassportQrToken(t: t, ck: ck, codeContent: codeContent)
    }

    func aliPassportPollQrStatus(token: AliPassportQrToken) async throws -> AliPassportQrPollResult {
        var components = URLComponents(string: "https://passport.alipan.com/newlogin/qrcode/query.do")!
        components.queryItems = [
            URLQueryItem(name: "appName", value: "aliyun_drive"),
            URLQueryItem(name: "fromSite", value: "52"),
            URLQueryItem(name: "appEntrance", value: "web"),
            URLQueryItem(name: "isMobile", value: "false"),
            URLQueryItem(name: "lang", value: "zh_CN"),
            URLQueryItem(name: "t", value: token.t),
            URLQueryItem(name: "ck", value: token.ck)
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("https://www.alipan.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.alipan.com/", forHTTPHeaderField: "Referer")
        request.setValue(aliUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, _) = try await session.data(for: request)
        let json = try parseJSON(data)
        guard let content = json["content"] as? [String: Any],
              let dataObj = content["data"] as? [String: Any] else {
            return .failed(message: "阿里 Passport 轮询返回格式异常")
        }
        let status = dataObj["qrCodeStatus"] as? String ?? ""
        switch status.uppercased() {
        case "NEW":
            return .pending
        case "SCANED":
            return .scanned
        case "CONFIRMED":
            guard let bizExt = dataObj["bizExt"] as? String else {
                print("[Ali Passport] CONFIRMED 但未返回 bizExt，dataObj keys: \(dataObj.keys)")
                return .failed(message: "扫码确认成功但未返回 bizExt")
            }
            print("[Ali Passport] bizExt raw (first 100): \(String(bizExt.prefix(100)))")
            let normalized = bizExt.replacingOccurrences(of: "-", with: "+")
                                   .replacingOccurrences(of: "_", with: "/")
            var bizData: Data?
            if let data = Data(base64Encoded: normalized) {
                bizData = data
            } else if let data = Data(base64Encoded: normalized + "=") {
                bizData = data
            } else if let data = Data(base64Encoded: normalized + "==") {
                bizData = data
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
            return .expired
        case "CANCELED":
            return .canceled
        default:
            return .failed(message: "未知状态: \(status)")
        }
    }

    func aliPassportSaveCredential(refreshToken: String, userInfo: [String: Any]) {
        let accessToken = userInfo["token"] as? String
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

    // MARK: - UC 原生扫码

    struct UCQrLoginToken {
        let token: String
        let clientId: String
        let pollClientId: String
        let qrPayload: String
    }

    enum UCQrPollResult {
        case pending
        case scanned
        case success(serviceTicket: String)
        case expired
        case failed(message: String)
    }

    func ucCreateQrToken(clientId: String = "532", pollClientId: String = "532") async throws -> UCQrLoginToken {
        var components = URLComponents(string: "https://api.open.uc.cn/cas/ajax/getTokenForQrcodeLogin")!
        components.queryItems = [
            URLQueryItem(name: "pr", value: "ucpro"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "sys", value: "darwin"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "v", value: "1.2"),
            URLQueryItem(name: "request_id", value: UUID().uuidString.lowercased())
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("https://drive.uc.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://drive.uc.cn/", forHTTPHeaderField: "Referer")
        request.setValue(ucUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, _) = try await ucSession.data(for: request)
        let json = try parseJSON(data)
        guard let token = extractString(json, keys: ["token", "qrcode_token"]) ?? extractNestedString(json, path: ["data", "members", "token"]) else {
            throw AuthError.invalidResponse("UC 未返回二维码 token")
        }
        return UCQrLoginToken(token: token, clientId: clientId, pollClientId: pollClientId, qrPayload: ucQRCodePayload(token: token, clientId: pollClientId))
    }

    func ucPollQrStatus(token: UCQrLoginToken) async throws -> UCQrPollResult {
        var components = URLComponents(string: "https://api.open.uc.cn/cas/ajax/getServiceTicketByQrcodeToken")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: token.pollClientId),
            URLQueryItem(name: "v", value: "1.2"),
            URLQueryItem(name: "request_id", value: UUID().uuidString.lowercased()),
            URLQueryItem(name: "token", value: token.token)
        ]
        var request = URLRequest(url: components.url!)
        // UC 与夸克共用 CAS，轮询需使用 pan.quark.cn 域名才能正确同步扫码状态
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        request.setValue(ucUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, _) = try await ucSession.data(for: request)
        let json = try parseJSON(data)
        let rawBody = String(data: data, encoding: .utf8) ?? "nil"
        print("[VBox UC Poll] raw: \(rawBody)")
        let ticket = extractNestedString(json, path: ["data", "members", "service_ticket"])
            ?? extractNestedString(json, path: ["data", "service_ticket"])
            ?? extractString(json, keys: ["service_ticket", "ticket"])
        if let ticket, !ticket.isEmpty {
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
        if status == -2 {
            return .failed(message: json["message"] as? String ?? "UC 轮询状态码 -2")
        }
        if [50004002, 50004003, 50004004, 50004005].contains(status) { return .expired }
        if status == 50004000 { return .scanned }
        if status == 50004001 { return .pending }
        if status != -1 { print("[VBox UC Poll] unknown status: \(status)") }
        return .pending
    }

    func ucExchangeServiceTicket(_ serviceTicket: String) async throws {
        // UC 与夸克共用 CAS，account/info 需使用 pan.quark.cn 域名才能正确换取 Cookie
        var components = URLComponents(string: "https://pan.quark.cn/account/info")!
        components.queryItems = [
            URLQueryItem(name: "st", value: serviceTicket),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "platform", value: "pc")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        request.setValue(ucUserAgent, forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        let oneShot = URLSession(configuration: config, delegate: UCTrustSessionDelegate(), delegateQueue: nil)
        defer { oneShot.finishTasksAndInvalidate() }

        let (data, response) = try await oneShot.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.remoteError("UC account/info HTTP 失败")
        }
        let cookie = collectCookies(from: http, storage: oneShot.configuration.httpCookieStorage, url: URL(string: "https://pan.quark.cn")!)
        guard !cookie.isEmpty else { throw AuthError.invalidResponse("UC 未返回 Cookie") }

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
            guard let url = URL(string: "https://yun.139.com/w/") else { return }
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await switchToQRCodeTab()
                startPolling()
            }
        }

        private func switchToQRCodeTab() async {
            let js = #"""
            (function() {
                var elems = document.querySelectorAll('div, span, button, a, li, p, label');
                for (var i = 0; i < elems.length; i++) {
                    var el = elems[i];
                    var txt = (el.textContent || '').trim();
                    var cls = ((el.className||'') + ' ' + (el.id||'')).toLowerCase();
                    if ((txt.indexOf('扫码') !== -1 || txt.indexOf('二维码') !== -1 ||
                         cls.indexOf('qr') !== -1 || cls.indexOf('scan') !== -1) &&
                        el.offsetWidth > 0 && el.offsetHeight > 0) {
                        el.click();
                        return 'clicked';
                    }
                }
                return 'notfound';
            })()
            """#
            do {
                let result = try await webView.evaluateJavaScript(js)
                if let r = result as? String, r == "clicked" {
                    statusText = "已切换到扫码登录，请扫描二维码"
                } else {
                    statusText = "请使用中国移动云盘APP扫码登录"
                }
            } catch {
                statusText = "请使用中国移动云盘APP扫码登录"
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
                for _ in 1...120 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }

                    let cookies = await self.getAllCookies()
                    let cookieStr = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

                    let hasSSOToken = cookies.contains { cookie in
                        let name = cookie.name.lowercased()
                        return (name == "ssotoken" || name == "sso_token") && cookie.value.count > 10
                    }

                    if hasSSOToken {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功"
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
                try await validateCookie(url: "https://www.123pan.com/b/api/share/get?limit=1&next=1&shareKey=test&SharePwd=&ParentFileId=0&Page=1", cookie: credential.cookie ?? "", referer: "https://www.123pan.com/")
            case .pan139:
                try await validateCookie(url: "https://yun.139.com/", cookie: credential.cookie ?? "", referer: "https://yun.139.com/")
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
    func saveWebViewCookie(type: CloudDriveManager.DriveType, cookie: String, userName: String? = nil) -> Bool {
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
            accessToken: nil,
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
            statusMessage: "WebView 已保存授权",
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
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/1.8.5 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/ucpan_other_ch"
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
        // UC 使用 1_n0ZCv 路径，重定向到 broccoli.uc.cn（UC自己的域名）
        // 4_eMHBJ 会重定向到 b.quark.cn（夸克下载页），不能用于 UC
        var components = URLComponents(string: "https://su.uc.cn/1_n0ZCv")!
        components.queryItems = [
            URLQueryItem(name: "uc_param_str", value: "dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt"),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "uc_biz_str", value: "S:custom|C:titlebar_fix")
        ]
        return components.url?.absoluteString ?? "https://su.uc.cn/1_n0ZCv?uc_param_str=dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt&token=\(token)&client_id=\(clientId)&uc_biz_str=S:custom|C:titlebar_fix"
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

    private func validateCookie(url: String, cookie: String, referer: String) async throws {
        guard !cookie.isEmpty else { throw AuthError.notAuthorized("Cookie 为空") }
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = url.contains("/file/sort") ? "POST" : "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
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
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: CloudDriveCredential].self, from: data) else {
            credentials = [:]
            return
        }
        credentials = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func syncLegacyTokensIfNeeded() {
        for token in CloudDriveManager.shared.savedTokens {
            guard let type = CloudDriveManager.DriveType(rawValue: token.type),
                  credentials[type.rawValue] == nil else { continue }
            saveManualCredential(type: type, name: token.name, value: token.value)
        }
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

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message): return message
        case .remoteError(let message): return message
        case .notAuthorized(let message): return message
        }
    }
}
