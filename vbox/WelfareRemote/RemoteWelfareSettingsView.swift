//
//  RemoteWelfareSettingsView.swift
//  vbox
//
//  Phase 2：iOS 客户端新增文件（不改任何现有代码）
//  作用：远程源福利平台设置页面，与现有 WelfareSettingsView 并行存在。
//        - 顶部「使用福利远程源」Toggle（默认开）
//        - 关闭时给提示语：当前将使用内置资源版本
//        - 平台列表：从 WelfarePlatformConfigStore 拉取
//        - 每个平台展示：图标 + 名称 + 描述 + 当前域名 + 编辑域名
//        - 域名修改：写入 WelfareDomainStore（与旧版共享同一 store）
//        - 顶部「立即同步」按钮：手动刷新远程源
//
//  使用：
//    if WelfarePlatformConfigStore.shared.switchEnabled {
//        RemoteWelfareSettingsView()
//    } else {
//        WelfareSettingsView()  // 旧版
//    }
//

import SwiftUI

struct RemoteWelfareSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var configStore = WelfarePlatformConfigStore.shared
    @ObservedObject private var domainStore = WelfareDomainStore.shared

    @State private var editingPlatform: WelfarePlatform?
    @State private var editDomain: String = ""
    @State private var savedToast: String?

    // 代理设置相关
    @ObservedObject private var proxyStore = WelfareProxyStore.shared
    @State private var proxyInput: String = ""
    @State private var isProxyExpanded: Bool = false
    @FocusState private var proxyFocused: Bool

    var body: some View {
        List {
            // 1. 顶部：远程源开关
            switchSection

            // 2. 远程源状态信息
            statusSection

            // 3. 代理设置
            proxySection

            // 4. 平台列表（按 category 分组）
            ForEach(RemoteWelfareCategory.allCases) { cat in
                let plats = configStore.platforms(in: cat)
                if !plats.isEmpty {
                    Section(header: Text(cat.displayName)) {
                        ForEach(plats) { platform in
                            platformRow(platform)
                        }
                    }
                }
            }

            // 5. 底部：调试按钮
            debugSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("福利平台设置（远程源）")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            proxyInput = proxyStore.proxyURL
        }
        .sheet(item: $editingPlatform) { p in
            domainEditSheet(platform: p)
        }
        .overlay(alignment: .top) {
            if let toast = savedToast {
                Text(toast)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.85))
                    )
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - 开关 Section

    private var switchSection: some View {
        Section {
            Toggle(isOn: $configStore.switchEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("使用福利远程源")
                        .font(.system(size: 16, weight: .semibold))
                    Text(configStore.switchEnabled
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
    }

    // MARK: - 状态 Section

    private var statusSection: some View {
        Section(header: Text("远程源状态")) {
            HStack {
                Image(systemName: statusIconName)
                    .foregroundColor(statusColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.system(size: 14, weight: .medium))
                    if let detail = statusDetail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button(action: manualRefresh) {
                    HStack(spacing: 4) {
                        if case .loading = configStore.loadState {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("立即同步")
                    }
                    .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var statusIconName: String {
        switch configStore.loadState {
        case .idle: return "icloud.slash"
        case .loading: return "icloud.and.arrow.down"
        case .loaded: return "checkmark.icloud.fill"
        case .failed: return "exclamationmark.icloud.fill"
        }
    }

    private var statusColor: Color {
        switch configStore.loadState {
        case .idle: return .secondary
        case .loading: return .blue
        case .loaded: return .green
        case .failed: return .red
        }
    }

    private var statusTitle: String {
        switch configStore.loadState {
        case .idle: return "未加载"
        case .loading: return "正在拉取…"
        case .loaded(let count, _): return "已就绪 · \(count) 个平台"
        case .failed: return "拉取失败"
        }
    }

    private var statusDetail: String? {
        switch configStore.loadState {
        case .loaded(_, let v):
            if let v = v { return "version: \(v)" }
            return configStore.lastSuccessTime.map { "上次成功：\($0.formatted(date: .abbreviated, time: .shortened))" }
        case .failed(let msg):
            return msg
        default:
            return configStore.lastSuccessTime.map { "上次成功：\($0.formatted(date: .abbreviated, time: .shortened))" }
        }
    }

    // MARK: - 代理设置 Section

    /// 所有平台的扁平列表（跨分类）
    private var allPlatforms: [WelfarePlatform] {
        RemoteWelfareCategory.allCases.flatMap { configStore.platforms(in: $0) }
    }

    private var enabledProxyCount: Int {
        allPlatforms.filter { proxyStore.isProxyEnabled(for: $0.name) }.count
    }

    @ViewBuilder
    private var proxySection: some View {
        Section {
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
                            Text("\(enabledProxyCount)/\(allPlatforms.count) 已开启")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                if isProxyExpanded {
                    VStack(spacing: 0) {
                        ForEach(Array(allPlatforms.enumerated()), id: \.element.platformKey) { idx, platform in
                            proxyPlatformRow(platform)
                            if idx < allPlatforms.count - 1 {
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
        } header: {
            Text("代理设置")
        } footer: {
            Text("支持 URL 转发代理格式，在代理地址末尾拼接原始URL")
                .font(.system(size: 12))
        }
    }

    // MARK: - 平台代理开关行

    @ViewBuilder
    private func proxyPlatformRow(_ platform: WelfarePlatform) -> some View {
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
                        triggerServiceReset(for: platform)
                    }
                }
            ))
            .labelsHidden()
            .tint(.accentColor)
        }
        .padding(.vertical, 6)
        .padding(.leading, 4)
    }

    // MARK: - 代理相关方法

    private func saveProxy() {
        let trimmed = proxyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        proxyStore.setProxyURL(trimmed)
        // 所有代理开关默认关闭，不自动开启任何平台
        showToast("代理已保存")
        proxyFocused = false
    }

    private func clearProxy() {
        proxyStore.clearProxyURL()
        proxyInput = ""
        // 重置所有平台服务
        for platform in allPlatforms {
            triggerServiceReset(for: platform)
        }
        showToast("代理已清除")
    }

    // MARK: - 平台行

    private func platformRow(_ platform: WelfarePlatform) -> some View {
        Button {
            editingPlatform = platform
            editDomain = ""
        } label: {
            HStack(spacing: 12) {
                // 图标
                Image(systemName: platform.icon)
                    .font(.system(size: 18))
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                    )
                    .foregroundColor(.accentColor)
                // 名称 + 描述
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(platform.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.primary)
                        // 代理状态标识
                        if proxyStore.isProxyEnabled(for: platform.name) {
                            Image(systemName: "network")
                                .font(.system(size: 10))
                                .foregroundColor(.green)
                        }
                        Text("[\(platform.platformKey)]")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    Text(platform.desc)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(currentDomain(for: platform))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 130, alignment: .trailing)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
        }
    }

    // MARK: - 调试 Section

    private var debugSection: some View {
        Section(header: Text("调试")) {
            Button(action: { configStore.clearAllCache() }) {
                Label("清空远程源缓存", systemImage: "trash")
                    .foregroundColor(.red)
            }
        }
    }

    // MARK: - 域名编辑 Sheet

    private func domainEditSheet(platform: WelfarePlatform) -> some View {
        NavigationView {
            Form {
                domainEditPlatformSection(platform: platform)
                domainEditAddSection(platform: platform)
                domainEditDefaultHostsSection(platform: platform)
                domainEditCustomDomainsSection(platform: platform)
                domainEditDoneSection
            }
            .navigationTitle("编辑域名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { editingPlatform = nil }
                }
            }
        }
    }

    // MARK: - 域名编辑 Sheet 子视图（拆分以避免类型检查器超时）

    @ViewBuilder
    private func domainEditPlatformSection(platform: WelfarePlatform) -> some View {
        Section(header: Text("平台")) {
            HStack {
                Image(systemName: platform.icon)
                Text(platform.name)
                Spacer()
                Text("[\(platform.platformKey)]")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func domainEditAddSection(platform: WelfarePlatform) -> some View {
        Section(header: Text("添加新域名")) {
            TextField("https://example.com", text: $editDomain)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .autocorrectionDisabled(true)
            Button("添加域名") {
                addCustomDomain(for: platform)
            }
            .disabled(editDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private func domainEditDefaultHostsSection(platform: WelfarePlatform) -> some View {
        Section(header: Text("默认域名（按优先级）")) {
            ForEach(Array(platform.defaultHosts.enumerated()), id: \.offset) { idx, host in
                HStack {
                    Text("\(idx + 1).")
                        .foregroundColor(.secondary)
                    Text(host)
                        .font(.system(size: 13))
                    Spacer()
                    if currentDomain(for: platform) == host {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func domainEditCustomDomainsSection(platform: WelfarePlatform) -> some View {
        Section(header: Text("自定义域名")) {
            if domainStore.domains(for: platform.name).isEmpty {
                Text("暂无自定义域名。添加后会显示在这里，可随时删除。")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            } else {
                ForEach(domainStore.domains(for: platform.name), id: \.self) { domain in
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .font(.system(size: 12))
                            .foregroundColor(.accentColor)
                        Text(domain)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            removeCustomDomain(domain, for: platform)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Button(role: .destructive) {
                    clearCustomDomains(for: platform)
                } label: {
                    Text("全部删除自定义域名")
                }
            }
        } footer: {
            Text("播放时会优先尝试自定义域名，再回退默认域名。")
                .font(.system(size: 11))
        }
    }

    @ViewBuilder
    private var domainEditDoneSection: some View {
        Section {
            Button("完成") {
                editingPlatform = nil
            }
            .frame(maxWidth: .infinity)
            .foregroundColor(.white)
            .listRowBackground(Color.accentColor)
        }
    }

    // MARK: - 域名持久化

    private func currentDomain(for platform: WelfarePlatform) -> String {
        // 优先用 WelfareDomainStore 中的自定义域名
        if let custom = WelfareDomainStore.shared.domains(for: platform.name).first {
            return custom
        }
        // 否则用平台 defaultHosts 第一个
        return platform.primaryHost
    }

    private func addCustomDomain(for platform: WelfarePlatform) {
        let domain = editDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty,
              URL(string: domain) != nil,
              domain.hasPrefix("http://") || domain.hasPrefix("https://") else {
            showToast("域名格式错误")
            return
        }
        WelfareDomainStore.shared.addDomain(for: platform.name, domain)
        editDomain = ""

        // 触发对应 Service 重新探测
        triggerServiceReset(for: platform)

        showToast("域名已添加")
    }

    private func removeCustomDomain(_ domain: String, for platform: WelfarePlatform) {
        WelfareDomainStore.shared.removeDomain(for: platform.name, domain)
        triggerServiceReset(for: platform)
        showToast("域名已删除")
    }

    private func clearCustomDomains(for platform: WelfarePlatform) {
        WelfareDomainStore.shared.clearDomains(for: platform.name)
        triggerServiceReset(for: platform)
        showToast("已恢复默认域名")
    }

    private func triggerServiceReset(for platform: WelfarePlatform) {
        let type = WelfareServiceType(raw: platform.serviceType)
        switch type {
        case .dailyBattle:
            DailyBattleService.shared.reprobe()
            DailyBattleService.contest.reprobe()
        case .luoliAv:
            LuoliAVService.shared.reprobe()
        case .madouFree:
            MadouFreeService.shared.reprobe()
        case .jiujiu:
            JiujiuService.shared.reprobe()
        case .koreanPorn:
            KoreanPornService.shared.reprobe()
        case .kanliao:
            KanliaoService.shared.reprobe()
        case .heiliao:
            HeiliaoService.shared.reprobe()
        case .xigua:
            XiguaService.shared.reprobe()
        case .aidanVideo:
            AidanVideoService.shared.reprobe()
        case .aidanComic:
            AidanComicService.shared.reprobe()
        case .remoteCmsV10:
            RemoteCMSV10Service.service(for: platform).reprobe()
        case .mysteryMovie, .sihuVideo, .xcp, .sbAggregation, .fuliBase, .yboxSpecial, .yboxXjsp, .welfareSpider, .unknown:
            // 这些 Service 当前未暴露 reprobe()，域名已通过 WelfareDomainStore 持久化，
            // 下次进入页面会从 domain store 读取最新域名。
            break
        }
    }

    // MARK: - 手动刷新

    private func manualRefresh() {
        configStore.refresh { result in
            switch result {
            case .success(let count):
                showToast("已同步 · \(count) 个平台")
            case .failure(let err):
                showToast("同步失败：\(err.localizedDescription)")
            }
        }
    }

    // MARK: - Toast

    private func showToast(_ text: String) {
        withAnimation { savedToast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { savedToast = nil }
        }
    }
}
