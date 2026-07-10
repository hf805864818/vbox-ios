//
//  OnePlatformService.swift
//  vbox
//
//  One 平台服务层 — 基于 ybox FLEX++ 抓包逆向还原
//
//  加密协议：AES-128-CBC + PKCS7Padding
//  AES Key : 0f48a4e77e4a84f0 (Hex: 30663438613465373765346138346630)
//  AES IV  : 0a010b05040f070917030106080c0d5b
//
//  API 域名: api.em1oifd0.com
//  图片 CDN: enimg807.5pkwjhp.com
//
//  Created by FLEX++ Reverse Engineering on 2026/07/10.
//

import Foundation
import CommonCrypto

// MARK: - One 平台数据模型

/// 分类模型（来自 /v2.5/article/category 或 discovery 返回的分类列表）
struct OneCategory: Identifiable {
    var id: String { cateId }
    let cateId: String
    let name: String
    let icon: String?
    let sortOrder: Int
}

/// 视频/文章条目（来自 /v2.5/article/discovery 或分类列表）
struct OneVideoItem: Identifiable {
    var id: String { articleId }
    let articleId: String
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
    let description: String?
    let actorName: String?     // 演员名
}

/// 视频详情（来自 /v2.5/article/detail）
struct OneVideoDetail {
    let articleId: String
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
    /// 播放地址（可能需要进一步解析）
    let playUrl: String?
    /// 播放列表（多线路）
    let playUrls: [OnePlaySource]
}

/// 播放源
struct OnePlaySource: Identifiable {
    var id: String { name }
    let name: String       // 线路名，如 "高清" "备用"
    let url: String        // m3u8 或 mp4 地址
}

/// 专辑/系列
struct OneAlbum: Identifiable {
    var id: String { albumId }
    let albumId: String
    let title: String
    let cover: String
    let description: String
    let itemCount: Int
    let rating: String?
}

/// 章节/漫画章节
struct OneChapter: Identifiable {
    var id: String { chapterId }
    let chapterId: String
    let title: String
    let sortOrder: Int
    let isPaid: Bool
    let hasRead: Bool
}

/// 通用 API 响应包装
private struct OneAPIResponse<T> {
    let code: Int
    let message: String
    let data: T?
}

// MARK: - One 平台服务

class OnePlatformService: ObservableObject {
    static let shared = OnePlatformService()

    // MARK: - 配置

    /// API 基础域名（可通过 WelfareDomainStore 自定义）
    var baseURL: String {
        WelfareDomainStore.shared.domains(for: "One平台").first ?? "https://api.em1oifd0.com"
    }

    /// 图片 CDN 域名
    var imageCDN: String {
        "https://enimg807.5pkwjhp.com"
    }

    // MARK: - 认证信息
    // token 和 user-key 通过设备注册接口自动获取（游客模式）
    // UUID 自动生成并持久化

    @Published var token: String = ""          // JWT Token (自动注册获取)
    @Published var userKey: String = ""        // user-key (自动注册获取)
    @Published var uuid: String = ""           // 设备 UUID (自动生成)
    @Published var platform: String = "2"      // 平台：1=Android, 2=iOS
    @Published var appVersion: String = "5.2.0"
    @Published var isRegistered: Bool = false  // 是否已完成设备注册

    // MARK: - AES 密钥（已确认 ✓）
    // 通过 FLEX++ CCCrypt Hook 提取，已双向验证通过
    private let aesKeyHex = "30663438613465373765346138346630"  // "0f48a4e77e4a84f0" 的 hex
    private let aesIVHex  = "0a010b05040f070917030106080c0d5b"  // 固定 IV

    // 注册时使用的初始 userKey（用于生成注册请求的 sign）
    private let initialUserKey = "0f48a4e77e4a84f0"

    init() {
        // 读取已保存的 token
        if let savedToken = UserDefaults.standard.string(forKey: "one_platform_token"),
           !savedToken.isEmpty {
            self.token = savedToken
            self.isRegistered = true
        }
        if let savedUserKey = UserDefaults.standard.string(forKey: "one_platform_userkey"),
           !savedUserKey.isEmpty {
            self.userKey = savedUserKey
        }
        // UUID 自动生成并持久化
        if let savedUUID = UserDefaults.standard.string(forKey: "one_platform_uuid"),
           !savedUUID.isEmpty {
            self.uuid = savedUUID
        } else {
            let newUUID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            self.uuid = newUUID
            UserDefaults.standard.set(newUUID, forKey: "one_platform_uuid")
        }
    }

    // MARK: - AES-128-CBC 加解密引擎

    /// AES-128-CBC 加密
    /// - Parameter plaintext: 明文字符串
    /// - Returns: Base64 编码的密文
    func encrypt(_ plaintext: String) -> String? {
        guard let data = plaintext.data(using: .utf8) else { return nil }
        guard let key = Data(hexString: aesKeyHex),
              let iv = Data(hexString: aesIVHex) else { return nil }

        let encrypted = aesCBC(data: data, key: key, iv: iv, operation: CCOperation(kCCEncrypt))
        return encrypted?.base64EncodedString()
    }

    /// AES-128-CBC 解密
    /// - Parameter base64String: Base64 编码的密文
    /// - Returns: 明文字符串
    func decrypt(base64 base64String: String) -> String? {
        guard let data = Data(base64Encoded: base64String) else { return nil }
        guard let key = Data(hexString: aesKeyHex),
              let iv = Data(hexString: aesIVHex) else { return nil }

        guard let decrypted = aesCBC(data: data, key: key, iv: iv, operation: CCOperation(kCCDecrypt)) else {
            return nil
        }
        return String(data: decrypted, encoding: .utf8)
    }

    /// CommonCrypto AES-CBC 核心实现
    private func aesCBC(data: Data, key: Data, iv: Data, operation: CCOperation) -> Data? {
        let keyLength = key.count
        let dataLength = data.count
        let bufferSize = dataLength + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytesEncrypted: size_t = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    buffer.withUnsafeMutableBytes { bufferBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),  // CBC 是默认，无需额外 flag
                            keyBytes.baseAddress, keyLength,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, dataLength,
                            bufferBytes.baseAddress, bufferSize,
                            &numBytesEncrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            print("[OnePlatform] AES operation failed: status=\(status)")
            return nil
        }

        return buffer.prefix(numBytesEncrypted)
    }

    // MARK: - Sign 签名算法
    // ⚠️ sign 算法待确认，以下为常见组合的占位实现
    // 确认后请替换为正确算法
    //
    // 可能的算法（32位 hex = MD5）：
    //   MD5(timestamp + body + userKey)
    //   MD5(path + timestamp + body + secret)
    //   HMAC-MD5(key=userKey, data=timestamp+body)

    /// 生成 sign 签名
    /// - Parameters:
    ///   - path: 请求路径，如 /v2.5/article/discovery
    ///   - body: 请求体 JSON 字符串
    ///   - timestamp: 时间戳（秒）
    ///   - customUserKey: 自定义 userKey（用于注册等未登录场景）
    /// - Returns: 32 位 MD5 sign
    private func generateSign(path: String, body: String, timestamp: String, customUserKey: String? = nil) -> String {
        // TODO: 确认 sign 算法后替换
        // 当前使用最可能的组合：MD5(timestamp + body + userKey)
        let key = customUserKey ?? userKey
        let raw = "\(timestamp)\(body)\(key)"
        return md5(raw)
    }

    /// MD5 哈希
    private func md5(_ string: String) -> String {
        let data = Data(string.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_MD5(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 网络请求

    /// 发送加密请求并返回解密后的 JSON
    /// - Parameters:
    ///   - path: API 路径，如 /v2.5/article/discovery
    ///   - parameters: 请求参数（字典）
    ///   - customToken: 自定义 token（用于注册等特殊场景）
    ///   - customUserKey: 自定义 userKey（用于注册等特殊场景）
    /// - Returns: 解密后的 JSON 字典
    func request(path: String, parameters: [String: Any] = [:],
                 customToken: String? = nil, customUserKey: String? = nil) async throws -> [String: Any] {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let reqToken = customToken ?? token
        let reqUserKey = customUserKey ?? userKey

        // 1. 构造请求体 JSON
        let jsonData = try JSONSerialization.data(withJSONObject: parameters)
        guard let bodyString = String(data: jsonData, encoding: .utf8) else {
            throw OneError.invalidParameters
        }

        // 2. AES 加密请求体
        guard let encryptedBody = encrypt(bodyString) else {
            throw OneError.encryptionFailed
        }

        // 3. 生成 sign
        let sign = generateSign(path: path, body: bodyString, timestamp: timestamp, customUserKey: reqUserKey)

        // 4. 构造请求
        guard let url = URL(string: baseURL + path) else {
            throw OneError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(reqToken, forHTTPHeaderField: "token")
        request.setValue(reqUserKey, forHTTPHeaderField: "user-key")
        request.setValue(uuid, forHTTPHeaderField: "uuid")
        request.setValue(timestamp, forHTTPHeaderField: "timestamp")
        request.setValue(sign, forHTTPHeaderField: "sign")
        request.setValue(platform, forHTTPHeaderField: "platform")
        request.setValue(appVersion, forHTTPHeaderField: "app-version")
        request.setValue("iOS", forHTTPHeaderField: "User-Agent")

        // 5. 发送加密请求体
        request.httpBody = encryptedBody.data(using: .utf8)

        // 6. 发送请求
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OneError.networkError("无效响应")
        }

        guard httpResponse.statusCode == 200 else {
            throw OneError.networkError("HTTP \(httpResponse.statusCode)")
        }

        // 7. 解密响应
        // 响应格式可能是: gzip(Base64(AES-CBC(JSON)))
        // 先尝试直接 base64 解密
        guard let responseString = String(data: data, encoding: .utf8) else {
            throw OneError.decryptionFailed("无法读取响应")
        }

        // 尝试解密
        if let decrypted = decryptResponse(responseString) {
            // 解析 JSON
            if let jsonData = decrypted.data(using: .utf8),
               let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                // 检查业务状态码
                let code = json["code"] as? Int ?? json["retcode"] as? Int ?? -1
                let msg = json["message"] as? String ?? json["msg"] as? String ?? "未知错误"
                if code != 0 && code != 200 {
                    throw OneError.businessError(code: code, message: msg)
                }
                return json
            }
        }

        // 如果解密失败，尝试直接解析（可能是未加密的错误响应）
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        throw OneError.decryptionFailed("响应解密失败")
    }

    /// 解密响应数据（处理 gzip + base64 + AES）
    private func decryptResponse(_ responseString: String) -> String? {
        let trimmed = responseString.trimmingCharacters(in: .whitespacesAndNewlines)

        // 方式 1: 直接 Base64 → AES 解密
        if let decrypted = decrypt(base64: trimmed) {
            return decrypted
        }

        // 方式 2: 尝试先 gzip 解压再解密（如果响应是 gzip 压缩的）
        // 由于 URLSession 默认会自动解压 gzip，这里可能不需要
        // 但如果响应体是先加密再 gzip 的，需要特殊处理

        return nil
    }

    // MARK: - API 方法

    // MARK: 设备注册（游客登录）

    /// 设备注册 - 自动获取 token 和 user-key
    /// 调用时机：首次启动或 token 失效时
    /// - Returns: 是否注册成功
    @discardableResult
    func registerDevice() async -> Bool {
        do {
            // 设备注册接口（推测路径，可能需要调整）
            // 常见路径: /v2.5/user/device, /v2.5/app/init, /v2.5/user/register
            let paths = [
                "/v2.5/user/device",
                "/v2.5/app/init",
                "/v2.5/user/register",
                "/v2.5/index/init",
            ]

            let params: [String: Any] = [
                "device_id": uuid,
                "platform": platform,
                "app_version": appVersion,
            ]

            for path in paths {
                do {
                    let json = try await request(
                        path: path,
                        parameters: params,
                        customToken: "",
                        customUserKey: initialUserKey
                    )

                    // 尝试从响应中提取 token 和 user-key
                    if let data = json["data"] as? [String: Any] {
                        let token = (data["token"] as? String) ?? (data["access_token"] as? String) ?? ""
                        let userKey = (data["user_key"] as? String) ?? (data["userkey"] as? String) ?? ""

                        if !token.isEmpty {
                            await MainActor.run {
                                self.token = token
                                if !userKey.isEmpty {
                                    self.userKey = userKey
                                }
                                self.isRegistered = true
                                // 保存到本地
                                UserDefaults.standard.set(token, forKey: "one_platform_token")
                                if !userKey.isEmpty {
                                    UserDefaults.standard.set(userKey, forKey: "one_platform_userkey")
                                }
                            }
                            print("[OnePlatform] 设备注册成功, path=\(path)")
                            return true
                        }
                    }
                } catch {
                    // 这个路径不行，试下一个
                    print("[OnePlatform] 注册路径 \(path) 失败: \(error)")
                    continue
                }
            }

            print("[OnePlatform] 所有注册路径都失败")
            return false
        }
    }

    /// 确保已注册（如果没有 token 则自动注册）
    func ensureRegistered() async -> Bool {
        if isRegistered && !token.isEmpty {
            return true
        }
        return await registerDevice()
    }

    /// 获取分类列表
    func fetchCategories() async -> [OneCategory] {
        // 注意：实际接口路径需确认，以下为根据文档 A 的推测
        // 也可能从 discovery 接口返回的数据中提取分类
        do {
            let json = try await request(path: "/v2.5/article/category")
            if let data = json["data"] as? [[String: Any]] {
                return data.enumerated().compactMap { idx, item in
                    guard let cateId = item["cateid"] as? String ?? (item["id"] as? Int).map({ String($0) }),
                          let name = item["name"] as? String ?? item["catename"] as? String else { return nil }
                    return OneCategory(
                        cateId: cateId,
                        name: name,
                        icon: item["icon"] as? String,
                        sortOrder: idx
                    )
                }
            }
        } catch {
            print("[OnePlatform] fetchCategories error: \(error)")
        }
        return defaultCategories
    }

    /// 默认分类（兜底）
    var defaultCategories: [OneCategory] {
        [
            OneCategory(cateId: "0", name: "推荐", icon: nil, sortOrder: 0),
            OneCategory(cateId: "1", name: "国产", icon: nil, sortOrder: 1),
            OneCategory(cateId: "2", name: "日韩", icon: nil, sortOrder: 2),
            OneCategory(cateId: "3", name: "欧美", icon: nil, sortOrder: 3),
            OneCategory(cateId: "4", name: "动漫", icon: nil, sortOrder: 4),
            OneCategory(cateId: "5", name: "自拍", icon: nil, sortOrder: 5),
            OneCategory(cateId: "6", name: "综艺", icon: nil, sortOrder: 6),
        ]
    }

    /// 获取发现页/分类视频列表
    /// - Parameters:
    ///   - categoryId: 分类 ID，"0" 为推荐
    ///   - page: 页码，从 1 开始
    func fetchVideos(categoryId: String, page: Int = 1) async -> (items: [OneVideoItem], hasMore: Bool) {
        let params: [String: Any] = [
            "page": page,
            "cateid": categoryId,
            "pagesize": 20
        ]

        do {
            // 根据文档 A，发现页接口为 /v2.5/article/discovery
            let path = categoryId == "0" ? "/v2.5/article/discovery" : "/v2.5/article/list"
            let json = try await request(path: path, parameters: params)

            if let data = json["data"] as? [String: Any],
               let rows = data["rows"] as? [[String: Any]] ?? data["list"] as? [[String: Any]] {
                let items = rows.compactMap { parseVideoItem($0) }
                let total = data["total"] as? Int ?? 0
                let pageCount = data["totalpage"] as? Int ?? data["pagecount"] as? Int ?? 0
                let hasMore = page < pageCount || (total > 0 && items.count >= 20)
                return (items, hasMore)
            }
        } catch {
            print("[OnePlatform] fetchVideos(\(categoryId), page:\(page)) error: \(error)")
        }

        return ([], false)
    }

    /// 每日推荐
    func fetchDailyRecommend() async -> [OneVideoItem] {
        do {
            let json = try await request(path: "/v2.5/article/day")
            if let data = json["data"] as? [[String: Any]] {
                return data.compactMap { parseVideoItem($0) }
            }
        } catch {
            print("[OnePlatform] fetchDailyRecommend error: \(error)")
        }
        return []
    }

    /// 获取视频详情
    func fetchVideoDetail(articleId: String) async -> OneVideoDetail? {
        do {
            let json = try await request(path: "/v2.5/article/detail", parameters: ["id": articleId])
            if let data = json["data"] as? [String: Any] {
                return parseVideoDetail(data)
            }
        } catch {
            print("[OnePlatform] fetchVideoDetail(\(articleId)) error: \(error)")
        }
        return nil
    }

    /// 获取播放地址
    func fetchPlayURL(articleId: String) async -> String? {
        do {
            let json = try await request(path: "/v2.5/article/play", parameters: ["id": articleId])
            if let data = json["data"] as? [String: Any] {
                if let url = data["url"] as? String ?? data["playurl"] as? String {
                    return url
                }
            }
        } catch {
            print("[OnePlatform] fetchPlayURL(\(articleId)) error: \(error)")
        }
        return nil
    }

    /// 获取专辑列表
    func fetchAlbums(page: Int = 1) async -> [OneAlbum] {
        do {
            let json = try await request(path: "/v2.5/series/album/list", parameters: ["page": page, "pagesize": 20])
            if let data = json["data"] as? [String: Any],
               let rows = data["rows"] as? [[String: Any]] {
                return rows.compactMap { parseAlbum($0) }
            }
        } catch {
            print("[OnePlatform] fetchAlbums error: \(error)")
        }
        return []
    }

    /// 获取专辑章节
    func fetchChapters(albumId: String, page: Int = 1) async -> [OneChapter] {
        do {
            let json = try await request(path: "/v2.5/series/chapters", parameters: ["id": albumId, "page": page])
            if let data = json["data"] as? [[String: Any]] {
                return data.enumerated().compactMap { idx, item in
                    guard let chapId = item["id"] as? String ?? (item["chapterid"] as? Int).map({ String($0) }) else { return nil }
                    return OneChapter(
                        chapterId: chapId,
                        title: item["title"] as? String ?? "第\(idx + 1)章",
                        sortOrder: idx,
                        isPaid: item["ispaid"] as? Bool ?? false,
                        hasRead: item["hasread"] as? Bool ?? false
                    )
                }
            }
        } catch {
            print("[OnePlatform] fetchChapters(\(albumId)) error: \(error)")
        }
        return []
    }

    /// 搜索
    func search(keyword: String, page: Int = 1) async -> [OneVideoItem] {
        do {
            let json = try await request(path: "/v2.5/article/search", parameters: [
                "keyword": keyword,
                "page": page
            ])
            if let data = json["data"] as? [String: Any],
               let rows = data["rows"] as? [[String: Any]] {
                return rows.compactMap { parseVideoItem($0) }
            }
        } catch {
            print("[OnePlatform] search(\(keyword)) error: \(error)")
        }
        return []
    }

    // MARK: - 解析器

    private func parseVideoItem(_ dict: [String: Any]) -> OneVideoItem? {
        let articleId = dict["id"] as? String ?? (dict["articleid"] as? Int).map({ String($0) }) ?? ""
        guard !articleId.isEmpty else { return nil }

        let title = dict["title"] as? String ?? dict["name"] as? String ?? "未知标题"
        let cover = dict["cover"] as? String ?? dict["coverpic"] as? String ?? dict["pic"] as? String ?? ""
        let fullCover = cover.hasPrefix("http") ? cover : (imageCDN + cover)

        let duration = dict["duration"] as? String ?? dict["timelength"] as? String ?? ""
        let views = dict["views"] as? Int ?? dict["playnum"] as? Int ?? dict["hits"] as? Int ?? 0
        let likes = dict["likes"] as? Int ?? dict["upnum"] as? Int ?? 0
        let categoryId = dict["cateid"] as? String ?? (dict["categoryid"] as? Int).map({ String($0) }) ?? "0"
        let categoryName = dict["catename"] as? String ?? dict["category"] as? String

        let tags: [String] = {
            if let t = dict["tags"] as? [String] { return t }
            if let t = dict["tag"] as? String { return [t] }
            return []
        }()

        return OneVideoItem(
            articleId: articleId,
            title: title,
            cover: fullCover,
            duration: duration,
            views: views,
            likes: likes,
            categoryId: categoryId,
            categoryName: categoryName,
            tags: tags,
            rating: dict["score"] as? String ?? (dict["rating"] as? Double).map({ String($0) }),
            uploadTime: dict["addtime"] as? String ?? dict["uptime"] as? String,
            description: dict["description"] as? String ?? dict["intro"] as? String,
            actorName: dict["actor"] as? String ?? dict["actorname"] as? String
        )
    }

    private func parseVideoDetail(_ dict: [String: Any]) -> OneVideoDetail {
        let articleId = dict["id"] as? String ?? ""
        let title = dict["title"] as? String ?? ""
        let cover = dict["cover"] as? String ?? ""
        let fullCover = cover.hasPrefix("http") ? cover : (imageCDN + cover)
        let duration = dict["duration"] as? String ?? ""
        let views = dict["views"] as? Int ?? 0
        let likes = dict["likes"] as? Int ?? 0
        let description = dict["description"] as? String ?? dict["intro"] as? String ?? ""

        let tags: [String] = {
            if let t = dict["tags"] as? [String] { return t }
            if let t = dict["tag"] as? String { return [t] }
            return []
        }()

        // 播放地址
        var playUrls: [OnePlaySource] = []
        if let playList = dict["playurls"] as? [[String: Any]] {
            for item in playList {
                if let name = item["name"] as? String, let url = item["url"] as? String {
                    playUrls.append(OnePlaySource(name: name, url: url))
                }
            }
        }
        if let singleUrl = dict["playurl"] as? String ?? dict["url"] as? String {
            playUrls.append(OnePlaySource(name: "默认", url: singleUrl))
        }

        return OneVideoDetail(
            articleId: articleId,
            title: title,
            cover: fullCover,
            duration: duration,
            views: views,
            likes: likes,
            description: description,
            tags: tags,
            actorName: dict["actor"] as? String,
            categoryName: dict["catename"] as? String,
            uploadTime: dict["addtime"] as? String,
            rating: dict["score"] as? String,
            playUrl: playUrls.first?.url,
            playUrls: playUrls
        )
    }

    private func parseAlbum(_ dict: [String: Any]) -> OneAlbum? {
        let albumId = dict["id"] as? String ?? (dict["albumid"] as? Int).map({ String($0) }) ?? ""
        guard !albumId.isEmpty else { return nil }

        let cover = dict["cover"] as? String ?? ""
        let fullCover = cover.hasPrefix("http") ? cover : (imageCDN + cover)

        return OneAlbum(
            albumId: albumId,
            title: dict["title"] as? String ?? "",
            cover: fullCover,
            description: dict["description"] as? String ?? "",
            itemCount: dict["itemcount"] as? Int ?? dict["total"] as? Int ?? 0,
            rating: dict["score"] as? String
        )
    }

    // MARK: - 保存配置

    func saveToken(_ token: String, userKey: String, uuid: String) {
        self.token = token
        self.userKey = userKey
        self.uuid = uuid
        UserDefaults.standard.set(token, forKey: "one_platform_token")
        UserDefaults.standard.set(userKey, forKey: "one_platform_userkey")
        UserDefaults.standard.set(uuid, forKey: "one_platform_uuid")
    }

    var isConfigured: Bool {
        !token.isEmpty && !userKey.isEmpty
    }
}

// MARK: - 错误类型

enum OneError: Error, LocalizedError {
    case invalidURL
    case invalidParameters
    case encryptionFailed
    case decryptionFailed(String)
    case networkError(String)
    case businessError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 URL"
        case .invalidParameters: return "无效参数"
        case .encryptionFailed: return "加密失败"
        case .decryptionFailed(let msg): return "解密失败: \(msg)"
        case .networkError(let msg): return "网络错误: \(msg)"
        case .businessError(let code, let msg): return "业务错误(\(code)): \(msg)"
        }
    }
}

// MARK: - Data Hex 扩展

private extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var idx = hexString.startIndex
        for _ in 0..<len {
            let end = hexString.index(idx, offsetBy: 2)
            let byteString = hexString[idx..<end]
            if let num = UInt8(byteString, radix: 16) {
                data.append(num)
            } else {
                return nil
            }
            idx = end
        }
        self = data
    }
}
