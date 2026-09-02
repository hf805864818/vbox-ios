//
//  ExtscreenAPIClient.swift
//  vbox
//
//  PG extscreen API 客户端 — 完整扫码登录 + Token 刷新流程
//  对应 Python: alitoken2.py 的网络请求部分
//

import Foundation

// MARK: - API 响应模型

struct ExtscreenTimestampResponse: Codable {
    let code: Int
    let data: TimestampData

    struct TimestampData: Codable {
        let timestamp: Int      // API 返回整数，需转为 String 使用
    }
}

struct ExtscreenAPIResponse: Codable {
    let code: Int
    let data: EncryptedData?
    let t: Int?          // 服务端时间戳（整数，用于解密密钥重新生成）
    let msg: String?

    struct EncryptedData: Codable {
        let iv: String         // hex 格式
        let ciphertext: String  // base64 格式
    }
}

// 扫码授权状态
struct QrcodeStatusResponse: Codable {
    let status: String
    let authCode: String?
}

// Token 响应（解密后的 JSON）
struct ExtscreenTokenResult: Codable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
    let token_type: String?
}

// MARK: - extscreen API 客户端

/// extscreen API 客户端
/// 负责: 获取时间戳 → 生成二维码 → 轮询状态 → 换取 token → 刷新 token
actor ExtscreenAPIClient {

    static let shared = ExtscreenAPIClient()

    private let baseURL = "https://api.extscreen.com"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        // 允许 HTTP（extscreen 使用 HTTP）
        // Info.plist 中已配置 ATS 例外
        session = URLSession(configuration: config)
    }

    // MARK: - Step 0: 获取时间戳

    /// 从 extscreen 获取服务器时间戳
    /// 对应 Python: requests.get("http://api.extscreen.com/timestamp")
    func getTimestamp() async throws -> String {
        guard let url = URL(string: "\(baseURL)/timestamp") else {
            throw ExtscreenError.networkError("Invalid timestamp URL")
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ExtscreenError.timestampFailed
        }

        let result = try JSONDecoder().decode(ExtscreenTimestampResponse.self, from: data)

        guard result.code == 200 else {
            throw ExtscreenError.timestampFailed
        }

        print("[PG] extscreen 时间戳: \(result.data.timestamp)")
        return String(result.data.timestamp)
    }

    // MARK: - Step 1: 生成二维码

    /// 生成扫码登录二维码
    /// 对应 Python: get_qrcode_url()
    /// - Parameter crypto: 已初始化的加密器
    /// - Returns: (二维码链接, sid)
    func getQrcode(crypto: ExtscreenCrypto) async throws -> (qrLink: String, sid: String) {
        let apiPath = "/v2/qrcode"

        // 1. 构建加密请求体
        let plainBody: [String: Any] = [
            "scopes": "user:base,file:all:read,file:all:write",
            "width": 500,
            "height": 500,
        ]

        let encrypted = try crypto.encrypt(plainBody)
        let requestBody: [String: Any] = [
            "iv": encrypted.iv,
            "ciphertext": encrypted.ciphertext,
        ]

        // 2. 计算签名
        let sign = crypto.computeSign(method: "POST", apiPath: apiPath)
        let headers = crypto.getHeaders(sign: sign)

        // 3. 发送请求
        let url = URL(string: "\(baseURL)/aliyundrive\(apiPath)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ExtscreenError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            throw ExtscreenError.qrcodeFailed
        }

        // 4. 解析响应
        let apiResponse = try JSONDecoder().decode(ExtscreenAPIResponse.self, from: data)

        guard apiResponse.code == 200,
              let encryptedData = apiResponse.data else {
            throw ExtscreenError.apiError(
                code: apiResponse.code,
                message: apiResponse.msg ?? "Unknown"
            )
        }

        // 5. 解密响应
        let decryptedJSON = try crypto.decrypt(
            ciphertextBase64: encryptedData.ciphertext,
            ivHex: encryptedData.iv,
            t: apiResponse.t.map { String($0) }
        )

        guard let decryptedData = decryptedJSON.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: decryptedData) as? [String: Any],
              let sid = result["sid"] as? String else {
            throw ExtscreenError.qrcodeFailed
        }

        // 6. 构建二维码链接
        let qrLink = "https://www.aliyundrive.com/o/oauth/authorize?sid=\(sid)"

        print("[PG] extscreen 二维码生成成功, sid=\(sid)")
        return (qrLink, sid)
    }

    // MARK: - Step 2: 轮询扫码状态

    /// 轮询扫码授权状态
    /// 对应 Python: check_qrcode_status(sid)
    /// - Parameters:
    ///   - sid: 二维码会话 ID
    ///   - timeout: 超时秒数（默认 120 秒）
    ///   - onStatusChange: 状态变化回调
    /// - Returns: authCode
    func pollQrcodeStatus(
        sid: String,
        timeout: TimeInterval = 120,
        onStatusChange: @escaping (String) -> Void
    ) async throws -> String {

        let url = URL(string: "https://openapi.alipan.com/oauth/qrcode/\(sid)/status")!
        let startTime = Date()
        var pollCount = 0

        while Date().timeIntervalSince(startTime) < timeout {
            // 每 3 秒轮询一次
            try await Task.sleep(nanoseconds: 3_000_000_000)
            pollCount += 1

            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("[PG] 轮询请求失败, 重试中...")
                continue
            }

            let result = try JSONDecoder().decode(QrcodeStatusResponse.self, from: data)

            // 回调通知状态变化
            await MainActor.run {
                onStatusChange(result.status)
            }

            if result.status == "LoginSuccess" {
                guard let authCode = result.authCode else {
                    throw ExtscreenError.tokenExchangeFailed
                }
                print("[PG] 扫码成功, authCode=\(authCode)")
                return authCode
            }

            // 状态: "New", "Scaned", "Expired", "LoginSuccess"
            if result.status == "Expired" {
                throw ExtscreenError.pollingTimeout
            }

            print("[PG] 轮询 #\(pollCount) 状态: \(result.status)")
        }

        throw ExtscreenError.pollingTimeout
    }

    // MARK: - Step 3: authCode 换取 refresh_token

    /// 用 authCode 换取初始 refresh_token
    /// 对应 Python: get_refreshtoken(auth_token)
    /// - Parameters:
    ///   - authCode: 扫码授权后的 authCode
    ///   - crypto: 加密器
    /// - Returns: refresh_token (32位)
    func getRefreshToken(authCode: String, crypto: ExtscreenCrypto) async throws -> String {
        let apiPath = "/v4/token"

        // 1. 加密请求体
        let plainBody: [String: Any] = [
            "code": authCode,
        ]

        let encrypted = try crypto.encrypt(plainBody)
        let requestBody: [String: Any] = [
            "iv": encrypted.iv,
            "ciphertext": encrypted.ciphertext,
        ]

        // 2. 签名 + Headers
        let sign = crypto.computeSign(method: "POST", apiPath: apiPath)
        let headers = crypto.getHeaders(sign: sign)

        // 3. 发送请求
        let url = URL(string: "\(baseURL)/aliyundrive\(apiPath)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ExtscreenError.tokenExchangeFailed
        }

        // 4. 解析响应
        let apiResponse = try JSONDecoder().decode(ExtscreenAPIResponse.self, from: data)

        guard apiResponse.code == 200,
              let encryptedData = apiResponse.data else {
            throw ExtscreenError.apiError(
                code: apiResponse.code,
                message: apiResponse.msg ?? "Unknown"
            )
        }

        // 5. 解密
        let decryptedJSON = try crypto.decrypt(
            ciphertextBase64: encryptedData.ciphertext,
            ivHex: encryptedData.iv,
            t: apiResponse.t.map { String($0) }
        )

        // 6. 解析 token
        guard let decryptedData = decryptedJSON.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: decryptedData) as? [String: Any],
              let refreshToken = result["refresh_token"] as? String else {
            throw ExtscreenError.tokenExchangeFailed
        }

        print("[PG] refresh_token 获取成功 (32位)")
        return refreshToken
    }

    // MARK: - Step 4: 刷新 access_token

    /// 用 refresh_token 刷新获取新的 access_token
    /// 对应 Python: get_token(refresh_token)
    /// - Parameters:
    ///   - refreshToken: 32 位 refresh_token
    ///   - crypto: 加密器
    /// - Returns: (access_token, 新的 refresh_token, 过期时间)
    func refreshToken(
        refreshToken: String,
        crypto: ExtscreenCrypto
    ) async throws -> (accessToken: String, newRefreshToken: String?, expiresIn: Int?) {

        let apiPath = "/v4/token"

        // 1. 加密请求体
        let plainBody: [String: Any] = [
            "refresh_token": refreshToken,
        ]

        let encrypted = try crypto.encrypt(plainBody)
        let requestBody: [String: Any] = [
            "iv": encrypted.iv,
            "ciphertext": encrypted.ciphertext,
        ]

        // 2. 签名 + Headers
        let sign = crypto.computeSign(method: "POST", apiPath: apiPath)
        let headers = crypto.getHeaders(sign: sign)

        // 3. 发送请求
        let url = URL(string: "\(baseURL)/aliyundrive\(apiPath)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ExtscreenError.tokenRefreshFailed
        }

        // 4. 解析响应
        let apiResponse = try JSONDecoder().decode(ExtscreenAPIResponse.self, from: data)

        guard apiResponse.code == 200,
              let encryptedData = apiResponse.data else {
            throw ExtscreenError.apiError(
                code: apiResponse.code,
                message: apiResponse.msg ?? "Unknown"
            )
        }

        // 5. 解密
        let decryptedJSON = try crypto.decrypt(
            ciphertextBase64: encryptedData.ciphertext,
            ivHex: encryptedData.iv,
            t: apiResponse.t.map { String($0) }
        )

        // 6. 解析 token
        guard let decryptedData = decryptedJSON.data(using: .utf8) else {
            throw ExtscreenError.tokenRefreshFailed
        }

        let result = try JSONDecoder().decode(ExtscreenTokenResult.self, from: decryptedData)

        print("[PG] access_token 刷新成功, expires_in=\(result.expires_in ?? 7200)s")
        return (result.access_token, result.refresh_token, result.expires_in)
    }

    // MARK: - 便捷方法: 一键初始化 Crypto

    /// 获取时间戳并初始化加密器
    func makeCrypto() async throws -> ExtscreenCrypto {
        let timestamp = try await getTimestamp()
        return ExtscreenCrypto(timestamp: timestamp)
    }
}
