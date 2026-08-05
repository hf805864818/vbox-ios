import Foundation
import SwiftUI
import CommonCrypto

// MARK: - 平台封面图加载器
// 对应 Python 脚本中的封面图处理逻辑:
// - 神秘电影: 直接从 38.je:36 加载, 需要 UA/Referer 头 (img_url 方法)
// - 每日大乱斗/大赛: 封面图 AES 加密, 需客户端解密 (aesimg + _proc_url 方法)

// MARK: - 加载模式

enum PlatformImageMode {
    /// 神秘电影: 直接加载, 支持 @UA@Referer 头注入格式
    case mysteryMovie
    /// 每日大乱斗/大赛: AES 加密图片, 需解密后显示
    case dailyBattle
    /// 普通图片, 无特殊处理
    case plain
}

// MARK: - AES 图片解密器
// 对应 Python 脚本 aesimg() 方法
// 密钥对1: f5d965df75336270 / 97b60394abc2fbe1 (CBC)
// 密钥对2: 75336270f5d965df / abc2fbe197b60394 (CBC)
// 也尝试 ECB 模式

struct AESImageDecryptor {
    static let keyPairs: [(key: [UInt8], iv: [UInt8])] = [
        (Array("f5d965df75336270".utf8), Array("97b60394abc2fbe1".utf8)),
        (Array("75336270f5d965df".utf8), Array("abc2fbe197b60394".utf8)),
    ]

    /// 解密 AES 加密的图片数据
    /// 对应 Python: aesimg(data) 方法
    static func decrypt(_ data: Data) -> Data {
        // 如果已经是有效的图片格式 (JPEG/PNG/GIF), 无需解密
        if data.starts(with: [0xFF, 0xD8]) || data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: Array("GIF8".utf8)) {
            return data
        }

        guard data.count >= 16 else { return data }

        // 尝试 CBC 模式
        for (key, iv) in keyPairs {
            if let decrypted = decryptCBC(data, key: key, iv: iv) {
                // 验证解密结果是否为有效图片
                if decrypted.starts(with: [0xFF, 0xD8]) || decrypted.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                    return decrypted
                }
            }
        }

        // 尝试 ECB 模式
        for (key, _) in keyPairs {
            if let decrypted = decryptECB(data, key: key) {
                if decrypted.starts(with: [0xFF, 0xD8]) {
                    return decrypted
                }
            }
        }

        return data
    }

    /// AES-CBC 解密 + PKCS7 去填充
    private static func decryptCBC(_ data: Data, key: [UInt8], iv: [UInt8]) -> Data? {
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytesDecrypted = 0

        let status = buffer.withUnsafeMutableBytes { bufferPtr in
            data.withUnsafeBytes { dataPtr in
                iv.withUnsafeBufferPointer { ivPtr in
                    key.withUnsafeBufferPointer { keyPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, data.count,
                            bufferPtr.baseAddress, bufferSize,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return buffer.prefix(numBytesDecrypted)
    }

    /// AES-ECB 解密 + PKCS7 去填充
    private static func decryptECB(_ data: Data, key: [UInt8]) -> Data? {
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytesDecrypted = 0

        let status = buffer.withUnsafeMutableBytes { bufferPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBufferPointer { keyPtr in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                        keyPtr.baseAddress, key.count,
                        nil,
                        dataPtr.baseAddress, data.count,
                        bufferPtr.baseAddress, bufferSize,
                        &numBytesDecrypted
                    )
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return buffer.prefix(numBytesDecrypted)
    }
}

// MARK: - 图片缓存

class PlatformImageCache {
    static let shared = PlatformImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private var loadingTasks: [String: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()

    init() {
        cache.countLimit = 300
        cache.totalCostLimit = 80 * 1024 * 1024 // 80MB
    }

    func get(_ key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ key: String, _ image: UIImage) {
        cache.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height))
    }

    func getLoadingTask(_ key: String) -> Task<UIImage?, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return loadingTasks[key]
    }

    func setLoadingTask(_ key: String, _ task: Task<UIImage?, Never>) {
        lock.lock()
        loadingTasks[key] = task
        lock.unlock()
    }

    func removeLoadingTask(_ key: String) {
        lock.lock()
        loadingTasks.removeValue(forKey: key)
        lock.unlock()
    }
}

// MARK: - 平台图片加载器

class PlatformImageLoader {
    static let shared = PlatformImageLoader()
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.urlCache = URLCache(memoryCapacity: 30 * 1024 * 1024, diskCapacity: 0)
        config.requestCachePolicy = .returnCacheDataElseLoad
        self.session = URLSession(configuration: config)
    }

    /// 解析 @User-Agent=...@Referer=... 格式 (TVBox 约定)
    /// 返回 (干净URL, 额外请求头)
    /// 对应 Python 神秘电影 img_url() 方法的 @UA@Referer 后缀
    static func parseHeaderSuffix(_ urlString: String) -> (url: String, headers: [String: String]) {
        var cleanURL = urlString
        var headers: [String: String] = [:]

        let pattern = "@([^=]+)=([^@]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (urlString, [:])
        }

        let nsRange = NSRange(urlString.startIndex..., in: urlString)
        let matches = regex.matches(in: urlString, range: nsRange)

        // 从后往前找到第一个 @ 的位置, 分割 URL 和头部参数
        if let firstMatch = matches.first {
            let atRange = Range(firstMatch.range, in: urlString)!
            cleanURL = String(urlString[..<atRange.lowerBound])

            for match in matches {
                guard let keyRange = Range(match.range(at: 1), in: urlString),
                      let valueRange = Range(match.range(at: 2), in: urlString) else { continue }
                let key = String(urlString[keyRange])
                let value = String(urlString[valueRange])
                headers[key] = value
            }
        }

        return (cleanURL, headers)
    }

    /// 加载图片
    /// - Parameters:
    ///   - urlString: 图片 URL (可能包含 @UA@Referer 后缀)
    ///   - mode: 加载模式
    /// - Returns: 解码后的 UIImage
    func loadImage(urlString: String, mode: PlatformImageMode) async -> UIImage? {
        // 1. 处理 data: 内嵌图片 (Base64)
        if urlString.hasPrefix("data:") {
            return loadDataImage(urlString, mode: mode)
        }

        // 2. 解析 @UA@Referer 头部后缀
        let (cleanURL, extraHeaders) = PlatformImageLoader.parseHeaderSuffix(urlString)

        guard let url = URL(string: cleanURL) else { return nil }

        let cacheKey = PlatformImageLoader.makeCacheKey(urlString, mode: mode)
        if let cached = PlatformImageCache.shared.get(cacheKey) {
            return cached
        }

        // 防止重复并发加载同一图片
        if let existingTask = PlatformImageCache.shared.getLoadingTask(cacheKey) {
            return await existingTask.value
        }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self = self else { return nil }
            return await self.fetchAndProcess(url: url, headers: extraHeaders, mode: mode, cacheKey: cacheKey)
        }
        PlatformImageCache.shared.setLoadingTask(cacheKey, task)
        let result = await task.value
        PlatformImageCache.shared.removeLoadingTask(cacheKey)
        return result
    }

    /// 处理 data: 内嵌图片
    /// 对应 Python _proc_url() 中 data:image 分支
    private func loadDataImage(_ dataURL: String, mode: PlatformImageMode) -> UIImage? {
        guard let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
        let base64String = String(dataURL[dataURL.index(after: commaIndex)...])
        guard let rawData = Data(base64Encoded: base64String) else { return nil }

        let imageData: Data
        switch mode {
        case .dailyBattle:
            // AES 解密
            imageData = AESImageDecryptor.decrypt(rawData)
        case .mysteryMovie, .plain:
            imageData = rawData
        }

        return UIImage(data: imageData)
    }

    /// 从网络获取并处理图片
    private func fetchAndProcess(url: URL, headers: [String: String], mode: PlatformImageMode, cacheKey: String) async -> UIImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let sslBypass = headers["X-VBox-SSL-Bypass"] == "1"

        // 根据模式设置默认头
        switch mode {
        case .mysteryMovie:
            // 神秘电影: 使用 @UA@Referer 解析出的头, 或默认头
            if let ua = headers["User-Agent"] { request.setValue(ua, forHTTPHeaderField: "User-Agent") }
            else { request.setValue("Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/104.0.5112.97 Mobile Safari/537.36", forHTTPHeaderField: "User-Agent") }
            if let referer = headers["Referer"] { request.setValue(referer, forHTTPHeaderField: "Referer") }
            else { request.setValue("https://h4ivs.sm431.vip/", forHTTPHeaderField: "Referer") }
            request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        case .dailyBattle:
            // 每日大乱斗/大赛: 使用浏览器 UA
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

        case .plain:
            break
        }

        // 应用额外头
        for (key, value) in headers {
            if key == "X-VBox-SSL-Bypass" { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let activeSession: URLSession
            if sslBypass {
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 10
                config.timeoutIntervalForResource = 15
                activeSession = URLSession(configuration: config, delegate: WelfareSSLBypassDelegate(), delegateQueue: nil)
            } else {
                activeSession = session
            }
            let (data, response) = try await activeSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            let imageData: Data
            switch mode {
            case .dailyBattle:
                // AES 解密图片数据 (对应 Python aesimg)
                imageData = AESImageDecryptor.decrypt(data)
            case .mysteryMovie, .plain:
                imageData = data
            }

            guard let image = UIImage(data: imageData) else { return nil }
            PlatformImageCache.shared.set(cacheKey, image)
            return image
        } catch {
            print("[PlatformImageLoader] 加载失败: \(url) - \(error.localizedDescription)")
            return nil
        }
    }
}
