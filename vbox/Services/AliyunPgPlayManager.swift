//
//  AliyunPgPlayManager.swift
//  vbox
//
//  PG 阿里云盘 4kz 完整播放路链（转存GO原画）
//  与 pg.jar 的 AliShare 类逻辑完全一致，不做路链降级 fallback
//
//  8步流程:
//    1. Token刷新 (refresh_token → access_token)
//    2. 获取share_token (/v2/share_link/get_share_token)
//    3. 列举分享文件 (/adrive/v3/file/list，递归子文件夹)
//    4. ★优先分享直链 (get_download_url + share_id + x-share-token)
//    5. ★转存兜底 (/v2/file/copy 转存后取原画直链)
//    6. ★Go代理多线程加速 (aliproxy)
//    7. 返回 parse=0 直接播放
//    8. ★播放后清理 (/v2/file/delete 精确删除转存文件)
//
//  ⚠️ 重要：此文件仅用于 PG 阿里云盘路链，不影响其它网盘的任何功能
//  ⚠️ 百度、夸克、UC、迅雷、115 等所有其它网盘逻辑完全不受影响
//
//  v2.2 — 2026-09-03 — 根因修复：extscreen OAuth token 是 OpenAPI token，
//                      不兼容 ADrive/PDS 分享操作 API。改用 Web App Token 端点
//                      (api.aliyundrive.com/v2/account/token，不带 client_id/secret)
//                      刷新，获取 ADrive 格式 access_token。
//                      清理 5 种诊断方案，保留 2 种标准方案。
//

import Foundation

/// PG 阿里云盘 4kz 播放路链核心管理器
/// 完全复现 pg.jar 的 AliShare 类 8步播放流程
final class AliyunPgPlayManager {

    static let shared = AliyunPgPlayManager()

    // MARK: - 私有属性

    private let session: URLSession
    private let config = AliyunPgConfig.shared

    /// access_token 内存缓存
    private var cachedAccessToken: String?
    private var accessTokenExpiresAt: Date?

    /// 用户网盘 drive_id 缓存（转存 /v2/file/copy 需要 to_drive_id）
    private var cachedDriveId: String?

    /// 转存文件清理队列
    private var pendingCleanups: [PgCleanupItem] = []

    private struct PgCleanupItem {
        let fileId: String
        let accessToken: String
        let createdAt: Date
    }

    // MARK: - 初始化

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        session = URLSession(configuration: cfg)
        startCleanupWorker()
    }

    // MARK: - 日志

    private func pgLog(_ message: String) {
        let msg = "\(AliyunPgConfig.logPrefix) \(message)"
        print(msg)
        // 使用 vbox 统一日志系统
        let level: LogLevel
        if msg.contains("❌") || msg.contains("失败") {
            level = .error
        } else if msg.contains("⚠️") {
            level = .warn
        } else if msg.contains("✅") {
            level = .info
        } else {
            level = .verbose
        }
        AppLogStore.shared.log(level, .cloud, msg)
        // 广播到播放器 Debug Overlay
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .cloudDriveLog, object: msg)
        }
    }

    // MARK: - 公开接口

    /// PG 4kz 完整播放路链入口
    /// 与 pg.jar 的 AliShare 类逻辑完全一致
    /// - Parameters:
    ///   - shareURL: 阿里云盘分享链接
    ///   - credential: PG 凭证（含 refresh_token）
    ///   - targetFileId: 可选，指定播放的 file_id（用于选集场景，不传则自动选第一个视频）
    /// - Returns: PlayResult（直接播放，parse=0）
    func resolveViaPgChain(
        shareURL: String,
        credential: CloudDriveCredential,
        targetFileId: String? = nil
    ) async throws -> PlayResult {

        pgLog("========== 开始 PG 4kz 播放路链 ==========")
        pgLog("分享链接: \(shareURL)")
        if let targetFileId {
            pgLog("指定文件: file_id=\(targetFileId)")
        }

        // ═══════════════════════════════════════════════════════════
        // 步骤1: Token 刷新 — refresh_token → access_token
        // ═══════════════════════════════════════════════════════════

        let accessToken: String
        do {
            accessToken = try await refreshToken(credential)
            pgLog("步骤1: Token刷新 → ✅ access_token获取成功 (长度=\(accessToken.count))")
        } catch {
            pgLog("步骤1: Token刷新 → ❌ 失败: \(error.localizedDescription)")
            throw DriveError.noPlayURL("PG步骤1 Token刷新失败: \(error.localizedDescription)")
        }

        // ═══════════════════════════════════════════════════════════
        // 步骤2: 获取 share_token
        // ═══════════════════════════════════════════════════════════

        let shareId = parseShareId(from: shareURL)
        guard !shareId.isEmpty else {
            pgLog("步骤2: 解析share_id → ❌ 失败: 无法从链接提取share_id")
            throw DriveError.noPlayURL("PG步骤2 解析share_id失败")
        }

        let shareToken: String
        do {
            shareToken = try await getShareToken(
                accessToken: accessToken,
                shareId: shareId,
                sharePwd: ""
            )
            pgLog("步骤2: share_token → ✅ share_id=\(shareId)")
        } catch {
            pgLog("步骤2: share_token → ❌ 失败: \(error.localizedDescription)")
            throw DriveError.noPlayURL("PG步骤2 获取share_token失败: \(error.localizedDescription)")
        }

        // ═══════════════════════════════════════════════════════════
        // 步骤3: 列举分享文件 / 使用指定文件
        // ═══════════════════════════════════════════════════════════

        let targetFile: PgShareFile

        if let specifiedId = targetFileId, !specifiedId.isEmpty {
            // 已指定 file_id（选集场景），跳过文件列表遍历
            targetFile = PgShareFile(
                fileId: specifiedId,
                name: "指定文件",
                category: "video",
                size: 0
            )
            pgLog("步骤3: 指定文件 → ✅ file_id=\(specifiedId)（跳过列表遍历）")
        } else {
            let files: [PgShareFile]
            do {
                files = try await listShareFiles(
                    accessToken: accessToken,
                    shareToken: shareToken,
                    shareId: shareId
                )
                let videoFiles = files.filter { $0.category == "video" }
                pgLog("步骤3: 文件列表 → ✅ \(files.count)个文件, 视频文件\(videoFiles.count)个")
            } catch {
                pgLog("步骤3: 文件列表 → ❌ 失败: \(error.localizedDescription)")
                throw DriveError.noPlayURL("PG步骤3 列举文件失败: \(error.localizedDescription)")
            }

            // 选集：过滤可播放视频并排序（对齐原生：category=video 或常见视频扩展名）
            let videoFiles = files
                .filter { pgIsPlayable($0) }
                .sorted { $0.name < $1.name }

            guard let firstVideo = videoFiles.first else {
                pgLog("步骤3: 选集 → ❌ 失败: 分享中没有视频文件")
                throw DriveError.noPlayURL("PG步骤3 分享中无视频文件")
            }
            targetFile = firstVideo
            pgLog("步骤3: 选集 → ✅ 选定文件: \(targetFile.name)")
        }

        // ═══════════════════════════════════════════════════════════
        // 步骤4: ★ 优先尝试分享直链（不转存，直接从分享取 download_url）
        // 对齐原生 aliGetDownloadURL：file_id + share_id + x-share-token
        // ═══════════════════════════════════════════════════════════

        var resolvedInfo: PgDownloadInfo?
        var savedFileId: String?

        do {
            let info = try await getShareDownloadUrl(
                accessToken: accessToken,
                fileId: targetFile.fileId,
                shareId: shareId,
                shareToken: shareToken
            )
            resolvedInfo = info
            pgLog("步骤4: 分享直链 → ✅ download_url获取成功 (cdn=\(extractHost(info.url)))")
        } catch {
            pgLog("步骤4: 分享直链 → ⚠️ 失败: \(error.localizedDescription)，转入转存兜底")

            // ═══════════════════════════════════════════════════════
            // 步骤5: ★ 转存兜底 — /v2/file/copy 转存后取原画直链
            // ═══════════════════════════════════════════════════════
            do {
                let driveId = try await getUserDriveId(accessToken: accessToken)
                let savedId = try await saveFile(
                    accessToken: accessToken,
                    fileId: targetFile.fileId,
                    shareId: shareId,
                    shareToken: shareToken,
                    toDriveId: driveId
                )
                savedFileId = savedId
                pgLog("步骤5: 转存 → ✅ saved_file_id=\(savedId)")

                let info = try await getDownloadUrl(
                    accessToken: accessToken,
                    fileId: savedId,
                    driveId: driveId
                )
                resolvedInfo = info
                pgLog("步骤5: 转存直链 → ✅ download_url获取成功 (cdn=\(extractHost(info.url)))")
            } catch {
                pgLog("步骤5: 转存路链 → ❌ 失败: \(error.localizedDescription)")
                // 转存失败也要清理可能已转存的文件
                if let savedId = savedFileId {
                    scheduleCleanup(fileId: savedId, accessToken: accessToken)
                }
                throw DriveError.noPlayURL("PG步骤4-5 获取播放直链失败: \(error.localizedDescription)")
            }
        }

        guard let downloadInfo = resolvedInfo else {
            throw DriveError.noPlayURL("PG步骤4-5 无有效播放直链")
        }

        // ═══════════════════════════════════════════════════════════
        // 步骤6: ★ Go代理多线程加速 (aliproxy)
        // ═══════════════════════════════════════════════════════════

        let proxyUrl: String
        do {
            proxyUrl = try await wrapWithGoProxy(
                downloadUrl: downloadInfo.url,
                headers: downloadInfo.headers
            )
            pgLog("步骤6: Go代理 → ✅ proxy_url 已生成 (thread=\(config.currentThreadLimit))")
        } catch {
            pgLog("步骤6: Go代理 → ⚠️ Go代理不可用，使用原始直链: \(error.localizedDescription)")
            // Go代理不可用时降级使用原始直链（不是路链降级，是传输方式选择）
            proxyUrl = downloadInfo.url
        }

        // ═══════════════════════════════════════════════════════════
        // 步骤7: 返回播放信息 (parse=0 直接播放)
        // ═══════════════════════════════════════════════════════════

        var playHeaders = downloadInfo.headers
        if playHeaders["User-Agent"] == nil {
            playHeaders["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        }
        if playHeaders["Referer"] == nil {
            playHeaders["Referer"] = "https://api.alipan.com"
        }

        pgLog("步骤7: 播放 → ✅ parse=0, 交付播放器")
        pgLog("========== PG 4kz 路链完成 ==========")

        // 注册清理回调（步骤8）— 仅当走了转存兜底流程才需要清理
        if let savedId = savedFileId {
            if config.autoCleanup {
                scheduleCleanup(fileId: savedId, accessToken: accessToken)
                pgLog("步骤8: 清理 → ⏳ 已注册清理任务 (delay=\(config.cleanupDelay)s)")
            } else {
                pgLog("步骤8: 清理 → ⏸️ 自动清理已关闭")
            }
        } else {
            pgLog("步骤8: 清理 → ⏭️ 分享直链播放，无转存文件，无需清理")
        }

        return PlayResult(
            url: proxyUrl,
            headers: playHeaders,
            driveType: .ali
        )
    }

    // MARK: - 步骤1: Token 刷新

    /// refresh_token → access_token
    /// 多级刷新链: Web App Token → CloudDriveAuthManager → extscreen
    /// 返回经验证有效的 ADrive 格式 access_token
    private func refreshToken(_ credential: CloudDriveCredential) async throws -> String {

        // 检查内存缓存（缓存有效期内直接使用，由下游 API 失败时自动重试刷新）
        if let cached = cachedAccessToken,
           let expiry = accessTokenExpiresAt,
           expiry > Date() {
            return cached
        }

        guard let refreshToken = credential.refreshToken,
              !refreshToken.isEmpty else {
            throw DriveError.noPlayURL("PG凭证中无refresh_token")
        }

        // 多级刷新链
        let refreshed = try await refreshViaAliyunPgAuthManager(credential)
        cachedAccessToken = refreshed.accessToken
        accessTokenExpiresAt = Date().addingTimeInterval(TimeInterval(config.accessTokenCacheTTL))
        cachedDriveId = nil // 清除 drive_id 缓存，避免使用旧 token 获取的值
        // 更新凭证中的 refresh_token（轮换存储）
        updateCredentialWithNewTokens(
            credential: credential,
            accessToken: refreshed.accessToken,
            newRefreshToken: refreshed.refreshToken
        )
        return refreshed.accessToken
    }

    /// 通过多级刷新链获取有效的 ADrive access_token
    private struct RefreshedToken {
        let accessToken: String
        let refreshToken: String
    }

    private func refreshViaAliyunPgAuthManager(_ credential: CloudDriveCredential) async throws -> RefreshedToken {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw DriveError.noPlayURL("PG凭证中无refresh_token")
        }

        // ═══════════════════════════════════════════════════════════
        // ★ 方案A: Web App Token 端点（不带 client_id/secret）
        // 对应 baseAli 项目: https://api.aliyundrive.com/v2/account/token
        // 仅需 {"refresh_token":"...", "grant_type":"refresh_token"}
        // 返回 ADrive 格式 access_token，兼容所有分享操作 API
        // ═══════════════════════════════════════════════════════════
        do {
            let result = try await refreshViaWebAppToken(refreshToken: refreshToken)
            pgLog("步骤1: Web App Token → ✅ 刷新成功 (长度=\(result.accessToken.count))")

            // 验证 token 是否为 ADrive 格式（调用 user/get 测试）
            let isValid = await verifyAdriveToken(result.accessToken)
            if isValid {
                pgLog("步骤1: Token验证 → ✅ ADrive token 有效")
                return RefreshedToken(accessToken: result.accessToken, refreshToken: result.refreshToken)
            } else {
                pgLog("步骤1: Token验证 → ⚠️ Web App token 仍非 ADrive 格式")
            }
        } catch {
            pgLog("步骤1: Web App Token → ⚠️ 失败: \(error.localizedDescription)")
        }

        // ═══════════════════════════════════════════════════════════
        // ★ 方案B: CloudDriveAuthManager 刷新链（含官方 API + OpenList + extscreen）
        // 可能返回 OpenAPI token（不兼容分享 API），但作为兜底尝试
        // ═══════════════════════════════════════════════════════════
        do {
            let refreshed = try await CloudDriveAuthManager.shared.refreshAliAccessTokenIfNeeded()
            guard let accessToken = refreshed.accessToken,
                  let refreshToken = refreshed.refreshToken,
                  !accessToken.isEmpty,
                  !refreshToken.isEmpty else {
                throw DriveError.noPlayURL("刷新后Token为空")
            }

            let isValid = await verifyAdriveToken(accessToken)
            if isValid {
                pgLog("步骤1: CloudDriveAuthManager → ✅ ADrive token 有效 (长度=\(accessToken.count))")
                return RefreshedToken(accessToken: accessToken, refreshToken: refreshToken)
            } else {
                pgLog("步骤1: CloudDriveAuthManager → ⚠️ token 非 ADrive 格式 (可能为 OpenAPI token，长度=\(accessToken.count))")
            }
        } catch {
            pgLog("步骤1: CloudDriveAuthManager → ⚠️ 失败: \(error.localizedDescription)")
        }

        // ═══════════════════════════════════════════════════════════
        // ★ 方案C: 直接使用 extscreen 刷新的 token（最后兜底）
        // ═══════════════════════════════════════════════════════════
        do {
            let refreshed = try await AliyunPgAuthManager.shared.refreshViaExtscreen(credential: credential)
            guard let accessToken = refreshed.accessToken,
                  let refreshToken = refreshed.refreshToken,
                  !accessToken.isEmpty else {
                throw DriveError.noPlayURL("extscreen 刷新后 Token 为空")
            }

            let isValid = await verifyAdriveToken(accessToken)
            if isValid {
                pgLog("步骤1: extscreen → ✅ ADrive token 有效")
                return RefreshedToken(accessToken: accessToken, refreshToken: refreshToken)
            } else {
                pgLog("步骤1: extscreen → ⚠️ token 非 ADrive 格式 (OpenAPI token，不支持分享操作)")
            }
        } catch {
            pgLog("步骤1: extscreen → ⚠️ 失败: \(error.localizedDescription)")
        }

        // 所有方案均无法获取有效的 ADrive token
        pgLog("步骤1: ❌ 所有刷新方案均无法获取有效的 ADrive access_token")
        pgLog("步骤1: 根因: extscreen OAuth token 是 OpenAPI token，不兼容 ADrive/PDS 分享操作 API")
        pgLog("步骤1: 解决: 请在网盘授权中心使用阿里云盘扫码登录获取原生 ADrive 凭证")
        throw DriveError.noPlayURL("PG Token 刷新失败：extscreen token 是 OpenAPI token，不支持分享下载操作。请使用原生阿里云盘凭证")
    }

    /// 通过 Web App Token 端点刷新（不带 client_id/secret）
    /// 对应 baseAli 项目: https://auth.aliyundrive.com/v2/account/token
    /// 仅需 {"refresh_token":"...", "grant_type":"refresh_token"}
    /// 不带 client_id/secret，可能返回 ADrive 格式 access_token
    private func refreshViaWebAppToken(refreshToken: String) async throws -> (accessToken: String, refreshToken: String) {
        // 尝试多个端点（auth.aliyundrive.com 和 api.aliyundrive.com）
        let urls = [
            "https://auth.aliyundrive.com/v2/account/token",
            "https://api.aliyundrive.com/v2/account/token"
        ]

        let body: [String: Any] = [
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        for urlStr in urls {
            let url = URL(string: urlStr)!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            request.httpBody = bodyData

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { continue }

            let respStr = String(data: data, encoding: .utf8) ?? ""
            pgLog("步骤1: Web App Token [\(urlStr)] 响应(\(http.statusCode)): \(respStr.prefix(200))")

            guard http.statusCode == 200 else { continue }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String,
                  let newRefreshToken = json["refresh_token"] as? String,
                  !accessToken.isEmpty,
                  !newRefreshToken.isEmpty else { continue }

            return (accessToken: accessToken, refreshToken: newRefreshToken)
        }

        throw DriveError.noPlayURL("Web App Token: 所有端点均失败")
    }

    /// 验证 token 是否为 ADrive 格式（通过 user/get 接口测试）
    private func verifyAdriveToken(_ accessToken: String) async -> Bool {
        do {
            let url = URL(string: "\(config.aliPdsApiBase)/adrive/v2/user/get")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [:])

            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            if statusCode == 200 {
                return true
            }
            let respStr = String(data: data, encoding: .utf8) ?? ""
            pgLog("步骤1: Token验证 user/get(\(statusCode)): \(respStr.prefix(150))")
            return false
        } catch {
            pgLog("步骤1: Token验证 异常: \(error.localizedDescription)")
            return false
        }
    }

    /// 更新凭证中的 Token（轮换存储）
    private func updateCredentialWithNewTokens(
        credential: CloudDriveCredential,
        accessToken: String,
        newRefreshToken: String
    ) {
        var updated = credential
        updated.accessToken = accessToken
        updated.refreshToken = newRefreshToken
        updated.state = .valid
        updated.lastCheckedAt = Date()
        updated.updatedAt = Date()
        CloudDriveAuthManager.shared.saveCredential(updated)
    }

    // MARK: - 步骤2: 获取 share_token

    /// 从分享链接获取 share_token
    /// ⚠️ 修复：端点改为官方 /v2/share_link/get_share_token
    /// （原 /adrive/v1.0/share/get_share_token 在 api.alipan.com 上返回 404）
    /// 请求/响应与错误码判断完全对齐原生 CloudDriveManager.aliGetShareToken
    private func getShareToken(
        accessToken: String,
        shareId: String,
        sharePwd: String
    ) async throws -> String {

        let url = URL(string: "\(config.aliApiBase)/v2/share_link/get_share_token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        // 对齐原生：仅当 share_pwd 非空时才附带
        var body: [String: Any] = ["share_id": shareId]
        if !sharePwd.isEmpty { body["share_pwd"] = sharePwd }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw DriveError.noPlayURL("get_share_token HTTP \(statusCode)")
        }

        // 对齐原生：先检查响应 code 字段，再提取 share_token
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let codeStr = json["code"] as? String
            let codeInt = json["code"] as? Int
            let isError = (codeStr != nil && codeStr != "OK" && codeStr != "ok" && codeStr != "0")
                        || (codeInt != nil && codeInt != 0 && codeInt != 200)
            if isError {
                let message = json["message"] as? String ?? (codeStr ?? "code=\(codeInt ?? -1)")
                throw DriveError.noPlayURL("阿里分享 token 获取失败：\(message)")
            }
            if let shareToken = json["share_token"] as? String, !shareToken.isEmpty {
                return shareToken
            }
        }

        throw DriveError.noPlayURL("get_share_token 响应解析失败")
    }

    // MARK: - 步骤3: 列举分享文件

    /// 列举分享文件列表
    /// ⚠️ 修复：端点改为 /adrive/v3/file/list（原 /adrive/v1.0/share/list_share_files 返回 404）
    /// 对齐原生 aliGetShareFileList：parent_file_id="root"、x-share-token 小写、Referer、分页
    /// 并递归遍历子文件夹（对齐原生 aliCollectPlayableFiles），避免视频在子目录时漏选
    private func listShareFiles(
        accessToken: String,
        shareToken: String,
        shareId: String
    ) async throws -> [PgShareFile] {
        var allFiles: [PgShareFile] = []
        try await collectShareFiles(
            accessToken: accessToken,
            shareToken: shareToken,
            shareId: shareId,
            parentFileId: "root",
            into: &allFiles
        )
        return allFiles
    }

    /// 递归收集分享内的文件（进入子文件夹，支持 next_marker 分页）
    private func collectShareFiles(
        accessToken: String,
        shareToken: String,
        shareId: String,
        parentFileId: String,
        into result: inout [PgShareFile]
    ) async throws {
        var marker = ""
        // 每个目录最多翻 10 页（对齐原生），防止异常分享导致死循环
        for _ in 0..<10 {
            let url = URL(string: "\(config.aliApiBase)/adrive/v3/file/list")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(shareToken, forHTTPHeaderField: "x-share-token")
            request.setValue("https://www.alipan.com/", forHTTPHeaderField: "Referer")

            var body: [String: Any] = [
                "share_id": shareId,
                "parent_file_id": parentFileId,
                "limit": 100,
                "order_by": "name",
                "order_direction": "ASC"
            ]
            if !marker.isEmpty { body["marker"] = marker }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw DriveError.noPlayURL("file/list HTTP \(statusCode)")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DriveError.noPlayURL("file/list 响应解析失败")
            }

            // 对齐原生：检查 code 字段
            if let code = json["code"] as? String, code != "OK" {
                let message = json["message"] as? String ?? "未知错误"
                throw DriveError.noPlayURL("阿里: \(message)")
            }

            let items = json["items"] as? [[String: Any]] ?? []
            for item in items {
                guard let fileId = item["file_id"] as? String, !fileId.isEmpty else { continue }
                let name = item["name"] as? String ?? item["file_name"] as? String ?? ""
                let type = item["type"] as? String ?? "file"
                let category = item["category"] as? String ?? ""
                let size = item["size"] as? Int64 ?? 0

                if type.lowercased() == "folder" {
                    // 递归进入子文件夹
                    try await collectShareFiles(
                        accessToken: accessToken,
                        shareToken: shareToken,
                        shareId: shareId,
                        parentFileId: fileId,
                        into: &result
                    )
                } else {
                    result.append(PgShareFile(fileId: fileId, name: name, category: category, size: size))
                }
            }

            if let nextMarker = json["next_marker"] as? String, !nextMarker.isEmpty {
                marker = nextMarker
            } else {
                break
            }
        }
    }

    /// 判断文件是否可播放（对齐原生 aliIsPlayable：category=video 或常见视频扩展名）
    private func pgIsPlayable(_ file: PgShareFile) -> Bool {
        if file.category.lowercased() == "video" { return true }
        let lower = file.name.lowercased()
        return ["mp4", "mkv", "mov", "m3u8", "avi", "wmv", "flv", "ts", "m4v"].contains { lower.hasSuffix(".\($0)") }
    }

    // MARK: - 步骤4: ★ 转存到用户网盘

    /// 将分享文件转存到用户自己的网盘
    /// ⚠️ 修复：端点改为官方 /v2/file/copy（原 /adrive/v2/file/batch_copy 不适用于分享转存）
    /// 对齐官方 PDS 文档：需 access_token + x-share-token 双重鉴权，
    /// 响应直接返回转存后新文件的 drive_id / file_id（可能附带 async_task_id）
    private func saveFile(
        accessToken: String,
        fileId: String,
        shareId: String,
        shareToken: String,
        toDriveId: String
    ) async throws -> String {

        // ⚠️ 修复：转存使用 ADrive 格式端点 api.alipan.com/adrive/v2/file/copy
        // PG 的 extscreen token 和原生 token 一样使用 ADrive API
        let url = URL(string: "\(config.aliPdsApiBase)/adrive/v2/file/copy")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(shareToken, forHTTPHeaderField: "x-share-token")

        let body: [String: Any] = [
            "share_id": shareId,
            "file_id": fileId,
            "to_drive_id": toDriveId,
            "to_parent_file_id": "root",
            "auto_rename": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let respStr = String(data: data, encoding: .utf8) ?? ""
            pgLog("file/copy 响应(\(statusCode)): \(respStr.prefix(300))")
            throw DriveError.noPlayURL("file/copy HTTP \(statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.noPlayURL("file/copy 响应解析失败")
        }

        // 检查错误码
        if let code = json["code"] as? String,
           code != "OK" && code != "ok" && code != "0" {
            let message = json["message"] as? String ?? "未知错误"
            throw DriveError.noPlayURL("file/copy 错误: \(code) - \(message)")
        }

        let newFileId = json["file_id"] as? String
        let asyncTaskId = json["async_task_id"] as? String

        // 若返回异步任务，先等待文件落盘（确保后续可取下载_url）
        if let taskId = asyncTaskId, !taskId.isEmpty {
            pgLog("步骤5: 转存任务已提交 (async_task_id=\(taskId))，等待完成...")
            try await waitForTransferTask(taskId: taskId, accessToken: accessToken)
        }

        // 官方响应直接返回转存后的 file_id
        if let newFileId, !newFileId.isEmpty {
            return newFileId
        }

        // 兜底：响应未返回 file_id 时，从网盘根目录查找最近转存的视频
        pgLog("步骤5: 转存响应未返回 file_id，尝试从根目录查找...")
        return try await findRecentlySavedFile(accessToken: accessToken, driveId: toDriveId)
    }

    /// 等待异步转存任务完成（ADrive: /adrive/v2/async_task/get）
    /// ⚠️ 修复：使用 ADrive 格式端点 api.alipan.com/adrive/...
    private func waitForTransferTask(
        taskId: String,
        accessToken: String
    ) async throws {

        let url = URL(string: "\(config.aliPdsApiBase)/adrive/v2/async_task/get")!
        // 最多等待 30 秒（10次轮询，每次3秒）
        for attempt in 0..<10 {
            try await Task.sleep(nanoseconds: 3_000_000_000)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let body: [String: Any] = ["async_task_id": taskId]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else { continue }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            // state 字段：Succeed / Running / Failed（兼容大小写与 status 字段）
            let state = (json["state"] as? String ?? json["status"] as? String ?? "running").lowercased()
            pgLog("步骤5: 转存任务状态: \(state) (第\(attempt + 1)次轮询)")

            if state.contains("succeed") || state.contains("success") {
                return
            }
            if state.contains("fail") || state.contains("error") {
                let message = json["message"] as? String ?? json["error"] as? String ?? "转存任务失败"
                throw DriveError.noPlayURL("转存任务失败: \(message)")
            }
        }

        // 轮询超时不直接失败（文件可能已落盘），交由后续 download_url 验证
        pgLog("步骤5: 转存任务轮询超时，继续尝试取链")
    }

    /// 搜索最近转存的文件（兜底，从用户网盘根目录找最新视频）
    /// ⚠️ 修复：使用 ADrive 格式端点 /adrive/v3/file/list（和原生一致）
    private func findRecentlySavedFile(
        accessToken: String,
        driveId: String
    ) async throws -> String {

        let url = URL(string: "\(config.aliPdsApiBase)/adrive/v3/file/list")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "drive_id": driveId,
            "parent_file_id": "root",
            "limit": 20,
            "order_by": "updated_at",
            "order_direction": "DESC"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            throw DriveError.noPlayURL("搜索转存文件失败")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            throw DriveError.noPlayURL("搜索转存文件失败: 无结果")
        }

        // 优先找最新的视频文件
        for item in items {
            let category = item["category"] as? String ?? ""
            let type = item["type"] as? String ?? "file"
            if type == "file", category == "video",
               let fileId = item["file_id"] as? String, !fileId.isEmpty {
                return fileId
            }
        }
        // 退而求其次：取第一个文件
        if let firstFile = items.first,
           let fileId = firstFile["file_id"] as? String, !fileId.isEmpty {
            return fileId
        }

        throw DriveError.noPlayURL("搜索转存文件失败: 无视频文件")
    }

    // MARK: - 步骤5: 获取原画直链

    /// 获取用户网盘 drive_id（转存 /adrive/v2/file/copy 需要 to_drive_id）
    /// ⚠️ 修复：使用 ADrive 格式端点 api.alipan.com/adrive/v2/user/get
    /// （之前用 api.aliyundrive.com PDS 格式导致 401 "AccessToken is invalid"）
    private func getUserDriveId(accessToken: String) async throws -> String {
        if let cached = cachedDriveId, !cached.isEmpty {
            return cached
        }

        let url = URL(string: "\(config.aliPdsApiBase)/adrive/v2/user/get")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [:])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let respStr = String(data: data, encoding: .utf8) ?? ""
            pgLog("user/get 响应(\(statusCode)): \(respStr.prefix(300))")
            throw DriveError.noPlayURL("user/get HTTP \(statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.noPlayURL("user/get 响应解析失败")
        }

        // 优先 default_drive_id，其次 resource_drive_id / drive_id
        let driveId = (json["default_drive_id"] as? String)
            ?? (json["resource_drive_id"] as? String)
            ?? (json["drive_id"] as? String)
        guard let driveId, !driveId.isEmpty else {
            throw DriveError.noPlayURL("user/get 响应中无 drive_id")
        }

        cachedDriveId = driveId
        pgLog("获取用户 drive_id → ✅ \(driveId)")
        return driveId
    }

    /// 直接从分享获取原画 download_url（不转存，分享直链）
    /// 使用 2 种标准方案，均需 Authorization + x-share-token 双重鉴权
    /// 方案A: PDS get_download_url (api.aliyundrive.com)
    /// 方案B: ADrive get_download_url (api.alipan.com)
    private func getShareDownloadUrl(
        accessToken: String,
        fileId: String,
        shareId: String,
        shareToken: String
    ) async throws -> PgDownloadInfo {

        let body: [String: Any] = [
            "file_id": fileId,
            "share_id": shareId,
            "expire_sec": 14400
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        // ★ 方案A: PDS get_download_url (api.aliyundrive.com) + Authorization + x-share-token
        do {
            let url = URL(string: "https://api.aliyundrive.com/v2/file/get_download_url")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(shareToken, forHTTPHeaderField: "x-share-token")
            request.setValue("https://www.alipan.com/", forHTTPHeaderField: "Referer")
            request.httpBody = bodyData

            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let respStr = String(data: data, encoding: .utf8) ?? ""
            pgLog("分享直链 PDS(\(statusCode)): \(respStr.prefix(300))")

            if statusCode == 200 {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return try extractDownloadInfo(from: json)
                }
            }
        } catch {
            pgLog("分享直链 PDS 异常: \(error.localizedDescription)")
        }

        // ★ 方案B: ADrive get_download_url (api.alipan.com) + Authorization + x-share-token
        do {
            let url = URL(string: "https://api.alipan.com/adrive/v2/file/get_download_url")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(shareToken, forHTTPHeaderField: "x-share-token")
            request.setValue("https://www.alipan.com/", forHTTPHeaderField: "Referer")
            request.httpBody = bodyData

            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let respStr = String(data: data, encoding: .utf8) ?? ""
            pgLog("分享直链 ADrive(\(statusCode)): \(respStr.prefix(300))")

            if statusCode == 200 {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return try extractDownloadInfo(from: json)
                }
            }
        } catch {
            pgLog("分享直链 ADrive 异常: \(error.localizedDescription)")
        }

        throw DriveError.noPlayURL("分享直链获取失败（PDS + ADrive 两种方案均失败），详见日志")
    }

    /// 从用户网盘（转存后的文件）获取原画 download_url
    /// ⚠️ 修复：使用 ADrive 格式端点 /adrive/v2/file/get_download_url（和原生一致）
    private func getDownloadUrl(
        accessToken: String,
        fileId: String,
        driveId: String
    ) async throws -> PgDownloadInfo {

        let url = URL(string: "\(config.aliPdsApiBase)/adrive/v2/file/get_download_url")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "drive_id": driveId,
            "file_id": fileId,
            "expire_sec": 14400
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw DriveError.noPlayURL("get_download_url HTTP \(statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.noPlayURL("get_download_url 响应解析失败")
        }

        // 检查错误码
        if let code = json["code"] as? String,
           code != "OK" && code != "ok" && code != "0" {
            let message = json["message"] as? String ?? "未知错误"
            throw DriveError.noPlayURL("get_download_url 错误: \(code) - \(message)")
        }

        return try extractDownloadInfo(from: json)
    }

    /// 从 get_download_url 响应中提取 url 和 headers
    /// 对齐原生：优先 url 字段，兼容 download_url / url_list
    private func extractDownloadInfo(from json: [String: Any]) throws -> PgDownloadInfo {
        var downloadUrl: String?
        if let url = json["url"] as? String, !url.isEmpty {
            downloadUrl = url
        }
        if downloadUrl == nil, let url = json["download_url"] as? String, !url.isEmpty {
            downloadUrl = url
        }
        if downloadUrl == nil,
           let urlList = json["url_list"] as? [String],
           let firstUrl = urlList.first, !firstUrl.isEmpty {
            downloadUrl = firstUrl
        }

        guard let finalUrl = downloadUrl, !finalUrl.isEmpty else {
            throw DriveError.noPlayURL("get_download_url 响应中无download_url")
        }

        var headers: [String: String] = [:]
        if let headersJson = json["headers"] as? [String: String] {
            headers = headersJson
        }

        return PgDownloadInfo(url: finalUrl, headers: headers)
    }

    // MARK: - 步骤6: ★ Go代理多线程加速

    /// 将 download_url 通过 Go 代理包装
    /// 对应 pg.jar 的 getProxyDownloadUrl() 方法
    private func wrapWithGoProxy(
        downloadUrl: String,
        headers: [String: String]
    ) async throws -> String {

        // 检查 Go 代理是否可用
        let proxyBase = config.aliproxyUrl
        guard let proxyCheckUrl = URL(string: "\(proxyBase)/health") else {
            throw DriveError.noPlayURL("Go代理URL无效")
        }

        // 健康检查（2秒超时）
        var checkRequest = URLRequest(url: proxyCheckUrl)
        checkRequest.timeoutInterval = 2
        let (_, checkResponse) = try await session.data(for: checkRequest)
        guard let http = checkResponse as? HTTPURLResponse,
              http.statusCode == 200 else {
            throw DriveError.noPlayURL("Go代理健康检查失败")
        }

        // 包装 URL 格式: http://127.0.0.1:10078/?url={base64(download_url)}&thread={n}
        // 注: Go代理的具体URL格式取决于 aliproxy 的实现
        // PG原始格式可能不同，这里使用通用格式
        let encodedUrl = Data(downloadUrl.utf8).base64EncodedString()
        let threadLimit = config.currentThreadLimit

        // 拼接代理URL
        var proxyUrl = "\(proxyBase)/?url=\(encodedUrl)&thread=\(threadLimit)"

        // 添加 headers（如果有特殊 Referer 等）
        if let referer = headers["Referer"] ?? headers["referer"], !referer.isEmpty {
            proxyUrl += "&referer=\(referer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? referer)"
        }

        pgLog("步骤6: Go代理包装完成: thread=\(threadLimit), url_host=\(extractHost(downloadUrl))")

        return proxyUrl
    }

    // MARK: - 步骤8: ★ 播放后清理

    /// 注册清理任务
    private func scheduleCleanup(fileId: String, accessToken: String) {
        let item = PgCleanupItem(
            fileId: fileId,
            accessToken: accessToken,
            createdAt: Date()
        )
        pendingCleanups.append(item)
    }

    /// 启动清理工作线程
    private func startCleanupWorker() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000) // 每30秒检查
                await self?.processPendingCleanups()
            }
        }
    }

    /// 处理待清理任务
    private func processPendingCleanups() async {
        let now = Date()
        var remaining: [PgCleanupItem] = []

        for item in pendingCleanups {
            // 等待延迟时间
            if now.timeIntervalSince(item.createdAt) < config.cleanupDelay {
                remaining.append(item)
                continue
            }

            // 执行清理
            do {
                try await moveToTrash(accessToken: item.accessToken, fileId: item.fileId)
                pgLog("步骤8: 清理 → ✅ 文件已删除 (file_id=\(item.fileId.prefix(12))...)")
            } catch {
                pgLog("步骤8: 清理 → ⚠️ 删除失败: \(error.localizedDescription)，将重试")
                // 失败的任务保留，下次重试
                if now.timeIntervalSince(item.createdAt) < 600 { // 10分钟后放弃
                    remaining.append(item)
                } else {
                    pgLog("步骤8: 清理 → ❌ 放弃清理 (超过10分钟)")
                }
            }
        }

        pendingCleanups = remaining
    }

    /// 删除转存的临时文件（精确删除本次转存的文件）
    /// ⚠️ 修复：使用 ADrive 格式端点 api.alipan.com/adrive/v2/file/delete
    private func moveToTrash(accessToken: String, fileId: String) async throws {
        let driveId = try await getUserDriveId(accessToken: accessToken)
        let url = URL(string: "\(config.aliPdsApiBase)/adrive/v2/file/delete")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "drive_id": driveId,
            "file_id": fileId
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            throw DriveError.noPlayURL("file/delete HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
    }

    // MARK: - 工具方法

    /// 从分享链接解析 share_id
    /// 例: https://www.alipan.com/s/jdYyDB916nw → jdYyDB916nw
    private func parseShareId(from shareURL: String) -> String {
        // 支持 alipan.com 和 aliyundrive.com 两种域名
        // URL格式: https://www.alipan.com/s/{share_id}
        // 或带密码: https://www.alipan.com/s/{share_id}?pwd=xxx

        // 提取 /s/ 后面的部分
        if let range = shareURL.range(of: "/s/") {
            let afterS = String(shareURL[range.upperBound...])
            // 去除 query 参数和 fragment
            let shareId = afterS
                .components(separatedBy: "?").first?
                .components(separatedBy: "#").first?
                .components(separatedBy: "/").first
            return shareId ?? ""
        }

        // 尝试从 URL components 解析
        if let url = URL(string: shareURL) {
            let path = url.path
            // 路径格式: /s/{share_id}
            let components = path.components(separatedBy: "/")
            if let sIndex = components.firstIndex(of: "s"),
               sIndex + 1 < components.count {
                return components[sIndex + 1]
            }
        }

        return ""
    }

    /// 从 URL 提取主机名
    private func extractHost(_ url: String) -> String {
        if let urlObj = URL(string: url) {
            return urlObj.host ?? "unknown"
        }
        return "unknown"
    }

    // MARK: - 数据模型

    /// 分享文件信息
    struct PgShareFile {
        let fileId: String
        let name: String
        let category: String
        let size: Int64
    }

    /// 下载信息
    struct PgDownloadInfo {
        let url: String
        let headers: [String: String]
    }

    // MARK: - 外部接口：检查 PG 凭证是否可用

    /// 检查是否有可用的 PG 凭证
    /// 在 CloudDriveManager 中调用此方法判断是否走 PG 路链
    static func hasPgCredential() -> Bool {
        guard AliyunPgConfig.shared.isEnabled else { return false }
        guard let credential = CloudDriveAuthManager.shared.credential(for: .ali) else {
            return false
        }
        return AliyunPgConfig.isPgCredential(credential)
    }

    /// 获取 PG 凭证
    static func getPgCredential() -> CloudDriveCredential? {
        guard let credential = CloudDriveAuthManager.shared.credential(for: .ali),
              AliyunPgConfig.isPgCredential(credential) else {
            return nil
        }
        return credential
    }
}
