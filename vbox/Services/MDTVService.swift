//
//  MDTVService.swift
//  vbox
//
//  麻豆平台（MDTV）服务层 — 基于阅姝阁 App 逆向还原
//
//  加密协议：AES 系列（具体模式和密钥待确认）
//  请求格式: {"post-data": "base64加密数据"}
//  响应格式: {"suffix": "随机6位hex", "data": "base64加密数据"}
//
//  API 域名: api.nzp1ve.com
//  平台标识: JGDZMX (suffix 请求头)
//  图片 CDN: vvbacksixiuw.n123dx.xyz
//  视频 CDN: m3md.n6uem8.xyz (HLS m3u8)
//
//  Created by Reverse Engineering on 2026/07/10.
//

import Foundation
import CommonCrypto

// MARK: - 麻豆平台数据模型

/// 分类/频道模型
struct MDTVCategory: Identifiable {
    var id: String { cateId }
    let cateId: String
    let name: String
    let icon: String?
    let sortOrder: Int
}

/// 视频条目
struct MDTVVideoItem: Identifiable {
    var id: String { videoId }
    let videoId: String
    let title: String
    let cover: String          // 封面图 URL 路径（需拼接 CDN 域名）
    let duration: String       // 时长
    let views: Int             // 播放量
    let likes: Int             // 点赞数
    let categoryId: String
    let categoryName: String?
    let tags: [String]
    let rating: String?        // 评分
    let uploadTime: String?    // 上传时间
}

/// 视频详情
struct MDTVVideoDetail {
    let videoId: String
    let title: String
    let cover: String
    let duration: String
    let views: Int
    let likes: Int
    let description: String
    let tags: [String]
    let actorName: String?
    let categoryName: String?
    let uploadTime: String?
    let rating: String?
    /// 播放地址
    let playUrl: String?
    /// 播放列表（多线路）
    let playUrls: [MDTVPlaySource]
}

/// 播放源
struct MDTVPlaySource: Identifiable {
    var id: String { name }
    let name: String       // 线路名
    let url: String        // m3u8 或 mp4 地址
}

/// 标签
struct MDTVTag: Identifiable, Hashable {
    var id: String { tagId }
    let tagId: String
    let name: String
    let count: Int
}

/// 通用 API 响应包装
private struct MDTVAPIResponse<T> {
    let code: Int
    let message: String
    let data: T?
}

// MARK: - 加密模式枚举

enum MDTVEncryptMode: String, CaseIterable {
    case cbc = "AES-CBC"
    case cfb = "AES-CFB"
    case ctr = "AES-CTR"
    case ofb = "AES-OFB"
    case ecb = "AES-ECB"
}

// MARK: - 麻豆平台服务

class MDTVService: ObservableObject {
    static let shared = MDTVService()

    // MARK: - 配置

    /// API 基础域名（可通过 WelfareDomainStore 自定义）
    var baseURL: String {
        WelfareDomainStore.shared.domains(for: "麻豆平台").first ?? "https://api.nzp1ve.com"
    }

    /// 图片 CDN 域名
    var imageCDN: String {
        "https://vvbacksixiuw.n123dx.xyz"
    }

    /// 平台标识（suffix 请求头）
    let platformSuffix = "JGDZMX"

    // MARK: - AES 密钥候选（按优先级尝试）
    /// 从阅姝阁 App 二进制中提取的候选密钥
    private let aesKeyCandidates: [String] = {
        // 1. 已知的 hex 候选（32字符 = 16字节）
        var candidates: [String] = [
            "368480924a6c78e2e8681551a7cf4c21",  // 候选1: 二进制字符串
            "563e8eeef42931cc858dc0d1080f4f6f",  // 候选2: 二进制字符串
            "7a7352fa6ff2d4f238ec81eb0a62b81d",  // 候选3: 二进制字符串
            "d20a1be77c3d3c41b2a5accaee1ce549",  // 候选4: 二进制字符串
            "31a92ee2029fd10d901b113e990710f0",  // 候选5: 二进制字符串
            "db7c2abf62e35e668076bead208b0000",  // 候选6: _decryptData附近找到（14字节补零）
            "30663438613465373765346138346630",  // 候选7: FLEX CCCrypt 抓到的 key
        ]

        // 2. 常见 UTF-8 字符串密钥候选（加密库通常用字符串转 bytes）
        let utf8Keys = [
            "JGDZMX",                    // 平台标识
            "mdtv", "MdTv", "MDTV",      // 平台名
            "madou", "Madou", "MADOU",   // 麻豆
            "jiamidi", "jiaguidi",       // 可能的密钥名
            "jiami", "jiag",             // 缩写
            "encrypt", "decrypt",        // 通用加密词
            "aeskey", "aes_key",         // AES key
            "secret", "password",        // 通用密钥词
            "keykeykeykeykeyk",          // 16字节占位
            "secretsecretsecr",          // 16字节占位
            "0123456789abcdef",          // 常见测试密钥
            "abcdefghijklmnopqrst",      // 16字节字母
            "1234567890123456",          // 16字节数字
            "0f48a4e77e4a84f0",          // One平台密钥
            "6d89c6d11f1a00dcfa5451fc6712a5532",  // One平台候选
        ]

        for key in utf8Keys {
            candidates.append(key.data(using: .utf8)!.hexString)
            candidates.append(key.data(using: .utf8)!.hexString.ljust(32, "0"))
            // 不足16字节时重复填充
            if key.count < 16 {
                let repeated = String(repeating: key, count: (16 / key.count) + 1).prefix(16)
                candidates.append(String(repeated).data(using: .utf8)!.hexString)
            }
        }

        // 3. 关键词 MD5/SHA1 前16字节作为密钥
        let hashKeywords = [
            "JGDZMX", "mdtv", "MdTv", "MDTV",
            "madou", "Madou", "MADOU",
            "jiamidi", "jiaguidi",
            "encrypt", "decrypt", "aeskey",
            "mdtv_key", "mdtv_secret", "mdtv_aes",
            "JGDZMX_key", "JGDZMX_secret",
        ]
        for kw in hashKeywords {
            if let data = kw.data(using: .utf8) {
                candidates.append(data.md5Hex)
                candidates.append(data.sha1Hex.prefix(32).description)
            }
        }

        return Array(Set(candidates)).sorted()
    }()

    /// IV 候选
    private let aesIVCandidates: [String] = {
        var candidates = [
            "0a010b05040f070917030106080c0d5b",  // 固定 IV (One平台同款)
            "00000000000000000000000000000000",  // 零 IV
        ]

        // 把平台标识作为 IV 候选
        let ivStrings = ["JGDZMX", "mdtv", "MadTv", "MDTV"]
        for s in ivStrings {
            if let data = s.data(using: .utf8) {
                var hex = data.hexString
                hex += String(repeating: "0", count: max(0, 32 - hex.count))
                candidates.append(String(hex.prefix(32)))
            }
        }

        return candidates
    }()

    /// 加密模式候选（按优先级尝试）
    private let modeCandidates: [MDTVEncryptMode] = [
        .cfb,  // CFB 模式有部分匹配迹象
        .cbc,  // CBC 最常见
        .ctr,  // CTR 流密码
        .ofb,  // OFB 模式
        .ecb,  // ECB 模式
    ]

    // 当前使用的密钥/IV/模式索引（找到正确的后保存）
    private var currentKeyIndex: Int {
        get { UserDefaults.standard.integer(forKey: "mdtv_key_idx") }
        set { UserDefaults.standard.set(newValue, forKey: "mdtv_key_idx") }
    }

    private var currentIVIndex: Int {
        get { UserDefaults.standard.integer(forKey: "mdtv_iv_idx") }
        set { UserDefaults.standard.set(newValue, forKey: "mdtv_iv_idx") }
    }

    private var currentModeIndex: Int {
        get { UserDefaults.standard.integer(forKey: "mdtv_mode_idx") }
        set { UserDefaults.standard.set(newValue, forKey: "mdtv_mode_idx") }
    }

    /// 是否已找到正确的加密配置
    @Published var isKeyFound: Bool = false

    /// 首页 Tab 列表（本地默认 + 远程热更新）
    @Published var homeTabs: [String] = []

    /// 本地默认 Tab
    private let defaultTabs = ["推荐", "分类", "标签"]

    /// 当前 AES key
    private var aesKeyHex: String { aesKeyCandidates[min(currentKeyIndex, aesKeyCandidates.count - 1)] }

    /// 当前 AES IV
    private var aesIVHex: String { aesIVCandidates[min(currentIVIndex, aesIVCandidates.count - 1)] }

    /// 当前加密模式
    private var currentMode: MDTVEncryptMode { modeCandidates[min(currentModeIndex, modeCandidates.count - 1)] }

    init() {
        // 检查是否已保存有效的密钥配置
        let savedKeyIdx = UserDefaults.standard.integer(forKey: "mdtv_key_idx")
        let savedModeIdx = UserDefaults.standard.integer(forKey: "mdtv_mode_idx")
        isKeyFound = (savedKeyIdx > 0 || savedModeIdx > 0)
            && UserDefaults.standard.bool(forKey: "mdtv_key_verified")

        // 加载保存的 Tab 配置，如果没有则使用默认 Tab
        if let savedTabs = UserDefaults.standard.array(forKey: "mdtv_home_tabs") as? [String], !savedTabs.isEmpty {
            homeTabs = savedTabs
        } else {
            homeTabs = defaultTabs
        }
    }

    // MARK: - 首页 Tab 配置

    /// 获取首页 Tab 配置（本地默认 + 远程热更新）
    /// - Returns: Tab 名称数组
    func fetchTabConfig() async throws -> [String] {
        // 优先尝试从远程接口获取
        // 接口路径和参数格式待密钥确认后调整
        do {
            let response: MDTVAPIResponse<[String]> = try await request("/app/mdtv/home_tabs", parameters: [:])
            if let tabs = response.data, !tabs.isEmpty {
                await MainActor.run {
                    homeTabs = tabs
                    UserDefaults.standard.set(tabs, forKey: "mdtv_home_tabs")
                }
                return tabs
            }
        } catch {
            print("[MDTV] 远程 Tab 配置获取失败: \(error.localizedDescription)")
        }

        // 远程失败则使用默认 Tab
        await MainActor.run {
            if homeTabs.isEmpty {
                homeTabs = defaultTabs
            }
        }
        return homeTabs
    }

    /// 重置 Tab 配置（恢复默认）
    func resetTabs() {
        homeTabs = defaultTabs
        UserDefaults.standard.removeObject(forKey: "mdtv_home_tabs")
    }

    // MARK: - 核心请求方法

    /// 发送加密请求并自动解密响应
    /// - Parameters:
    ///   - path: 接口路径（如 /video/channel）
    ///   - parameters: 请求参数字典
    /// - Returns: 解密后的 JSON 数据
    func request<T: Decodable>(_ path: String, parameters: [String: Any] = [:]) async throws -> T {
        // 1. 加密请求参数
        let plaintext = try JSONSerialization.data(withJSONObject: parameters)
        guard let encryptedRequest = encryptRequest(plaintext) else {
            throw MDTVError.encryptionFailed
        }

        // 2. 构建请求体
        let requestBody: [String: Any] = [
            "post-data": encryptedRequest
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)

        // 3. 发送请求
        guard let url = URL(string: baseURL + path) else {
            throw MDTVError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Dart/3.4 (dart:io)", forHTTPHeaderField: "User-Agent")
        request.setValue(platformSuffix, forHTTPHeaderField: "suffix")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw MDTVError.networkError
        }

        // 4. 解析响应
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encryptedData = json["data"] as? String else {
            throw MDTVError.invalidResponse
        }

        // 5. 解密响应数据
        guard let decryptedData = try decryptResponse(encryptedData) else {
            // 解密失败，尝试暴力探测密钥
            if let foundData = try await bruteForceDecrypt(encryptedData) {
                return try JSONDecoder().decode(T.self, from: foundData)
            }
            throw MDTVError.decryptionFailed
        }

        // 6. 解析解密后的数据
        return try JSONDecoder().decode(T.self, from: decryptedData)
    }

    /// 发送请求并返回解密后的原始 Data（不需要 Decodable 类型约束）
    /// 用于触发密钥探测等场景
    func requestRaw(_ path: String, parameters: [String: Any] = [:]) async throws -> Data {
        // 1. 加密请求参数
        let plaintext = try JSONSerialization.data(withJSONObject: parameters)
        guard let encryptedRequest = encryptRequest(plaintext) else {
            throw MDTVError.encryptionFailed
        }

        // 2. 构建请求体
        let requestBody: [String: Any] = [
            "post-data": encryptedRequest
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)

        // 3. 发送请求
        guard let url = URL(string: baseURL + path) else {
            throw MDTVError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Dart/3.4 (dart:io)", forHTTPHeaderField: "User-Agent")
        request.setValue(platformSuffix, forHTTPHeaderField: "suffix")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw MDTVError.networkError
        }

        // 4. 解析响应
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encryptedData = json["data"] as? String else {
            throw MDTVError.invalidResponse
        }

        // 5. 解密响应数据
        if let decryptedData = try decryptResponse(encryptedData) {
            return decryptedData
        }

        // 解密失败，尝试暴力探测密钥
        if let foundData = try await bruteForceDecrypt(encryptedData) {
            return foundData
        }
        throw MDTVError.decryptionFailed
    }

    // MARK: - 加密请求

    /// 加密请求体
    private func encryptRequest(_ plaintext: Data) -> String? {
        // 使用当前配置加密
        guard let key = Data(hexString: aesKeyHex),
              let iv = Data(hexString: aesIVHex) else { return nil }

        switch currentMode {
        case .cbc:
            return aesCBC(data: plaintext, key: key, iv: iv, operation: CCOperation(kCCEncrypt))?.base64EncodedString()
        case .cfb:
            return aesCFB(data: plaintext, key: key, iv: iv, operation: CCOperation(kCCEncrypt))?.base64EncodedString()
        case .ctr:
            // CTR 模式需要额外处理
            return nil
        case .ofb:
            return nil
        case .ecb:
            return aesECB(data: plaintext, key: key, operation: CCOperation(kCCEncrypt))?.base64EncodedString()
        }
    }

    // MARK: - 解密响应

    /// 解密响应数据
    private func decryptResponse(_ base64String: String) throws -> Data? {
        guard let data = Data(base64Encoded: base64String) else { return nil }
        guard let key = Data(hexString: aesKeyHex),
              let iv = Data(hexString: aesIVHex) else { return nil }

        switch currentMode {
        case .cbc:
            guard let decrypted = aesCBC(data: data, key: key, iv: iv, operation: CCOperation(kCCDecrypt)) else {
                return nil
            }
            // 验证是不是有效的 JSON
            do {
                _ = try JSONSerialization.jsonObject(with: decrypted)
                return decrypted
            } catch {
                return nil
            }
        case .cfb:
            guard let decrypted = aesCFB(data: data, key: key, iv: iv, operation: CCOperation(kCCDecrypt)) else {
                return nil
            }
            do {
                _ = try JSONSerialization.jsonObject(with: decrypted)
                return decrypted
            } catch {
                return nil
            }
        default:
            return nil
        }
    }

    // MARK: - 暴力密钥探测

    /// 暴力探测正确的密钥和模式
    private func bruteForceDecrypt(_ base64String: String) async throws -> Data? {
        guard let data = Data(base64Encoded: base64String) else { return nil }

        print("[MDTV] 开始暴力探测密钥... 共 \(aesKeyCandidates.count) 个密钥 × \(modeCandidates.count) 个模式 × \(aesIVCandidates.count) 个IV")

        for (modeIdx, mode) in modeCandidates.enumerated() {
            for (keyIdx, keyHex) in aesKeyCandidates.enumerated() {
                for (ivIdx, ivHex) in aesIVCandidates.enumerated() {
                    guard let key = Data(hexString: keyHex),
                          let iv = Data(hexString: ivHex) else { continue }

                    var decrypted: Data?

                    switch mode {
                    case .cbc:
                        decrypted = aesCBC(data: data, key: key, iv: iv, operation: CCOperation(kCCDecrypt))
                    case .cfb:
                        decrypted = aesCFB(data: data, key: key, iv: iv, operation: CCOperation(kCCDecrypt))
                    case .ecb:
                        decrypted = aesECB(data: data, key: key, operation: CCOperation(kCCDecrypt))
                    default:
                        continue
                    }

                    if let decrypted = decrypted {
                        // 验证是不是有效的 JSON
                        do {
                            let jsonObj = try JSONSerialization.jsonObject(with: decrypted)
                            // 检查常见的响应结构
                            if let dict = jsonObj as? [String: Any],
                               dict["code"] != nil || dict["data"] != nil {
                                print("[MDTV] ✓ 找到正确的加密配置!")
                                print("  模式: \(mode.rawValue)")
                                print("  Key: \(keyHex)")
                                print("  IV: \(ivHex)")

                                // 保存配置
                                currentKeyIndex = keyIdx
                                currentIVIndex = ivIdx
                                currentModeIndex = modeIdx
                                UserDefaults.standard.set(true, forKey: "mdtv_key_verified")
                                isKeyFound = true

                                return decrypted
                            }
                        } catch {
                            continue
                        }
                    }
                }
            }
        }

        print("[MDTV] ✗ 暴力探测失败，所有组合均未成功")
        return nil
    }

    // MARK: - AES 加解密底层实现

    /// AES-CBC 模式
    private func aesCBC(data: Data, key: Data, iv: Data, operation: CCOperation) -> Data? {
        let keyLength = key.count
        let dataLength = data.count
        let bufferSize = dataLength + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytes: size_t = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    buffer.withUnsafeMutableBytes { bufferBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, keyLength,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, dataLength,
                            bufferBytes.baseAddress, bufferSize,
                            &numBytes
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return buffer.prefix(numBytes)
    }

    /// AES-CFB 模式
    private func aesCFB(data: Data, key: Data, iv: Data, operation: CCOperation) -> Data? {
        let keyLength = key.count
        let dataLength = data.count
        let bufferSize = dataLength + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytes: size_t = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    buffer.withUnsafeMutableBytes { bufferBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCModeCFB),
                            keyBytes.baseAddress, keyLength,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, dataLength,
                            bufferBytes.baseAddress, bufferSize,
                            &numBytes
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return buffer.prefix(numBytes)
    }

    /// AES-ECB 模式
    private func aesECB(data: Data, key: Data, operation: CCOperation) -> Data? {
        let keyLength = key.count
        let dataLength = data.count
        let bufferSize = dataLength + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytes: size_t = 0

        let status = key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                buffer.withUnsafeMutableBytes { bufferBytes in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, keyLength,
                        nil,  // ECB 不需要 IV
                        dataBytes.baseAddress, dataLength,
                        bufferBytes.baseAddress, bufferSize,
                        &numBytes
                    )
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return buffer.prefix(numBytes)
    }

    // MARK: - 业务接口方法

    /// 获取分类/频道列表
    func fetchCategories() async throws -> [MDTVCategory] {
        // 临时调用触发密钥探测，解析逻辑待密钥确认后完善
        _ = try? await requestRaw("/video/channel")
        return []
    }

    /// 获取视频列表
    /// - Parameters:
    ///   - categoryId: 分类ID（nil表示全部）
    ///   - page: 页码
    ///   - limit: 每页数量
    func fetchVideos(categoryId: String? = nil, page: Int = 1, limit: Int = 20) async throws -> [MDTVVideoItem] {
        var params: [String: Any] = ["page": page, "limit": limit]
        if let categoryId = categoryId {
            params["cid"] = categoryId
        }
        _ = try? await requestRaw("/video/listcache", parameters: params)
        return []
    }

    /// 获取标签列表
    func fetchTags() async throws -> [MDTVTag] {
        _ = try? await requestRaw("/video/tags")
        return []
    }

    /// 搜索视频
    func searchVideos(keyword: String, page: Int = 1) async throws -> [MDTVVideoItem] {
        let params: [String: Any] = ["keyword": keyword, "page": page]
        _ = try? await requestRaw("/app/mdtv/search", parameters: params)
        return []
    }

    /// 获取视频详情
    func fetchVideoDetail(_ videoId: String) async throws -> MDTVVideoDetail? {
        return nil
    }

    /// 获取播放地址
    func fetchPlayURL(_ videoId: String) async throws -> String? {
        return nil
    }

    // MARK: - 工具方法

    /// 拼接完整图片 URL
    func imageURL(_ path: String) -> String {
        if path.hasPrefix("http") {
            return path
        }
        return imageCDN + (path.hasPrefix("/") ? path : "/" + path)
    }

    /// 重置密钥配置（用于调试）
    func resetKeyConfig() {
        UserDefaults.standard.removeObject(forKey: "mdtv_key_idx")
        UserDefaults.standard.removeObject(forKey: "mdtv_iv_idx")
        UserDefaults.standard.removeObject(forKey: "mdtv_mode_idx")
        UserDefaults.standard.removeObject(forKey: "mdtv_key_verified")
        isKeyFound = false
    }
}

// MARK: - 错误类型

enum MDTVError: Error {
    case invalidURL
    case networkError
    case encryptionFailed
    case decryptionFailed
    case invalidResponse
    case keyNotFound
}

extension MDTVError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的URL"
        case .networkError:
            return "网络请求失败"
        case .encryptionFailed:
            return "请求加密失败"
        case .decryptionFailed:
            return "响应解密失败（密钥可能不正确）"
        case .invalidResponse:
            return "响应格式错误"
        case .keyNotFound:
            return "未找到正确的加密密钥"
        }
    }
}

// MARK: - Data Hex 扩展

extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(count: len)
        var startIndex = hexString.startIndex
        for i in 0..<len {
            let endIndex = hexString.index(startIndex, offsetBy: 2)
            let bytes = hexString[startIndex..<endIndex]
            if var num = UInt8(bytes, radix: 16) {
                data[i] = num
            } else {
                return nil
            }
            startIndex = endIndex
        }
        self = data
    }

    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }

    var md5Hex: String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        withUnsafeBytes { bytes in
            _ = CC_MD5(bytes.baseAddress, CC_LONG(count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var sha1Hex: String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        withUnsafeBytes { bytes in
            _ = CC_SHA1(bytes.baseAddress, CC_LONG(count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - String Hex 扩展

extension String {
    var dataHexString: String? {
        return data(using: .utf8)?.hexString
    }

    /// 左对齐填充字符串到指定长度（类似 Python 的 str.ljust）
    func ljust(_ length: Int, _ pad: String = " ") -> String {
        if self.count >= length { return self }
        let padding = String(repeating: pad, count: (length - self.count) / pad.count + 1)
        return self + padding.prefix(length - self.count)
    }
}

// MARK: - MDTVAPIResponse Codable 支持

extension MDTVAPIResponse: Decodable where T: Decodable {}
