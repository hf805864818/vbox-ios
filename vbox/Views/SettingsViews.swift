import SwiftUI

// MARK: - 设置视图
struct SettingsView: View {
    @StateObject private var spiderManager = SpiderManager.shared
    @State private var autoPlayNext = true
    @State private var playInBackground = true
    @State private var usePictureInPicture = true
    @State private var selectedQuality = "1080P"
    @State private var selectedSpeed = 1.0
    @State private var showCacheAlert = false
    @State private var cacheSize: String = "256 MB"
    @State private var showUpdateSheet = false
    @StateObject private var updateManager = UpdateManager.shared
    @State private var isChecking = false
    @State private var newURL = ""
    @State private var errorMessage = ""

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
                            
                            if spiderManager.isLoading {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("加载中...")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            if let error = spiderManager.errorMessage {
                                Text(error)
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                            }
                            
                            if !spiderManager.savedURLs.isEmpty {
                                Text("已保存的订阅源")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .padding(.top, 4)
                                
                                ForEach(spiderManager.savedURLs, id: \.self) { url in
                                    HStack {
                                        Image(systemName: "link")
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                        Text(url)
                                            .font(.system(size: 11))
                                            .lineLimit(1)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Button(action: { spiderManager.removeSubscriptionURL(url) }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 16))
                                                .foregroundColor(.gray)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            
                            if spiderManager.isInitialized {
                                Text("已加载 \(spiderManager.subscribedSites.count) 个站点")
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

                        SettingsNavigationRow(
                            title: "默认倍速",
                            subtitle: "\(selectedSpeed)x",
                            icon: "speedometer"
                        ) {
                            // 显示倍速选择
                        }
                    }

                    // 订阅管理
                    SettingsSection(title: "订阅管理") {
                        SettingsNavigationRow(
                            title: "订阅源配置",
                            subtitle: "管理视频源订阅",
                            icon: "link"
                        ) {
                            // 跳转到订阅配置页面
                        }

                        SettingsNavigationRow(
                            title: "源管理",
                            subtitle: "已配置 3 个源",
                            icon: "list.bullet"
                        ) {
                            // 显示源列表
                        }

                        SettingsNavigationRow(
                            title: "添加新源",
                            subtitle: "从URL添加视频源",
                            icon: "plus.circle.fill"
                        ) {
                            // 添加新源
                        }
                    }

                    // 存储管理
                    SettingsSection(title: "存储管理") {
                        SettingsNavigationRow(
                            title: "缓存管理",
                            subtitle: cacheSize,
                            icon: "externaldrive.fill"
                        ) {
                            showCacheAlert = true
                        }

                        SettingsNavigationRow(
                            title: "下载设置",
                            subtitle: "仅WiFi下载",
                            icon: "arrow.down.circle.fill"
                        ) {
                            // 下载设置
                        }
                    }

                    // 其他设置
                    SettingsSection(title: "其他") {
                        HStack {
                            Text("版本")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3")
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Color.primary.opacity(0.05))

                        HStack {
                            Text("构建")
                                .foregroundColor(.primary)
                            Spacer()
                            Text("build " + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Color.primary.opacity(0.05))

                        SettingsNavigationRow(
                            title: "隐私政策",
                            subtitle: "",
                            icon: "doc.text.fill"
                        ) {
                            // 隐私政策
                        }

                        SettingsNavigationRow(
                            title: "用户协议",
                            subtitle: "",
                            icon: "doc.plaintext.fill"
                        ) {
                            // 用户协议
                        }
                    }
                }
                .padding(.bottom, 100)
            }
        }
        .background(Color(hex: "000000"))
        .alert("清理缓存", isPresented: $showCacheAlert) {
            Button("取消", role: .cancel) { }
            Button("确定", role: .destructive) {
                // 执行清理缓存操作
                cacheSize = "0 MB"
            }
        } message: {
            Text("确定要清理所有缓存吗？这将删除所有已缓存的视频数据。")
        }
    }
    
    private func addSubscription() {
        let url = newURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        spiderManager.saveSubscriptionURL(url)
        Task {
            await spiderManager.loadSubscribeConfig(from: url)
            newURL = ""
        }
    }
}

// 设置区块
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 8)

            VStack(spacing: 1) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.thinMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)
        }
    }
}

// 设置开关行
struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(Color.secondary)
                }
            }

            Spacer()

            // 毛玻璃开关
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            Color.primary.opacity(0.05)
        )
    }
}

// 设置导航行
struct SettingsNavigationRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(Color(hex: "E11D48"))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundColor(Color.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundColor(Color.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                Color.primary.opacity(0.05)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 订阅配置视图
struct SubscribeConfigView: View {
    @State private var subscribeURL = ""
    @State private var isLoading = false
    @State private var showSuccessAlert = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // 导航栏
                NavigationBar(
                    title: "订阅配置",
                    showBackButton: true
                ) {
                    // 返回
                }

                VStack(spacing: 24) {
                    // 说明卡片
                    InfoCard(
                        icon: "info.circle.fill",
                        title: "什么是订阅源？",
                        description: "订阅源是一个包含多个视频站点配置的JSON文件，通过订阅源可以聚合观看来自不同站点的视频内容。"
                    )

                    // 添加订阅源表单
                    VStack(spacing: 16) {
                        Text("添加新订阅源")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // URL输入框
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
                                    Button(action: {
                                        subscribeURL = ""
                                    }) {
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
                                    .stroke(
                                        subscribeURL.isEmpty
                                            ? Color.white.opacity(0.1)
                                            : Color(hex: "E11D48").opacity(0.3),
                                        lineWidth: 1
                                    )
                            )
                        }

                        // 添加按钮
                        Button(action: {
                            loadSubscribeConfig()
                        }) {
                            HStack(spacing: 8) {
                                if isLoading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 18))
                                }

                                Text(isLoading ? "加载中..." : "添加订阅源")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                ZStack {
                                    // 液态背景
                                    if !isLoading {
                                        LiquidBackground()
                                            .blur(radius: 10)
                                            .opacity(0.4)
                                    }

                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
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
                            Text("已配置的订阅源")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.primary)

                            Spacer()
                        }
                        .padding(.horizontal, 16)

                        LazyVStack(spacing: 12) {
                            ForEach(mockSubscribeSources) { source in
                                SubscribeSourceCard(source: source)
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // 常用订阅源推荐
                    VStack(spacing: 12) {
                        HStack {
                            Text("常用订阅源推荐")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.primary)

                            Spacer()
                        }
                        .padding(.horizontal, 16)

                        LazyVStack(spacing: 12) {
                            ForEach(recommendedSources) { source in
                                RecommendedSourceCard(source: source) {
                                    subscribeURL = source.url
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 100)
            }
        }
        .background(Color(hex: "000000"))
        .alert("成功", isPresented: $showSuccessAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text("订阅源添加成功！")
        }
        .alert("错误", isPresented: $showErrorAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    private func loadSubscribeConfig() {
        guard !subscribeURL.isEmpty else { return }
        isLoading = true
        
        Task {
            await spiderManager.loadSubscribeConfig(from: subscribeURL)
            await MainActor.run {
                isLoading = false
                if let error = spiderManager.errorMessage {
                    errorMessage = error
                    showErrorAlert = true
                } else {
                    showSuccessAlert = true
                    subscribeURL = ""
                }
            }
        }
    }
}

// 信息卡片
struct InfoCard: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(Color(hex: "E11D48"))
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(Color(hex: "E11D48").opacity(0.15))
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)

                Text(description)
                    .font(.system(size: 13))
                    .foregroundColor(Color.secondary)
                    .lineSpacing(2)
            }

            Spacer()

            Button(action: {}) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundColor(Color.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(hex: "E11D48").opacity(0.2),
                            Color(hex: "E11D48").opacity(0.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .padding(.horizontal, 16)
    }
}

// 订阅源卡片
struct SubscribeSourceCard: View {
    let source: SubscribeSource
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                // 图标
                ZStack {
                    // 液态背景
                    LiquidBackground()
                        .frame(width: 50, height: 50)
                        .blur(radius: 8)
                        .opacity(0.4)

                    Image(systemName: "server.rack")
                        .font(.system(size: 22))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .frame(width: 50, height: 50)

                // 信息
                VStack(alignment: .leading, spacing: 6) {
                    Text(source.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)

                    HStack(spacing: 8) {
                        Label("\(source.siteCount) 个站点", systemImage: "tv.circle.fill")
                        Label("上次更新: \(source.lastUpdated)", systemImage: "clock.circle.fill")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(Color.secondary)
                }

                Spacer()

                // 操作按钮
                HStack(spacing: 12) {
                    Button(action: {}) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(Color(hex: "E11D48"))
                    }

                    Button(action: {}) {
                        Image(systemName: "trash.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.red)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14))
                        .foregroundColor(Color.secondary)
                }
            }
            .padding(16)
            .background(
                Color.primary.opacity(0.05)
            )

            // 展开的详情
            if isExpanded {
                VStack(spacing: 12) {
                    Divider()
                        .background(Color.white.opacity(0.1))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("源地址")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.secondary)

                        Text(source.url)
                            .font(.system(size: 13))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                    }

                    HStack {
                        Label("自动更新: 开启", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.green)

                        Spacer()

                        Label("状态: 正常", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                    }
                }
                .padding(16)
                .background(
                    Color.primary.opacity(0.03)
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.1),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isExpanded.toggle()
            }
        }
    }
}

// 推荐源卡片
struct RecommendedSourceCard: View {
    let source: RecommendedSource
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // 图标
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "E11D48").opacity(0.2), Color(hex: "F43F5E").opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 50, height: 50)

                Image(systemName: "star.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            // 信息
            VStack(alignment: .leading, spacing: 6) {
                Text(source.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)

                Text(source.description)
                    .font(.system(size: 13))
                    .foregroundColor(Color.secondary)
                    .lineLimit(2)
            }

            Spacer()

            // 添加按钮
            Button(action: action) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Color(hex: "E11D48"))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(hex: "E11D48").opacity(0.15),
                            Color(hex: "E11D48").opacity(0.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - 数据模型
struct SubscribeSource: Identifiable {
    let id = UUID()
    let name: String
    let url: String
    let siteCount: Int
    let lastUpdated: String
}

struct RecommendedSource: Identifiable {
    let id = UUID()
    let name: String
    let url: String
    let description: String
}

// Mock数据
let mockSubscribeSources: [SubscribeSource] = [
    SubscribeSource(
        name: "官方推荐源",
        url: "https://example.com/official.json",
        siteCount: 156,
        lastUpdated: "2024-01-15"
    ),
    SubscribeSource(
        name: "高清影视源",
        url: "https://example.com/hd.json",
        siteCount: 89,
        lastUpdated: "2024-01-10"
    ),
    SubscribeSource(
        name: "动漫专区",
        url: "https://example.com/anime.json",
        siteCount: 45,
        lastUpdated: "2024-01-08"
    )
]

let recommendedSources: [RecommendedSource] = [
    RecommendedSource(
        name: "TVBox官方源",
        url: "https://tvbox.github.io/config.json",
        description: "官方维护的稳定源，包含大量优质视频站点"
    ),
    RecommendedSource(
        name: "影视聚合源",
        url: "https://movie.example.com/aggregation.json",
        description: "聚合多个影视站点的配置，内容丰富"
    ),
    RecommendedSource(
        name: "高清4K源",
        url: "https://4k.example.com/config.json",
        description: "专注于4K高清视频内容"
    )
]
// 导航栏组件
struct NavigationBar: View {
    let title: String
    let showBackButton: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            // 返回按钮
            if showBackButton {
                Button(action: action) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20))
                        .foregroundColor(.primary)
                        .frame(width: 40, height: 40)
                }
            }

            Spacer()

            // 标题
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            // 占位，保持标题居中
            if showBackButton {
                Color.clear
                    .frame(width: 40, height: 40)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [
                    Color(hex: "0F0F23").opacity(0.95),
                    Color(hex: "000000").opacity(0.98)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}
