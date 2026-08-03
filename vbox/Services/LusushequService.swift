import Foundation
import CommonCrypto

// MARK: - SSL 证书绕过（API 服务器使用自签名证书）

/// 仅供六速社区 Service 使用，不替换全局 URLSession.shared 的默认行为。
/// 仅在通过 apiSession / EncImageURLProtocol 发出的请求中生效。
final class LusushequSSLDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - .enc 加密封面图 URLProtocol
//
// 六速社区的列表页和详情页封面以 .enc 结尾，内容是 AES-256-CBC 加密的图片。
// AsyncImage 无法直接加载加密数据，因此注册一个 URLProtocol 拦截 .enc 请求，
// 在内部下载 → AES 解密 → 返回明文图片数据。
//
// 安全边界：
// - 只拦截 URL 以 ".enc" 结尾的请求，不影响其他任何资源。
// - 解密失败时返回错误，AsyncImage 会自动降级为占位图。
// - 内部下载使用独立的 ephemeral session（带 SSL 绕过），不会触发递归拦截。

final class EncImageURLProtocol: URLProtocol {

    private static var registered = false
    private static let cache = NSCache<NSString, NSData>()

    /// 注册 URLProtocol（幂等，多次调用安全）
    static func register() {
        guard !registered else { return }
        URLProtocol.registerClass(EncImageURLProtocol.self)
        registered = true
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url?.absoluteString else { return false }
        return url.hasSuffix(".enc")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let urlString = url.absoluteString

        // 命中内存缓存
        if let cached = EncImageURLProtocol.cache.object(forKey: urlString as NSString) {
            deliver(data: cached as Data, url: url)
            return
        }

        // 下载 .enc 加密数据（独立 session，避免递归拦截 + 绕过 SSL）
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = []
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config, delegate: LusushequSSLDelegate(), delegateQueue: nil)

        let task = session.dataTask(with: req) { [weak self] data, _, error in
            guard let self = self else { return }
            session.invalidateAndCancel()

            if let error = error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }

            guard let data = data else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
                return
            }

            // AES-256-CBC 解密
            guard let decrypted = LusushequService.decryptEncImage(data) else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.cannotDecodeContentData))
                return
            }

            // 写入内存缓存
            EncImageURLProtocol.cache.setObject(decrypted as NSData, forKey: urlString as NSString)

            self.deliver(data: decrypted, url: url)
        }
        task.resume()
    }

    override func stopLoading() {
        // 下载由 session.invalidateAndCancel() 在完成回调中清理
    }

    private func deliver(data: Data, url: URL) {
        let contentType = LusushequService.detectImageContentType(data)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": contentType,
                "Content-Length": "\(data.count)",
                "Cache-Control": "max-age=3600",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - 六速社区 Service
//
// 对应 Python Spider：sources/welfare-js/lusushequ.py
// API Host：https://215.x89cneo.com:51111（自签名 SSL）
// 数据加密：base64(URL-safe) → XOR(key)
// 封面加密：AES-256-CBC，Key=32字节固定，IV=文件前16字节
// 播放：m3u8 统一替换 cdnId=3（消除 Brotli 压缩问题）
//
// 继承 FuliBaseService，复用 FuliPlatformMainView 自适应框架，
// 不创建独立页面，不影响现有资源蜘蛛、网盘和播放链路。

final class LusushequService: FuliBaseService {

    static let shared = LusushequService()

    // MARK: - 常量

    private let referer = "https://3.3xlg40o.com/"
    private let userAgent = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36"

    /// 封面图片 AES-256-CBC 解密密钥（来自 encryptedImageCore-BYbwSfDp.js）
    private static let imgKey = "H0Z%7n#k$H8*M7xSE^N@8xXZPG*RZ&wY"

    /// 硬编码分类（从 Python Spider CATEGORIES 提取）
    /// type_id 格式: {type}_{id}，调用 API 时拆分为 type 和 id
    private let categoryList: [(typeId: String, typeName: String)] = [
        ("label_266", "传媒"),
        ("label_262", "国产"),
        ("label_263", "日本AV"),
        ("label_264", "欧美"),
        ("label_267", "动漫"),
        ("label_341", "三级"),
        ("label_342", "AI换脸"),
        ("label_343", "AV无码"),
        ("cate_130", "黑料"),
        ("cate_143", "探花"),
        ("cate_127", "SM"),
        ("cate_144", "乱伦"),
        ("cate_178", "颜值"),
        ("cate_153", "人妻少妇"),
        ("cate_133", "自拍"),
        ("cate_146", "中文字幕"),
        ("cate_246", "多男一女"),
        ("cate_247", "多女一男"),
        ("cate_142", "主播大秀"),
    ]

    // MARK: - Session（SSL 绕过）

    private lazy var apiSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: LusushequSSLDelegate(), delegateQueue: nil)
    }()

    // MARK: - Init

    init() {
        super.init(
            platformName: "六速社区",
            defaultHosts: ["https://215.x89cneo.com:51111"]
        )
        // 注册 .enc 图片解密拦截器（幂等）
        EncImageURLProtocol.register()
    }

    // MARK: - API 核心

    /// 请求 API 并解密返回的 JSON 数据
    /// - Parameters:
    ///   - path: API 路径（如 /api/old_v3/video/home）
    ///   - params: 查询参数
    /// - Returns: 解密后的 JSON 对象（数组或字典），失败返回 nil
    private func apiCall(_ path: String, params: [String: String]? = nil) async -> Any? {
        let host = currentHost.isEmpty ? (defaultHosts.first ?? "") : currentHost
        var urlString = host + path

        if let params = params {
            let qs = params
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "&")
            urlString += "?" + qs
        }

        guard let url = URL(string: urlString) else {
            print("[六速社区] 无效 URL: \(urlString)")
            return nil
        }

        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

        do {
            let (data, _) = try await apiSession.data(for: req)

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["code"] as? Int) == 200,
                  let encData = json["data"] as? String,
                  let key = json["key"] as? String else {
                print("[六速社区] API 响应格式异常: \(path)")
                return nil
            }

            return decryptResponse(encData, key: key)

        } catch {
            print("[六速社区] API 请求失败 \(path): \(error.localizedDescription)")
            return nil
        }
    }

    /// 解密 API 响应数据
    /// 流程：base64 URL-safe 解码 → XOR(key) → JSON 解析
    private func decryptResponse(_ encData: String, key: String) -> Any? {
        // 1. 清理 + URL-safe base64 → 标准 base64
        var s = encData
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // 2. 补齐 padding
        let pad = (4 - s.count % 4) % 4
        s += String(repeating: "=", count: pad)

        guard let raw = Data(base64Encoded: s) else {
            print("[六速社区] base64 解码失败")
            return nil
        }

        // 3. XOR 解密
        let keyBytes = Array(key.utf8)
        var result = Data(count: raw.count)
        for i in 0..<raw.count {
            result[i] = raw[i] ^ keyBytes[i % keyBytes.count]
        }

        // 4. JSON 解析
        return try? JSONSerialization.jsonObject(with: result)
    }

    // MARK: - 封面图 AES-256-CBC 解密（静态方法，供 EncImageURLProtocol 调用）

    /// AES-256-CBC 解密 .enc 封面图
    /// - Key: 固定 32 字节
    /// - IV: 文件前 16 字节
    /// - 密文: 文件剩余部分
    /// - Padding: PKCS7
    static func decryptEncImage(_ data: Data) -> Data? {
        guard data.count >= 32, data.count % 16 == 0 else { return nil }

        let key = Array(imgKey.utf8)           // 32 bytes
        let iv = Array(data.prefix(16))         // 16 bytes
        let encrypted = Array(data.dropFirst(16))

        var decrypted = [UInt8](repeating: 0, count: encrypted.count)
        var decryptedLength = 0
        let decryptedCount = decrypted.count

        let status = key.withUnsafeBufferPointer { keyPtr in
            iv.withUnsafeBufferPointer { ivPtr in
                encrypted.withUnsafeBufferPointer { encPtr in
                    decrypted.withUnsafeMutableBufferPointer { decPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            encPtr.baseAddress, encrypted.count,
                            decPtr.baseAddress, decryptedCount,
                            &decryptedLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return Data(decrypted.prefix(decryptedLength))
    }

    /// 检测解密后的图片类型
    static func detectImageContentType(_ data: Data) -> String {
        // JPEG: FF D8
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 {
            return "image/jpeg"
        }
        // PNG: 89 50 4E 47
        if data.count >= 4, data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 {
            return "image/png"
        }
        return "image/jpeg"
    }

    // MARK: - 构建视频条目

    private func buildVideo(_ item: [String: Any]) -> FuliVideo? {
        guard let id = item["id"] else { return nil }
        let vid = String(describing: id)
        guard !vid.isEmpty else { return nil }

        let name = item["title"] as? String ?? ""
        let pic = (item["upload_thumb"] as? String) ?? (item["thumb"] as? String) ?? ""
        let remarks = item["label"] as? String

        // .enc 封面由 EncImageURLProtocol 在 AsyncImage 加载时自动解密
        // 非 .enc 封面直接返回原始 URL
        return FuliVideo(vodId: vid, vodName: name, vodPic: pic, vodRemarks: remarks)
    }

    // MARK: - FuliPlatformService 实现

    override func fetchHomeContent() async -> FuliHomeResult {
        // 分类列表（硬编码，不依赖网络）
        let categories = categoryList.map {
            FuliCategory(typeId: $0.typeId, typeName: $0.typeName)
        }

        // 首页推荐视频
        var videos: [FuliVideo] = []
        if let sections = await apiCall("/api/old_v3/video/home") as? [[String: Any]] {
            var seen = Set<String>()
            for section in sections {
                guard let list = section["list"] as? [[String: Any]] else { continue }
                for item in list {
                    if let video = buildVideo(item) {
                        if !seen.contains(video.vodId) {
                            seen.insert(video.vodId)
                            videos.append(video)
                        }
                    }
                }
            }
            videos = Array(videos.prefix(72))
        }

        return FuliHomeResult(categories: categories, videos: videos)
    }

    override func fetchCategoryContent(
        category: FuliCategory,
        subCategory: FuliCategory?,
        page: Int
    ) async -> FuliCategoryResult {
        let tid = subCategory?.typeId ?? category.typeId

        // 拆分 type_id: "label_266" → type="label", id="266"
        let parts = tid.components(separatedBy: "_")
        guard parts.count == 2 else {
            return FuliCategoryResult(videos: [], page: page, hasMore: false)
        }
        let ctype = parts[0]
        let cid = parts[1]

        guard let data = await apiCall("/api/old_v3/video/getList", params: [
            "type": ctype,
            "id": cid,
            "page": String(page),
            "page_size": "20",
        ]) as? [String: Any] else {
            return FuliCategoryResult(videos: [], page: page, hasMore: false)
        }

        let list = data["list"] as? [[String: Any]] ?? []
        let videos = list.compactMap { buildVideo($0) }

        // 计算总页数
        let total = parseIntValue(data["total"]) ?? (videos.count * 10)
        let pageCount = max(1, (total + 19) / 20)
        let hasMore = page < pageCount

        return FuliCategoryResult(videos: videos, page: page, hasMore: hasMore)
    }

    override func fetchDetail(vodId: String) async -> FuliDetail {
        guard let data = await apiCall("/api/v3/home/public/video/long/detail", params: ["id": vodId]) else {
            return FuliDetail(
                vodId: vodId, vodName: "", vodPic: "",
                vodContent: nil, playFrom: "六速社区", episodes: []
            )
        }

        // API 返回结构可能是 {data: {...}} 或直接是字典/数组
        let item: [String: Any]?
        if let dict = data as? [String: Any], let inner = dict["data"] as? [String: Any] {
            item = inner
        } else if let array = data as? [[String: Any]], let first = array.first {
            item = first
        } else if let dict = data as? [String: Any] {
            item = dict
        } else {
            item = nil
        }

        guard let item = item, item["id"] != nil else {
            return FuliDetail(
                vodId: vodId, vodName: "", vodPic: "",
                vodContent: nil, playFrom: "六速社区", episodes: []
            )
        }

        let name = item["title"] as? String ?? "未知影片"
        let pic = (item["upload_thumb"] as? String) ?? (item["thumb"] as? String) ?? ""
        let desc = (item["desc"] as? String) ?? (item["classify"] as? String) ?? ""
        var content = desc
        if content.count > 500 {
            content = String(content.prefix(500))
        }

        // 构建播放线路
        var episodes: [FuliEpisode] = []
        let playHls = item["play_hls_url"] as? String ?? ""
        let cdnList = item["cdn_list"] as? [[String: Any]] ?? []

        if !playHls.isEmpty {
            // 默认线路
            episodes.append(FuliEpisode(name: "默认线路", url: playHls))

            // 其他 CDN 线路：正则替换 cdnId
            for cdn in cdnList.dropFirst() {
                guard let cdnId = cdn["id"] else { continue }
                let cdnTitle = cdn["title"] as? String ?? "线路\(cdnId)"
                let cdnHls = playHls.replacingOccurrences(
                    of: "cdnId=\\d+",
                    with: "cdnId=\(cdnId)",
                    options: .regularExpression
                )
                episodes.append(FuliEpisode(name: cdnTitle, url: cdnHls))
            }
        }

        // play_hls 为空时用 href 兜底
        if episodes.isEmpty {
            let href = item["href"] as? String ?? ""
            if !href.isEmpty {
                var playUrl = href
                if !playUrl.hasPrefix("http") {
                    playUrl = "https://kbu.xn--xhq15jk0k96h.cn/encryption-ts" + playUrl
                }
                episodes.append(FuliEpisode(name: "默认线路", url: playUrl))
            }
        }

        return FuliDetail(
            vodId: vodId,
            vodName: name,
            vodPic: pic,
            vodContent: content,
            playFrom: "六速社区",
            episodes: episodes
        )
    }

    override func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        guard let data = await apiCall("/api/old_v3/video/search", params: [
            "keywords": keyword,
            "page": String(page),
            "page_size": "20",
        ]) as? [String: Any] else {
            return FuliSearchResult(videos: [], page: page, hasMore: false)
        }

        let list = data["list"] as? [[String: Any]] ?? []
        let videos = list.compactMap { buildVideo($0) }

        let total = parseIntValue(data["total"]) ?? (videos.count * 10)
        let pageCount = max(1, (total + 19) / 20)
        let hasMore = page < pageCount

        return FuliSearchResult(videos: videos, page: page, hasMore: hasMore)
    }

    override func fetchPlayerURL(episode: FuliEpisode) async -> FuliPlayerResult {
        var url = episode.url

        // 统一替换 cdnId=3：cdnId=3 从不返回 Brotli 压缩，最稳定
        if url.contains("cdnId=") {
            url = url.replacingOccurrences(
                of: "cdnId=\\d+",
                with: "cdnId=3",
                options: .regularExpression
            )
        }

        let headers = [
            "User-Agent": userAgent,
            "Referer": referer,
        ]

        // 尝试预加载 m3u8 并修复 key URI（根相对路径 → 绝对路径）
        // 解决问题：m3u8 中 #EXT-X-KEY 的 URI 是根相对路径 /api/v2/...，
        // AVPlayer 从本地文件播放时无法正确解析相对路径。
        // 预加载后将 key URI 改写为绝对路径，写入临时文件返回。
        if let rewrittenURL = await rewriteM3U8KeyURIs(url: url) {
            return FuliPlayerResult(url: rewrittenURL, headers: headers, parse: 0)
        }

        // 预加载失败时回退到直接 URL（AVPlayer 自行解析相对路径）
        return FuliPlayerResult(url: url, headers: headers, parse: 0)
    }

    // MARK: - m3u8 key URI 兼容性处理

    /// 预加载 m3u8 内容，将 #EXT-X-KEY 中的根相对路径 URI 改写为绝对路径，
    /// 然后写入临时文件返回。
    ///
    /// 对应 Python 脚本 `_proxy_m3u8` 中的 key URI 修复逻辑：
    /// - 根相对路径 `/api/v2/...` → `https://host:port/api/v2/...`
    /// - 相对路径 `key.bin` → `https://host:port/path/to/key.bin`
    ///
    /// 使用 apiSession（SSL 绕过）下载 m3u8 内容，
    /// 解决 API 服务器自签名 SSL 证书导致 AVPlayer 无法直接加载的问题。
    private func rewriteM3U8KeyURIs(url: String) async -> String? {
        guard let urlObj = URL(string: url) else { return nil }

        var req = URLRequest(url: urlObj)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")

        do {
            let (data, response) = try await apiSession.data(for: req)

            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let content = String(data: data, encoding: .utf8),
                  content.contains("#EXTM3U") else {
                return nil
            }

            // 获取最终 URL（可能经过重定向），用于计算 base
            let finalURLString = http.url?.absoluteString ?? url

            // 解析 scheme://host[:port]
            guard let finalURL = URL(string: finalURLString),
                  let scheme = finalURL.scheme,
                  let host = finalURL.host else {
                return nil
            }
            let port = finalURL.port.map { ":\($0)" } ?? ""
            let schemeHostPort = "\(scheme)://\(host)\(port)"

            // 计算 base path（去掉 query 和文件名）
            // 例如 https://host/path/to/playlist.m3u8?cdnId=3 → https://host/path/to/
            let pathOnly = finalURLString.components(separatedBy: "?")[0]
            let basePath: String
            if let lastSlash = pathOnly.lastIndex(of: "/") {
                basePath = String(pathOnly[..<lastSlash]) + "/"
            } else {
                basePath = schemeHostPort + "/"
            }

            // 逐行处理，修复 #EXT-X-KEY 中的 URI
            var lines = content.components(separatedBy: "\n")
            for i in 0..<lines.count {
                let line = lines[i].trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("#EXT-X-KEY"), line.contains("URI=\"") else { continue }

                // 提取 URI="..." 中的值
                guard let uriStartRange = line.range(of: "URI=\""),
                      let uriEndRange = line.range(of: "\"", range: uriStartRange.upperBound..<line.endIndex) else {
                    continue
                }
                let uri = String(line[uriStartRange.upperBound..<uriEndRange.lowerBound])

                // 已经是绝对路径，不需要修复
                if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
                    continue
                }

                // 根相对路径 /api/v2/... → https://host:port/api/v2/...
                // 相对路径 key.bin → https://host:port/path/to/key.bin
                let absoluteURI: String
                if uri.hasPrefix("/") {
                    absoluteURI = schemeHostPort + uri
                } else {
                    absoluteURI = basePath + uri
                }

                lines[i] = line.replacingOccurrences(
                    of: "URI=\"\(uri)\"",
                    with: "URI=\"\(absoluteURI)\""
                )
            }

            // 写入临时文件
            let rewrittenContent = lines.joined(separator: "\n")
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent("lusushequ_\(UUID().uuidString).m3u8")
            try rewrittenContent.data(using: .utf8)?.write(to: tempFile, options: .atomic)

            print("[六速社区] m3u8 key URI 已修复，临时文件: \(tempFile.lastPathComponent)")
            return tempFile.absoluteString

        } catch {
            print("[六速社区] m3u8 预加载失败，回退到直接 URL: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 辅助

    /// 安全解析 Int 值（兼容 Int 和 String 类型）
    private func parseIntValue(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let s = value as? String, let n = Int(s) { return n }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }
}
