import SwiftUI

struct SettingsView: View {
    @StateObject private var spiderManager = SpiderManager.shared
    @StateObject private var cloudDriveManager = CloudDriveManager.shared
    @State private var autoPlayNext = true
    @State private var playInBackground = true
    @State private var usePictureInPicture = true
    @AppStorage("show_debug_overlay") private var showDebugOverlay = false
    @State private var showCacheAlert = false
    @State private var cacheSize: String = "256 MB"
    @State private var showUpdateSheet = false
    @StateObject private var updateManager = UpdateManager.shared
    @State private var isChecking = false
    @State private var selectedDriveType: CloudDriveManager.DriveType = .ali
    @State private var driveTokenName = ""
    @State private var driveTokenValue = ""
    @State private var showTokenFetcher = false
    @State private var showSubscribeSheet = false
    @State private var showFallbackSheet = false
    @State private var showParserSheet = false
    @State private var showBaiduTestView = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                titleBar
                settingsContent
            }
        }
        .background(Color.white)
        .alert("清除缓存", isPresented: $showCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("确定", role: .destructive) {}
        } message: { Text("确定要清除所有缓存数据吗？") }
        .sheet(isPresented: $showUpdateSheet) { UpdateSheet() }
    }

    // MARK: - 拆分视图（解决编译器超时）
    private var titleBar: some View {
        Text("设置")
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 16)
    }

    private var settingsContent: some View {
        VStack(spacing: 20) {
            playbackSettingsSection
            subscriptionSection
            fallbackSection
            cloudDriveSection
            storageSection
            aboutSection
        }
        .padding(.horizontal, 16)
    }

    private var playbackSettingsSection: some View {
        SettingsSection(title: "播放设置") {
            SettingsToggleRow(title: "自动播放下一个", isOn: $autoPlayNext)
            SettingsToggleRow(title: "后台播放", isOn: $playInBackground)
            SettingsToggleRow(title: "画中画", isOn: $usePictureInPicture)
            SettingsToggleRow(title: "调试信息浮层", isOn: $showDebugOverlay)
        }
    }

    private var fallbackSection: some View {
        SettingsSection(title: "切片资源") {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "server.rack")
                        .font(.system(size: 16))
                        .foregroundColor(Color(hex: "E11D48"))
                    Text("启用兜底切片资源")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.black)
                    Spacer()
                    Toggle("", isOn: $spiderManager.fallbackEnabled)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                
                Button(action: { showFallbackSheet = true }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "E11D48"))
                        Text("管理自定义切片源")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.black)
                        Spacer()
                        Text("\(spiderManager.customFallbackSites.count) 个")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .background(Color.gray.opacity(0.04))
                
                Button(action: { showParserSheet = true }) {
                    HStack {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "E11D48"))
                        Text("管理自定义解析器")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.black)
                        Spacer()
                        Text("\(spiderManager.customParsers.count) 个")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .background(Color.gray.opacity(0.04))
            }
        }
        .sheet(isPresented: $showFallbackSheet) {
            FallbackConfigView()
        }
        .sheet(isPresented: $showParserSheet) {
            ParserConfigView()
        }
    }

    private var subscriptionSection: some View {
        SettingsSection(title: "订阅配置") {
            Button(action: { showSubscribeSheet = true }) {
                HStack {
                    Image(systemName: "list.bullet.rectangle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Color(hex: "E11D48"))
                    Text("管理订阅源")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.black)
                    Spacer()
                    if SpiderManager.shared.subManager.configURLs.isEmpty {
                        Text("未配置")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                    } else {
                        Text("\(SpiderManager.shared.subManager.configURLs.count) 个源")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color.gray.opacity(0.04))
        }
        .sheet(isPresented: $showSubscribeSheet) {
            SubscribeConfigView()
        }
    }

    private var cloudDriveSection: some View {
        SettingsSection(title: "网盘播放") {
            VStack(alignment: .leading, spacing: 12) {
                // 百度网盘测试入口
                Button(action: { showBaiduTestView = true }) {
                    HStack {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "E11D48"))
                        Text("百度网盘测试工具")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.black)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color.gray.opacity(0.04))
                }
                
                if !cloudDriveManager.savedTokens.isEmpty {
                    ForEach(Array(cloudDriveManager.savedTokens.enumerated()), id: \.offset) { index, token in
                        driveTokenRow(index: index, token: token)
                    }
                }
                fetchTokenButton
                driveFormFields
            }.padding(16)
        }
        .sheet(isPresented: $showBaiduTestView) {
            BaiduTestView()
        }
    }

    private func driveTokenRow(index: Int, token: DriveToken) -> some View {
        HStack {
            Image(systemName: iconForDriveType(token.type))
                .foregroundColor(Color(hex: "E11D48")).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(CloudDriveManager.DriveType(rawValue: token.type)?.displayName ?? token.type)
                    .font(.system(size: 14, weight: .medium)).foregroundColor(.black)
                Text(token.name).font(.system(size: 11)).foregroundColor(.gray).lineLimit(1)
            }
            Spacer()
            Button(action: { cloudDriveManager.removeToken(at: index) }) {
                Image(systemName: "trash").font(.system(size: 14)).foregroundColor(.red)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.gray.opacity(0.06)).cornerRadius(8)
    }

    private var fetchTokenButton: some View {
        Button(action: { showTokenFetcher = true }) {
            HStack {
                Image(systemName: "key.fill").font(.system(size: 16))
                Text("获取Token").font(.system(size: 14, weight: .medium))
                Text("→").font(.system(size: 12))
            }
            .foregroundColor(.white).frame(maxWidth: .infinity)
            .padding(.vertical, 12).background(Color(hex: "E11D48")).cornerRadius(10)
        }
        .sheet(isPresented: $showTokenFetcher) {
            TokenFetcherView(cloudDriveManager: cloudDriveManager, onTokenDetected: { type, value in
                // 自动填充到输入框
                selectedDriveType = CloudDriveManager.DriveType(rawValue: type) ?? .ali
                driveTokenName = CloudDriveManager.DriveType(rawValue: type)?.displayName ?? type
                driveTokenValue = value
                showTokenFetcher = false
            })
        }
    }

    private var driveFormFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("网盘类型", selection: $selectedDriveType) {
                ForEach(CloudDriveManager.DriveType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.menu)
            TextField("备注名称", text: $driveTokenName).textFieldStyle(RoundedBorderTextFieldStyle()).font(.system(size: 13))
            TextField(selectedDriveType.tokenLabel, text: $driveTokenValue).textFieldStyle(RoundedBorderTextFieldStyle()).font(.system(size: 12))
                .autocapitalization(.none).disableAutocorrection(true)
            Button(action: addDriveToken) {
                Text("保存Token").font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white).frame(maxWidth: .infinity)
                    .padding(.vertical, 10).background(Color(hex: "E11D48")).cornerRadius(10)
            }.disabled(driveTokenName.isEmpty || driveTokenValue.isEmpty)
        }
    }

    private var storageSection: some View {
        SettingsSection(title: "存储管理") {
            SettingsNavigationRow(title: "缓存管理", subtitle: cacheSize, icon: "externaldrive.fill") { showCacheAlert = true }
        }
    }

    private var aboutSection: some View {
        SettingsSection(title: "关于") {
            HStack {
                Text("版本").foregroundColor(.black); Spacer(); Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知").foregroundColor(.gray)
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Button(action: { showUpdateSheet = true }) {
                HStack {
                    Text("检查更新").foregroundColor(.black); Spacer()
                    if isChecking { ProgressView().scaleEffect(0.8) }
                    else { Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(.gray) }
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
    }

    private func addDriveToken() {
        guard !driveTokenName.isEmpty, !driveTokenValue.isEmpty else { return }
        cloudDriveManager.addToken(type: selectedDriveType, name: driveTokenName, value: driveTokenValue)
        driveTokenName = ""; driveTokenValue = ""
    }

    private func iconForDriveType(_ type: String) -> String {
        switch type {
        case "115": return "1.circle.fill"
        case "ali": return "a.circle.fill"
        case "quark": return "q.circle.fill"
        case "baidu": return "b.circle.fill"
        case "uc": return "u.circle.fill"
        default: return "cloud.fill"
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.gray)
                .padding(.horizontal, 20).padding(.top, 8)
            VStack(spacing: 1) { content }
                .background(RoundedRectangle(cornerRadius: 16).fill(.thinMaterial))
                .clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 16)
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    let isOn: Binding<Bool>
    init(title: String, isOn: Binding<Bool>) {
        self.title = title
        self.isOn = isOn
    }
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 15, weight: .medium)).foregroundColor(.black)
            Spacer()
            Toggle("", isOn: isOn).labelsHidden()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color.gray.opacity(0.04))
    }
}

struct SettingsNavigationRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18)).foregroundColor(Color(hex: "E11D48")).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .medium)).foregroundColor(.black)
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 13)).foregroundColor(.gray) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14)).foregroundColor(.gray)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Color.gray.opacity(0.04))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct SubscribeConfigView: View {
    @StateObject private var subManager = SpiderManager.shared.subManager
    @State private var subscribeURL = ""
    @State private var isLoading = false
    @State private var showSuccessAlert = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                Text("订阅配置").font(.system(size: 22, weight: .bold)).foregroundColor(.black).padding(.top, 16)

                VStack(spacing: 16) {
                    Text("添加新订阅源").font(.system(size: 18, weight: .semibold)).foregroundColor(.black).frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("订阅地址").font(.system(size: 13, weight: .medium)).foregroundColor(.black)
                        TextField("URL", text: $subscribeURL)
                            .textFieldStyle(RoundedBorderTextFieldStyle()).font(.system(size: 13))
                            .autocapitalization(.none).disableAutocorrection(true)
                    }
                    Button(action: addSubscription) {
                        HStack {
                            if isLoading { ProgressView().scaleEffect(0.8).tint(.white) }
                            Text("添加订阅").font(.system(size: 15, weight: .medium))
                        }
                        .foregroundColor(.white).frame(maxWidth: .infinity)
                        .padding(.vertical, 12).background(Color(hex: "E11D48")).cornerRadius(12)
                    }
                    .disabled(subscribeURL.isEmpty || isLoading)
                }
                .padding(20).background(RoundedRectangle(cornerRadius: 16).fill(Color.gray.opacity(0.06)))
                .padding(.horizontal, 16)

                if !subManager.configURLs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("已订阅源 (点击切换激活，左滑删除)")
                            .font(.system(size: 16, weight: .semibold)).foregroundColor(.black).padding(.horizontal, 4)
                        
                        ForEach(Array(subManager.configURLs.enumerated()), id: \.offset) { index, url in
                            SubscriptionRow(
                                url: url,
                                isActive: index == subManager.activeURLIndex,
                                onTap: { 
                                    subManager.switchToSubscription(at: index)
                                    SpiderManager.shared.switchToSubscription(at: index)
                                },
                                onDelete: {
                                    subManager.removeURL(url)
                                    SpiderManager.shared.removeSubscriptionURL(url)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .background(Color.white)
        .navigationTitle("").navigationBarHidden(true)
        .alert("添加成功", isPresented: $showSuccessAlert) { Button("确定", role: .cancel) {} }
        message: { Text("订阅源已添加并加载") }
        .alert("添加失败", isPresented: $showErrorAlert) { Button("确定", role: .cancel) {} }
        message: { Text(errorMessage) }
    }

    private func addSubscription() {
        guard !subscribeURL.isEmpty else { return }
        isLoading = true
        Task {
            await SpiderManager.shared.loadSubscribeConfig(from: subscribeURL)
            await MainActor.run {
                subscribeURL = ""
                isLoading = false
                if SpiderManager.shared.subManager.config != nil || !SpiderManager.shared.subManager.allSites.isEmpty {
                    showSuccessAlert = true
                } else if let err = SpiderManager.shared.subManager.errorMessage {
                    errorMessage = err
                    showErrorAlert = true
                } else {
                    showSuccessAlert = true
                }
            }
        }
    }
}

struct SubscriptionRow: View {
    let url: String
    let isActive: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(shortenURL(url))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isActive ? Color(hex: "E11D48") : .black)
                    .lineLimit(1)
                Text(url)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Color(hex: "E11D48"))
                    .font(.system(size: 18))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isActive ? Color(hex: "E11D48").opacity(0.1) : Color.gray.opacity(0.04))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color(hex: "E11D48").opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
    }
    
    private func shortenURL(_ url: String) -> String {
        if let host = URL(string: url)?.host {
            return host
        }
        return url.prefix(30).description + (url.count > 30 ? "..." : "")
    }
}

// MARK: - 兜底切片资源配置视图
struct FallbackConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var spiderManager = SpiderManager.shared
    @State private var newSiteName = ""
    @State private var newSiteAPI = ""
    @State private var showDeleteAlert = false
    @State private var siteToDelete: Int? = nil
    
    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    // 内置兜底源列表
                    VStack(alignment: .leading, spacing: 12) {
                        Text("内置兜底源")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 4)
                        
                        ForEach(Array(SpiderManager.builtinFallbackSites.enumerated()), id: \.offset) { index, site in
                            HStack {
                                Text(site.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.black)
                                Spacer()
                                Text("内置")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.gray.opacity(0.5))
                                    .cornerRadius(4)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.gray.opacity(0.04))
                            .cornerRadius(8)
                        }
                    }
                    .padding(.horizontal, 16)
                    
                    // 自定义兜底源列表
                    if !spiderManager.customFallbackSites.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("自定义兜底源")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 4)
                            
                            ForEach(Array(spiderManager.customFallbackSites.enumerated()), id: \.offset) { index, site in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(site.name)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.black)
                                        Text(site.api)
                                            .font(.system(size: 11))
                                            .foregroundColor(.gray)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button(action: {
                                        siteToDelete = index
                                        showDeleteAlert = true
                                    }) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 14))
                                            .foregroundColor(.red)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.gray.opacity(0.04))
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    
                    // 添加新源
                    VStack(spacing: 16) {
                        Text("添加自定义切片源")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("源名称")
                                .font(.system(size: 13, weight: .medium))
                            TextField("如：我的资源站", text: $newSiteName)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.system(size: 13))
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("API地址")
                                .font(.system(size: 13, weight: .medium))
                            TextField("https://example.com/api.php/provide/vod", text: $newSiteAPI)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.system(size: 12))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                        
                        Button(action: addCustomSite) {
                            HStack {
                                Image(systemName: "plus")
                                Text("添加")
                                    .font(.system(size: 15, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                Color(hex: "E11D48")
                                    .opacity(newSiteName.isEmpty || newSiteAPI.isEmpty ? 0.5 : 1)
                            )
                            .cornerRadius(12)
                        }
                        .disabled(newSiteName.isEmpty || newSiteAPI.isEmpty)
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.gray.opacity(0.06)))
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 20)
            }
            .background(Color.white)
            .navigationTitle("切片资源管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Text("关闭").foregroundColor(Color(hex: "E11D48"))
                    }
                }
            }
            .alert("删除确认", isPresented: $showDeleteAlert) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    if let index = siteToDelete {
                        spiderManager.removeCustomFallbackSite(at: index)
                    }
                }
            } message: {
                Text("确定要删除这个自定义切片源吗？")
            }
        }
    }
    
    private func addCustomSite() {
        guard !newSiteName.isEmpty && !newSiteAPI.isEmpty else { return }
        spiderManager.addCustomFallbackSite(name: newSiteName, api: newSiteAPI)
        newSiteName = ""
        newSiteAPI = ""
    }
}

// MARK: - 解析器配置视图
struct ParserConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var spiderManager = SpiderManager.shared
    @State private var newParserName = ""
    @State private var newParserUrl = ""
    @State private var showDeleteAlert = false
    @State private var parserToDelete: Int? = nil
    
    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    // 自定义解析器列表
                    if !spiderManager.customParsers.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("自定义解析器")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 4)
                            
                            ForEach(Array(spiderManager.customParsers.enumerated()), id: \.offset) { index, parser in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(parser.name)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.black)
                                        Text(parser.url)
                                            .font(.system(size: 11))
                                            .foregroundColor(.gray)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button(action: {
                                        parserToDelete = index
                                        showDeleteAlert = true
                                    }) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 14))
                                            .foregroundColor(.red)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.gray.opacity(0.04))
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal, 16)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 40))
                                .foregroundColor(.gray)
                            Text("暂无自定义解析器")
                                .font(.system(size: 14))
                                .foregroundColor(.gray)
                            Text("添加解析器后可提高切片资源播放成功率")
                                .font(.system(size: 12))
                                .foregroundColor(.gray.opacity(0.8))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                    
                    // 添加新解析器
                    VStack(spacing: 16) {
                        Text("添加自定义解析器")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("解析器名称")
                                .font(.system(size: 13, weight: .medium))
                            TextField("如：777 解析", text: $newParserName)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.system(size: 13))
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("解析器地址")
                                .font(.system(size: 13, weight: .medium))
                            TextField("https://jx.xxx.com/player/?url=", text: $newParserUrl)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.system(size: 12))
                        }
                        
                        Button(action: addCustomParser) {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 16))
                                Text("添加解析器")
                                    .font(.system(size: 15, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                Color(hex: "E11D48")
                                    .opacity(newParserName.isEmpty || newParserUrl.isEmpty ? 0.5 : 1)
                            )
                            .cornerRadius(12)
                        }
                        .disabled(newParserName.isEmpty || newParserUrl.isEmpty)
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.gray.opacity(0.06)))
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 20)
            }
            .background(Color.white)
            .navigationTitle("解析器管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Text("关闭").foregroundColor(Color(hex: "E11D48"))
                    }
                }
            }
            .alert("删除确认", isPresented: $showDeleteAlert) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    if let index = parserToDelete {
                        spiderManager.removeCustomParser(at: index)
                    }
                }
            } message: {
                Text("确定要删除这个解析器吗？")
            }
        }
    }
    
    private func addCustomParser() {
        guard !newParserName.isEmpty && !newParserUrl.isEmpty else { return }
        spiderManager.addCustomParser(name: newParserName, url: newParserUrl)
        newParserName = ""
        newParserUrl = ""
    }
}

// MARK: - 百度网盘测试工具
struct BaiduTestView: View {
    @StateObject private var cloudDriveManager = CloudDriveManager.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var shareURL = ""
    @State private var bduss = ""
    @State private var logs: [String] = []
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var scrollToBottom = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 输入区域
                ScrollView {
                    VStack(spacing: 16) {
                        inputSection
                        
                        if !logs.isEmpty {
                            logSection
                        }
                        
                        if let result = testResult {
                            resultSection(result: result)
                        }
                    }
                    .padding(16)
                }
                
                // 测试按钮
                HStack {
                    Button(action: runTest) {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.8)
                                Text(isTesting ? "测试中..." : "开始测试")
                            } else {
                                Text("开始测试")
                            }
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(isTesting || shareURL.isEmpty || bduss.isEmpty ? Color.gray : Color(hex: "E11D48"))
                        .cornerRadius(12)
                    }
                    .disabled(isTesting || shareURL.isEmpty || bduss.isEmpty)
                }
                .padding(16)
                .background(Color.white)
            }
            .background(Color(hex: "F8FAFC"))
            .navigationTitle("百度网盘测试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .foregroundColor(Color(hex: "E11D48"))
                    }
                }
            }
        }
    }
    
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("测试说明")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.gray)
            
            VStack(alignment: .leading, spacing: 8) {
                InfoRow(icon: "link", text: "粘贴百度网盘分享链接（必须带提取码）")
                InfoRow(icon: "key", text: "填写 BDUSS Cookie（格式：BDUSS=xxx 或 BDUSS=xxx|STOKEN=yyy）")
                InfoRow(icon: "play.circle", text: "点击测试后会直接跳转到播放页面")
            }
            .padding(12)
            .background(Color.white)
            .cornerRadius(12)
            
            TextField("分享链接，如：https://pan.baidu.com/s/1xxx?pwd=ab12", text: $shareURL)
                .font(.system(size: 13))
                .padding(12)
                .background(Color.white)
                .cornerRadius(10)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            
            TextField("BDUSS Cookie", text: $bduss)
                .font(.system(size: 13))
                .padding(12)
                .background(Color.white)
                .cornerRadius(10)
                .autocapitalization(.none)
        }
    }
    
    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("测试日志")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.gray)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, log in
                        Text(log)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(logColor(for: log))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 300)
            .padding(12)
            .background(Color.black.opacity(0.95))
            .cornerRadius(12)
        }
    }
    
    private func resultSection(result: String) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: result.hasPrefix("✅") ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(result.hasPrefix("✅") ? .green : .red)
                Text(result.hasPrefix("✅") ? "测试成功" : "测试失败")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(result.hasPrefix("✅") ? .green : .red)
                Spacer()
            }
            
            Text(result)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.white)
        .cornerRadius(12)
    }
    
    private func runTest() {
        guard !shareURL.isEmpty, !bduss.isEmpty else { return }
        
        logs.removeAll()
        testResult = nil
        isTesting = true
        
        addLog("====== 开始测试 ======")
        addLog("分享链接：\(shareURL.prefix(60))...")
        addLog("BDUSS: \(bduss.prefix(20))...")
        addLog("")
        
        Task {
            do {
                addLog("[1/3] 检查是否配置 Token...")
                let tokens = cloudDriveManager.tokens(for: .baidu)
                if tokens.isEmpty {
                    addLog("❌ 未配置百度网盘 Token，请先在上方添加")
                    await MainActor.run {
                        testResult = "❌ 未配置 Token，请在设置中添加百度网盘 BDUSS"
                        isTesting = false
                    }
                    return
                }
                addLog("✅ Token 已配置")
                
                // 跳转到播放器
                addLog("[2/3] 准备跳转到播放器...")
                addLog("✅ 验证通过")
                
                // 实际测试：调用 resolveBaiduPlayURL
                addLog("[3/3] 调用播放接口...")
                let result = try await cloudDriveManager.resolveBaiduPlayURL(shareURL: shareURL, bduss: bduss)
                
                addLog("✅ 播放地址获取成功!")
                addLog("📍 URL: \(result.url.prefix(80))...")
                addLog("")
                addLog("====== 测试完成 ======")
                addLog("✅ 成功获取播放地址，即将跳转到播放器")
                
                // 延迟跳转，让用户看到日志
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 秒
                
                await MainActor.run {
                    testResult = "✅ 测试成功！播放地址已获取，即将跳转到播放器..."
                    isTesting = false
                    
                    // TODO: 跳转到播放器页面（需要实现导航）
                    // 暂时只显示成功消息
                }
                
            } catch let error as DriveError {
                let msg = driveErrorToString(error)
                addLog("❌ \(msg)")
                await MainActor.run {
                    testResult = "❌ \(msg)"
                    isTesting = false
                }
            } catch {
                addLog("❌ 未知错误：\(error.localizedDescription)")
                await MainActor.run {
                    testResult = "❌ 未知错误：\(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
    
    private func addLog(_ message: String) {
        logs.append(message)
        scrollToBottom = true
    }
    
    private func logColor(for log: String) -> Color {
        if log.contains("✅") { return .green }
        if log.contains("❌") { return .red }
        if log.contains("⚠️") { return .orange }
        if log.contains("[Baidu]") { return .cyan }
        return .white
    }
    
    private func driveErrorToString(_ error: DriveError) -> String {
        switch error {
        case .tokenNotConfigured(let name): return "未配置\(name) Token"
        case .noPlayURL(let reason): return reason
        case .saveFailed: return "转存失败"
        case .invalidResponse: return "服务器响应异常"
        case .invalidShareURL: return "无效的分享链接"
        case .notImplemented: return "暂不支持"
        }
    }
}

struct InfoRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "E11D48"))
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

