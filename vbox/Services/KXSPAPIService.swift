import Foundation
import Security
import CommonCrypto

// MARK: - 空虚视频 / 三更 H5 API 服务
// 技术来源：用户从三更 App 内获取到的 H5 推广地址
// https://dh202607011058.yinmei.online/#/?s=10086&isH5=1&httpUrl=xn--oorr81b2yk37g.com

// MARK: - Errors
enum KXSPError: Error, LocalizedError {
    case invalidURL
    case cryptoFailure(String)
    case missingEncryptKey
    case invalidResponse
    case serverError(Int, String?)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效 URL"
        case .cryptoFailure(let msg): return "加密失败: \(msg)"
        case .missingEncryptKey: return "响应缺少 encrypt-key"
        case .invalidResponse: return "响应解析失败"
        case .serverError(let code, let msg): return "服务器错误 \(code): \(msg ?? "未知")"
        case .notConfigured: return "尚未完成初始化配置"
        }
    }
}

// MARK: - 配置常量
struct KXSPConfig {
    /// 默认 clientId（模块 1581 中的默认值，/user/account 使用）
    static let defaultClientId = "e5cd7e4891bf95d1d19206ce24a7b32e"
    /// 默认 tenantId
    static let defaultTenantId = "1597SYS53852"
    /// 接口路径前缀
    static let apiPrefix = "f7d118c31f8f4b9aa421e30d233ecd19"
    /// 包名，调用 /config 时使用
    static let packageName = "com.kuaishou"
    /// 默认渠道码（URL 中的 s 参数）
    static let defaultSource = "10086"
    /// 设备类型：1 = H5/iOS
    static let deviceType = 1

    /// H5 URL 里带来的 httpUrl，没有协议头。可运行时覆盖。
    static let defaultHttpUrl = "xn--oorr81b2yk37g.com"
    /// 视频内容 API 默认域名（aiApi），带 https:// 前缀
    static let defaultAiApi = "https://test1234.xn--6kr83q8rgfo4c.com"

    /// 备用域名列表（按优先级排序，第一个失败自动试下一个）
    /// 后期域名挂了直接在这里加新域名就行，不需要改其他代码
    static let fallbackDomains: [String] = [
        "xn--oorr81b2yk37g.com",
        // 可以在这里继续添加备用域名，例如：
        // "example1.com",
        // "example2.com",
    ]

    /// 服务端 RSA 公钥（用于加密请求 AES key）
    static let serverPublicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDQRJet4emadll2irsccbpWJjNJQQZ8RjWbCw6vQnERELabmbIbaZeD6Egn5J2ZByqe9UONV2M0w2kmez1MUknlMcjsqBpkgFa9zc41JHm17rIEoKiO1BIc1MuzuXEExYCw1UvCM2qxQq41VorvDUakuGfOsO03u1KATuR9XN3JiQIDAQAB
    -----END PUBLIC KEY-----
    """

    /// 客户端 RSA 私钥（用于解密响应 AES key）
    static let clientPrivateKeyPEM = """
    -----BEGIN PRIVATE KEY-----
    MIICeAIBADANBgkqhkiG9w0BAQEFAASCAmIwggJeAgEAAoGBALMkU3vRgTzZPs2ZYTdxJEGF8gH9HjdcJvdzzXYGGBVeOl6vNGU2f5ln7Tb/hj9dHBuTYT/t31o2C3xgg3GKl2qrC48aGKDLb8EI1LQcgs2ErGDID6i2Iup45IzRRRXB6pj6wd2p43YJpYAFYNtkWBxRIP/cLrCc4ozCBbQqmy1pAgMBAAECgYAkzkzcvrG358awhVflBTj2wWd0oyXHKAbVhpRrMFtYYJDLjWHNfcH/qcuiJiPV9vJkdAZiFSRzq3D2r/mxpVDwgIRNJ5Qx0avwwKHmwuQsz/lATwm0zXneepvnEE1VKu3hklG3zGss8xsr3jfplM8KngAknVLWX9wbpzmsZZ5dtQJBANyuowO7zT8vfg+un8GLA5G4RMf7skgSKhpW7wR2j8eYZJ8Y+ZELjhRghKTg0Xk9RENTrAGoQH5Om1ogRq94y/cCQQDPz8gPuH7yJGtroMvO+15ps/AJ2ZkYZwen/YJ+mg9CpI5bthVRMjnu/jziwdzr8tWGRKy+/J+2fuL8++0kibmfAkEAmGPgHgvpx+A75QhpOXWNmWrt1Ety6WHhwR6XHzXgQ6xwj4znicm460lbT6AQBvDP2s5E0UAmiRIvJSV0qmd4MQJBAMlGwssXMz1ssO6Jy10qcoOG2JNxwqqz/+Jh1CazKNyvbYK+lV8TerFUZbxrcILHrLBji71gCYFE3K2ThFjDXJkCQQCT6mBEaLQm75ag23PDZl3F7fZ4wTtkGDVGGHGrsYnrD0Bes+yz8mpvHdmgzF5SgfXI7Zvylga3qgBY8PUEPPbj
    -----END PRIVATE KEY-----
    """
}

// MARK: - 运行时配置项
struct KXSPRuntimeConfig {
    /// 运行时的 clientId（通常 /config 返回后覆盖默认值）
    var clientId: String = KXSPConfig.defaultClientId
    /// tenantId（一般不变）
    var tenantId: String = KXSPConfig.defaultTenantId
    /// 接口域名，会被随机子域替换
    var httpUrl: String = KXSPConfig.defaultHttpUrl
    /// 来源配置：video/shortVideo 的 fromId
    var iosFromId: [String: Any]?
    /// 图片域名
    var imageDomain: String?
    /// 文件域名
    var fileDomain: String?
    /// 视频播放域名列表
    var videoDomain: [String]?
    /// 长视频播放服务器配置
    var playServer: [String: Any]?
    /// 短视频播放服务器配置
    var shortPlayServer: [String: Any]?

    /// 从 playServer 中提取的播放线路列表（[{lineName, lineDomain}]）
    var playLines: [[String: String]] {
        guard let playServer = playServer,
              let lines = playServer["playLine"] as? [[String: String]] else {
            return []
        }
        return lines
    }

    /// 第一条播放线路的域名（用于视频播放地址补全）
    var firstPlayDomain: String? {
        playLines.first?["lineDomain"]
    }

    /// 从 shortPlayServer 中提取的短视频播放线路列表
    var shortPlayLines: [[String: String]] {
        guard let shortPlayServer = shortPlayServer,
              let lines = shortPlayServer["playLine"] as? [[String: String]] else {
            return []
        }
        return lines
    }

    /// 短视频第一条播放线路的域名
    var firstShortPlayDomain: String? {
        shortPlayLines.first?["lineDomain"]
    }
    /// AI 接口域名
    var aiApi: String?
    /// 官网
    var webSite: String?

    /// 从 /config 返回的 [{configKey, configValue}] 初始化
    init(items: [[String: Any]]) {
        var dict: [String: [String: Any]] = [:]
        for item in items {
            if let key = item["configKey"] as? String {
                dict[key] = item
            }
        }

        if let cid = dict["clientId"]?["configValue"] as? String, !cid.isEmpty {
            self.clientId = cid
        }
        if let tid = dict["tenantId"]?["configValue"] as? String, !tid.isEmpty {
            self.tenantId = tid
        }
        if let url = dict["httpUrl"]?["configValue"] as? String, !url.isEmpty {
            self.httpUrl = url
        }
        if let img = dict["imageDomain"]?["configValue"] as? String, !img.isEmpty {
            self.imageDomain = img.hasPrefix("http") ? img : "https://" + img
        }
        if let file = dict["fileDomain"]?["configValue"] as? String, !file.isEmpty {
            self.fileDomain = file.hasPrefix("http") ? file : "https://" + file
        }
        if let web = dict["webSite"]?["configValue"] as? String, !web.isEmpty {
            self.webSite = web
        }
        if let ai = dict["aiApi"]?["configValue"] as? String, !ai.isEmpty {
            self.aiApi = ai.hasPrefix("http") ? ai : "https://" + ai
        }

        if let fromIdStr = dict["iosFromId"]?["configValue"] as? String,
           let data = fromIdStr.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            self.iosFromId = obj
        }

        if let videoDomainStr = dict["videoDomain"]?["configValue"] as? String,
           let data = videoDomainStr.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            if let arr = obj as? [String] {
                self.videoDomain = arr
            } else if let str = obj as? String {
                self.videoDomain = [str]
            }
        }

        if let playServerStr = dict["playServer"]?["configValue"] as? String,
           let data = playServerStr.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            self.playServer = obj
        }

        if let shortStr = dict["shortPlayServer"]?["configValue"] as? String,
           let data = shortStr.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            self.shortPlayServer = obj
        }
    }
}

// MARK: - AES/RSA 加密助手
struct KXSPCrypto {

    // MARK: AES-ECB-PKCS7
    static func aesEncrypt(data: Data, key: String) -> String? {
        guard let keyData = key.data(using: .utf8) else { return nil }
        let cryptLength = data.count + kCCBlockSizeAES128
        var cryptData = Data(count: cryptLength)

        var numBytesEncrypted: size_t = 0
        let status = cryptData.withUnsafeMutableBytes { cryptBytes in
            data.withUnsafeBytes { dataBytes in
                keyData.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                            keyBytes.baseAddress, keyData.count,
                            nil,
                            dataBytes.baseAddress, data.count,
                            cryptBytes.baseAddress, cryptLength,
                            &numBytesEncrypted)
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        cryptData.count = numBytesEncrypted
        return cryptData.base64EncodedString()
    }

    static func aesDecrypt(base64: String, key: String) -> Data? {
        guard let data = Data(base64Encoded: base64),
              let keyData = key.data(using: .utf8) else { return nil }
        let cryptLength = data.count + kCCBlockSizeAES128
        var cryptData = Data(count: cryptLength)

        var numBytesDecrypted: size_t = 0
        let status = cryptData.withUnsafeMutableBytes { cryptBytes in
            data.withUnsafeBytes { dataBytes in
                keyData.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                            keyBytes.baseAddress, keyData.count,
                            nil,
                            dataBytes.baseAddress, data.count,
                            cryptBytes.baseAddress, cryptLength,
                            &numBytesDecrypted)
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        cryptData.count = numBytesDecrypted
        return cryptData
    }

    // MARK: RSA PKCS1-v1_5
    static func rsaEncrypt(string: String, publicKeyPEM: String) -> String? {
        guard let keyData = stripPEM(publicKeyPEM),
              let key = createSecKey(data: keyData, isPrivate: false),
              let plainData = string.data(using: .utf8) else { return nil }

        let blockSize = SecKeyGetBlockSize(key)
        var encrypted = Data(count: blockSize)
        var encryptedLen = blockSize

        let status = encrypted.withUnsafeMutableBytes { encryptedBytes in
            plainData.withUnsafeBytes { plainBytes in
                SecKeyEncrypt(key,
                              .PKCS1,
                              plainBytes.bindMemory(to: UInt8.self).baseAddress!,
                              plainData.count,
                              encryptedBytes.bindMemory(to: UInt8.self).baseAddress!,
                              &encryptedLen)
            }
        }
        guard status == errSecSuccess else { return nil }

        encrypted.count = encryptedLen
        return encrypted.base64EncodedString()
    }

    static func rsaDecrypt(base64: String, privateKeyPEM: String) -> String? {
        guard let keyData = stripPEM(privateKeyPEM),
              let key = createSecKey(data: keyData, isPrivate: true),
              let cipherData = Data(base64Encoded: base64) else { return nil }

        let blockSize = SecKeyGetBlockSize(key)
        var decrypted = Data(count: blockSize)
        var decryptedLen = blockSize

        let status = decrypted.withUnsafeMutableBytes { decryptedBytes in
            cipherData.withUnsafeBytes { cipherBytes in
                SecKeyDecrypt(key,
                              .PKCS1,
                              cipherBytes.bindMemory(to: UInt8.self).baseAddress!,
                              cipherData.count,
                              decryptedBytes.bindMemory(to: UInt8.self).baseAddress!,
                              &decryptedLen)
            }
        }
        guard status == errSecSuccess else { return nil }

        decrypted.count = decryptedLen
        return String(data: decrypted, encoding: .utf8)
    }

    // MARK: Helpers
    private static func stripPEM(_ pem: String) -> Data? {
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\\n", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Data(base64Encoded: stripped)
    }

    private static func createSecKey(data: Data, isPrivate: Bool) -> SecKey? {
        let tag = isPrivate ? "com.vbox.kxsp.private" : "com.vbox.kxsp.public"
        let tagData = tag.data(using: .utf8)!

        // 清理旧 key
        SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: tagData] as CFDictionary)

        let keyClass = isPrivate ? kSecAttrKeyClassPrivate : kSecAttrKeyClassPublic
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: keyClass,
            kSecAttrKeySizeInBits: 1024,
            kSecAttrApplicationTag: tagData,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &error) else {
            if let err = error?.takeRetainedValue() {
                print("[KXSP] 创建 SecKey 失败: \(err.localizedDescription)")
            }
            return nil
        }
        return key
    }
}

// MARK: - API 服务
@MainActor
final class KXSPAPIService: ObservableObject {
    static let shared = KXSPAPIService()

    @Published var isConfigured = false
    @Published var lastError: String?

    private var runtime: KXSPRuntimeConfig?
    private var userData: [String: Any] = [:]
    private var deviceNumber: String = ""

    // MARK: - 多域名切换
    /// 可用域名列表（初始化时验证通过的域名会排在前面）
    private var availableDomains: [String] = KXSPConfig.fallbackDomains
    /// 当前使用的域名索引
    private var currentDomainIndex: Int = 0
    /// 当前生效的主域名
    private var currentHttpUrl: String {
        guard currentDomainIndex < availableDomains.count else {
            return KXSPConfig.defaultHttpUrl
        }
        return availableDomains[currentDomainIndex]
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.httpCookieStorage = HTTPCookieStorage.shared
        return URLSession(configuration: c)
    }()

    private init() {}

    // MARK: - 初始化入口
    /// 调用 /user/account + /config，完成后续请求所需的运行时配置
    func setup(httpUrl: String? = nil) async {
        isConfigured = false
        lastError = nil

        if let url = httpUrl, !url.isEmpty {
            runtime = KXSPRuntimeConfig(items: [])
            runtime?.httpUrl = url
        }

        do {
            // 1. 生成设备号
            deviceNumber = generateDeviceNumber()

            // 2. 注册/获取账号
            let account = try await fetchAccount()
            if let data = account["data"] as? [String: Any] {
                userData = data
                if let dn = data["deviceNumber"] as? String, !dn.isEmpty {
                    deviceNumber = dn
                }
            }

            // 3. 获取平台配置
            let config = try await fetchConfig()
            if let data = config["data"] as? [[String: Any]] {
                runtime = KXSPRuntimeConfig(items: data)
                if let url = httpUrl, !url.isEmpty {
                    runtime?.httpUrl = url
                }
            }

            isConfigured = true
        } catch {
            lastError = error.localizedDescription
            print("[KXSP] setup 失败: \(error)")
        }
    }

    // MARK: - 公共请求

    /// 用户/配置类 API 请求（使用 httpUrl 域名，请求体/响应体均为 JSON 包装）
    private func request(path: String,
                         params: [String: Any],
                         useRuntimeConfig: Bool = true) async throws -> [String: Any] {
        let clientId = (useRuntimeConfig ? runtime?.clientId : nil) ?? KXSPConfig.defaultClientId
        let tenantId = runtime?.tenantId ?? KXSPConfig.defaultTenantId
        let httpUrl = runtime?.httpUrl ?? KXSPConfig.defaultHttpUrl

        let aesKey = randomString(length: 32)
        let plainJSON = try JSONSerialization.data(withJSONObject: params)
        guard let encryptedData = KXSPCrypto.aesEncrypt(data: plainJSON, key: aesKey) else {
            throw KXSPError.cryptoFailure("AES 加密失败")
        }
        guard let aesKeyB64 = aesKey.data(using: .utf8)?.base64EncodedString(),
              let encryptedKey = KXSPCrypto.rsaEncrypt(string: aesKeyB64,
                                                        publicKeyPEM: KXSPConfig.serverPublicKeyPEM) else {
            throw KXSPError.cryptoFailure("RSA 加密 AES key 失败")
        }

        let host = replaceApiDomain(httpUrl)
        guard let url = URL(string: "https://\(host)/\(KXSPConfig.apiPrefix)\(path)") else {
            throw KXSPError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue(clientId, forHTTPHeaderField: "clientId")
        req.setValue(tenantId, forHTTPHeaderField: "tenantId")
        req.setValue(encryptedKey, forHTTPHeaderField: "encrypt-key")
        req.setValue("true", forHTTPHeaderField: "isEncrypt")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["data": encryptedData])

        let (data, response) = try await session.data(for: req)
        guard let httpResp = response as? HTTPURLResponse else {
            throw KXSPError.invalidResponse
        }

        guard httpResp.statusCode == 200 else {
            throw KXSPError.serverError(httpResp.statusCode, String(data: data, encoding: .utf8))
        }

        guard let respEncryptKey = httpResp.value(forHTTPHeaderField: "encrypt-key"),
              let respKeyB64 = KXSPCrypto.rsaDecrypt(base64: respEncryptKey,
                                                      privateKeyPEM: KXSPConfig.clientPrivateKeyPEM),
              let respKeyData = Data(base64Encoded: respKeyB64),
              let respKeyString = String(data: respKeyData, encoding: .utf8) else {
            throw KXSPError.missingEncryptKey
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encryptedResp = json["data"] as? String,
              let decryptedData = KXSPCrypto.aesDecrypt(base64: encryptedResp, key: respKeyString),
              let decryptedJSON = try? JSONSerialization.jsonObject(with: decryptedData) as? [String: Any] else {
            throw KXSPError.invalidResponse
        }

        if let code = decryptedJSON["code"] as? Int, code != 200 {
            throw KXSPError.serverError(code, decryptedJSON["msg"] as? String)
        }

        return decryptedJSON
    }

    /// 视频内容类 API 请求（使用 aiApi 域名，请求体/响应体均为纯 base64 字符串）
    private func videoRequest(path: String,
                              params: [String: Any]) async throws -> [String: Any] {
        let clientId = runtime?.clientId ?? KXSPConfig.defaultClientId
        let tenantId = runtime?.tenantId ?? KXSPConfig.defaultTenantId
        // 视频 API 使用 aiApi 域名
        let baseURL = runtime?.aiApi ?? KXSPConfig.defaultAiApi

        let aesKey = randomString(length: 32)
        let plainJSON = try JSONSerialization.data(withJSONObject: params)
        guard let encryptedData = KXSPCrypto.aesEncrypt(data: plainJSON, key: aesKey) else {
            throw KXSPError.cryptoFailure("AES 加密失败")
        }
        guard let aesKeyB64 = aesKey.data(using: .utf8)?.base64EncodedString(),
              let encryptedKey = KXSPCrypto.rsaEncrypt(string: aesKeyB64,
                                                        publicKeyPEM: KXSPConfig.serverPublicKeyPEM) else {
            throw KXSPError.cryptoFailure("RSA 加密 AES key 失败")
        }

        guard let url = URL(string: baseURL + path) else {
            throw KXSPError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue(clientId, forHTTPHeaderField: "clientId")
        req.setValue(tenantId, forHTTPHeaderField: "tenantId")
        req.setValue(encryptedKey, forHTTPHeaderField: "encrypt-key")
        req.setValue("true", forHTTPHeaderField: "isEncrypt")
        // 视频 API 请求体是纯 base64 字符串
        req.httpBody = encryptedData.data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        guard let httpResp = response as? HTTPURLResponse else {
            throw KXSPError.invalidResponse
        }

        guard httpResp.statusCode == 200 else {
            throw KXSPError.serverError(httpResp.statusCode, String(data: data, encoding: .utf8))
        }

        guard let respEncryptKey = httpResp.value(forHTTPHeaderField: "encrypt-key"),
              let respKeyB64 = KXSPCrypto.rsaDecrypt(base64: respEncryptKey,
                                                      privateKeyPEM: KXSPConfig.clientPrivateKeyPEM),
              let respKeyData = Data(base64Encoded: respKeyB64),
              let respKeyString = String(data: respKeyData, encoding: .utf8) else {
            throw KXSPError.missingEncryptKey
        }

        // 视频 API 响应体是纯 base64 字符串，直接解密
        guard let encryptedResp = String(data: data, encoding: .utf8),
              let decryptedData = KXSPCrypto.aesDecrypt(base64: encryptedResp, key: respKeyString),
              let decryptedJSON = try? JSONSerialization.jsonObject(with: decryptedData) as? [String: Any] else {
            throw KXSPError.invalidResponse
        }

        if let code = decryptedJSON["code"] as? Int, code != 200 {
            throw KXSPError.serverError(code, decryptedJSON["msg"] as? String)
        }

        return decryptedJSON
    }

    // MARK: - 账号 / 配置
    private func fetchAccount() async throws -> [String: Any] {
        var params: [String: Any] = [
            "superiorInvitationCode": KXSPConfig.defaultSource,
            "deviceType": KXSPConfig.deviceType,
            "deviceNumber": deviceNumber,
            "deviceModel": "iPhone",
            "userId": userData["userId"] as? String ?? ""
        ]
        return try await request(path: "/user/account", params: params, useRuntimeConfig: false)
    }

    private func fetchConfig() async throws -> [String: Any] {
        let params: [String: Any] = ["packageName": KXSPConfig.packageName]
        return try await request(path: "/config", params: params, useRuntimeConfig: false)
    }

    // MARK: - 业务接口

    /// 视频导航分类列表（顶部大分类）
    func fetchVideoNavList() async throws -> [SangeBigCategory] {
        let params: [String: Any] = [
            "locationType": "nav_index_top",
            "navTagStatus": 0,
            "appId": 0,
            "deviceNumber": deviceNumber,
            "deviceType": KXSPConfig.deviceType
        ]
        let resp = try await videoRequest(path: "/video/api/nav/list", params: params)
        guard let data = resp["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { SangeBigCategory(dict: $0) }
    }

    /// 视频列表（按分类 navigationId 获取）
    func fetchVideoList(navigationId: String? = nil,
                        page: Int = 1,
                        pageSize: Int = 20) async throws -> [SangeVideoItem] {
        var params: [String: Any] = [
            "page": page,
            "pageSize": pageSize,
            "appId": 0,
            "deviceNumber": deviceNumber,
            "deviceType": KXSPConfig.deviceType
        ]
        if let navId = navigationId, !navId.isEmpty {
            params["navigationId"] = navId
        }
        if let fromId = runtime?.iosFromId?["listFromId"] {
            params["fromId"] = fromId
        }
        let resp = try await videoRequest(path: "/video/api/video/list", params: params)
        return parseVideoList(resp)
    }

    /// 视频详情（含播放地址）
    func fetchVideoDetail(id: String) async throws -> SangeVideoItem? {
        let params: [String: Any] = [
            "id": id,
            "appId": 0,
            "deviceNumber": deviceNumber,
            "deviceType": KXSPConfig.deviceType
        ]
        let resp = try await videoRequest(path: "/video/api/video/detail", params: params)
        // 详情接口 data 直接是视频对象
        var item: SangeVideoItem?
        if let data = resp["data"] as? [String: Any] {
            item = SangeVideoItem(dict: data)
        } else if let data = resp["data"] as? [[String: Any]], let first = data.first {
            item = SangeVideoItem(dict: first)
        }
        if var video = item {
            // 自动补全封面和播放地址域名
            video.cover = fullImageUrl(video.cover)
            if let playUrl = video.playUrl {
                video.playUrl = fullVideoUrl(playUrl)
            }
            if let defaultPlayUrl = video.defaultPlayUrl {
                video.defaultPlayUrl = fullVideoUrl(defaultPlayUrl)
            }
            return video
        }
        return nil
    }

    /// 首页推荐列表（多个推荐分类，每个分类下有视频列表）
    /// 接口路径: /video/api/recommend/list
    func fetchRecommendList(page: Int = 1,
                            pageSize: Int = 20) async throws -> [SangeRecommendCategory] {
        // 先获取导航分类，拿到第一个分类 ID 作为 navId
        let navList = try? await fetchVideoNavList()
        let firstNavId = navList?.first?.id

        var params: [String: Any] = [
            "count": pageSize,
            "appId": 0,
            "deviceNumber": deviceNumber,
            "deviceType": KXSPConfig.deviceType
        ]
        // 必须有 navId
        if let navId = firstNavId {
            params["navId"] = navId
        } else if let fromId = runtime?.iosFromId?["recommendFromId"] {
            params["fromId"] = fromId
        } else if let fromId = runtime?.iosFromId?["listFromId"] {
            params["fromId"] = fromId
        }
        let resp = try await videoRequest(path: "/video/api/recommend/list", params: params)
        return parseRecommendList(resp)
    }

    /// 搜索视频
    func searchVideo(keyword: String,
                     page: Int = 1,
                     pageSize: Int = 20) async throws -> [SangeVideoItem] {
        var params: [String: Any] = [
            "page": page,
            "pageSize": pageSize,
            "keyword": keyword,
            "appId": 0,
            "deviceNumber": deviceNumber,
            "deviceType": KXSPConfig.deviceType
        ]
        if let fromId = runtime?.iosFromId?["listFromId"] {
            params["fromId"] = fromId
        }
        let resp = try await videoRequest(path: "/video/api/search", params: params)
        return parseVideoList(resp)
    }

    // MARK: - URL 补全

    /// 图片路径补全：如果已经是 http 开头直接返回，否则拼接 imageDomain（优先）或 fileDomain
    func fullImageUrl(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return path
        }
        let domain = runtime?.imageDomain ?? runtime?.fileDomain ?? ""
        if domain.isEmpty { return path }
        let trimmed = path.hasPrefix("/") ? path : "/" + path
        return domain + trimmed
    }

    /// 视频播放地址补全：如果已经是 http 开头直接返回，否则拼接 playServer 第一条线路域名
    func fullVideoUrl(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return path
        }
        // 优先使用 playServer 第一条线路域名
        if let domain = runtime?.firstPlayDomain, !domain.isEmpty {
            let trimmed = path.hasPrefix("/") ? path : "/" + path
            return domain + trimmed
        }
        // 回退到 videoDomain 列表第一个
        if let domains = runtime?.videoDomain, !domains.isEmpty {
            let domain = domains[0].hasPrefix("http") ? domains[0] : "https://" + domains[0]
            let trimmed = path.hasPrefix("/") ? path : "/" + path
            return domain + trimmed
        }
        // 最后回退到 fileDomain
        if let file = runtime?.fileDomain {
            let trimmed = path.hasPrefix("/") ? path : "/" + path
            return file + trimmed
        }
        return path
    }

    /// 短视频播放地址补全
    func fullShortVideoUrl(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return path
        }
        let domain = runtime?.firstShortPlayDomain ?? runtime?.firstPlayDomain ?? ""
        if domain.isEmpty { return path }
        let trimmed = path.hasPrefix("/") ? path : "/" + path
        return domain + trimmed
    }
}

// MARK: - 解析辅助
private extension KXSPAPIService {
    func parseVideoList(_ resp: [String: Any]) -> [SangeVideoItem] {
        let list: [[String: Any]]

        // 1. data 直接是数组
        if let data = resp["data"] as? [[String: Any]] {
            list = data
        }
        // 2. data 是字典，里面有 list 字段
        else if let data = resp["data"] as? [String: Any],
                  let rows = data["list"] as? [[String: Any]] {
            list = rows
        }
        // 3. data 是字典，里面有 rows 字段
        else if let data = resp["data"] as? [String: Any],
                  let rows = data["rows"] as? [[String: Any]] {
            list = rows
        }
        // 4. data 是字典，里面有 videoList 字段（推荐接口的单个分类场景）
        else if let data = resp["data"] as? [String: Any],
                  let rows = data["videoList"] as? [[String: Any]] {
            list = rows
        }
        // 5. data 是字典，items 字段
        else if let data = resp["data"] as? [String: Any],
                  let rows = data["items"] as? [[String: Any]] {
            list = rows
        }
        // 6. 顶层直接有 list 字段
        else if let rows = resp["list"] as? [[String: Any]] {
            list = rows
        }
        // 7. 顶层直接有 rows 字段
        else if let rows = resp["rows"] as? [[String: Any]] {
            list = rows
        }
        else {
            list = []
        }

        return list.compactMap { dict in
            var item = SangeVideoItem(dict: dict)
            // 自动补全封面和播放地址域名
            item.cover = fullImageUrl(item.cover)
            if let playUrl = item.playUrl {
                item.playUrl = fullVideoUrl(playUrl)
            }
            if let defaultPlayUrl = item.defaultPlayUrl {
                item.defaultPlayUrl = fullVideoUrl(defaultPlayUrl)
            }
            return item
        }
    }

    /// 解析推荐列表接口返回（推荐分类数组，每个分类内含 videoList）
    func parseRecommendList(_ resp: [String: Any]) -> [SangeRecommendCategory] {
        let rawList: [[String: Any]]

        // 1. data 直接是数组
        if let data = resp["data"] as? [[String: Any]] {
            rawList = data
        }
        // 2. data 是字典，里面有 list 字段
        else if let data = resp["data"] as? [String: Any],
                  let list = data["list"] as? [[String: Any]] {
            rawList = list
        }
        // 3. data 是字典，里面有 rows 字段
        else if let data = resp["data"] as? [String: Any],
                  let list = data["rows"] as? [[String: Any]] {
            rawList = list
        }
        // 4. 顶层直接有 list
        else if let list = resp["list"] as? [[String: Any]] {
            rawList = list
        }
        else {
            rawList = []
        }

        // 处理两种结构：
        // - 直接是分类字典 {recId, recName, videoList: [...]}
        // - 嵌套结构 {recommendCategory: {...}, videoList: [...]}
        return rawList.compactMap { catDict in
            let finalDict: [String: Any]
            let videoList: [[String: Any]]

            if let recCat = catDict["recommendCategory"] as? [String: Any] {
                // 嵌套结构：把 recommendCategory 和 videoList 合并
                var merged = recCat
                let vl = catDict["videoList"] as? [[String: Any]] ?? []
                merged["videoList"] = vl
                finalDict = merged
                videoList = vl
            } else {
                // 直接结构
                finalDict = catDict
                if let vl = catDict["videoList"] as? [[String: Any]] {
                    videoList = vl
                } else if let vl = catDict["list"] as? [[String: Any]] {
                    videoList = vl
                } else {
                    videoList = []
                }
            }

            var cat = SangeRecommendCategory(dict: finalDict)
            // 如果 model 没解析到 videoList，手动赋值
            if cat.videoList.isEmpty && !videoList.isEmpty {
                cat.videoList = videoList.compactMap { SangeVideoItem(dict: $0) }
            }
            // 对每个分类下的视频补全域名
            cat.videoList = cat.videoList.map { video in
                var v = video
                v.cover = fullImageUrl(v.cover)
                if let playUrl = v.playUrl {
                    v.playUrl = fullVideoUrl(playUrl)
                }
                if let defaultPlayUrl = v.defaultPlayUrl {
                    v.defaultPlayUrl = fullVideoUrl(defaultPlayUrl)
                }
                return v
            }
            return cat
        }
    }
}

// MARK: - 工具函数
private extension KXSPAPIService {
    func generateDeviceNumber() -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let random = Int.random(in: 100000...999999)
        return "\(timestamp)\(random)"
    }

    func randomString(length: Int) -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    /// 仿 JS replaceApiDomain：把域名替换为随机 8 位子域
    func replaceApiDomain(_ httpUrl: String) -> String {
        var url = httpUrl
        if url.hasPrefix("http://") {
            url = String(url.dropFirst(7))
        } else if url.hasPrefix("https://") {
            url = String(url.dropFirst(8))
        }

        let parts = url.split(separator: ".", omittingEmptySubsequences: false)
        let sub = randomString(length: 8)

        if parts.count > 2 {
            // 有子域：替换第一个子域
            return "\(sub)." + parts.dropFirst().joined(separator: ".")
        } else {
            // 无子域：前面加随机子域
            return "\(sub)." + url
        }
    }
}
