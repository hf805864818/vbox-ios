import SwiftUI

// MARK: - 设置视图
struct SettingsView: View {
    @StateObject private var subManager = SubscriptionManager()
    @State private var autoPlayNext = true
    @State private var playInBackground = true
    @State private var usePictureInPicture = true
    @State private var selectedQuality = "1080P"
    @State private var selectedSpeed = 1.0
    @State private var showCacheAlert = false
    @State private var cacheSize: String = "256 MB"
    @State private var newURL = ""
    @State private var showAddAlert = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // 导航栏
                NavigationBar(
                    title: "设置",
                    showBackButton: true
                ) {
                    // 返回
                }

                VStack(spacing: 20) {
                    // 订阅源管理
                    SettingsSection(title: "订阅源管理") {
                        VStack(alignment: .leading, spacing: 12) {
                            // 添加新订阅源
                            HStack {
                                TextField("输入订阅源JSON地址...", text: $newURL)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .font(.system(size: 14))
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                
                                Button(action: addSubscription) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 24))
                                        .foregroundColor(Color(hex: "E11D48"))
                                }
                                .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            
                            if subManager.isLoading {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("加载中...")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            if let error = subManager.errorMessage {
                                Text(error)
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                            }
                            
                            // 已保存的订阅源列表
                            if !subManager.configURLs.isEmpty {
                                Text("已保存的订阅源")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .padding(.top, 4)
                                
                                ForEach(subManager.configURLs, id: \.self) { url in
                                    HStack {
                                        Image(systemName: "link")
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                        Text(url)
                                            .font(.system(size: 11))
                                            .lineLimit(1)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Button(action: { subManager.removeURL(url) }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 16))
                                                .foregroundColor(.gray)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            
                            if subManager.isLoaded {
                                Text("已加载 \(subManager.allSites.count) 个站点")
                                    .font(.system(size: 12))
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    
                    // 播放设置
                    SettingsSection(title: "播放设置") {
                        SettingsToggleRow(
                            title: "自动播放下一集",
                            subtitle: "播放完成后自动播放下一集",
                            isOn: $autoPlayNext
                        )

                        SettingsToggleRow(
                            title: "后台播放",
                            subtitle: "最小化后继续播放",
                            isOn: $playInBackground
                        )

                        SettingsToggleRow(
                            title: "画中画模式",
                            subtitle: "使用画中画窗口播放",
                            isOn: $usePictureInPicture
                        )

                        SettingsNavigationRow(
                            title: "默认画质",
                            subtitle: selectedQuality,
                            icon: "tv"
                        ) {
                            // 显示画质选择
                        }
                    }

                    // 播放速度
                    SettingsSection(title: "播放速度") {
                        VStack(spacing: 8) {
                            Slider(value: $selectedSpeed, in: 0.5...2.0, step: 0.25)
                                .tint(Color(hex: "E11D48"))
                            Text("\(selectedSpeed, specifier: "%.2f")x")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }

                    // 缓存管理
                    SettingsSection(title: "缓存管理") {
                        SettingsNavigationRow(
                            title: "清除缓存",
                            subtitle: cacheSize,
                            icon: "trash"
                        ) {
                            showCacheAlert = true
                        }
                        .alert("清除缓存", isPresented: $showCacheAlert) {
                            Button("取消", role: .cancel) {}
                            Button("确定", role: .destructive) {
                                clearCache()
                            }
                        } message: {
                            Text("确定要清除 \(cacheSize) 缓存吗？")
                        }
                    }

                    // 关于
                    SettingsSection(title: "关于") {
                        HStack {
                            Text("版本")
                                .foregroundColor(.primary)
                            Spacer()
                            Text("v0.3")
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .background(Color.black.opacity(0.95))
        .navigationBarHidden(true)
    }

    private func addSubscription() {
        let url = newURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        Task {
            await subManager.loadConfig(from: url)
            newURL = ""
        }
    }

    private func clearCache() {
        // 清理缓存逻辑
        cacheSize = "0 MB"
    }
}

// MARK: - 订阅配置视图
struct SubscribeConfigView: View {
    @StateObject private var spiderManager = SpiderManager.shared
    @State private var subscribeURL = ""
    @State private var isLoading = false
    @State private var showSuccessAlert = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var savedURLs: [String] = []

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                NavigationBar(
                    title: "订阅配置",
                    showBackButton: true
                ) {}

                VStack(spacing: 24) {
                    InfoCard(
                        icon: "info.circle.fill",
                        title: "什么是订阅源？",
                        description: "订阅源是一个包含多个视频站点配置的JSON文件，通过订阅源可以聚合观看来自不同站点的视频内容。"
                    )

                    VStack(spacing: 16) {
                        Text("添加新订阅源")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("订阅地址")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)

                            HStack(spacing: 10) {
                                Image(systemName: "link")
                                    .foregroundColor(Color.secondary)

                                TextField("https://example.com/config.json", text: $subscribeURL)
                                    .foregroundColor(.primary)
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.URL)
                                    .autocorrectionDisabled()

                                if !subscribeURL.isEmpty {
                                    Button(action: { subscribeURL = "" }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(Color.secondary)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.ultraThinMaterial)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(subscribeURL.isEmpty ? Color.white.opacity(0.1) : Color(hex: "E11D48").opacity(0.3), lineWidth: 1)
                            )
                        }

                        Button(action: loadSubscribeConfig) {
                            HStack(spacing: 8) {
                                if isLoading {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "plus.circle.fill").font(.system(size: 18))
                                }
                                Text(isLoading ? "加载中..." : "添加订阅源").font(.system(size: 16, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                ZStack {
                                    if !isLoading { LiquidBackground().blur(radius: 10).opacity(0.4) }
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(LinearGradient(colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")], startPoint: .leading, endPoint: .trailing))
                                }
                            )
                        }
                        .disabled(subscribeURL.isEmpty || isLoading)
                        .opacity(subscribeURL.isEmpty || isLoading ? 0.6 : 1.0)
                    }
                    .padding(.horizontal, 16)

                    // 已配置的订阅源
                    VStack(spacing: 12) {
                        HStack {
                            Text("已配置的订阅源").font(.system(size: 18, weight: .semibold)).foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)

                        if savedURLs.isEmpty {
                            Text("暂无已配置的订阅源").font(.system(size: 14)).foregroundColor(.secondary).padding(.vertical, 20)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(savedURLs, id: \.self) { url in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Image(systemName: "link").font(.system(size: 14)).foregroundColor(Color(hex: "E11D48"))
                                            Text(url).font(.system(size: 13)).lineLimit(2).foregroundColor(.primary)
                                            Spacer()
                                            Button(action: {
                                                spiderManager.removeSubscriptionURL(url)
                                                savedURLs = spiderManager.getSavedSubscriptionURLs()
                                            }) {
                                                Image(systemName: "trash").font(.system(size: 14)).foregroundColor(.red)
                                            }
                                        }
                                        if spiderManager.isLoading {
                                            HStack { ProgressView().scaleEffect(0.6); Text("加载中...").font(.system(size: 11)).foregroundColor(.secondary) }
                                        }
                                        if let err = spiderManager.errorMessage {
                                            Text(err).font(.system(size: 11)).foregroundColor(.red)
                                        }
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)

                    // 已加载站点
                    if !spiderManager.subscribedSites.isEmpty {
                        VStack(spacing: 12) {
                            HStack {
                                Text("已加载站点").font(.system(size: 18, weight: .semibold)).foregroundColor(.primary)
                                Spacer()
                                HStack(spacing: 4) {
                                    Circle().fill(Color.green).frame(width: 8, height: 8)
                                    Text("\(spiderManager.homeVideos.count) 个视频").font(.system(size: 12)).foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 16)

                            ForEach(spiderManager.subscribedSites, id: \.self) { key in
                                HStack {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                    Text(key).font(.system(size: 14))
                                    Spacer()
                                }
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.ultraThinMaterial))
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                }
                .padding(.bottom, 100)
            }
        }
        .background(Color(hex: "000000"))
        .alert("加载成功", isPresented: $showSuccessAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("订阅源已成功加载，\(spiderManager.subscribedSites.count) 个站点已就绪")
        }
        .alert("加载失败", isPresented: $showErrorAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            savedURLs = spiderManager.getSavedSubscriptionURLs()
        }
    }

    private func loadSubscribeConfig() {
        let url = subscribeURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        isLoading = true
        errorMessage = ""
        spiderManager.saveSubscriptionURL(url)

        Task {
            await spiderManager.loadSubscribeConfig(from: url)
            isLoading = false
            savedURLs = spiderManager.getSavedSubscriptionURLs()
            if let err = spiderManager.errorMessage {
                errorMessage = err
                showErrorAlert = true
            } else {
                showSuccessAlert = true
            }
        }
    }
}

// MARK: - 信息卡片
struct InfoCard: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(Color(hex: "E11D48"))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)

                Text(description)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineSpacing(4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .padding(.horizontal, 16)
    }
}
