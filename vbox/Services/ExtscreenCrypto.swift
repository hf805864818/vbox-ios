//
//  ExtscreenCrypto.swift
//  vbox
//
//  PG extscreen 加密层 — 从 Python alitoken2.py 1:1 翻译
//  包含: h() 字符变换, MD5 密钥派生, AES-256-CBC 加解密, SHA256 签名
//

import Foundation
import CryptoKit
import CommonCrypto

// MARK: - extscreen 加密核心

/// extscreen API 加密工具
/// 对应 Python: AliyunPanTvToken 类的加密相关方法
struct ExtscreenCrypto {

    // 设备参数（固定值，与 PG Python 端一致）
    let akv = "2.6.1143"
    let apv = "1.4.0.2"
    let brand = "samsung"
    let model = "SM-S908E"

    // 运行时参数
    let timestamp: String       // 从 api.extscreen.com/timestamp 获取
    let uniqueId: String        // UUID hex（每次初始化生成）
    let wifiMac: String         // 随机12位数字

    // MARK: - 初始化

    init(timestamp: String, uniqueId: String? = nil, wifiMac: String? = nil) {
        self.timestamp = timestamp
        self.uniqueId = uniqueId ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        self.wifiMac = wifiMac ?? String(format: "%012d", Int.random(in: 100000000000...999999999999))
    }

    // MARK: - 参数字典

    /// 获取设备参数字典
    /// 对应 Python: get_params()
    func getParams() -> [String: String] {
        return [
            "akv": akv,
            "apv": apv,
            "b": brand,
            "d": uniqueId,
            "m": model,
            "mac": "",
            "n": model,
            "t": timestamp,
            "wifiMac": wifiMac,
        ]
    }

    // MARK: - h() 字符变换函数

    /// 自定义字符变换函数
    /// 对应 Python: h(char_array, modifier)
    ///
    /// - Parameters:
    ///   - input: 输入字符串（去重后的字符数组）
    ///   - modifier: 时间戳修饰符
    /// - Returns: 变换后的字符串
    func h(_ input: String, modifier: String) -> String {
        // 去重保持顺序（Python: list(dict.fromkeys(char_array))）
        var seen = Set<Character>()
        var uniqueChars: [Character] = []
        for char in input {
            if !seen.contains(char) {
                seen.insert(char)
                uniqueChars.append(char)
            }
        }

        // 从 modifier 提取数值部分（Python: modifier_str[7:] if len > 7 else '0'）
        let modifierStr = String(modifier)
        let numericModifierStr: String
        if modifierStr.count > 7 {
            numericModifierStr = String(modifierStr.dropFirst(7))
        } else {
            numericModifierStr = "0"
        }

        // 数值转换
        let numericModifier = Int(numericModifierStr) ?? 0
        let modVal = numericModifier % 127

        // 字符变换
        var result = ""
        for c in uniqueChars {
            let charCode = c.asciiValue ?? 0
            // abs(char_code - mod_val - 1)
            // 注意: Python 的 ord 返回 int，Swift 的 asciiValue 返回 UInt8
            // 需要处理为有符号运算
            var newCharCode = Int(charCode)
            newCharCode = abs(newCharCode - modVal - 1)
            if newCharCode < 33 {
                newCharCode += 33
            }
            if newCharCode > 0 && newCharCode < 256 {
                result.append(Character(UnicodeScalar(newCharCode)!))
            }
        }
        return result
    }

    // MARK: - 密钥生成

    /// 生成 AES 密钥（使用 self.timestamp）
    /// 对应 Python: generate_key()
    /// - Returns: MD5 hex 字符串（32字符），作为 AES-256 的 UTF-8 字节密钥
    func generateKey() -> String {
        return generateKey(withTimestamp: timestamp)
    }

    /// 使用指定时间戳生成 AES 密钥
    /// 对应 Python: generate_key_with_t(t)
    /// 用于解密服务端响应（响应中的 t 字段）
    func generateKey(withTimestamp t: String) -> String {
        var params = getParams()
        params["t"] = t

        // 按 key 排序，拼接所有值（排除 "t"）
        let sortedKeys = params.keys.sorted()
        let concatenatedParams = sortedKeys
            .filter { $0 != "t" }
            .compactMap { params[$0] }
            .joined()

        // h() 变换
        let hashedKey = h(concatenatedParams, modifier: t)

        // MD5 hex digest
        let hash = Insecure.MD5.hash(data: Data(hashedKey.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 随机 IV

    /// 生成 16 位随机 IV 字符串 [a-z0-9]
    /// 对应 Python: random_iv_str(length=16)
    func randomIV(length: Int = 16) -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        var result = ""
        for _ in 0..<length {
            if let randomChar = chars.randomElement() {
                result.append(randomChar)
            }
        }
        return result
    }

    // MARK: - AES-256-CBC 加密

    /// 加密 JSON 对象
    /// 对应 Python: encrypt(plain_obj)
    /// - Parameter plainObj: 要加密的字典
    /// - Returns: (iv 字符串, base64 密文)
    func encrypt(_ plainObj: [String: Any]) throws -> (iv: String, ciphertext: String) {
        // 1. 生成密钥
        let key = generateKey()
        let keyBytes = Array(key.utf8)  // 32字节 → AES-256

        // 2. 生成随机 IV
        let ivStr = randomIV()
        let ivBytes = Array(ivStr.utf8)  // 16字节

        // 3. JSON 序列化
        let jsonData = try JSONSerialization.data(
            withJSONObject: plainObj,
            options: [.sortedKeys]  // separators=(',', ':') 的等价
        )

        // 4. PKCS7 填充 + AES-CBC 加密
        let paddedData = pkcs7Pad(jsonData, blockSize: 16)
        let encrypted = try aesCBCEncrypt(
            data: paddedData,
            key: keyBytes,
            iv: ivBytes
        )

        // 5. Base64 编码
        let base64Ciphertext = Data(encrypted).base64EncodedString()

        return (ivStr, base64Ciphertext)
    }

    // MARK: - AES-256-CBC 解密

    /// 解密服务端响应
    /// 对应 Python: decrypt(ciphertext, iv, t=None)
    /// - Parameters:
    ///   - ciphertextBase64: Base64 编码的密文
    ///   - ivHex: 十六进制格式 IV（服务端返回）
    ///   - t: 服务端时间戳（用于重新生成密钥）
    /// - Returns: 解密后的 JSON 字符串
    func decrypt(ciphertextBase64: String, ivHex: String, t: String?) throws -> String {
        // 1. 生成密钥（如果有服务端时间戳则用该时间戳）
        let key = (t != nil) ? generateKey(withTimestamp: t!) : generateKey()
        let keyBytes = Array(key.utf8)

        // 2. IV 从 hex 转换（服务端返回的 IV 是 hex 格式）
        guard let ivBytes = hexToBytes(ivHex) else {
            throw ExtscreenError.invalidIVHex
        }

        // 3. Base64 解码密文
        guard let ciphertextData = Data(base64Encoded: ciphertextBase64) else {
            throw ExtscreenError.invalidBase64
        }

        // 4. AES-CBC 解密
        let decrypted = try aesCBCDecrypt(
            data: Array(ciphertextData),
            key: keyBytes,
            iv: ivBytes
        )

        // 5. PKCS7 去填充
        let unpadded = pkcs7Unpad(decrypted)

        // 6. 返回 UTF-8 字符串
        guard let result = String(data: unpadded, encoding: .utf8) else {
            throw ExtscreenError.invalidUTF8
        }

        return result
    }

    // MARK: - SHA256 签名

    /// 计算 SHA256 签名
    /// 对应 Python: compute_sign(method, api_path)
    /// - Parameters:
    ///   - method: HTTP 方法 ("POST" / "GET")
    ///   - apiPath: API 路径 (如 "/v4/token", "/v2/qrcode")
    /// - Returns: SHA256 hex 字符串
    func computeSign(method: String, apiPath: String) -> String {
        // Python: api_path = "/api" + api_path
        let fullApiPath = "/api" + apiPath
        let key = generateKey()

        // content = f"{method}-{api_path}-{timestamp}-{unique_id}-{key}"
        let content = "\(method)-\(fullApiPath)-\(timestamp)-\(uniqueId)-\(key)"

        // SHA256
        let hash = SHA256.hash(data: Data(content.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 请求头

    /// 构建 HTTP 请求头
    /// 对应 Python: get_headers(sign)
    func getHeaders(sign: String) -> [String: String] {
        return [
            "User-Agent": "Mozilla/5.0 (Linux; U; Android 15; zh-cn; SM-S908E Build/UKQ1.231108.001) AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1",
            "Host": "api.extscreen.com",
            "Content-Type": "application/json;",
            "akv": akv,
            "apv": apv,
            "b": brand,
            "d": uniqueId,
            "m": model,
            "n": model,
            "t": timestamp,
            "wifiMac": wifiMac,
            "sign": sign,
        ]
    }

    // MARK: - AES-CBC 原生实现

    /// AES-CBC 加密
    private func aesCBCEncrypt(data: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        var encryptedData = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var numEncrypted = 0

        let status = key.withUnsafeBufferPointer { keyPtr in
            iv.withUnsafeBufferPointer { ivPtr in
                data.withUnsafeBufferPointer { dataPtr in
                    encryptedData.withUnsafeMutableBufferPointer { outPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            0,
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, data.count,
                            outPtr.baseAddress, encryptedData.count,
                            &numEncrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw ExtscreenError.aesEncryptFailed(status: Int(status))
        }

        return Array(encryptedData.prefix(numEncrypted))
    }

    /// AES-CBC 解密
    private func aesCBCDecrypt(data: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        var decryptedData = [UInt8](repeating: 0, count: data.count + 16)
        var decryptedLength = 0

        let status = key.withUnsafeBufferPointer { keyPtr in
            iv.withUnsafeBufferPointer { ivPtr in
                data.withUnsafeBufferPointer { dataPtr in
                    decryptedData.withUnsafeMutableBufferPointer { outPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            0,  // CBC mode, no PKCS7 (we handle padding manually)
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, data.count,
                            outPtr.baseAddress, decryptedData.count,
                            &decryptedLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw ExtscreenError.aesDecryptFailed(status: Int(status))
        }

        return Array(decryptedData.prefix(decryptedLength))
    }

    // MARK: - PKCS7 填充

    /// PKCS7 填充
    private func pkcs7Pad(_ data: Data, blockSize: Int) -> [UInt8] {
        let bytes = Array(data)
        let padLength = blockSize - (bytes.count % blockSize)
        let padding = [UInt8](repeating: UInt8(padLength), count: padLength)
        return bytes + padding
    }

    /// PKCS7 去填充
    private func pkcs7Unpad(_ data: [UInt8]) -> Data {
        guard !data.isEmpty else { return Data() }
        let padLength = Int(data.last!)
        guard padLength > 0 && padLength <= 16 && padLength <= data.count else {
            return Data(data)
        }
        return Data(data.prefix(data.count - padLength))
    }

    // MARK: - 工具

    /// Hex 字符串转字节数组
    private func hexToBytes(_ hex: String) -> [UInt8]? {
        let len = hex.count
        guard len % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(len / 2)
        var index = hex.startIndex
        for _ in 0..<len/2 {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }
        return bytes
    }
}

// MARK: - 错误类型

enum ExtscreenError: Error, LocalizedError {
    case invalidIVHex
    case invalidBase64
    case invalidUTF8
    case aesEncryptFailed(status: Int)
    case aesDecryptFailed(status: Int)
    case apiError(code: Int, message: String)
    case timestampFailed
    case qrcodeFailed
    case pollingTimeout
    case tokenExchangeFailed
    case tokenRefreshFailed
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidIVHex: return "无效的 IV hex 格式"
        case .invalidBase64: return "无效的 Base64 编码"
        case .invalidUTF8: return "解密后数据不是有效的 UTF-8 字符串"
        case .aesEncryptFailed(let status): return "AES 加密失败 (状态码: \(status))"
        case .aesDecryptFailed(let status): return "AES 解密失败 (状态码: \(status))"
        case .apiError(let code, let message): return "extscreen API 错误 [\(code)]: \(message)"
        case .timestampFailed: return "获取 extscreen 时间戳失败"
        case .qrcodeFailed: return "生成二维码失败"
        case .pollingTimeout: return "扫码超时，请重试"
        case .tokenExchangeFailed: return "authCode 换取 token 失败"
        case .tokenRefreshFailed: return "token 刷新失败"
        case .networkError(let msg): return "网络错误: \(msg)"
        }
    }
}
