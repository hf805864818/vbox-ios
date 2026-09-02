//
//  AliyunPgAuthManager.swift
//  vbox
//
//  PG 阿里云盘认证管理器 — 通过 extscreen API 实现 OAuth 扫码登录
//  与 vbox 现有 CloudDriveAuthManager 集成，完全独立新增
//
//  ★ 不修改 CloudDriveAuthManager 现有方法
//  ★ 不影响百度/夸克/UC 网盘的任何逻辑
//

import Foundation
import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - PG 扫码状态

enum PgQrLoginState: Equatable {
    case idle
    case loading
    case waitingScan
    case scanned
    case exchanging
    case success
    case error(String)

    var displayText: String {
        switch self {
        case .idle: return "准备中"
        case .loading: return "正在生成二维码..."
        case .waitingScan: return "请使用阿里云盘 App 扫码"
        case .scanned: return "已扫码，请在手机上确认"
        case .exchanging: return "正在获取 Token..."
        case .success: return "登录成功！"
        case .error(let msg): return "错误: \(msg)"
        }
    }
}

// MARK: - PG 认证管理器

class AliyunPgAuthManager: ObservableObject {

    static let shared = AliyunPgAuthManager()

    @Published var qrLoginState: PgQrLoginState = .idle
    @Published var qrCodeImage: UIImage?
    @Published var qrCodeLink: String?

    private var isCancelled = false

    private init() {}

    // MARK: - 完整扫码登录流程

    func startQrLogin() async {
        await MainActor.run {
            qrLoginState = .loading
            qrCodeImage = nil
            qrCodeLink = nil
            isCancelled = false
        }

        do {
            // Step 0: 初始化加密器
            let crypto = try await ExtscreenAPIClient.shared.makeCrypto()

            // Step 1: 生成二维码
            let (qrLink, sid) = try await ExtscreenAPIClient.shared.getQrcode(crypto: crypto)
            let qrImage = generateQRImage(from: qrLink)

            await MainActor.run {
                self.qrCodeLink = qrLink
                self.qrCodeImage = qrImage
                self.qrLoginState = .waitingScan
            }

            // Step 2: 轮询扫码状态
            let authCode = try await ExtscreenAPIClient.shared.pollQrcodeStatus(
                sid: sid,
                timeout: 120
            ) { [weak self] status in
                Task { @MainActor in
                    guard let self = self else { return }
                    switch status {
                    case "New":
                        self.qrLoginState = .waitingScan
                    case "Scaned":
                        self.qrLoginState = .scanned
                    case "LoginSuccess":
                        self.qrLoginState = .exchanging
                    case "Expired":
                        self.qrLoginState = .error("二维码已过期，请重试")
                    default:
                        break
                    }
                }
            }

            guard !isCancelled else { return }

            // Step 3: authCode 换取 refresh_token
            let refreshToken = try await ExtscreenAPIClient.shared.getRefreshToken(
                authCode: authCode,
                crypto: crypto
            )

            // Step 4: 保存凭证
            savePgCredential(refreshToken: refreshToken, crypto: crypto)

            // Step 5: 刷新 access_token
            let refreshResult = try await ExtscreenAPIClient.shared.refreshToken(
                refreshToken: refreshToken,
                crypto: crypto
            )

            updateAccessToken(
                accessToken: refreshResult.accessToken,
                newRefreshToken: refreshResult.newRefreshToken,
                expiresIn: refreshResult.expiresIn
            )

            await MainActor.run {
                self.qrLoginState = .success
            }

            print("[PG] 阿里云盘扫码登录完成！")

        } catch {
            await MainActor.run {
                self.qrLoginState = .error(error.localizedDescription)
            }
            print("[PG] 扫码登录失败: \(error)")
        }
    }

    func cancel() {
        isCancelled = true
        DispatchQueue.main.async {
            self.qrLoginState = .idle
        }
    }

    // MARK: - 凭证存储（与 vbox 集成）

    private func savePgCredential(refreshToken: String, crypto: ExtscreenCrypto) {
        let extra: [String: String] = [
            "pg_source": "qr_scan",
            "pg_timestamp": crypto.timestamp,
            "is_vip": "false",
            "vip_thread_limit": "32",
            "vod_flags": "4kz|auto",
        ]

        let credential = CloudDriveCredential(
            driveType: CloudDriveManager.DriveType.ali.rawValue,
            authType: .manual,
            accessToken: nil,
            refreshToken: refreshToken,
            cookie: nil,
            driveId: nil,
            userId: nil,
            userName: nil,
            avatar: nil,
            expiresAt: nil,
            updatedAt: Date(),
            lastCheckedAt: nil,
            state: .valid,
            statusMessage: "PG extscreen 扫码登录",
            extra: extra
        )

        CloudDriveAuthManager.shared.saveCredential(credential)

        print("[PG] 凭证已保存")
    }

    private func updateAccessToken(
        accessToken: String,
        newRefreshToken: String?,
        expiresIn: Int?
    ) {
        guard var cred = CloudDriveAuthManager.shared.credential(for: .ali) else {
            print("[PG] 未找到凭证，无法更新 access_token")
            return
        }

        cred.accessToken = accessToken
        if let newRt = newRefreshToken, !newRt.isEmpty {
            cred.refreshToken = newRt
        }
        cred.expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn ?? 7200))
        cred.state = .valid
        cred.statusMessage = "PG access_token 已刷新"
        cred.lastCheckedAt = Date()
        cred.updatedAt = Date()

        CloudDriveAuthManager.shared.saveCredential(cred)
        print("[PG] access_token 已更新")
    }

    // MARK: - Token 刷新（PG extscreen 方式）

    func refreshViaExtscreen(credential: CloudDriveCredential) async throws -> CloudDriveCredential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw ExtscreenError.tokenRefreshFailed
        }

        let timestamp = try await ExtscreenAPIClient.shared.getTimestamp()
        let crypto = ExtscreenCrypto(timestamp: timestamp)

        let result = try await ExtscreenAPIClient.shared.refreshToken(
            refreshToken: refreshToken,
            crypto: crypto
        )

        var cred = credential
        cred.accessToken = result.accessToken
        if let newRt = result.newRefreshToken, !newRt.isEmpty {
            cred.refreshToken = newRt
        }
        cred.expiresAt = Date().addingTimeInterval(TimeInterval(result.expiresIn ?? 7200))
        cred.state = .valid
        cred.statusMessage = "PG extscreen 刷新成功"
        cred.lastCheckedAt = Date()
        cred.updatedAt = Date()
        cred.extra["pg_timestamp"] = timestamp

        CloudDriveAuthManager.shared.saveCredential(cred)
        print("[PG] extscreen 刷新成功")
        return cred
    }

    // MARK: - 工具

    private func generateQRImage(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)

        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    var hasPgCredential: Bool {
        guard let cred = CloudDriveAuthManager.shared.credential(for: .ali) else {
            return false
        }
        return cred.extra["pg_source"] != nil
    }

    func getPgPlayParams() -> (isVip: Bool, threadLimit: Int, vodFlags: String) {
        guard let cred = CloudDriveAuthManager.shared.credential(for: .ali) else {
            return (false, 8, "4k|auto")
        }

        let isVip = cred.extra["is_vip"] == "true"
        let threadLimit = Int(cred.extra["vip_thread_limit"] ?? "8") ?? 8
        let vodFlags = cred.extra["vod_flags"] ?? "4k|auto"

        return (isVip, isVip ? threadLimit : 8, vodFlags)
    }
}
