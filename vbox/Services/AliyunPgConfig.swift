//
//  AliyunPgConfig.swift
//  vbox
//
//  PG 阿里云盘 4kz 播放配置管理
//  对应 PG tokenm.json 中的配置字段
//
//  ⚠️ 重要：此文件仅用于 PG 阿里云盘路链，不影响其它网盘的任何功能
//
//  v2.0 — 2026-09-03
//

import Foundation

/// PG 阿里云盘 4kz 播放配置管理
/// 对应 pg.jar 的 tokenm.json / tokentemplate.json 配置
final class AliyunPgConfig {

    static let shared = AliyunPgConfig()

    // MARK: - 开关

    /// PG 播放路链总开关
    /// false 时走 vbox 原生 CloudDriveManager 阿里云盘逻辑（完全不影响现有逻辑）
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "pg_ali_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "pg_ali_enabled") }
    }

    // MARK: - vod_flags（对应 tokenm.json）

    /// 播放画质标志
    /// "4kz|auto" = 转存GO原画 + 自动选择最高画质
    /// "4ko|auto" = 转存Open原画
    /// "qhd|auto" / "fhd|auto" / "hd|auto" / "sd|auto" / "ld|auto" = 预览画质
    var vodFlags: String {
        get { UserDefaults.standard.string(forKey: "pg_ali_vod_flags") ?? "4kz|auto" }
        set { UserDefaults.standard.set(newValue, forKey: "pg_ali_vod_flags") }
    }

    /// 是否使用 4kz 模式（转存GO原画）
    var is4kzMode: Bool {
        vodFlags.hasPrefix("4kz")
    }

    // MARK: - VIP 线程配置（对应 tokenm.json）

    var isVip: Bool {
        get { UserDefaults.standard.object(forKey: "pg_ali_is_vip") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "pg_ali_is_vip") }
    }

    /// VIP 并发线程数
    var vipThreadLimit: Int {
        get { UserDefaults.standard.object(forKey: "pg_ali_thread_limit") as? Int ?? 32 }
        set { UserDefaults.standard.set(newValue, forKey: "pg_ali_thread_limit") }
    }

    /// 夜间线程配置 "19-23=32"
    var vipThreadLimitNight: String {
        get { UserDefaults.standard.string(forKey: "pg_ali_thread_night") ?? "19-23=32" }
        set { UserDefaults.standard.set(newValue, forKey: "pg_ali_thread_night") }
    }

    // MARK: - Go 代理配置（对应 aliproxy）

    /// Go 代理本地端口（vbox 已移植）
    var aliproxyPort: Int {
        get { UserDefaults.standard.object(forKey: "pg_ali_proxy_port") as? Int ?? 10078 }
        set { UserDefaults.standard.set(newValue, forKey: "pg_ali_proxy_port") }
    }

    /// Go 代理本地地址
    var aliproxyUrl: String {
        "http://127.0.0.1:\(aliproxyPort)"
    }

    /// Go 代理工作目录
    var aliproxyDir: String {
        "pg_aliproxy"
    }

    // MARK: - API 端点配置（对应 open_api_url）

    /// Token 刷新端点（extscreen API）
    var openApiUrl: String {
        "https://api.extscreen.com/aliyundrive/token"
    }

    /// 阿里云盘 API 基础地址
    /// 分享级接口（share_token、file/list）使用 api.alipan.com（ADrive 格式）
    let aliApiBase = "https://api.alipan.com"
    let aliDownloadApiBase = "https://api.alipan.com"

    /// ⚠️ 用户级接口（user/get、file/copy、file/delete 等）
    /// PG 的 extscreen token 和原生 token 一样，使用 api.alipan.com ADrive 格式端点
    /// 之前误用 api.aliyundrive.com PDS 格式导致 401 "AccessToken is invalid"
    let aliPdsApiBase = "https://api.alipan.com"

    // MARK: - 转存配置

    /// 转存目标文件夹名（在用户网盘根目录下）
    var transferFolderName: String {
        get { UserDefaults.standard.string(forKey: "pg_ali_transfer_dir") ?? "vbox_pg_temp" }
        set { UserDefaults.standard.set(newValue, forKey: "pg_ali_transfer_dir") }
    }

    /// 转存后是否自动清理（播放结束后删除）
    var autoCleanup: Bool {
        get { UserDefaults.standard.object(forKey: "pg_ali_auto_cleanup") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "pg_ali_auto_cleanup") }
    }

    /// 清理延迟（秒），播放结束后等待多久再删除转存文件
    var cleanupDelay: TimeInterval {
        get { UserDefaults.standard.object(forKey: "pg_ali_cleanup_delay") as? Double ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "pg_ali_cleanup_delay") }
    }

    // MARK: - 缓存配置

    /// access_token 内存缓存有效期（秒）
    let accessTokenCacheTTL: Int = 7200

    // MARK: - 日志前缀

    /// 日志前缀，用于统一识别 PG 路链日志
    static let logPrefix = "[PG-Play]"

    // MARK: - 私有初始化

    private init() {
        // 默认启用（仅当存在 PG 凭证时才真正生效）
        if UserDefaults.standard.object(forKey: "pg_ali_enabled") == nil {
            UserDefaults.standard.set(true, forKey: "pg_ali_enabled")
        }
    }

    // MARK: - 当前线程数（根据时间段自动切换）

    /// 根据当前时间获取并发线程数
    /// 夜间配置 "19-23=32" 表示 19:00-23:00 使用 32 线程
    var currentThreadLimit: Int {
        guard isVip else { return 1 }
        let hour = Calendar.current.component(.hour, from: Date())
        // 解析夜间配置
        if let nightConfig = parseNightConfig(vipThreadLimitNight) {
            if hour >= nightConfig.startHour && hour < nightConfig.endHour {
                return nightConfig.threadLimit
            }
        }
        return vipThreadLimit
    }

    private struct NightConfig {
        let startHour: Int
        let endHour: Int
        let threadLimit: Int
    }

    private func parseNightConfig(_ config: String) -> NightConfig? {
        // 格式: "19-23=32"
        let parts = config.split(separator: "=")
        guard parts.count == 2,
              let threads = Int(parts[1]) else { return nil }
        let hours = parts[0].split(separator: "-")
        guard hours.count == 2,
              let start = Int(hours[0]),
              let end = Int(hours[1]) else { return nil }
        return NightConfig(startHour: start, endHour: end, threadLimit: threads)
    }

    // MARK: - 凭证标记

    /// PG 凭证标记键（存储在 CloudDriveCredential.extra 中）
    static let pgSourceKey = "pg_source"
    /// PG 凭证标记值（与 AliyunPgAuthManager.savePgCredential 中设置的值一致）
    static let pgSourceValue = "qr_scan"

    /// 判断凭证是否来自 PG（扫码登录获取）
    /// 检查 extra 中是否存在 pg_source 标记，兼容多种来源值
    static func isPgCredential(_ credential: CloudDriveCredential) -> Bool {
        credential.extra[pgSourceKey] != nil
    }
}
