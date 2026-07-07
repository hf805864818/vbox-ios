//
//  BaiduProxyClient.swift
//  vbox
//
//  百度网盘 Cloudflare Worker 代理客户端
//  用于通过 HMAC 签名认证调用 Worker 端 API
//

import Foundation
import CryptoKit

/// Worker 代理响应数据
struct BaiduProxyPlayData: Codable {
    let url: String
    let type: String
    let file_name: String?
    let quality: String?
    let headers: [String: String]?
}

struct BaiduProxyResponse: Codable {
    let success: Bool
    let data: BaiduProxyPlayData?
    let error: String?
}

/// 百度网盘 Cloudflare Worker 代理客户端
class BaiduProxyClient {
    static let shared = BaiduProxyClient()

    // ========== 配置（必须与 Worker 端保持一致）==========
    private let baseURL = "https://vbox.ltd"
    private let token = "199114"
    private let secret = "vbox-baidu-secret-2026-change-me"

    // 发送带签名的 POST 请求
    private func sendRequest(
        path: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        // 1. 序列化 Body
        let bodyData = try JSONSerialization.data(withJSONObject: params)
        let bodyString = String(data: bodyData, encoding: .utf8) ?? ""
        
        // 打印请求参数用于调试
        print("[BaiduProxy] >> POST \(path)")
        print("[BaiduProxy] >> 请求参数：\(bodyString.prefix(200))")
        if let cookiePreview = params["cookie"] as? String {
            let preview = cookiePreview.prefix(50)
            print("[BaiduProxy] >> Cookie 预览：\(preview)...(长度:\(cookiePreview.count))")
        }

        // 2. 生成签名
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let message = path + timestamp + nonce + bodyString
        let signature = self.hmacSHA256(message: message, key: secret)
        
        print("[BaiduProxy] >> 签名：\(signature.prefix(16))...")

        // 3. 构造请求
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Nonce")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 30

        // 4. 发送请求
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // 打印原始响应用于调试
        if let respStr = String(data: data, encoding: .utf8) {
            print("[BaiduProxy] << 原始响应 (\(respStr.count) 字符)：\(respStr.prefix(500))")
        }
        
        guard let httpResp = response as? HTTPURLResponse else {
            print("[BaiduProxy]  无效的响应类型")
            throw NSError(domain: "BaiduProxy", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "无效的响应"
            ])
        }
        
        print("[BaiduProxy] << HTTP 状态码: \(httpResp.statusCode)")

        guard httpResp.statusCode == 200 else {
            let errText = String(data: data, encoding: .utf8) ?? "HTTP \(httpResp.statusCode)"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = json["error"] as? String {
                    print("[BaiduProxy]  HTTP 错误：\(error)")
                }
                return json
            }
            print("[BaiduProxy]  HTTP \(httpResp.statusCode)：\(errText)")
            throw NSError(domain: "BaiduProxy", code: httpResp.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(httpResp.statusCode): \(errText)"
            ])
        }

        // 5. 解析 JSON
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[BaiduProxy]  无效的 JSON 响应")
            throw NSError(domain: "BaiduProxy", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "无效的 JSON 响应"
            ])
        }
        
        if let respStr = String(data: try JSONSerialization.data(withJSONObject: json), encoding: .utf8) {
            print("[BaiduProxy] << JSON 响应：\(respStr.prefix(300))")
        }

        return json
    }

    // HMAC-SHA256 签名
    private func hmacSHA256(message: String, key: String) -> String {
        let keyData = SymmetricKey(data: key.data(using: .utf8)!)
        let mac = HMAC<SHA256>.authenticationCode(
            for: message.data(using: .utf8)!,
            using: keyData
        )
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 业务方法

    /// 解析分享链接
    /// - Parameters:
    ///   - url: 百度网盘分享链接
    ///   - pwd: 提取码（可选）
    /// - Returns: 解析结果 JSON
    func parseShareLink(url: String, pwd: String = "", cookie: String = "") async throws -> [String: Any] {
        return try await sendRequest(
            path: "/api/baidu/parse",
            params: ["url": url, "pwd": pwd, "cookie": cookie]
        )
    }

    /// 获取播放地址
    /// - Parameters:
    ///   - shareURL: 百度网盘分享链接
    ///   - pwd: 提取码（可选）
    ///   - fsId: 文件 ID（可选，不填则取第一个）
    /// - Returns: 包含播放地址的 JSON
    func getPlayURL(shareURL: String, pwd: String = "", fsId: String = "", cookie: String = "", pcsCookie: String = "") async throws -> [String: Any] {
        return try await sendRequest(
            path: "/api/baidu/play",
            params: ["url": shareURL, "pwd": pwd, "fs_id": fsId, "cookie": cookie, "pcs_cookie": pcsCookie]
        )
    }
}
