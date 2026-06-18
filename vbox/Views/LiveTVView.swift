import SwiftUI
import AVKit
import Combine
import UIKit
import UniformTypeIdentifiers

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
                        Button(action: {
                            // 先关闭 sheet，再弹出 fileImporter
                            dismiss()
                            // 延迟后弹出文件选择器
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                onImportLocal()
                            }
                        }) {
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
        case .defaultIPTV, .defaultIPTV2:
            return "tv"
        case .subscribe:
            return "doc.text"
        case .custom:
            return "link"
        }
    }

    private var typeColor: Color {
        switch source {
        case .defaultIPTV, .defaultIPTV2:
            return .blue
        case .subscribe:
            return .green
        case .custom:
            return .orange
        }
    }

    private var typeLabel: String {
        switch source {
        case .defaultIPTV, .defaultIPTV2:
            return "默认源"
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
    @State private var currentCategory: String = ""
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

    // 当前大分类下的小分类（子分组）
    @State private var subCategories: [String] = []
    @State private var currentSubCategory: String = ""

    // 本地文件导入
    @State private var showFileImporter = false

    private var currentCategories: [LiveCategory] {
        return service.dynamicCategories
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // 分类标签栏
                    categoryTabs

                    // 小分类标签栏（如果有子分组）
                    if !subCategories.isEmpty {
                        subCategoryTabs
                    }

                    // 频道列表
                    channelList
                }

                // 右下角浮动按钮（自动隐藏/显示）
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 16))
                            .foregroundColor(.accentColor)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showSourcePicker = true
                                resetHideTimer()
                            }
                            .padding(.trailing, 16)
                            .padding(.bottom, 80)
                            .opacity(isFloatingButtonVisible ? 1 : 0)
                            .animation(.easeInOut(duration: 0.3), value: isFloatingButtonVisible)
                    }
                }
                .allowsHitTesting(isFloatingButtonVisible)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EmptyView()
                }
            }
            .sheet(isPresented: $showFileImporter) {
                DocumentPickerView { url in
                    handleDocumentPick(url: url)
                }
            }
            .sheet(isPresented: $showSourcePicker) {
                LiveSourcePickerView(
                    sources: service.availableSources,
                    currentSource: service.currentSource,
                    onSelect: { source in
                        service.switchSource(to: source)
                        showSourcePicker = false
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
                        showFileImporter = true
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
                if currentCategory.isEmpty, let first = currentCategories.first {
                    currentCategory = first.tid
                }
                loadChannelsIfNeeded(for: currentCategory)
                startHideTimer()
            }
            .onDisappear {
                hideTimer?.invalidate()
                hideTimer = nil
            }
            .onChange(of: service.currentSource) { _ in
                channelsCache.removeAll()
                subCategories = []
                currentSubCategory = ""
                if let first = currentCategories.first {
                    currentCategory = first.tid
                    loadChannelsIfNeeded(for: first.tid)
                }
            }
            .onChange(of: service.dynamicCategories) { _ in
                if !currentCategories.contains(where: { $0.tid == currentCategory }) {
                    if let first = currentCategories.first {
                        currentCategory = first.tid
                        loadChannelsIfNeeded(for: first.tid)
                    }
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

    // MARK: - 处理本地文件导入（DocumentPicker）
    private func handleDocumentPick(url: URL?) {
        guard let url = url else {
            print("[LiveTV] 没有选中文件")
            return
        }
        print("[LiveTV] 选中文件: \(url)")

        let accessGranted = url.startAccessingSecurityScopedResource()
        print("[LiveTV] 安全域访问权限: \(accessGranted)")
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let content: String
            if let utf8Content = try? String(contentsOf: url, encoding: .utf8) {
                content = utf8Content
            } else {
                let data = try Data(contentsOf: url)
                content = String(data: data, encoding: .ascii) ?? ""
            }

            let fileName = url.deletingPathExtension().lastPathComponent
            print("[LiveTV] 文件名: \(fileName), 内容长度: \(content.count)")

            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed: [SubscribeChannel]
            if trimmed.hasPrefix("#EXTM3U") {
                print("[LiveTV] 检测到 M3U 格式")
                parsed = service.parseM3U(content: content)
            } else {
                print("[LiveTV] 按 TXT 格式解析")
                parsed = service.parseTXT(content: content)
            }

            print("[LiveTV] 解析到 \(parsed.count) 个频道")

            if !parsed.isEmpty {
                service.addLocalChannels(name: fileName, channels: parsed)
                let customSource = LiveSourceType.custom(name: fileName, url: "local://\(fileName)")
                service.switchSource(to: customSource)
                channelsCache.removeAll()
                subCategories = []
                currentSubCategory = ""
                if let first = currentCategories.first {
                    currentCategory = first.tid
                    loadChannelsIfNeeded(for: first.tid, forceReload: true)
                }
                print("[LiveTV] 导入成功，已切换到源: \(fileName)")
            } else {
                print("[LiveTV] 文件内容解析为空")
            }
        } catch {
            print("[LiveTV] 读取文件失败: \(error)")
        }
    }

    // MARK: - 分类标签栏
    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(currentCategories) { category in
                    CategoryTabButton(
                        category: category,
                        isSelected: currentCategory == category.tid
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentCategory = category.tid
                            currentSubCategory = ""
                        }
                        loadChannelsIfNeeded(for: category.tid)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemBackground))
    }

    // MARK: - 小分类标签栏
    private var subCategoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // "全部"选项
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentSubCategory = ""
                    }
                }) {
                    Text("全部")
                        .font(.system(size: 13, weight: currentSubCategory.isEmpty ? .semibold : .regular))
                        .foregroundColor(currentSubCategory.isEmpty ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(currentSubCategory.isEmpty ? Color.accentColor : Color(.systemGray5))
                        )
                }
                .buttonStyle(PlainButtonStyle())

                ForEach(subCategories, id: \.self) { sub in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentSubCategory = sub
                        }
                    }) {
                        Text(sub)
                            .font(.system(size: 13, weight: currentSubCategory == sub ? .semibold : .regular))
                            .foregroundColor(currentSubCategory == sub ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(currentSubCategory == sub ? Color.accentColor : Color(.systemGray5))
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }

    // MARK: - 频道列表（2列网格）
    private var channelList: some View {
        Group {
            if isLoading {
                LoadingView()
            } else if let channels = channelsCache[currentCategory], !channels.isEmpty {
                let filteredChannels = filteredChannelsBySubCategory(channels)
                ScrollView {
                    if filteredChannels.isEmpty {
                        VStack(spacing: 20) {
                            Image(systemName: "tv.slash")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text("该分组下暂无频道")
                                .font(.system(size: 15))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 100)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(filteredChannels) { channel in
                                ChannelGridItem(channel: channel, service: service)
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
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { _ in
                            resetHideTimer()
                        }
                )
                .simultaneousGesture(
                    TapGesture()
                        .onEnded { _ in
                            resetHideTimer()
                        }
                )
            } else {
                EmptyStateView {
                    loadChannelsIfNeeded(for: currentCategory)
                }
            }
        }
    }

    // MARK: - 按小分类过滤频道
    private func filteredChannelsBySubCategory(_ channels: [LiveChannel]) -> [LiveChannel] {
        guard !currentSubCategory.isEmpty else { return channels }
        // 从频道的 sources 或名称中匹配子分组
        // 由于 LiveChannel 没有直接的 group 字段，我们从 service.subscribeChannels 中查找匹配
        // 这里用频道名称的模糊匹配：如果频道名包含子分类名，则归入该子分类
        return channels.filter { channel in
            channel.name.contains(currentSubCategory)
        }
    }

    // MARK: - 提取当前分类下的子分组
    private func extractSubCategories(from channels: [LiveChannel]) {
        // 从 subscribeChannels 中查找属于当前分类的频道，提取它们的 group 作为子分组
        let categoryGroups = service.subscribeChannels.compactMap { ch -> String? in
            guard let group = ch.group, !group.isEmpty else { return nil }
            // 判断该频道是否属于当前大分类
            // 通过频道名匹配
            return group
        }

        // 去重并排序
        let uniqueGroups = Array(Set(categoryGroups)).sorted()
        // 只保留出现次数 >= 2 的分组（避免孤立的分组）
        let groupCounts = Dictionary(grouping: categoryGroups, by: { $0 })
        subCategories = uniqueGroups.filter { (groupCounts[$0]?.count ?? 0) >= 2 }

        if !subCategories.isEmpty && !subCategories.contains(currentSubCategory) {
            currentSubCategory = ""
        }
    }

    // MARK: - 加载频道
    private func loadChannelsIfNeeded(for categoryId: String, forceReload: Bool = false) {
        guard !categoryId.isEmpty else { return }
        guard channelsCache[categoryId] == nil || forceReload else { return }
        isLoading = true

        Task {
            let channels = await service.fetchChannels(tid: categoryId)
            await MainActor.run {
                channelsCache[categoryId] = channels
                isLoading = false
                // 提取子分组
                extractSubCategories(from: channels)
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
                if let logo = category.logo, let url = URL(string: logo) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    } placeholder: {
                        Image(systemName: category.icon)
                            .font(.system(size: 14, weight: .medium))
                    }
                } else {
                    Image(systemName: category.icon)
                        .font(.system(size: 14, weight: .medium))
                }
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

// MARK: - 频道网格卡片
struct ChannelGridItem: View {
    let channel: LiveChannel
    @ObservedObject var service: LiveTVService
    @State private var isResolving = false
    @State private var routeCount = 1

    var body: some View {
        VStack(spacing: 0) {
            // 封面图（16:9 比例）
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray6))
                    .aspectRatio(16/9, contentMode: .fit)

                if let logo = channel.logo, let url = URL(string: logo) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Image(systemName: "tv.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.orange.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "tv.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.orange.opacity(0.6))
                }
            }
            .clipped()

            // 频道名称 + 线路数
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 4) {
                    Text("\(routeCount)条线路")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if isResolving {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
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

// MARK: - 系统播放器（AVPlayerViewController 封装）
struct SystemPlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.exitsFullScreenWhenPlaybackEnds = false
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

// MARK: - 直播频道详情Sheet（小窗口预览 + 线路切换 + 全屏）
struct LivePlayerSheet: View {
    let channel: LiveChannel
    @ObservedObject var service: LiveTVService
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var availableRoutes: [String] = []
    @State private var currentRouteIndex = 0

    // 全屏播放
    @State private var showSystemPlayer = false

    // 线路选择菜单
    @State private var showRouteMenu = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 上半部分：小视频预览窗口（带叠加层）
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

                    // 叠加层：左上角线路切换 + 右上角全屏按钮
                    if player != nil {
                        VStack {
                            HStack {
                                // 左上角：线路切换按钮
                                if availableRoutes.count > 1 {
                                    Menu {
                                        ForEach(0..<availableRoutes.count, id: \.self) { index in
                                            Button(action: {
                                                switchRoute(to: index)
                                            }) {
                                                HStack {
                                                    Text("线路 \(index + 1)")
                                                    if index == currentRouteIndex {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.triangle.branch")
                                                .font(.system(size: 12))
                                            Text("线路 \(currentRouteIndex + 1)/\(availableRoutes.count)")
                                                .font(.system(size: 12, weight: .medium))
                                        }
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            Capsule()
                                                .fill(Color.black.opacity(0.5))
                                        )
                                    }
                                }

                                Spacer()

                                // 右上角：全屏按钮
                                Button(action: {
                                    showSystemPlayer = true
                                }) {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 16))
                                        .foregroundColor(.white)
                                        .padding(8)
                                        .background(
                                            Circle()
                                                .fill(Color.black.opacity(0.5))
                                        )
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            Spacer()
                        }
                        .padding(8)
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
                                        switchRoute(to: index)
                                    }) {
                                        HStack(spacing: 12) {
                                            ZStack {
                                                Circle()
                                                    .fill(index == currentRouteIndex ? Color.accentColor : Color(.systemGray4))
                                                    .frame(width: 32, height: 32)
                                                Text("\(index + 1)")
                                                    .font(.system(size: 14, weight: .bold))
                                                    .foregroundColor(.white)
                                            }

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
            .fullScreenCover(isPresented: $showSystemPlayer) {
                if let player = player {
                    SystemPlayerViewController(player: player)
                        .ignoresSafeArea()
                }
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

    // MARK: - 切换线路
    private func switchRoute(to index: Int) {
        guard index != currentRouteIndex && index < availableRoutes.count else { return }
        currentRouteIndex = index

        let urlString = availableRoutes[index]
        guard let url = URL(string: urlString) else { return }

        let avPlayer = AVPlayer(url: url)
        self.player = avPlayer
        avPlayer.play()
    }

    private func truncateURL(_ url: String) -> String {
        if url.count > 50 {
            let start = url.prefix(25)
            let end = url.suffix(20)
            return "\(start)...\(end)"
        }
        return url
    }

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

// MARK: - 文件选择器（UIDocumentPickerViewController 封装）
struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, dismiss: dismiss)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        let dismiss: DismissAction

        init(onPick: @escaping (URL?) -> Void, dismiss: DismissAction) {
            self.onPick = onPick
            self.dismiss = dismiss
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.onPick(urls.first)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            dismiss()
        }
    }
}

// MARK: - Preview
struct LiveTVView_Previews: PreviewProvider {
    static var previews: some View {
        LiveTVView()
    }
}
