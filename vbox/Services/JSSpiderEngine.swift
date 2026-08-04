import Foundation
import JavaScriptCore
import CryptoKit
import CommonCrypto
import Security

/// JavaScriptCore 异常
struct JSError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// JS引擎桥接层 — 管理 JavaScriptCore 上下文，加载蜘蛛脚本，调用蜘蛛API
class JSSpiderEngine {

    // MARK: - 属性
    private let context: JSContext
    private let httpBridge: JSHTTPBridge

    var onLog: ((String) -> Void)?

    // MARK: - 初始化
    init(sslBypass: Bool = false) {
        self.context = JSContext()
        self.httpBridge = JSHTTPBridge()
        self.httpBridge.sslBypass = sslBypass
        setupContext()
    }

    /// 配置 JSContext 的桥接
    private func setupContext() {
        // 异常捕获
        context.exceptionHandler = { [weak self] _, exception in
            let msg = exception?.toString() ?? "未知JS错误"
            self?.onLog?("❌ JS异常: \(msg)")
        }

        // 桥接 console.log / console.error
        let console: @convention(block) (String) -> Void = { [weak self] msg in
            self?.onLog?("📗 \(msg)")
        }
        context.setObject(unsafeBitCast(console, to: AnyObject.self),
                         forKeyedSubscript: "__consoleLog" as NSString)
        context.evaluateScript("""
        console = {
            log: function(...args) { __consoleLog(args.join(' ')); },
            error: function(...args) { __consoleLog('ERROR: ' + args.join(' ')); }
        };
        """)

        // 桥接 print() — 蜘蛛脚本常用
        let printFunc: @convention(block) (String) -> Void = { [weak self] msg in
            self?.onLog?("🖨️ \(msg)")
        }
        context.setObject(unsafeBitCast(printFunc, to: AnyObject.self),
                         forKeyedSubscript: "print" as NSString)

        // 桥接 http() — 蜘蛛脚本的网络请求
        let httpFunc: @convention(block) (String, [String: Any]) -> [String: Any] = { [weak self] url, options in
            guard let self = self else { return ["ok": false, "status": 500, "content": "引擎已释放"] }
            return self.httpBridge.syncRequest(url: url, options: options)
        }
        context.setObject(unsafeBitCast(httpFunc, to: AnyObject.self),
                         forKeyedSubscript: "_http" as NSString)

        // 注册全局 http 和 req 函数
        context.evaluateScript("""
        var http = function(url, options) {
            if (!options) options = {};
            options.async = false;
            return _http(url, options);
        };
        var req = http;
        """)

        // 桥接 crypto — AES-CBC 解密 + MD5 哈希
        let aesDecrypt: @convention(block) (String, String) -> String = { encData, keyB64 in
            guard let keyData = Data(base64Encoded: keyB64),
                  let cipherData = Data(base64Encoded: encData) else {
                return ""
            }
            let cryptLength = cipherData.count + kCCBlockSizeAES128
            var cryptData = Data(count: cryptLength)
            var numBytesDecrypted: size_t = 0
            let status = cryptData.withUnsafeMutableBytes { cryptBytes in
                cipherData.withUnsafeBytes { dataBytes in
                    keyData.withUnsafeBytes { keyBytes in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, keyData.count,
                                keyBytes.baseAddress,  // IV = key
                                dataBytes.baseAddress, cipherData.count,
                                cryptBytes.baseAddress, cryptLength,
                                &numBytesDecrypted)
                    }
                }
            }
            guard status == kCCSuccess else { return "" }
            cryptData.count = numBytesDecrypted
            return String(data: cryptData, encoding: .utf8) ?? ""
        }
        context.setObject(unsafeBitCast(aesDecrypt, to: AnyObject.self),
                         forKeyedSubscript: "__aesDecrypt" as NSString)

        let md5Hash: @convention(block) (String) -> String = { text in
            let digest = Insecure.MD5.hash(data: text.data(using: .utf8) ?? Data())
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        context.setObject(unsafeBitCast(md5Hash, to: AnyObject.self),
                         forKeyedSubscript: "__md5" as NSString)

        let b64Decode: @convention(block) (String) -> String = { text in
            guard let data = Data(base64Encoded: text) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        context.setObject(unsafeBitCast(b64Decode, to: AnyObject.self),
                         forKeyedSubscript: "__b64Decode" as NSString)

        let b64Encode: @convention(block) (String) -> String = { text in
            return Data(text.utf8).base64EncodedString()
        }
        context.setObject(unsafeBitCast(b64Encode, to: AnyObject.self),
                         forKeyedSubscript: "__b64Encode" as NSString)

        // ====== 新增 crypto 桥接函数（仅新增，不修改已有函数） ======

        // AES-ECB 解密 (base64密文, base64密钥 → UTF-8字符串)
        let aesDecryptECB: @convention(block) (String, String) -> String = { encDataB64, keyB64 in
            guard let keyData = Data(base64Encoded: keyB64),
                  let cipherData = Data(base64Encoded: encDataB64) else {
                return ""
            }
            let cryptLength = cipherData.count + kCCBlockSizeAES128
            var cryptData = Data(count: cryptLength)
            var numBytesDecrypted: size_t = 0
            let status = cryptData.withUnsafeMutableBytes { cryptBytes in
                cipherData.withUnsafeBytes { dataBytes in
                    keyData.withUnsafeBytes { keyBytes in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                                keyBytes.baseAddress, keyData.count,
                                nil,  // ECB 模式无 IV
                                dataBytes.baseAddress, cipherData.count,
                                cryptBytes.baseAddress, cryptLength,
                                &numBytesDecrypted)
                    }
                }
            }
            guard status == kCCSuccess else { return "" }
            cryptData.count = numBytesDecrypted
            return String(data: cryptData, encoding: .utf8) ?? ""
        }
        context.setObject(unsafeBitCast(aesDecryptECB, to: AnyObject.self),
                         forKeyedSubscript: "__aesDecryptECB" as NSString)

        // SHA256 哈希 (文本 → hex字符串)
        let sha256Hash: @convention(block) (String) -> String = { text in
            let digest = SHA256.hash(data: text.data(using: .utf8) ?? Data())
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        context.setObject(unsafeBitCast(sha256Hash, to: AnyObject.self),
                         forKeyedSubscript: "__sha256" as NSString)

        // HMAC-SHA256 (key, message → base64字符串)
        let hmacSHA256: @convention(block) (String, String) -> String = { key, message in
            let keyData = SymmetricKey(data: key.data(using: .utf8) ?? Data())
            let msgData = message.data(using: .utf8) ?? Data()
            let hmac = HMAC<SHA256>.authenticationCode(for: msgData, using: keyData)
            return Data(hmac).base64EncodedString()
        }
        context.setObject(unsafeBitCast(hmacSHA256, to: AnyObject.self),
                         forKeyedSubscript: "__hmacSHA256" as NSString)

        // RSA-SHA256 签名 (message, privateKeyBase64 → base64签名)
        let rsaSign: @convention(block) (String, String) -> String = { message, privateKeyB64 in
            guard let keyData = Data(base64Encoded: privateKeyB64) else { return "" }
            let msgData = message.data(using: .utf8) ?? Data()

            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
            ]
            var error: Unmanaged<CFError>?

            // 尝试直接创建 SecKey (PKCS#8 格式)
            var secKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error)

            // 如果失败，尝试去掉 PKCS#8 头部（前26字节）作为 PKCS#1
            if secKey == nil && keyData.count > 26 {
                error = nil
                let pkcs1Data = keyData.subdata(in: 26..<keyData.count)
                secKey = SecKeyCreateWithData(pkcs1Data as CFData, attributes as CFDictionary, &error)
            }

            guard let key = secKey else { return "" }

            guard let signature = SecKeyCreateSignature(key,
                                                          .rsaSignatureMessagePKCS1v15SHA256,
                                                          msgData as CFData,
                                                          &error) else { return "" }
            return (signature as Data).base64EncodedString()
        }
        context.setObject(unsafeBitCast(rsaSign, to: AnyObject.self),
                         forKeyedSubscript: "__rsaSign" as NSString)

        // UUID v4 生成
        let uuidGen: @convention(block) () -> String = {
            return UUID().uuidString.lowercased()
        }
        context.setObject(unsafeBitCast(uuidGen, to: AnyObject.self),
                         forKeyedSubscript: "__uuid" as NSString)

        // Hex 字符串转 Base64
        let hexToB64: @convention(block) (String) -> String = { hexStr in
            let cleaned = hexStr.replacingOccurrences(of: " ", with: "")
                                 .replacingOccurrences(of: "\n", with: "")
                                 .replacingOccurrences(of: "\r", with: "")
            var data = Data()
            var i = cleaned.startIndex
            while i < cleaned.endIndex {
                let next = cleaned.index(i, offsetBy: 2, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
                if let byte = UInt8(cleaned[i..<next], radix: 16) {
                    data.append(byte)
                }
                i = next
            }
            return data.base64EncodedString()
        }
        context.setObject(unsafeBitCast(hexToB64, to: AnyObject.self),
                         forKeyedSubscript: "__hexToB64" as NSString)

        context.evaluateScript("""
        var crypto = {
            AES: {
                decrypt: function(encData, keyB64) { return __aesDecrypt(encData, keyB64); },
                decryptECB: function(encDataB64, keyB64) { return __aesDecryptECB(encDataB64, keyB64); }
            },
            RSA: {
                sign: function(message, privateKeyB64) { return __rsaSign(message, privateKeyB64); }
            },
            MD5: function(text) { return __md5(text); },
            SHA256: function(text) { return __sha256(text); },
            HMAC: {
                SHA256: function(key, message) { return __hmacSHA256(key, message); }
            },
            base64: {
                decode: function(text) { return __b64Decode(text); },
                encode: function(text) { return __b64Encode(text); }
            },
            hex: {
                toBase64: function(hexStr) { return __hexToB64(hexStr); }
            },
            uuid: function() { return __uuid(); }
        };
        """)

        // 桥接 XMLHttpRequest (简化版)
        let xhrOpen: @convention(block) (String, String, Bool) -> Void = { method, url, async in
            // 简单模式，忽略async
        }
        context.setObject(unsafeBitCast(xhrOpen, to: AnyObject.self),
                         forKeyedSubscript: "__xhrOpen" as NSString)

        // 桥接 atob / btoa — 标准 Web API，处理二进制 base64
        // atob 返回二进制字符串（每个字符 charCode 0-255），btoa 接受二进制字符串
        // JS 蜘蛛脚本可用 atob 解码 base64 后进行 XOR/AES 等二进制操作
        let atobFunc: @convention(block) (String) -> String = { b64 in
            var s = b64.replacingOccurrences(of: "-", with: "+")
                       .replacingOccurrences(of: "_", with: "/")
            let pad = (4 - s.count % 4) % 4
            s += String(repeating: "=", count: pad)
            guard let data = Data(base64Encoded: s) else { return "" }
            // 返回二进制字符串（Latin-1 编码，每个字符 = 一个字节）
            return String(data: data, encoding: .isoLatin1) ?? ""
        }
        context.setObject(unsafeBitCast(atobFunc, to: AnyObject.self),
                         forKeyedSubscript: "__atob" as NSString)

        let btoaFunc: @convention(block) (String) -> String = { binaryStr in
            let data = binaryStr.data(using: .isoLatin1) ?? Data()
            return data.base64EncodedString()
        }
        context.setObject(unsafeBitCast(btoaFunc, to: AnyObject.self),
                         forKeyedSubscript: "__btoa" as NSString)

        context.evaluateScript("""
        var atob = function(s) { return __atob(s); };
        var btoa = function(s) { return __btoa(s); };
        """)

        onLog?("✅ JS引擎上下文初始化完成")
    }

    // MARK: - 加载蜘蛛脚本

    /// 加载蜘蛛脚本字符串
    func loadScript(_ script: String) throws {
        let result = context.evaluateScript(script)
        if let exception = context.exception {
            throw JSError(message: "加载脚本失败: \(exception.toString() ?? "未知错误")")
        }
        onLog?("✅ 蜘蛛脚本加载完成 (\(script.count) 字符)")
    }

    /// 从 Bundle 加载蜘蛛脚本
    func loadScriptFromBundle(fileName: String, ext: String = "js") throws {
        guard let path = Bundle.main.path(forResource: fileName, ofType: ext),
              let script = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw JSError(message: "找不到脚本文件: \(fileName).\(ext)")
        }
        try loadScript(script)
    }

    /// 从远程URL加载蜘蛛脚本
    func loadScriptFromURL(_ urlString: String) async throws {
        guard let url = URL(string: urlString) else {
            throw JSError(message: "无效的URL: \(urlString)")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let script = String(data: data, encoding: .utf8) else {
            throw JSError(message: "无法解码脚本: \(urlString)")
        }
        try loadScript(script)
    }

    /// 加载引擎库（模板.js/cat.js等标准库）
    func loadLibrary(_ script: String) throws {
        // 库脚本用 evaluateScript 但不检查 spider 注册
        context.evaluateScript(script)
        if let exception = context.exception {
            throw JSError(message: "加载库失败: \(exception.toString() ?? "未知错误")")
        }
    }

    // MARK: - 注册蜘蛛

    /// 检查并注册 __JS_SPIDER__
    var isSpiderReady: Bool {
        let exists = context.evaluateScript("typeof globalThis.__JS_SPIDER__ !== 'undefined'")
        return exists?.toBool() ?? false
    }

    /// 注册蜘蛛对象到 globalThis
    func registerSpider() throws {
        let script = """
        if (typeof globalThis.__JS_SPIDER__ === 'undefined') {
            if (typeof spider !== 'undefined') {
                if (typeof spider.__jsEvalReturn === 'function') {
                    globalThis.__JS_SPIDER__ = spider.__jsEvalReturn();
                } else if (typeof spider.default === 'function') {
                    globalThis.__JS_SPIDER__ = spider.default();
                } else {
                    globalThis.__JS_SPIDER__ = spider;
                }
                if (globalThis.__JS_SPIDER__) {
                    globalThis.__JS_SPIDER__.is_cat = true;
                }
            }
        }
        typeof globalThis.__JS_SPIDER__ !== 'undefined';
        """
        let result = context.evaluateScript(script)
        if result?.toBool() != true {
            throw JSError(message: "无法注册蜘蛛: 没有找到 spider 对象")
        }
        onLog?("✅ 蜘蛛已注册到 globalThis.__JS_SPIDER__")
    }

    // MARK: - 调用蜘蛛API

    /// 调用 spider.init(config)
    func callInit(config: [String: Any]) -> Bool {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: config),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return false
        }
        let script = "globalThis.__JS_SPIDER__.init(\(jsonStr))"
        let result = context.evaluateScript(script)
        return result?.toBool() ?? false
    }

    /// 通用调用：自动判断返回值是字符串还是对象，避免双重 JSON 编码
    private func callSpiderMethod<T: Decodable>(_ methodName: String, args: [String] = [], as type: T.Type) throws -> T {
        let escapedArgs = args.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" }.joined(separator: ", ")
        let rawScript = "globalThis.__JS_SPIDER__.\(methodName)(\(escapedArgs))"
        let rawResult = context.evaluateScript(rawScript)

        let jsonString: String
        if let result = rawResult {
            if result.isString {
                // 返回值已经是 JSON 字符串，直接使用
                jsonString = result.toString()
            } else if result.isObject || result.isArray {
                // 🔧 修复: 将已有结果存入临时变量再 stringify，避免重复执行蜘蛛方法
                // 旧代码用 JSON.stringify(rawScript) 会导致 playerContent 等方法被调用两次
                // 网络请求翻倍、耗时翻倍，更容易触发 30s 超时
                context.setObject(result, forKeyedSubscript: "__tmpResult" as NSString)
                let stringifyScript = "JSON.stringify(__tmpResult)"
                guard let str = context.evaluateScript(stringifyScript)?.toString() else {
                    context.evaluateScript("delete globalThis.__tmpResult")
                    throw JSError(message: "\(methodName) 返回无效")
                }
                context.evaluateScript("delete globalThis.__tmpResult")
                jsonString = str
            } else {
                throw JSError(message: "\(methodName) 返回类型无效")
            }
        } else {
            throw JSError(message: "\(methodName) 返回无效")
        }

        guard let data = jsonString.data(using: .utf8) else {
            throw JSError(message: "\(methodName) 返回无效")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// 调用 spider.homeContent()
    func callHomeContent() throws -> HomeContentResult {
        try callSpiderMethod("homeContent", as: HomeContentResult.self)
    }

    /// 调用 spider.categoryContent(tid, pg, extend)
    func callCategoryContent(tid: String, pg: Int, extend: String = "{}") throws -> CategoryContentResult {
        try callSpiderMethod("categoryContent", args: [tid, String(pg), extend], as: CategoryContentResult.self)
    }

    /// 调用 spider.detailContent(ids)
    func callDetailContent(ids: String) throws -> DetailContentResult {
        try callSpiderMethod("detailContent", args: [ids], as: DetailContentResult.self)
    }

    /// 调用 spider.searchContent(key, quick, pg)
    func callSearchContent(keyword: String, pg: Int = 1) throws -> SearchContentResult {
        try callSpiderMethod("searchContent", args: [keyword, "false", String(pg)], as: SearchContentResult.self)
    }

    /// 调用 spider.playerContent(vod_id, flag, url)
    func callPlayerContent(vodId: String, flag: String, url: String) throws -> PlayerContentResult {
        try callSpiderMethod("playerContent", args: [vodId, flag, url], as: PlayerContentResult.self)
    }

    // MARK: - 通用调用

    /// 调用任意蜘蛛方法（返回原始JS值，用于调试）
    func callRawFunction(_ script: String) -> JSValue? {
        return context.evaluateScript(script)
    }
}
