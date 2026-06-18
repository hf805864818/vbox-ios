import SwiftUI
import AVKit
import Combine
import UIKit

// MARK: - 直播源选择视图
struct LiveSourcePickerView: View {
    let sources: [LiveSourceType]
    let currentSource: LiveSourceType
    let onSelect: (LiveSourceType) -> Void
    let onAddCustom: (String, String) -> Void
    let onRemoveCustom: (Int) -> Void
    var onImportLocal: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showAddAlert = false
    @State private var customName = ""
    @State private var customURL = ""

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("可用直播源")) {
                    ForEach(sources) { source in
                        SourceRowView(
                            source: source,
                            isSelected: source.id == currentSource.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect(source)
                            dismiss()
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if isCustomSource(source) {
                                if let index = customSourceIndex(of: source) {
                                    Button(role: .destructive) {
                                        onRemoveCustom(index)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Button(action: { showAddAlert = true }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.orange)
                            Text("添加自定义源")
                                .foregroundColor(.primary)
                            Spacer()
                        }
                    }

                    if let onImportLocal = onImportLocal {
                        Button(action: { onImportLocal() }) {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.blue)
                                Text("导入本地直播文件")
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                        }
                    }
                } header: {
                    Text("添加源")
                } footer: {
                    Text("支持导入 M3U、TXT、JSON 等格式的直播源文件")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("选择直播源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .alert("添加自定义源", isPresented: $showAddAlert) {
                TextField("源名称", text: $customName)
                TextField("M3U/TXT URL", text: $customURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                Button("取消", role: .cancel) {
                    customName = ""
                    customURL = ""
                }
                Button("添加") {
                    if !customName.isEmpty && !customURL.isEmpty {
                        onAddCustom(customName, customURL)
                        customName = ""
                        customURL = ""
                    }
                }
            } message: {
                Text("请输入直播源名称和订阅地址（M3U或TXT格式）")
            }
        }
    }

    private func isCustomSource(_ source: LiveSourceType) -> Bool {
        if case .custom = source { return true }
        return false
    }

    private func customSourceIndex(of source: LiveSourceType) -> Int? {
        let customList = sources.filter {
            if case .custom = $0 { return true }
            return false
        }
        return customList.firstIndex(where: { $0.id == source.id })
    }
}

// MARK: - 源列表行视图
struct SourceRowView: View {
    let source: LiveSourceType
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // 类型图标
            ZStack {
                Circle()
                    .fill(typeColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: typeIcon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(typeColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(source.displayName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)

                Text(typeLabel)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.orange)
            } else {
                Image(systemName: "circle")
                    .font(.system(size: 22))
                    .foregroundColor(Color(.systemGray4))
            }
        }
        .padding(.vertical, 4)
        .background(isSelected ? Color.orange.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
    }

    private var typeIcon: String {
        switch source {
        case .defaultIPTV:
            return "tv"
        case .cctvLive:
            return "antenna.radiowaves.left.and.right"
        case .subscribe:
            return "doc.text"
        case .custom:
            return "link"
        }
    }

    private var typeColor: Color {
        switch source {
        case .defaultIPTV:
            return .blue
        case .cctvLive:
            return .red
        case .subscribe:
            return .green
        case .custom:
            return .orange
        }
    }

    private var typeLabel: String {
        switch source {
        case .defaultIPTV:
            return "默认源"
        case .cctvLive:
            return "央视源"
        case .subscribe:
            return "订阅源"
        case .custom:
            return "自定义源"
        }
    }
}

// MARK: - 主视图
struct LiveTVView: View {
    @StateObject private var service = LiveTVService.shared
    @State private var channelsCache: [String: [LiveChannel]] = [:]
    @State private var isLoading = false
    @State private var currentCategory: String = "itv"
    @State private var selectedChannel: LiveChannel?
    @State private var showPlayer = false
    @State private var showEPGSheet = false
    @State private var selectedChannelForEPG: LiveChannel?
    @State private var errorMessage: String?
    @State private var showError = false

    // 新增状态变量
    @State private var showSourcePicker = false
    @State private var sourcePickerOffset: CGFloat = 0

    // 浮动按钮自动隐藏/显示
    @State private var isFloatingButtonVisible = true
    @State private var hideTimer: Timer?
    @State private var lastInteractionTime = Date()

    // 订阅源分组缓存
    @State private var subscribeGroups: [String] = []
    @State private var currentSubscribeGroup: String = ""

    // 本地文件导入
    @State private var showFileImporter = false

    private var isDefaultSource: Bool {
        return service.currentSource.isDefault
    }

    private var isCCTVSource: Bool {
        if case .cctvLive = service.currentSource { return true }
        return false
    }

    private var currentCategories: [LiveCategory] {
        if isCCTVSource {
            // 央视源：只有央视和国际两个分类
            return [
                LiveCategory(id: "ys", name: "央视", tid: "ys", icon: "antenna.radiowaves.left.and.right"),
                LiveCategory(id: "gt", name: "国际", tid: "gt", icon: "globe.asia.australia"),
            ]
        } else if isDefaultSource {
            return service.categories
        } else {
            // 订阅源/自定义源：使用分组作为分类
            return subscribeGroups.map { group in
                LiveCategory(
                    id: group,
                    name: group,
                    tid: group,
                    icon: "tv"
                )
            }
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // 分类标签栏
                    categoryTabs

                    // 频道列表
                    channelList
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { _ in
                            resetHideTimer()
                        }
                )
                .onTapGesture {
                    resetHideTimer()
                }

                // 右下角浮动按钮（自动隐藏/显示）
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10))
                            .foregroundColor(.accentColor)
                            .onTapGesture {
                                showSourcePicker = true
                                resetHideTimer()
                            }
                            .padding(.trailing, 16)
                            .padding(.bottom, 80) // 向上移动避免底栏遮挡
                            .opacity(isFloatingButtonVisible ? 1 : 0)
                            .animation(.easeInOut(duration: 0.3), value: isFloatingButtonVisible)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EmptyView()
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.plainText, .data, .item],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result: result)
            }
            .sheet(isPresented: $showSourcePicker) {
                LiveSourcePickerView(
                    sources: service.availableSources,
                    currentSource: service.currentSource,
                    onSelect: { source in
                        service.switchSource(to: source)
                        showSourcePicker = false
                        // 刷新当前页面数据
                        channelsCache.removeAll()
                        loadChannelsIfNeeded(for: currentCategory)
                    },
                    onAddCustom: { name, url in
                        service.addCustomSource(name: name, url: url)
                    },
                    onRemoveCustom: { index in
                        service.removeCustomSource(at: index)
                    },
                    onImportLocal: {
                        // 先关闭 sheet，再弹出 fileImporter
                        showSourcePicker = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            showFileImporter = true
                        }
                    }
                )
                .presentationDetents([.medium])
            }
            .sheet(item: $selectedChannel) { channel in
                LivePlayerSheet(channel: channel, service: service)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showEPGSheet) {
                if let channel = selectedChannelForEPG {
                    EPGSheetView(channel: channel, service: service)
                }
            }
            .alert("错误", isPresented: $showError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "未知错误")
            }
            .onAppear {
                loadChannelsIfNeeded(for: currentCategory)
                startHideTimer()
            }
            .onDisappear {
                hideTimer?.invalidate()
                hideTimer = nil
            }
            .onChange(of: service.currentSource) { _ in
                // 源切换时重新计算分组和加载数据
                updateSubscribeGroups()
                channelsCache.removeAll()
                if let first = currentCategories.first {
                    currentCategory = first.id
                    loadChannelsIfNeeded(for: first.id)
                }
            }
        }
    }

    // MARK: - 浮动按钮自动隐藏/显示逻辑
    private func startHideTimer() {
        hideTimer?.invalidate()
        lastInteractionTime = Date()
        isFloatingButtonVisible = true
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let elapsed = Date().timeIntervalSince(lastInteractionTime)
            if elapsed >= 10.0 && isFloatingButtonVisible {
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isFloatingButtonVisible = false
                    }
                }
            }
        }
    }

    private func resetHideTimer() {
        lastInteractionTime = Date()
        if !isFloatingButtonVisible {
            withAnimation(.easeInOut(duration: 0.3)) {
                isFloatingButtonVisible = true
            }
        }
    }

    // MARK: - 处理本地文件导入
    private func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            print("[LiveTV] fileImporter 成功返回 \(urls.count) 个文件")
            guard let url = urls.first else {
                print("[LiveTV] 没有选中文件")
                return
            }
            print("[LiveTV] 选中文件: \(url)")

            // 获取对文件的访问权限
            let accessGranted = url.startAccessingSecurityScopedResource()
            print("[LiveTV] 安全域访问权限: \(accessGranted)")
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                // 尝试多种编码读取
                let content: String
                if let utf8Content = try? String(contentsOf: url, encoding: .utf8) {
                    content = utf8Content
                } else if let gbkContent = try? String(contentsOf: url, encoding: .gb_18030_2000) {
                    content = gbkContent
                } else {
                    content = try String(contentsOf: url, encoding: .ascii)
                }

                let fileName = url.deletingPathExtension().lastPathComponent
                print("[LiveTV] 文件名: \(fileName), 内容长度: \(content.count)")

                // 根据内容判断格式并解析
                let parsed: [SubscribeChannel]
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("#EXTM3U") {
                    print("[LiveTV] 检测到 M3U 格式")
                    parsed = service.parseM3U(content: content)
                } else {
                    print("[LiveTV] 按 TXT 格式解析")
                    parsed = service.parseTXT(content: content)
                }

                print("[LiveTV] 解析到 \(parsed.count) 个频道")

                if !parsed.isEmpty {
                    // 将解析到的频道添加为自定义源
                    service.addLocalChannels(name: fileName, channels: parsed)
                    // 自动切换到导入的源
                    let customSource = LiveSourceType.custom(name: fileName, url: "local://\(fileName)")
                    service.switchSource(to: customSource)
                    // 刷新频道列表
                    channelsCache.removeAll()
                    loadChannelsIfNeeded(for: currentCategory)
                    print("[LiveTV] 导入成功，已切换到源: \(fileName)")
                } else {
                    print("[LiveTV] 文件内容解析为空")
                }
            } catch {
                print("[LiveTV] 读取文件失败: \(error)")
            }
        case .failure(let error):
            print("[LiveTV] fileImporter 失败: \(error)")
        }
    }

    // MARK: - 更新订阅源分组
    private func updateSubscribeGroups() {
        guard !isDefaultSource else {
            subscribeGroups = []
            return
        }
        // 从 subscribeChannels 中提取所有 group
        let groups = Set(service.subscribeChannels.compactMap { $0.group })
        subscribeGroups = Array(groups).sorted()
        if !subscribeGroups.isEmpty && !subscribeGroups.contains(currentSubscribeGroup) {
            currentSubscribeGroup = subscribeGroups[0]
        }
    }

    // MARK: - 分类标签栏
    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(currentCategories) { category in
                    CategoryTabButton(
                        category: category,
                        isSelected: currentCategory == category.id
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentCategory = category.id
                        }
                        loadChannelsIfNeeded(for: category.id)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemBackground))
    }

    // MARK: - 频道列表
    private var channelList: some View {
        Group {
            if isLoading {
                LoadingView()
            } else if let channels = channelsCache[currentCategory], !channels.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(channels) { channel in
                            ChannelCard(channel: channel, service: service)
                                .onTapGesture {
                                    selectedChannel = channel
                                }
                                .contextMenu {
                                    Button {
                                        selectedChannelForEPG = channel
                                        showEPGSheet = true
                                    } label: {
                                        Label("节目单", systemImage: "list.bullet.rectangle")
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            } else {
                EmptyStateView {
                    loadChannelsIfNeeded(for: currentCategory)
                }
            }
        }
    }

    // MARK: - 加载频道
    private func loadChannelsIfNeeded(for categoryId: String, forceReload: Bool = false) {
        guard channelsCache[categoryId] == nil || forceReload else { return }
        isLoading = true

        Task {
            // 如果是订阅源，先确保分组数据已更新
            if !isDefaultSource && subscribeGroups.isEmpty {
                await MainActor.run {
                    updateSubscribeGroups()
                }
            }

            let channels = await service.fetchChannels(tid: categoryId)
            await MainActor.run {
                channelsCache[categoryId] = channels
                isLoading = false
                if channels.isEmpty && !forceReload {
                    errorMessage = "该分类暂无频道"
                    showError = true
                }
            }
        }
    }
}

// MARK: - 分类标签按钮
struct CategoryTabButton: View {
    let category: LiveCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: category.icon)
                    .font(.system(size: 14, weight: .medium))
                Text(category.name)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
            }
            .foregroundColor(isSelected ? .white : category.tintColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? category.backgroundColor : category.tintColor.opacity(0.1))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 频道卡片
struct ChannelCard: View {
    let channel: LiveChannel
    @ObservedObject var service: LiveTVService
    @State private var isResolving = false
    @State private var routeCount = 1

    var body: some View {
        HStack(spacing: 16) {
            // 频道图标
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.orange.opacity(0.1))
                    .frame(width: 56, height: 56)

                if let logo = channel.logo, let url = URL(string: logo) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFit()
                    } placeholder: {
                        Image(systemName: "tv.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.orange)
                    }
                    .frame(width: 40, height: 40)
                } else {
                    Image(systemName: "tv.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.orange)
                }
            }

            // 频道信息
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)

                HStack(spacing: 8) {
                    Label("线路 \(routeCount)", systemImage: "arrow.triangle.branch")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    if isResolving {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                }
            }

            Spacer()

            // 播放按钮
            Image(systemName: "play.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(.orange)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
        .onAppear {
            // 预解析线路数量
            Task {
                isResolving = true
                let sources = await service.resolveAllSources(channel: channel)
                await MainActor.run {
                    routeCount = max(1, sources.count)
                    isResolving = false
                }
            }
        }
    }
}

// MARK: - 加载中视图
struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("正在加载频道...")
                .font(.system(size: 16))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 空状态视图
struct EmptyStateView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "tv.slash")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("暂无频道")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.primary)

            Text("该分类下暂无可用频道")
                .font(.system(size: 15))
                .foregroundColor(.secondary)

            Button(action: onRetry) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("重新加载")
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.orange)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.orange.opacity(0.08))
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 100)
    }
}

// MARK: - 直播频道详情Sheet（小窗口预览 + 线路列表）
struct LivePlayerSheet: View {
    let channel: LiveChannel
    @ObservedObject var service: LiveTVService
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var availableRoutes: [String] = []
    @State private var currentRouteIndex = 0

    // 跳转到主播放器
    @State private var showFullScreenPlayer = false
    @State private var fullScreenVideo: VodItem?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 上半部分：小视频预览窗口
                ZStack {
                    Color.black
                        .aspectRatio(16/9, contentMode: .fit)

                    if let player = player {
                        VideoPlayer(player: player)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(16/9, contentMode: .fit)
                    } else if isLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                                .tint(.white)
                            Text("正在解析播放地址...")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    } else if let error = errorMessage {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 36))
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                            Button("重试") {
                                loadPlayer()
                            }
                            .font(.system(size: 14))
                            .foregroundColor(.orange)
                        }
                    }


                }

                // 下半部分：频道信息和线路列表
                VStack(spacing: 16) {
                    // 频道名称
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(channel.name)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.primary)

                            if let logo = channel.logo {
                                Text(logo)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()

                        if player != nil {
                            Button(action: {
                                openFullScreenPlayer()
                            }) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 18))
                                    .foregroundColor(.orange)
                            }
                        }

                        if availableRoutes.count > 1 {
                            Text("共 \(availableRoutes.count) 条线路")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color(.systemGray5)))
                        }
                    }
                    .padding(.horizontal, 16)

                    Divider()
                        .padding(.horizontal, 16)

                    // 线路列表
                    if availableRoutes.isEmpty && !isLoading {
                        VStack(spacing: 12) {
                            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text("暂无可用线路")
                                .font(.system(size: 15))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(0..<availableRoutes.count, id: \.self) { index in
                                    Button(action: {
                                        // 点击线路 -> 跳转到主播放器
                                        currentRouteIndex = index
                                        openFullScreenPlayer(routeIndex: index)
                                    }) {
                                        HStack(spacing: 12) {
                                            // 线路编号
                                            ZStack {
                                                Circle()
                                                    .fill(index == currentRouteIndex ? Color.accentColor : Color(.systemGray4))
                                                    .frame(width: 32, height: 32)
                                                Text("\(index + 1)")
                                                    .font(.system(size: 14, weight: .bold))
                                                    .foregroundColor(.white)
                                            }

                                            // 线路信息
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("线路 \(index + 1)")
                                                    .font(.system(size: 15, weight: .medium))
                                                    .foregroundColor(.primary)

                                                Text(truncateURL(availableRoutes[index]))
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }

                                            Spacer()

                                            if index == currentRouteIndex {
                                                Image(systemName: "play.circle.fill")
                                                    .font(.system(size: 24))
                                                    .foregroundColor(.accentColor)
                                            } else {
                                                Image(systemName: "play.circle")
                                                    .font(.system(size: 24))
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding(12)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(index == currentRouteIndex ? Color.accentColor.opacity(0.08) : Color(.systemBackground))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(index == currentRouteIndex ? Color.accentColor.opacity(0.3) : Color(.systemGray4), lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                .padding(.top, 16)
            }
            .navigationTitle("频道详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .fullScreenCover(item: $fullScreenVideo) { video in
                VideoPlayerViewV2(video: video)
            }
            .onAppear {
                loadPlayer()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
        }
    }

    // MARK: - 打开全屏播放器
    private func openFullScreenPlayer(routeIndex: Int? = nil) {
        let idx = routeIndex ?? currentRouteIndex
        guard idx < availableRoutes.count else { return }

        let urlString = availableRoutes[idx]
        // 构造 VodItem 传给主播放器
        // vodPlayUrl 格式: "线路名$url"
        let playUrl = "线路\(idx + 1)$\(urlString)"
        fullScreenVideo = VodItem(
            vodId: channel.id,
            vodName: channel.name,
            vodPic: channel.logo ?? "",
            vodRemarks: "直播",
            vodPlayFrom: "直播源",
            vodPlayUrl: playUrl
        )
    }

    // MARK: - 截断URL显示
    private func truncateURL(_ url: String) -> String {
        if url.count > 50 {
            let start = url.prefix(25)
            let end = url.suffix(20)
            return "\(start)...\(end)"
        }
        return url
    }

    // MARK: - 加载预览播放器
    private func loadPlayer() {
        isLoading = true
        errorMessage = nil

        Task {
            let routes = await service.resolveAllSources(channel: channel)
            print("[LivePlayer] 解析到 \(routes.count) 个线路")

            await MainActor.run {
                availableRoutes = routes
            }

            guard !routes.isEmpty else {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "无法获取播放地址"
                }
                return
            }

            let urlString = routes[min(currentRouteIndex, routes.count - 1)]
            guard let url = URL(string: urlString) else {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "播放地址格式无效"
                }
                return
            }

            print("[LivePlayer] 预览播放: \(urlString)")

            let avPlayer = AVPlayer(url: url)
            await MainActor.run {
                self.player = avPlayer
                self.isLoading = false
                avPlayer.play()
            }
        }
    }
}

// MARK: - 节目单Sheet
struct EPGSheetView: View {
    let channel: LiveChannel
    @ObservedObject var service: LiveTVService
    @Environment(\.dismiss) private var dismiss
    @State private var programs: [(time: String, title: String)] = []
    @State private var isLoading = true
    @State private var selectedDay = "today"

    private var dayOptions: [(String, String)] {
        [
            ("today", "今天"),
            ("yesterday", "昨天"),
            ("beforeyesterday", "前天")
        ]
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 日期选择
                Picker("日期", selection: $selectedDay) {
                    ForEach(dayOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                .onChange(of: selectedDay) { _ in
                    loadEPG()
                }

                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if programs.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "list.bullet.rectangle.portrait")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                        Text("暂无节目单")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else {
                    List(programs, id: \.time) { program in
                        HStack(spacing: 16) {
                            Text(program.time)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.orange)
                                .frame(width: 50, alignment: .leading)

                            Text(program.title)
                                .font(.system(size: 15))
                                .foregroundColor(.primary)

                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("\(channel.name) 节目单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadEPG()
            }
        }
    }

    private func loadEPG() {
        isLoading = true
        Task {
            let result = await service.fetchEPG(channel: channel, day: selectedDay)
            await MainActor.run {
                programs = result
                isLoading = false
            }
        }
    }
}

// MARK: - Preview
struct LiveTVView_Previews: PreviewProvider {
    static var previews: some View {
        LiveTVView()
    }
}
