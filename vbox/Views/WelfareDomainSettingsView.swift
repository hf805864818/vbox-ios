import SwiftUI

// MARK: - 福利平台域名管理页面
struct WelfareDomainSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var searchText = ""
    @State private var selectedPlatform: WelfareCrawlerConfig?
    @State private var showEditSheet = false
    @State private var customURLText = ""
    @State private var refreshTrigger = false

    // 按内容类型分组
    private var groupedPlatforms: [(String, [WelfareCrawlerConfig])] {
        let all = WelfareCrawlerConfig.all
        let filtered = searchText.isEmpty ? all : all.filter {
            $0.platformName.localizedCaseInsensitiveContains(searchText)
                || $0.platformId.localizedCaseInsensitiveContains(searchText)
        }
        let dict = Dictionary(grouping: filtered) { $0.contentType.displayName }
        return dict.sorted { $0.key < $1.key }
    }

    @AppStorage("live_proxy_url") private var liveProxyURL: String = ""
    @State private var proxyInputText: String = ""

    var body: some View {
        List {
            // 直播代理设置（置顶）
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundColor(.purple)
                        Text("直播代理地址")
                            .font(.system(size: 15, weight: .medium))
                    }

                    TextField("如 https://vbox.ltd/?token=xxx&url=", text: $proxyInputText)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .font(.system(size: 13))
                        .onAppear { proxyInputText = liveProxyURL }
                        .onChange(of: proxyInputText) { newValue in
                            liveProxyURL = newValue
                        }

                    Text("填上代理地址后，直播频道的播放地址会通过此代理转发，解决部分直播源无法直连的问题。留空则不使用代理。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            // 说明
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    Text("点击平台可修改接口域名，修改后立即生效")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }

            // 平台列表（按类型分组）
            ForEach(groupedPlatforms, id: \.0) { groupName, platforms in
                Section(header: Text(groupName)) {
                    ForEach(platforms) { platform in
                        platformRow(platform)
                    }
                }
            }

            // 底部操作
            Section {
                Button(role: .destructive) {
                    resetAll()
                } label: {
                    HStack {
                        Spacer()
                        Text("清除所有自定义域名")
                            .foregroundColor(.red)
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("平台域名管理")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索平台名称或ID")
        .sheet(isPresented: $showEditSheet) {
            if let platform = selectedPlatform {
                editSheet(platform)
            }
        }
    }

    // MARK: 平台行
    private func platformRow(_ platform: WelfareCrawlerConfig) -> some View {
        Button {
            selectedPlatform = platform
            customURLText = platform.customBaseURL ?? ""
            showEditSheet = true
        } label: {
            HStack(spacing: 12) {
                // 图标
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(platform.contentType.color.opacity(0.15))
                    Image(systemName: platform.contentType.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(platform.contentType.color)
                }
                .frame(width: 36, height: 36)

                // 名称 + 域名
                VStack(alignment: .leading, spacing: 3) {
                    Text(platform.platformName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(textColor)
                    Text(displayURL(platform))
                        .font(.system(size: 12))
                        .foregroundColor(platform.hasCustomURL ? .green : .secondary)
                        .lineLimit(1)
                }

                Spacer()

                // 自定义标识
                if platform.hasCustomURL {
                    Text("已自定义")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15))
                        .foregroundColor(.green)
                        .cornerRadius(4)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: 编辑弹窗
    private func editSheet(_ platform: WelfareCrawlerConfig) -> some View {
        NavigationView {
            Form {
                Section("平台信息") {
                    HStack {
                        Text("平台名称")
                        Spacer()
                        Text(platform.platformName)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("平台ID")
                        Spacer()
                        Text(platform.platformId)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("默认域名")
                        Spacer()
                        Text(platform.baseURL)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 200, alignment: .trailing)
                    }
                }

                Section("自定义域名") {
                    TextField("输入新的接口域名，如 https://example.com", text: $customURLText)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    Text("留空则恢复使用默认域名")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("修改域名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        showEditSheet = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        saveCustomURL(platform)
                    }
                    .bold()
                }
            }
        }
    }

    // MARK: 辅助方法
    private func displayURL(_ platform: WelfareCrawlerConfig) -> String {
        if let custom = platform.customBaseURL, !custom.isEmpty {
            return custom
        }
        return platform.baseURL
    }

    private func saveCustomURL(_ platform: WelfareCrawlerConfig) {
        var config = platform
        let trimmed = customURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        config.customBaseURL = trimmed.isEmpty ? nil : trimmed
        showEditSheet = false
        refreshTrigger.toggle()
    }

    private func resetAll() {
        WelfareCrawlerConfig.clearAllCustomURLs()
        refreshTrigger.toggle()
    }

    private var textColor: Color {
        settings.usesVisualSkin ? .white : Color(uiColor: .label)
    }
}

// MARK: - WelfareContentType 扩展
extension WelfareContentType {
    var displayName: String {
        switch self {
        case .video: return "视频"
        case .live: return "直播"
        case .comic: return "漫画"
        case .audio: return "音频"
        case .mixed: return "综合"
        }
    }

    var icon: String {
        switch self {
        case .video: return "play.rectangle.fill"
        case .live: return "antenna.radiowaves.left.and.right"
        case .comic: return "book.fill"
        case .audio: return "headphones"
        case .mixed: return "square.grid.3x3.fill"
        }
    }

    var color: Color {
        switch self {
        case .video: return Color(hex: "E11D48")
        case .live: return Color(hex: "7C3AED")
        case .comic: return Color(hex: "059669")
        case .audio: return Color(hex: "0284C7")
        case .mixed: return Color(hex: "D97706")
        }
    }
}
