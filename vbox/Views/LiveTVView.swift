import SwiftUI
import AVKit
import Combine

// MARK: - 直播源选择视图
struct LiveSourcePickerView: View {
    let sources: [LiveSourceType]
    let currentSource: LiveSourceType
    let onSelect: (LiveSourceType) -> Void
    let onAddCustom: (String, String) -> Void
    let onRemoveCustom: (Int) -> Void

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

    // 订阅源分组缓存
    @State private var subscribeGroups: [String] = []
    @State private var currentSubscribeGroup: String = ""

    private var isDefaultSource: Bool {
        if case .defaultIPTV = service.currentSource { return true }
        return false
    }

    private var currentCategories: [LiveCategory] {
        if isDefaultSource {
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

                // 右下角浮动按钮
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: { showSourcePicker = true }) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                                .frame(width: 50, height: 50)
                                .background(Color.orange)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                    }
                }
            }
            .navigationTitle("电视直播")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSourcePicker = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 14))
                            Text(service.currentSource.displayName)
                                .font(.system(size: 13))
                        }
                        .foregroundColor(.orange)
                    }
                }
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
                    }
                )
                .presentationDetents([.medium])
            }
            .sheet(item: $selectedChannel) { channel in
                LivePlayerSheet(channel: channel, service: service)
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
    private func loadChannelsIfNeeded(for categoryId: String) {
        guard channelsCache[categoryId] == nil else { return }
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
                if channels.isEmpty {
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
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.orange)
                .cornerRadius(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 100)
    }
}

// MARK: - 播放器Sheet
struct LivePlayerSheet: View {
    let channel: LiveChannel
    @ObservedObject var service: LiveTVService
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var currentRouteIndex = 0
    @State private var availableRoutes: [String] = []
    @State private var showRoutePicker = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack {
                    if let player = player {
                        VideoPlayer(player: player)
                            .aspectRatio(16/9, contentMode: .fit)
                            .cornerRadius(12)
                            .padding(.horizontal)
                    } else if isLoading {
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .tint(.white)
                            Text("正在解析播放地址...")
                                .foregroundColor(.white)
                        }
                        .frame(height: 200)
                    } else if let error = errorMessage {
                        VStack(spacing: 16) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 50))
                                .foregroundColor(.orange)
                            Text(error)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                            Button("重试") {
                                loadPlayer()
                            }
                            .foregroundColor(.orange)
                        }
                        .frame(height: 200)
                    }

                    Spacer()

                    // 控制栏
                    VStack(spacing: 16) {
                        Text(channel.name)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)

                        HStack(spacing: 20) {
                            Button(action: { dismiss() }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 44))
                                    .foregroundColor(.white.opacity(0.8))
                            }

                            if availableRoutes.count > 1 {
                                Button(action: { showRoutePicker = true }) {
                                    Image(systemName: "arrow.triangle.branch")
                                        .font(.system(size: 32))
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationBarHidden(true)
            .actionSheet(isPresented: $showRoutePicker) {
                ActionSheet(
                    title: Text("选择线路"),
                    buttons: availableRoutes.enumerated().map { index, route in
                        .default(Text("线路 \(index + 1)")) {
                            switchToRoute(index: index)
                        }
                    } + [.cancel(Text("取消"))]
                )
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

    private func loadPlayer() {
        isLoading = true
        errorMessage = nil

        Task {
            // 获取所有可用线路
            let routes = await service.resolveAllSources(channel: channel)
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

            // 使用指定线路
            let urlString = routes[min(currentRouteIndex, routes.count - 1)]
            guard let url = URL(string: urlString) else {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "播放地址无效"
                }
                return
            }

            let player = AVPlayer(url: url)
            await MainActor.run {
                self.player = player
                self.isLoading = false
                player.play()
            }
        }
    }

    private func switchToRoute(index: Int) {
        guard index < availableRoutes.count else { return }
        currentRouteIndex = index
        player?.pause()
        player = nil
        loadPlayer()
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
