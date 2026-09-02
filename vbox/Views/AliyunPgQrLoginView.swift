//
//  AliyunPgQrLoginView.swift
//  vbox
//
//  PG 阿里云盘扫码登录 UI — SwiftUI 折叠区
//

import SwiftUI

struct AliyunPgQrLoginView: View {

    @StateObject private var authManager = AliyunPgAuthManager.shared
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 20) {
                PgQrCodeSection()
                Divider().padding(.vertical, 4)
                PgPlayConfigSection()
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.purple)
                Text("PG 扫码登录")
                    .fontWeight(.medium)
                Spacer()
                if authManager.hasPgCredential {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
                Text("extscreen")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 扫码区

private struct PgQrCodeSection: View {

    @StateObject private var authManager = AliyunPgAuthManager.shared

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(authManager.qrLoginState.displayText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                if authManager.hasPgCredential {
                    Text("已登录")
                        .font(.caption)
                        .foregroundColor(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(12)
                }
            }

            HStack(spacing: 12) {
                if authManager.qrLoginState == .waitingScan ||
                   authManager.qrLoginState == .scanned ||
                   authManager.qrLoginState == .exchanging {
                    Button(action: { authManager.cancel() }) {
                        Text("取消")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.1))
                            .foregroundColor(.red)
                            .cornerRadius(8)
                    }
                } else {
                    Button {
                        Task {
                            await authManager.startQrLogin()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "qrcode.viewfinder")
                            Text(authManager.hasPgCredential ? "重新扫码" : "PG 扫码登录")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.purple)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }
            }

            if authManager.qrLoginState == .waitingScan ||
               authManager.qrLoginState == .scanned {
                if let qrImage = authManager.qrCodeImage {
                    VStack(spacing: 8) {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                            .cornerRadius(8)
                            .shadow(radius: 4)
                        Text("用阿里云盘 App 扫描二维码")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }

            if authManager.qrLoginState == .loading ||
               authManager.qrLoginState == .exchanging {
                ProgressView().scaleEffect(1.2)
            }

            if case .error(let msg) = authManager.qrLoginState {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
                .cornerRadius(8)
            }
        }
        .padding(.vertical, 8)
    }

    private var statusColor: Color {
        switch authManager.qrLoginState {
        case .idle: return .gray
        case .loading: return .orange
        case .waitingScan: return .blue
        case .scanned: return .yellow
        case .exchanging: return .orange
        case .success: return .green
        case .error: return .red
        }
    }
}

// MARK: - PG 播放参数

private struct PgPlayConfigSection: View {

    @State private var isVip = false
    @State private var vipThreadLimit = 32
    @State private var vodFlags = "4kz|auto"
    @State private var showSaved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("播放参数", systemImage: "play.circle.fill")
                .font(.headline)
                .foregroundColor(.secondary)

            Toggle("VIP 用户", isOn: $isVip)

            if isVip {
                HStack {
                    Text("并发线程").foregroundColor(.secondary)
                    Spacer()
                    Stepper("\(vipThreadLimit)", value: $vipThreadLimit, in: 1...64)
                    Text("\(vipThreadLimit)").monospacedDigit().frame(width: 30)
                }
            }

            HStack {
                Text("画质").foregroundColor(.secondary)
                Spacer()
                Picker("画质", selection: $vodFlags) {
                    Text("原画 4K").tag("4kz|auto")
                    Text("高清 FHD").tag("fhd")
                    Text("高清 HD").tag("hd")
                    Text("标清 SD").tag("sd")
                    Text("流畅 LD").tag("ld")
                }
                .pickerStyle(MenuPickerStyle())
            }

            Button(action: saveConfig) {
                Text("保存参数")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue)
                    .cornerRadius(8)
            }
        }
        .padding(.vertical, 4)
        .alert("已保存", isPresented: $showSaved) {
            Button("确定") { }
        } message: {
            Text("PG 播放参数已更新")
        }
        .onAppear { loadConfig() }
    }

    private func loadConfig() {
        let params = AliyunPgAuthManager.shared.getPgPlayParams()
        isVip = params.isVip
        vipThreadLimit = params.threadLimit
        vodFlags = params.vodFlags
    }

    private func saveConfig() {
        guard var cred = CloudDriveAuthManager.shared.credential(for: .ali) else {
            showSaved = true
            return
        }
        cred.extra["is_vip"] = isVip ? "true" : "false"
        cred.extra["vip_thread_limit"] = String(vipThreadLimit)
        cred.extra["vod_flags"] = vodFlags
        cred.updatedAt = Date()
        CloudDriveAuthManager.shared.saveCredential(cred)
        showSaved = true
    }
}
