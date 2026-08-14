import SwiftUI

// MARK: - 福利平台域名设置页面（多域名管理 + 代理设置）

struct WelfareSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = WelfareDomainStore.shared
    @ObservedObject private var proxyStore = WelfareProxyStore.shared
    @ObservedObject private var remoteConfigStore = WelfarePlatformConfigStore.shared
    @State private var editingPlatform: String? = nil
    @State private var editDomain: String = ""
    @State private var savedToast: String? = nil
    @State private var refreshID = UUID()
    @FocusState private var isFocused: Bool

    // 代理设置相关
    @State private var proxyInput: String = ""
    @State private var isProxyExpanded: Bool = true
    @FocusState private var proxyFocused: Bool

    // 阶段3 改造：兼容模式下不再硬编码任何福利平台，
    // 所有平台由远程源统一配置驱动，用户需开启远程源后在 RemoteWelfareSettingsView 中管理。
    private let platforms: [(name: String, icon: String, defaultHosts: [String])] = []

    var body: some View {
        if remoteConfigStore.switchEnabled {
            RemoteWelfareSettingsView()
        } else {
            builtinSettingsBody
        }
    }

    // MARK: - 内置资源域名设置主体

    private var builtinSettingsBody: some View {
        ZStack {
            List {
                // 远程源总开关
                Section {
                    Toggle(isOn: $remoteConfigStore.switchEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("使用福利远程源")
                                .font(.system(size: 16, weight: .semibold))
                            Text(remoteConfigStore.switchEnabled
                                 ? "开启：使用远程源中的福利平台列表"
                                 : "关闭：使用内置资源版本（与升级前一致）")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                    .tint(.accentColor)
                } footer: {
                    Text("关闭后，福利专区将回到内置资源版本，所有现有数据和播放功能不受影响。")
                        .font(.system(size: 11))
                }

                // 代理设置 Section
                Section {
                    proxySection
                } header: {
                    Text("代理设置")
                } footer: {
                    Text("支持 URL 转发代理格式，在代理地址末尾拼接原始URL")
                        .font(.system(size: 12))
                }

                Section {
                    Text("添加自定义域名后，系统会按顺序轮询。第一个可用的域名将被使用。左滑可删除已保存的域名。")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                Section {
                    if platforms.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.up.circle")
                                .font(.system(size: 32))
                                .foregroundColor(.accentColor)
                            Text("请开启上方「使用福利远程源」")
                                .font(.system(size: 14, weight: .medium))
                            Text("开启后可在远程源设置页管理各平台的域名和代理")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    } else {
                        ForEach(platforms, id: \.name) { platform in
                            platformRow(platform)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .id(refreshID)
            .onAppear {
                proxyInput = proxyStore.proxyURL
            }

            // 添加域名弹窗
            if let platform = editingPlatform {
                Color.black.opacity(0.3).ignoresSafeArea()
                    .onTapGesture { editingPlatform = nil }

                VStack(spacing: 20) {
                    Text("添加 \(platform) 域名")
                        .font(.system(size: 17, weight: .semibold))

                    TextField("输入新域名，如 https://example.com", text: $editDomain)
                        .font(.system(size: 14, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit { doAdd() }

                    HStack(spacing: 16) {
                        Button(action: { editingPlatform = nil }) {
                            Text("取消").font(.system(size: 15, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color(UIColor.secondarySystemBackground)).cornerRadius(10)
                        }
                        .buttonStyle(.plain)

                        Button(action: { doAdd() }) {
                            Text("添加").font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color.accentColor).cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(16).shadow(radius: 20)
                .padding(.horizontal, 30)
                .animation(.spring(response: 0.3), value: editingPlatform)
                .zIndex(10)
            }
        }
        .navigationTitle("福利平台设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }.font(.system(size: 15, weight: .semibold))
            }
        }
        .overlay(alignment: .top) {
            if let toast = savedToast {
                Text(toast).font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Color.green, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8).zIndex(20)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { savedToast = nil }
                        }
                    }
            }
        }
    }

    // MARK: - 代理设置 Section

    @ViewBuilder
    private var proxySection: some View {
        VStack(spacing: 12) {
            // 代理 URL 输入
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .foregroundColor(.accentColor)
                    .frame(width: 20)
                TextField("输入代理地址，如 https://your-proxy.com/?url=", text: $proxyInput)
                    .font(.system(size: 14, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .focused($proxyFocused)
                    .submitLabel(.done)
                    .onSubmit { saveProxy() }
            }

            // 保存/清除按钮
            HStack(spacing: 12) {
                Button(action: { saveProxy() }) {
                    Text("保存代理")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(proxyInput.isEmpty)

                if !proxyStore.proxyURL.isEmpty {
                    Button(action: { clearProxy() }) {
                        Text("清除代理")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }

            // 平台代理开关（折叠）
            Divider()
                .padding(.vertical, 4)

            Button(action: {
                withAnimation { isProxyExpanded.toggle() }
            }) {
                HStack {
                    Image(systemName: isProxyExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("平台代理开关")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    if proxyStore.proxyURL.isEmpty {
                        Text("未设置代理")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(enabledProxyCount)/\(platforms.count) 已开启")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            if isProxyExpanded {
                VStack(spacing: 0) {
                    ForEach(platforms, id: \.name) { platform in
                        proxyPlatformRow(platform)
                        if platform.name != platforms.last?.name {
                            Divider()
                                .padding(.leading, 32)
                        }
                    }
                }
                .padding(.top, 4)
                .opacity(proxyStore.proxyURL.isEmpty ? 0.5 : 1.0)
                .disabled(proxyStore.proxyURL.isEmpty)
            }
        }
        .padding(.vertical, 4)
    }

    private var enabledProxyCount: Int {
        platforms.filter { proxyStore.isProxyEnabled(for: $0.name) }.count
    }

    // MARK: - 平台代理开关行

    @ViewBuilder
    private func proxyPlatformRow(_ platform: (name: String, icon: String, defaultHosts: [String])) -> some View {
        HStack {
            Image(systemName: platform.icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            Text(platform.name)
                .font(.system(size: 14))
            Spacer()
            Toggle("", isOn: Binding(
                get: { proxyStore.isProxyEnabled(for: platform.name) },
                set: { newValue in
                    proxyStore.setProxyEnabled(newValue, for: platform.name)
                    if newValue {
                        resetService(for: platform.name)
                    }
                    refreshID = UUID()
                }
            ))
            .labelsHidden()
            .tint(.accentColor)
        }
        .padding(.vertical, 6)
        .padding(.leading, 4)
    }

    // MARK: - 平台行（域名设置）

    @ViewBuilder
    private func platformRow(_ platform: (name: String, icon: String, defaultHosts: [String])) -> some View {
        let customs = store.domains(for: platform.name)

        VStack(alignment: .leading, spacing: 8) {
            // 平台名称 + 添加按钮
            HStack {
                Image(systemName: platform.icon).foregroundColor(.accentColor)
                Text(platform.name).font(.system(size: 15, weight: .medium))

                // 代理状态标识
                if proxyStore.isProxyEnabled(for: platform.name) {
                    Image(systemName: "network")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(4)
                }

                Spacer()
                Button(action: {
                    editingPlatform = platform.name
                    editDomain = ""
                    isFocused = true
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.borderless)
            }

            // 默认域名
            if !platform.defaultHosts.isEmpty {
                HStack(spacing: 4) {
                    Text("默认：").font(.system(size: 11)).foregroundColor(.secondary)
                    Text(platform.defaultHosts[0])
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary).lineLimit(1)
                }
            }

            // 自定义域名列表（每个单独一行 + 删除按钮）
            ForEach(customs, id: \.self) { domain in
                HStack {
                    Image(systemName: "link").font(.system(size: 10)).foregroundColor(.accentColor)
                    Text(domain).font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.accentColor).lineLimit(1)
                    Spacer()
                    Button(action: {
                        store.removeDomain(for: platform.name, domain)
                        resetService(for: platform.name)
                        refreshID = UUID()
                        showToast("已删除域名")
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 4).padding(.horizontal, 8)
                .background(Color.accentColor.opacity(0.06))
                .cornerRadius(6)
            }

            // 全部重置按钮
            if !customs.isEmpty {
                Button(action: {
                    store.clearDomains(for: platform.name)
                    clearAndReset(for: platform.name)
                    refreshID = UUID()
                    showToast("已恢复默认域名")
                }) {
                    Text("全部重置为默认")
                        .font(.system(size: 12)).foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }

            // 统计
            let total = customs.count + platform.defaultHosts.count
            if total > 0 {
                Text("共 \(total) 个域名，按顺序轮询")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 代理相关方法

    private func saveProxy() {
        let trimmed = proxyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        proxyStore.setProxyURL(trimmed)

        // 所有代理开关默认关闭，不自动开启任何平台

        showToast("代理已保存")
        proxyFocused = false
        refreshID = UUID()
    }

    private func clearProxy() {
        proxyStore.clearProxyURL()
        proxyInput = ""
        // 重置所有平台服务
        for platform in platforms {
            resetService(for: platform.name)
        }
        showToast("代理已清除")
        refreshID = UUID()
    }

    // MARK: - 辅助方法

    private func doAdd() {
        guard let platform = editingPlatform else { return }
        let trimmed = editDomain.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.addDomain(for: platform, trimmed)
        showToast("域名已添加")
        editingPlatform = nil
        refreshID = UUID()
        resetService(for: platform)
    }

    private func showToast(_ msg: String) {
        withAnimation { savedToast = msg }
    }

    private func resetService(for name: String) {
        // 阶段3 改造：兼容模式下不再硬编码任何平台，
        // 所有平台域名/代理管理在 RemoteWelfareSettingsView 中处理。
        // 此函数保留 no-op，避免 caller 编译报错。
        _ = name
    }

    private func clearAndReset(for name: String) {
        // 阶段3 改造：兼容模式下不再硬编码任何平台，
        // 所有平台域名/代理管理在 RemoteWelfareSettingsView 中处理。
        // 此函数保留 no-op，避免 caller 编译报错。
        _ = name
    }
}
