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
                    if spiderManager.subscribedSites.isEmpty {
                        Text("未配置")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                    } else {
                        Text("\(spiderManager.subscribedSites.count) 个源")
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
                if !cloudDriveManager.savedTokens.isEmpty {
                    ForEach(Array(cloudDriveManager.savedTokens.enumerated()), id: \.offset) { index, token in
                        driveTokenRow(index: index, token: token)
                    }
                }
                fetchTokenButton
                driveFormFields
            }.padding(16)
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
                Text("版本").foregroundColor(.black); Spacer(); Text("3.61").foregroundColor(.gray)
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
    @StateObject private var spiderManager = SpiderManager.shared
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

                if !spiderManager.subscribedSites.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("已订阅源 (\(spiderManager.subscribedSites.count))")
                            .font(.system(size: 16, weight: .semibold)).foregroundColor(.black).padding(.horizontal, 4)
                        ForEach(spiderManager.subscribedSites, id: \.self) { site in
                            HStack {
                                Text(site).font(.system(size: 14, weight: .medium)).foregroundColor(.black)
                                Spacer()
                                Text("API")
                                    .font(.system(size: 10)).foregroundColor(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color(hex: "E11D48").opacity(0.8)).cornerRadius(4)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color.gray.opacity(0.04)).cornerRadius(8)
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
            await spiderManager.loadSubscribeConfig(from: subscribeURL)
            await MainActor.run {
                subscribeURL = ""
                isLoading = false
                showSuccessAlert = true
            }
        }
    }
}
