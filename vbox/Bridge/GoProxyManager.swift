import Foundation

// MARK: - Go HTTP/2 代理引擎桥接层
//
// 封装 gomobile 生成的 Quarkproxy.xcframework
// 依赖：Quarkproxy.xcframework（由 go-proxy/ 目录用 gomobile bind 生成）
//
// 使用方式：
//   1. App 启动时调用 GoProxyManager.shared.start()
//   2. 夸克播放时调用 GoProxyManager.shared.registerQuarkStream(...)
//   3. 获取返回的本地代理 URL 传给播放器
//   4. 调试用：GoProxyManager.shared.getDebugLogs() / getStats()

#if canImport(Quarkproxy)
import Quarkproxy
#endif

final class GoProxyManager: ObservableObject {
    static let shared = GoProxyManager()

    /// 代理端口（与 iBox 对齐使用 10078）
    private let port: Int = 10078

    @Published private(set) var isRunning = false
    @Published private(set) var statusInfo: String = "stopped"

    private init() {}

    // MARK: - 生命周期

    /// 启动 Go HTTP/2 代理服务器
    /// 在 AppDelegate.didFinishLaunching 或 App.init 中调用
    func start() {
        guard !isRunning else { return }
        startOnPort(port)
    }

    /// 停止代理服务器
    func stop() {
        #if canImport(Quarkproxy)
        _ = QuarkproxyStopProxy()
        #endif
        isRunning = false
        statusInfo = "stopped"
    }

    private func startOnPort(_ p: Int) {
        #if canImport(Quarkproxy)
        let result = QuarkproxyStartProxy(p)
        if result.hasPrefix("ok") {
            isRunning = true
            statusInfo = result
            print("[GoProxy] ✅ \(result)")
        } else {
            // 尝试备用端口
            tryFallbackPorts()
        }
        #else
        print("[GoProxy] ⚠️ 未集成框架，降级直链")
        #endif
    }

    private func tryFallbackPorts() {
        let fallbacks = [10079, 18080, 18082, 19090]
        for p in fallbacks {
            #if canImport(Quarkproxy)
            let result = QuarkproxyStartProxy(p)
            if result.hasPrefix("ok") {
                isRunning = true
                statusInfo = result
                print("[GoProxy] ✅ 备用端口: \(result)")
                return
            }
            #endif
        }
        print("[GoProxy] ❌ 所有端口启动失败")
    }

    // MARK: - 夸克播放注册

    /// 注册夸克播放流，返回本地代理 URL
    /// - Parameters:
    ///   - upstreamURL: 夸克返回的 m3u8 或 download_url
    ///   - cookie: 含 Video-Auth 的完整 Cookie
    ///   - deviceID: 设备 ID（可选）
    ///   - source: 流类型标记（"v2-play-m3u8" 或 "download_url"），用于上层区分解码器
    /// - Returns: 代理地址；代理未运行时返回原始 URL（降级直链）
    func registerQuarkStream(upstreamURL: String,
                               cookie: String,
                               deviceID: String? = nil,
                               source: String = "") -> String {
        guard isRunning else { return upstreamURL }

        var headers: [String: String] = [
            "Cookie": cookie,
            "User-Agent": quarkDesktopUA,
            "Referer": "https://pan.quark.cn/",
            "Origin": "https://pan.quark.cn",
            "Accept": "*/*",
            "Accept-Encoding": "br, gzip, deflate",
        ]
        if let did = deviceID, !did.isEmpty {
            headers["X-Device-Id"] = did
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: headers),
              let headersJSON = String(data: jsonData, encoding: .utf8) else {
            return upstreamURL
        }

        #if canImport(Quarkproxy)
        let proxyURL = QuarkproxyRegisterStream(upstreamURL, headersJSON)

        if proxyURL.hasPrefix("http://127.0.0.1") {
            let fmtPrefix: String
            if source == "v2-play-m3u8" {
                fmtPrefix = "quark-m3u8"
            } else {
                fmtPrefix = "quark-stream"
            }
            let markedURL = proxyURL.replacingOccurrences(of: "/play?", with: "/\(fmtPrefix)/play?")
            print("[GoProxy] ✅ 注册: \(markedURL)")
            return markedURL
        } else {
            print("[GoProxy] ❌ 注册失败: \(proxyURL)")
            return upstreamURL
        }
        #else
        return upstreamURL
        #endif
    }

    // MARK: - 状态与缓存

    func queryStatus() -> String {
        #if canImport(Quarkproxy)
        return QuarkproxyProxyStatus()
        #else
        return "framework not integrated"
        #endif
    }

    func clearCache() {
        #if canImport(Quarkproxy)
        _ = QuarkproxyClearCache()
        #endif
    }

    // ===== 诊断接口（新增）=====

    /// 获取 Go 代理的调试日志（JSON 数组字符串）
    /// 每条格式: {"ts":"14:32:46.123","msg":"seg HIT(prefetch) ...video.ts bytes=123456 ms=15"}
    func getDebugLogs() -> String {
        #if canImport(Quarkproxy)
        return QuarkproxyGetDebugLogs()
        #else
        return "[]"
        #endif
    }

    /// 获取 Go 代理的统计信息（JSON 字符串）
    /// 包含: seg_total, seg_prefetch_hit, seg_disk_hit, seg_upstream,
    ///       upstream_avg_ms, upstream_max_ms, upstream_total_mb,
    ///       prefetch_attempts, prefetch_success, prefetch_fail
    func getStats() -> String {
        #if canImport(Quarkproxy)
        return QuarkproxyGetStats()
        #else
        return "{}"
        #endif
    }

    /// 重置 Go 代理的日志缓冲和统计计数器
    func resetDebug() {
        #if canImport(Quarkproxy)
        _ = QuarkproxyResetStats()
        #endif
    }

    // MARK: - 常量

    /// 夸克桌面端 UA（对齐 iBox 抓包）
    static let quarkDesktopUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) quark-cloud-drive/2.5.20 "
        + "Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 "
        + "Safari/537.36 Channel/pckk_other_ch"

    private var quarkDesktopUA: String { Self.quarkDesktopUA }
}
