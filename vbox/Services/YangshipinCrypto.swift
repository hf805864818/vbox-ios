import Foundation

// MARK: - 央视频加密工具

/// 央视频 API 加密/解密、签名、CKey 生成工具
enum YangshipinCrypto {

    // MARK: - 常量

    private static let delta: UInt32 = 0x9e3779b9
    private static let rounds = 16
    private static let logRounds = 4
    private static let saltLen = 2
    private static let zeroLen = 7

    /// TEA 加密密钥 (CKey)
    private static let teaCKey: [UInt8] = [
        0x59, 0xb2, 0xf7, 0xcf, 0x72, 0x5e, 0xf4, 0x3c,
        0x34, 0xfd, 0xd7, 0xc1, 0x23, 0x41, 0x1e, 0xd3
    ]

    /// Guard TEA 密钥
    private static let guardTeaKey: [UInt8] = [
        0x11, 0x0d, 0xbe, 0xc1, 0x0c, 0x23, 0xe7, 0xd2,
        0xe5, 0x6a, 0x1c, 0xad, 0x69, 0x14, 0xef, 0x1b
    ]

    /// XOR 密钥 (16 字节)
    private static let xorKey: [UInt8] = [
        0x84, 0x2e, 0xed, 0x08, 0xf0, 0x66, 0xe6, 0xea,
        0x48, 0xb4, 0xca, 0xa9, 0x91, 0xed, 0x6f, 0xf3
    ]

    /// Guard XOR 密钥 (8 字节)
    private static let guardXorKey: [UInt8] = [
        0xb3, 0xc9, 0x53, 0xa0, 0x69, 0x13, 0xad, 0x4d
    ]

    private static let standardAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
    private static let customAlphabet  = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-="

    // MARK: - TEA 加密/解密

    /// TEA 加密（8 字节块）
    private static func teaEncrypt(_ data: Data, key: [UInt8]) -> Data {
        var d = data
        if d.count < 8 {
            d.append(contentsOf: [UInt8](repeating: 0, count: 8 - d.count))
        }

        var y = UInt32(bigEndian: d.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) })
        var z = UInt32(bigEndian: d.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) })

        let k: [UInt32] = [
            key.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }.bigEndian,
            key.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }.bigEndian,
            key.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }.bigEndian,
            key.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }.bigEndian
        ]

        var s: UInt32 = 0
        for _ in 0..<rounds {
            s = s &+ delta
            y = y &+ (((z << 4) &+ k[0]) ^ (z &+ s) ^ ((z >> 5) &+ k[1]))
            z = z &+ (((y << 4) &+ k[2]) ^ (y &+ s) ^ ((y >> 5) &+ k[3]))
        }

        var result = Data()
        result.append(contentsOf: withUnsafeBytes(of: y.bigEndian) { Array($0) })
        result.append(contentsOf: withUnsafeBytes(of: z.bigEndian) { Array($0) })
        return result
    }

    /// TEA 解密（8 字节块）
    private static func teaDecrypt(_ data: Data, key: [UInt8]) -> Data {
        var y = UInt32(bigEndian: data.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) })
        var z = UInt32(bigEndian: data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) })

        let k: [UInt32] = [
            key.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }.bigEndian,
            key.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }.bigEndian,
            key.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }.bigEndian,
            key.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }.bigEndian
        ]

        var s = (delta << UInt32(logRounds)) & 0xffffffff
        for _ in 0..<rounds {
            z = z &- (((y << 4) &+ k[2]) ^ (y &+ s) ^ ((y >> 5) &+ k[3]))
            y = y &- (((z << 4) &+ k[0]) ^ (z &+ s) ^ ((z >> 5) &+ k[1]))
            s = s &- delta
        }

        var result = Data()
        result.append(contentsOf: withUnsafeBytes(of: y.bigEndian) { Array($0) })
        result.append(contentsOf: withUnsafeBytes(of: z.bigEndian) { Array($0) })
        return result
    }

    // MARK: - CBC 加密

    static func cbcEncrypt(_ plain: Data, key: [UInt8]) -> Data {
        let nLen = plain.count
        let padSaltZero = nLen + 1 + saltLen + zeroLen
        var nPad = padSaltZero % 8
        if nPad > 0 { nPad = 8 - nPad }

        var out = Data()
        var src = [UInt8](repeating: 0, count: 8)
        src[0] = UInt8((Int.random(in: 0...255) & 0xf8) | nPad)
        var si = 1

        var remainingPad = nPad
        while remainingPad > 0 {
            src[si] = UInt8.random(in: 0...255)
            si += 1
            remainingPad -= 1
        }

        var ivP = [UInt8](repeating: 0, count: 8)
        var ivC = [UInt8](repeating: 0, count: 8)

        // salt
        var i = 0
        while i < saltLen {
            if si < 8 {
                src[si] = UInt8.random(in: 0...255)
                si += 1
                i += 1
            }
            if si == 8 {
                for j in 0..<8 { src[j] ^= ivC[j] }
                let tb = Array(teaEncrypt(Data(src), key: key))
                for j in 0..<8 { src[j] = tb[j] ^ ivP[j] }
                ivP = Array(src)
                ivC = tb
                out.append(contentsOf: tb)
                si = 0
            }
        }

        // body
        var pi = 0
        var remaining = nLen
        while remaining > 0 {
            if si < 8 {
                src[si] = plain[pi]
                pi += 1
                si += 1
                remaining -= 1
            }
            if si == 8 {
                for j in 0..<8 { src[j] ^= ivC[j] }
                let tb = Array(teaEncrypt(Data(src), key: key))
                for j in 0..<8 { src[j] = tb[j] ^ ivP[j] }
                ivP = Array(src)
                ivC = tb
                out.append(contentsOf: tb)
                si = 0
            }
        }

        // zero
        i = 0
        while i < zeroLen {
            if si < 8 {
                src[si] = 0
                si += 1
                i += 1
            }
            if si == 8 {
                for j in 0..<8 { src[j] ^= ivC[j] }
                let tb = Array(teaEncrypt(Data(src), key: key))
                for j in 0..<8 { src[j] = tb[j] ^ ivP[j] }
                ivP = Array(src)
                ivC = tb
                out.append(contentsOf: tb)
                si = 0
            }
        }

        // last
        if si > 0 {
            for j in si..<8 { src[j] = 0 }
            for j in 0..<8 { src[j] ^= ivC[j] }
            let tb = Array(teaEncrypt(Data(src), key: key))
            for j in 0..<8 { src[j] = tb[j] ^ ivP[j] }
            out.append(contentsOf: tb)
        }

        return out
    }

    // MARK: - 自定义 Base64

    private static func base64Encode(_ data: Data) -> String {
        let std = data.base64EncodedString()
        var result = ""
        for ch in std {
            if let idx = standardAlphabet.firstIndex(of: ch) {
                let customIdx = customAlphabet.index(customAlphabet.startIndex, offsetBy: standardAlphabet.distance(from: standardAlphabet.startIndex, to: idx))
                result.append(customAlphabet[customIdx])
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    // MARK: - XOR

    private static func xor(_ data: [UInt8], key: [UInt8] = xorKey) -> [UInt8] {
        return data.enumerated().map { $0.element ^ key[$0.offset & (key.count - 1)] }
    }

    // MARK: - 签名计算

    static func calcSig(_ buf: [UInt8]) -> UInt32 {
        var s: UInt32 = 0
        for b in buf {
            s = (0x83 &* s &+ UInt32(b & 0xff)) & 0x7fffffff
        }
        return s
    }

    // MARK: - GUID 生成

    static func genGUID() -> String {
        return String(format: "%08x%04x%04x%04x%012x",
                      UInt32.random(in: 0...0xffffffff),
                      UInt32.random(in: 0...0xffff),
                      UInt32.random(in: 0...0xffff),
                      UInt32.random(in: 0...0xffff),
                      UInt64.random(in: 0...0xffffffffffff))
    }

    // MARK: - FlowID 生成

    static func genFlowID() -> String {
        let p: [UInt16] = [
            UInt16.random(in: 0...0xffff),
            UInt16.random(in: 0...0xffff),
            UInt16.random(in: 0...0xffff),
            UInt16.random(in: 0...0xfff) | 0x4000,
            UInt16.random(in: 0...0x3fff) | 0x8000,
            UInt16.random(in: 0...0xffff),
            UInt16.random(in: 0...0xffff),
            UInt16.random(in: 0...0xffff)
        ]
        return String(format: "%04X%04X-%04X-%04X-%04X-%04X%04X%04X_4330403",
                      p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7])
    }

    // MARK: - Guard Time 生成

    private static func last5(_ v: Any) -> String {
        let str = "\(v)"
        if str.count >= 5 {
            return String(str.suffix(5))
        }
        return ""
    }

    static func genGuardTime(ts: Int, guid: String) -> String {
        var body = Data()
        // timestamp (uint32 big-endian)
        var tsBE = UInt32(ts).bigEndian
        body.append(Data(bytes: &tsBE, count: 4))

        // 附加字段
        let parts: [(String, String)] = [
            (last5(guid), guid),
            (last5("null"), "null"),
            (last5("null"), "null"),
            ("-1", "-1")
        ]
        for (_, val) in parts {
            let pb = val.data(using: .utf8)!
            var len = UInt16(pb.count).bigEndian
            body.append(Data(bytes: &len, count: 2))
            body.append(pb)
        }

        // 前导长度
        var plain = Data()
        var bodyLen = UInt16(body.count).bigEndian
        plain.append(Data(bytes: &bodyLen, count: 2))
        plain.append(body)

        let chk = calcSig(Array(plain))

        var enc = cbcEncrypt(plain, key: guardTeaKey)
        var chkBE = chk.bigEndian
        enc.append(Data(bytes: &chkBE, count: 4))

        var el = Array(enc)
        for i in 0..<el.count {
            el[i] ^= guardXorKey[i & 7]
        }

        return el.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - CKey 加密

    private static func encryptCKey(_ data: Data) -> String {
        let chk = calcSig(Array(data))
        var enc = cbcEncrypt(data, key: teaCKey)
        var chkBE = chk.bigEndian
        enc.append(Data(bytes: &chkBE, count: 4))
        return "--01" + base64Encode(Data(xor(Array(enc))))
    }

    // MARK: - 构建 CKey 数据包

    private static func buildCKeyPacket(params: [String: Any]) -> Data {
        let platform = params["Platform"] as! Int
        let timestamp = params["Timestamp"] as! Int
        let sdtfrom = (params["Sdtfrom"] as! String).data(using: .utf8)!
        let randFlag = (params["randFlag"] as! String).data(using: .utf8)!
        let appVer = (params["appVer"] as! String).data(using: .utf8)!
        let vid = (params["vid"] as! String).data(using: .utf8)!
        let guid = (params["guid"] as! String).data(using: .utf8)!
        let uuid4 = (params["uuid4"] as! String).data(using: .utf8)!
        let ckGuardTime = (params["ck_guard_time"] as! String).data(using: .utf8)!

        var d = Data()

        // 12-byte header
        d.append(contentsOf: [0x00, 0x00, 0x00, 0x42, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x04, 0xd2])

        // Platform
        var platformBE = UInt32(platform).bigEndian
        d.append(Data(bytes: &platformBE, count: 4))

        // sig placeholder (will be filled later)
        var sigPlaceholder = UInt32(0).bigEndian
        d.append(Data(bytes: &sigPlaceholder, count: 4))

        // Timestamp
        var timestampBE = UInt32(timestamp).bigEndian
        d.append(Data(bytes: &timestampBE, count: 4))

        // String fields (length-prefixed)
        for v in [sdtfrom, randFlag, appVer, vid, guid] {
            var len = UInt16(v.count).bigEndian
            d.append(Data(bytes: &len, count: 2))
            d.append(v)
        }

        // part1 = 1
        var part1 = UInt32(1).bigEndian
        d.append(Data(bytes: &part1, count: 4))

        // isDlna = 1
        var isDlna = UInt32(1).bigEndian
        d.append(Data(bytes: &isDlna, count: 4))

        // "2622783A"
        let hexStr = "2622783A".data(using: .utf8)!
        var hexLen = UInt16(hexStr.count).bigEndian
        d.append(Data(bytes: &hexLen, count: 2))
        d.append(hexStr)

        // "nil"
        let nilStr = "nil".data(using: .utf8)!
        var nilLen = UInt16(nilStr.count).bigEndian
        d.append(Data(bytes: &nilLen, count: 2))
        d.append(nilStr)

        // uuid4
        var uuidLen = UInt16(uuid4.count).bigEndian
        d.append(Data(bytes: &uuidLen, count: 2))
        d.append(uuid4)

        // bundleID = "nil"
        var bundleLen = UInt16(3).bigEndian
        d.append(Data(bytes: &bundleLen, count: 2))
        d.append("nil".data(using: .utf8)!)

        // 固定字符串
        let fixedStrings = ["v0.1.000", "com.cctv.yangshipin.app.iphone", "4330403", "ex_json_bus", "ex_json_vs"]
        for s in fixedStrings {
            let sd = s.data(using: .utf8)!
            var slen = UInt16(sd.count).bigEndian
            d.append(Data(bytes: &slen, count: 2))
            d.append(sd)
        }

        // ck_guard_time
        var cgtLen = UInt16(ckGuardTime.count).bigEndian
        d.append(Data(bytes: &cgtLen, count: 2))
        d.append(ckGuardTime)

        // 前导长度
        var buf = Data()
        var totalLen = UInt16(d.count).bigEndian
        buf.append(Data(bytes: &totalLen, count: 2))
        buf.append(d)

        // 计算签名
        let sig = calcSig(Array(buf))
        var sigBE = sig.bigEndian

        // 替换签名占位 (offset 18 = 2 (length) + 12 (header) + 4 (platform))
        var result = buf
        result.replaceSubrange(18..<22, with: Data(bytes: &sigBE, count: 4))

        return result
    }

    // MARK: - 生成 CKey

    /// 生成 CKey 参数
    /// - Parameters:
    ///   - cnlid: 频道 ID
    ///   - guid: GUID
    /// - Returns: (ckey: String, timestamp: Int)
    static func genCKey(cnlid: String, guid: String) -> (ckey: String, timestamp: Int) {
        let ts = Int(Date().timeIntervalSince1970)
        let cgt = genGuardTime(ts: ts, guid: guid)

        let params: [String: Any] = [
            "Platform": 4330403,
            "Timestamp": ts,
            "Sdtfrom": "dcgh",
            "vid": cnlid,
            "guid": guid,
            "appVer": "V8.22.1035.3031",
            "randFlag": "_zj1A5Gh6QYcxWjIUGos2w==",
            "uuid4": "57eab0c4-2c58-44c6-8ae9-dd2757525dc5",
            "ck_guard_time": cgt
        ]

        let pkt = buildCKeyPacket(params: params)
        let ckey = encryptCKey(pkt)

        return (ckey: ckey, timestamp: ts)
    }
}