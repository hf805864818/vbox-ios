import Foundation
import Security

// MARK: - M115Error

enum M115Error: Error, LocalizedError {
    case invalidKey
    case encryptionFailed
    case decryptionFailed
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidKey: return "M115: 无效的 RSA 公钥"
        case .encryptionFailed: return "M115: RSA 加密失败"
        case .decryptionFailed: return "M115: RSA 解密失败"
        case .invalidResponse(let msg): return "M115: \(msg)"
        }
    }
}

// MARK: - M115Cipher

/// 115 网盘 m115 RSA 加解密器
///
/// 基于 fake115uploader cipher.go 移植，实现 115 专有的 RSA+XOR 加密方案。
/// 参考: https://github.com/orzogc/fake115uploader/blob/master/cipher/cipher.go
///
/// 使用流程（有状态）:
/// 1. 创建实例
/// 2. 调用 encrypt() 加密请求 → 内部生成 randKey 和 keyS
/// 3. 发送加密请求到 proapi.115.com/app/chrome/downurl
/// 4. 调用 decrypt() 解密响应 → 复用 step 2 的 keyS
final class M115Cipher {

    // MARK: - 常量（与 Go 源码完全一致）

    /// gKeyL: 12 字节 XOR 密钥，用于加密阶段
    private static let gKeyL: [UInt8] = [
        0x78, 0x06, 0xAD, 0x4C, 0x33, 0x86, 0x5D, 0x18,
        0x4C, 0x01, 0x3F, 0x46
    ]

    /// gKts: 136 字节密钥表，用于 genKey 生成派生密钥
    private static let gKts: [UInt8] = [
        0xF0, 0xE5, 0x69, 0xAE, 0xBF, 0xDC, 0xBF, 0x8A,
        0x1A, 0x45, 0xE8, 0xBE, 0x7D, 0xA6, 0x73, 0xB8,
        0xDE, 0x8F, 0xE7, 0xC4, 0x45, 0xDA, 0x86, 0xC4,
        0x9B, 0x64, 0x8B, 0x14, 0x6A, 0xB4, 0xF1, 0xAA,
        0x38, 0x01, 0x35, 0x9E, 0x26, 0x69, 0x2C, 0x86,
        0x00, 0x6B, 0x4F, 0xA5, 0x36, 0x34, 0x62, 0xA6,
        0x2A, 0x96, 0x68, 0x18, 0xF2, 0x4A, 0xFD, 0xBD,
        0x6B, 0x97, 0x8F, 0x4D, 0x8F, 0x89, 0x13, 0xB7,
        0x6C, 0x8E, 0x93, 0xED, 0x0E, 0x0D, 0x48, 0x3E,
        0xD7, 0x2F, 0x88, 0xD8, 0xFE, 0xFE, 0x7E, 0x86,
        0x50, 0x95, 0x4F, 0xD1, 0xEB, 0x83, 0x26, 0x34,
        0xDB, 0x66, 0x7B, 0x9C, 0x7E, 0x9D, 0x7A, 0x81,
        0x32, 0xEA, 0xB6, 0x33, 0xDE, 0x3A, 0xA9, 0x59,
        0x34, 0x66, 0x3B, 0xAA, 0xBA, 0x81, 0x60, 0x48,
        0xB9, 0xD5, 0x81, 0x9C, 0xF8, 0x6C, 0x84, 0x77,
        0xFF, 0x54, 0x78, 0x26, 0x5F, 0xBE, 0xE8, 0x1E,
        0x36, 0x9F, 0x34, 0x80, 0x5C, 0x45, 0x2C, 0x9B,
        0x76, 0xD5, 0x1B, 0x8F, 0xCC, 0xC3, 0xB8, 0xF5
    ]

    /// RSA 公钥 PEM（1024-bit，与 fake115uploader 一致）
    private static let publicKeyPEM = """
-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCGhpgMD1okxLnUMCDNLCJwP/P0
UHVlKQWLHPiPCbhgITZHcZim4mgxSWWb0SLDNZL9ta1HlErR6k02xrFyqtYzjDu2
rGInUC0BCZOsln0a7wDwyOA43i5NO8LsNory6fEKbx7aT3Ji8TZCDAfDMbhxvxOf
dPMBDjxP5X3zr7cWgwIDAQAB
-----END PUBLIC KEY-----
"""

    private static let rsaKeySize = 16       // randKey 字节数
    private static let rsaBlockSize = 128    // RSA 块大小（1024 bit / 8）

    // MARK: - 运行时状态（有状态：encrypt 后 decrypt 复用）

    private let secKey: SecKey
    private let modulusN: RSABigInt
    private let exponentE: UInt32
    private var randKey: [UInt8] = []
    private var keyS: [UInt8] = []

    // MARK: - 初始化

    init() throws {
        // 解析 PEM 公钥
        let base64String = Self.publicKeyPEM
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let keyData = Data(base64Encoded: base64String) else {
            throw M115Error.invalidKey
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 1024
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            keyData as CFData,
            attributes as CFDictionary,
            &error
        ) else {
            throw M115Error.invalidKey
        }
        self.secKey = key

        // 从 PKCS1 外部表示提取 N 和 E（用于解密时的原始 RSA 运算）
        guard let externalData = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw M115Error.invalidKey
        }
        let (n, e) = try Self.parseRSAPublicKey(externalData)
        self.modulusN = n
        self.exponentE = e

        print("[M115] 初始化成功，N=\(n.bigEndianBytes().count) 字节, E=\(e)")
    }

    // MARK: - 加密

    /// 加密明文（对应 Go: RsaCipher.Encrypt）
    ///
    /// 流程:
    /// 1. 生成 16 字节随机 randKey
    /// 2. 生成 keyS = genKey(randKey, 4)
    /// 3. tmp = xor(plaintext, keyS)
    /// 4. 反转 tmp
    /// 5. xorText = randKey + xor(reversed_tmp, gKeyL)
    /// 6. RSA PKCS1v15 加密
    /// 7. Base64 编码
    func encrypt(_ plainText: [UInt8]) throws -> String {
        // 1. 生成随机密钥
        randKey = (0..<Self.rsaKeySize).map { _ in UInt8.random(in: 0...255) }
        keyS = Self.genKey(randKey, 4)

        // 2. XOR 明文
        var tmp = Self.xor(plainText, keyS)

        // 3. 反转
        tmp.reverse()

        // 4. 拼接 randKey + xor(reversed, gKeyL)
        var xorText = randKey
        xorText.append(contentsOf: Self.xor(tmp, Self.gKeyL))

        // 5. RSA PKCS1v15 加密
        var error: Unmanaged<CFError>?
        guard let cipherData = SecKeyCreateEncryptedData(
            secKey,
            .rsaEncryptionPKCS1,
            Data(xorText) as CFData,
            &error
        ) as Data? else {
            print("[M115] 加密失败: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            throw M115Error.encryptionFailed
        }

        // 6. Base64
        return cipherData.base64EncodedString()
    }

    // MARK: - 解密

    /// 解密密文（对应 Go: RsaCipher.Decrypt）
    ///
    /// 流程:
    /// 1. Base64 解码
    /// 2. 对每个 128 字节块做原始 RSA: m = n^e mod N
    /// 3. 去除 PKCS1 填充（找 0x00 分隔符）
    /// 4. 提取 randKey（前 16 字节）
    /// 5. keyL = genKey(randKey, 12)
    /// 6. tmp = xor(data, keyL)
    /// 7. 反转 tmp
    /// 8. result = xor(tmp, keyS)  ← 复用 encrypt 时生成的 keyS
    func decrypt(_ cipherTextBase64: String) throws -> [UInt8] {
        // 1. Base64 解码
        guard let cipherData = Data(base64Encoded: cipherTextBase64) else {
            throw M115Error.decryptionFailed
        }
        let text = [UInt8](cipherData)
        let blockCount = text.count / Self.rsaBlockSize

        print("[M115] 解密: \(text.count) 字节, \(blockCount) 块")

        // 2. 逐块原始 RSA 解密
        var plainText: [UInt8] = []
        for i in 0..<blockCount {
            let block = Array(text[i * Self.rsaBlockSize..<(i + 1) * Self.rsaBlockSize])
            let n = RSABigInt(bigEndianBytes: block)
            let m = n.powMod(exponentE, modulusN)
            let mBytes = m.bigEndianBytes()

            // 3. 查找 0x00 分隔符（PKCS1 v1.5: 0x00 0x02 ... 0x00 message）
            guard let sepIndex = mBytes.firstIndex(of: 0x00) else {
                print("[M115] 块 \(i): 未找到 0x00 分隔符, bytes=\(mBytes.prefix(16).map { String(format: "%02x", $0) }.joined())")
                throw M115Error.decryptionFailed
            }
            plainText.append(contentsOf: mBytes[(sepIndex + 1)...])
        }

        // 4. 提取 randKey
        guard plainText.count >= Self.rsaKeySize else {
            throw M115Error.decryptionFailed
        }
        let extractedRandKey = Array(plainText[0..<Self.rsaKeySize])
        plainText = Array(plainText[Self.rsaKeySize...])

        // 5. 生成 keyL 并 XOR
        let keyL = Self.genKey(extractedRandKey, 12)
        var tmp = Self.xor(plainText, keyL)

        // 6. 反转
        tmp.reverse()

        // 7. XOR with keyS（复用 encrypt 时生成的）
        let result = Self.xor(tmp, keyS)

        return result
    }

    // MARK: - 辅助函数（与 Go 源码逐行对齐）

    /// 生成派生密钥（对应 Go: genKey）
    ///
    /// - Parameters:
    ///   - randKey: 随机密钥
    ///   - keyLen: 输出密钥长度（加密=4, 解密=12）
    private static func genKey(_ randKey: [UInt8], _ keyLen: Int) -> [UInt8] {
        var xorKey: [UInt8] = []
        var length = keyLen * (keyLen - 1)
        var index = 0

        for i in 0..<keyLen {
            // Go: x = byte(uint8(randKey[i]) + uint8(gKts[index]))
            let x = randKey[i] &+ gKts[index]
            // Go: xorKey = append(xorKey, gKts[length]^x)
            xorKey.append(gKts[length] ^ x)
            length -= keyLen
            index += keyLen
        }
        return xorKey
    }

    /// XOR 操作（对应 Go: xor）
    ///
    /// 特殊处理: 先处理 src 长度 % 4 的余数部分，再循环 key
    private static func xor(_ src: [UInt8], _ key: [UInt8]) -> [UInt8] {
        var secret: [UInt8] = []
        let pad = src.count % 4

        // 处理头部余数
        if pad > 0 {
            for i in 0..<pad {
                secret.append(src[i] ^ key[i])
            }
        }

        // 处理剩余部分（循环 key）
        let remaining = Array(src[pad...])
        let keyLen = key.count
        var num = 0

        for s in remaining {
            if num >= keyLen {
                num = num % keyLen
            }
            secret.append(s ^ key[num])
            num += 1
        }

        return secret
    }

    /// 解析 RSA 公钥 ASN.1，提取模数 N 和指数 E
    private static func parseRSAPublicKey(_ data: Data) throws -> (RSABigInt, UInt32) {
        var offset = 0

        func readByte() -> UInt8? {
            guard offset < data.count else { return nil }
            let b = data[offset]; offset += 1; return b
        }

        func readLength() -> Int? {
            guard let first = readByte() else { return nil }
            if first < 0x80 { return Int(first) }
            let numBytes = Int(first & 0x7F)
            var length = 0
            for _ in 0..<numBytes {
                guard let b = readByte() else { return nil }
                length = (length << 8) | Int(b)
            }
            return length
        }

        func readInteger() -> [UInt8]? {
            guard readByte() == 0x02 else { return nil }  // INTEGER tag
            guard let length = readLength() else { return nil }
            guard offset + length <= data.count else { return nil }
            let bytes = Array(data[offset..<(offset + length)])
            offset += length
            // 去除 ASN.1 正数前导 0x00
            var stripped = bytes
            while stripped.count > 1 && stripped[0] == 0 { stripped.removeFirst() }
            return stripped
        }

        // SEQUENCE
        guard readByte() == 0x30 else { throw M115Error.invalidKey }
        _ = readLength()

        // INTEGER (modulus N)
        guard let nBytes = readInteger() else { throw M115Error.invalidKey }
        let n = RSABigInt(bigEndianBytes: nBytes)

        // INTEGER (exponent E)
        guard let eBytes = readInteger() else { throw M115Error.invalidKey }
        var e: UInt32 = 0
        for b in eBytes { e = (e << 8) | UInt32(b) }

        return (n, e)
    }
}

// MARK: - RSABigInt（简易大整数，用于原始 RSA 运算）

/// 1024-bit 大整数，用于 RSA 解密时的原始模幂运算 (n^e mod N)
///
/// Security framework 的 SecKeyCreateDecryptedData 不支持原始 RSA
/// （115 服务端用私钥"签名"响应，客户端用公钥做 n^e mod N "验签"），
/// 因此需要自行实现模幂运算。
///
/// 使用 [UInt32] 小端序字表示，乘法用 UInt64 中间结果。
struct RSABigInt {
    var words: [UInt32]

    init(words: [UInt32]) {
        self.words = words
        normalize()
    }

    init(bigEndianBytes: [UInt8]) {
        var bytes = bigEndianBytes
        while bytes.count % 4 != 0 { bytes.insert(0, at: 0) }
        words = stride(from: bytes.count - 4, through: 0, by: -4).map { i in
            UInt32(bytes[i]) << 24
                | UInt32(bytes[i + 1]) << 16
                | UInt32(bytes[i + 2]) << 8
                | UInt32(bytes[i + 3])
        }
        normalize()
    }

    func bigEndianBytes() -> [UInt8] {
        var result: [UInt8] = []
        for word in words.reversed() {
            result.append(UInt8(word >> 24))
            result.append(UInt8(word >> 16))
            result.append(UInt8(word >> 8))
            result.append(UInt8(word))
        }
        while result.count > 1 && result[0] == 0 { result.removeFirst() }
        return result
    }

    private mutating func normalize() {
        while words.count > 1 && words.last == 0 { words.removeLast() }
    }

    // MARK: - 比较

    func compare(_ other: RSABigInt) -> Int {
        let maxLen = max(words.count, other.words.count)
        for i in (0..<maxLen).reversed() {
            let a = i < words.count ? words[i] : UInt32(0)
            let b = i < other.words.count ? other.words[i] : UInt32(0)
            if a < b { return -1 }
            if a > b { return 1 }
        }
        return 0
    }

    // MARK: - 减法（假设 self >= other）

    func subtracting(_ other: RSABigInt) -> RSABigInt {
        var result = words
        var borrow: UInt32 = 0
        for i in 0..<max(result.count, other.words.count) {
            let a = i < result.count ? result[i] : UInt32(0)
            let b = i < other.words.count ? other.words[i] : UInt32(0)
            let (diff, overflow1) = a.subtractingReportingOverflow(b)
            let (diff2, overflow2) = diff.subtractingReportingOverflow(borrow)
            if i < result.count {
                result[i] = diff2
            } else {
                result.append(diff2)
            }
            borrow = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        return RSABigInt(words: result)
    }

    // MARK: - 乘法（Schoolbook）

    func multiply(_ other: RSABigInt) -> RSABigInt {
        let aLen = words.count
        let bLen = other.words.count
        var result = [UInt32](repeating: 0, count: aLen + bLen)

        for i in 0..<aLen {
            var carry: UInt64 = 0
            let ai = UInt64(words[i])
            for j in 0..<bLen {
                let product = ai * UInt64(other.words[j])
                    &+ UInt64(result[i + j])
                    &+ carry
                result[i + j] = UInt32(product & 0xFFFF_FFFF)
                carry = product >> 32
            }
            // 传播进位
            var k = i + bLen
            while carry > 0 && k < result.count {
                let sum = UInt64(result[k]) &+ carry
                result[k] = UInt32(sum & 0xFFFF_FFFF)
                carry = sum >> 32
                k += 1
            }
        }
        return RSABigInt(words: result)
    }

    // MARK: - 取模（逐位长除法）

    func mod(_ modulus: RSABigInt) -> RSABigInt {
        var remainder = RSABigInt(words: [0])
        let totalBits = bitCount()

        for i in (0..<totalBits).reversed() {
            // remainder 左移 1 位
            remainder = remainder.shiftedLeftBy1()

            // 设置最低位为 self 的当前位
            if bit(at: i) {
                if remainder.words.isEmpty {
                    remainder.words = [1]
                } else {
                    remainder.words[0] |= 1
                }
            }

            // 如果 remainder >= modulus，减去 modulus
            if remainder.compare(modulus) >= 0 {
                remainder = remainder.subtracting(modulus)
            }
        }
        return remainder
    }

    /// 模幂运算: self^exp mod modulus（平方乘法）
    func powMod(_ exp: UInt32, _ modulus: RSABigInt) -> RSABigInt {
        var result = RSABigInt(words: [1])
        var base = self.mod(modulus)
        var e = exp

        while e > 0 {
            if e & 1 == 1 {
                result = result.multiply(base).mod(modulus)
            }
            base = base.multiply(base).mod(modulus)
            e >>= 1
        }
        return result
    }

    // MARK: - 位操作

    /// 左移 1 位
    func shiftedLeftBy1() -> RSABigInt {
        var result = words
        var carry: UInt32 = 0
        for i in 0..<result.count {
            let newCarry = result[i] >> 31
            result[i] = (result[i] << 1) | carry
            carry = newCarry
        }
        if carry > 0 { result.append(carry) }
        return RSABigInt(words: result)
    }

    /// 获取指定位（0 = 最低位）
    func bit(at position: Int) -> Bool {
        let wordIdx = position / 32
        let bitIdx = position % 32
        guard wordIdx < words.count else { return false }
        return (words[wordIdx] >> bitIdx) & 1 == 1
    }

    /// 总位数
    func bitCount() -> Int {
        guard let lastWord = words.last, lastWord != 0 else { return 0 }
        return (words.count - 1) * 32 + (32 - lastWord.leadingZeroBitCount)
    }
}
