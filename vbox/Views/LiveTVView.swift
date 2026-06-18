import SwiftUI
import AVKit

// MARK: - 直播主页面（重构版：分类标签 + 小分类圆形图标 + 频道网格）
struct LiveTVView: View {
    @EnvironmentObject private var settings: AppSettings
    /// 当前选中的大分类
    @State private var selectedCategoryIndex: Int = 0
    /// 每个分类下的频道数据缓存 [分类id: 频道列表]
    @State private var channelsCache: [String: [LiveChannel]] = [:]
    /// 各分类加载状态
    @State private var loadingCategories: Set<String> = []
    /// 当前要播放的频道
    @State private var selectedChannel: LiveChannel?
    /// 是否显示播放器
    @State private var showPlayer = false
    /// 线路选择弹窗
    @State private var showRoutePicker = false
    /// 线路选择的目标频道
    @State private var routePickerChannel: LiveChannel?
    /// 频道已解析的线路缓存 [channelId: [urls]]
    @State private var resolvedSources: [String: [String]] = [:]

    private var service: LiveTVService { LiveTVService.shared }

    /// 当前选中的分类
    private var currentCategory: LiveCategory {
        service.categories[selectedCategoryIndex]
    }

    /// 当前分类的频道列表
    private var currentChannels: [LiveChannel] {
        channelsCache[currentCategory.id] ?? []
    }

    var body: some View {
        ZStack {
            // 页面背景色（适配深色模式）
            Color(uiColor: .systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部导航栏 - 横向可滑动分类标签
                LiveCategoryTabBar(
                    categories: service.categories,
                    selectedIndex: selectedCategoryIndex,
                    onSelect: { index in
                        selectedCategoryIndex = index
                        let cat = service.categories[index]
                        loadChannelsIfNeeded(for: cat)
                    }
                )

                // 小分类圆形图标行（使用当前分类下的频道作为子分类展示）
                LiveSubCategoryRow(
                    channels: currentChannels,
                    onSelect: { channel in
                        playChannel(channel, routeIndex: 0)
                    }
                )

                // 频道网格
                if loadingCategories.contains(currentCategory.id) {
                    // 加载中
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("正在加载频道...")
                            .font(.system(size: 14))
                            .foregroundColor(Color(uiColor: .secondaryLabel))
                    }
                    Spacer()
                } else if currentChannels.isEmpty {
                    // 空状态
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "tv.slash")
                            .font(.system(size: 48))
                            .foregroundColor(Color(uiColor: .tertiaryLabel))
                        Text("暂无频道数据")
                            .font(.system(size: 15))
                            .foregroundColor(Color(uiColor: .secondaryLabel))
                    }
                    Spacer()
                } else {
                    // 频道网格
                    ScrollView(showsIndicators: false) {
                        LiveChannelGrid(
                            channels: currentChannels,
                            resolvedSources: resolvedSources,
                            onChannelTap: { channel in
                                playChannel(channel, routeIndex: 0)
                            },
                            onRouteTap: { channel in
                                routePickerChannel = channel
                                showRoutePicker = true
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 20)
                    }
                }
            }

            // 线路选择弹窗
            if showRoutePicker, let channel = routePickerChannel {
                LiveRoutePickerOverlay(
                    channel: channel,
                    sources: resolvedSources[channel.id] ?? [],
                    isPresented: $showRoutePicker,
                    onSelect: { index in
                        showRoutePicker = false
                        playChannel(channel, routeIndex: index)
                    }
                )
            }
        }
        .fullScreenCover(item: $selectedChannel) { channel in
            LivePlayerView(channel: channel)
        }
        .onAppear {
            // 首次加载当前分类的频道
            loadChannelsIfNeeded(for: currentCategory)
        }
    }

    // MARK: - 加载频道数据（带缓存）
    private func loadChannelsIfNeeded(for category: LiveCategory) {
        if channelsCache[category.id] != nil { return }
        loadChannels(for: category)
    }

    private func loadChannels(for category: LiveCategory) {
        loadingCategories.insert(category.id)
        Task {
            let result = await service.fetchChannels(tid: category.tid)
            await MainActor.run {
                channelsCache[category.id] = result
                loadingCategories.remove(category.id)
            }
        }
    }

    // MARK: - 播放频道
    private func playChannel(_ channel: LiveChannel, routeIndex: Int) {
        // 如果已有解析的线路，直接播放
        if let sources = resolvedSources[channel.id], !sources.isEmpty {
            let idx = min(routeIndex, sources.count - 1)
            var playChannel = channel
            playChannel.sources = sources
            selectedChannel = playChannel
            return
        }
        // 否则先解析再播放
        selectedChannel = channel
    }
}

// MARK: - 顶部分类标签栏（横向可滑动，选中项橙色下划线）
struct LiveCategoryTabBar: View {
    let categories: [LiveCategory]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(Array(categories.enumerated()), id: \.element.id) { index, cat in
                    Button(action: { onSelect(index) }) {
                        VStack(spacing: 6) {
                            Text(cat.name)
                                .font(.system(size: 15, weight: index == selectedIndex ? .bold : .regular))
                                .foregroundColor(index == selectedIndex ? Color(uiColor: .label) : Color(uiColor: .secondaryLabel))

                            // 选中项橙色下划线
                            Rectangle()
                                .fill(index == selectedIndex ? Color.orange : Color.clear)
                                .frame(width: 20, height: 3)
                                .cornerRadius(1.5)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }
}

// MARK: - 小分类圆形图标行（横向可滑动）
struct LiveSubCategoryRow: View {
    let channels: [LiveChannel]
    let onSelect: (LiveChannel) -> Void

    /// 最多展示前20个频道作为小分类入口
    private var displayChannels: [LiveChannel] {
        Array(channels.prefix(20))
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(displayChannels) { channel in
                    Button(action: { onSelect(channel) }) {
                        VStack(spacing: 6) {
                            // 圆形图标
                            ZStack {
                                Circle()
                                    .fill(Color.orange.opacity(0.12))
                                    .frame(width: 50, height: 50)

                                Text(channel.name.prefix(2))
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.orange)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .frame(width: 40)
                            }

                            // 频道名称
                            Text(channel.name)
                                .font(.system(size: 11))
                                .foregroundColor(Color(uiColor: .secondaryLabel))
                                .lineLimit(1)
                                .frame(width: 56)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - 频道网格（2列）
struct LiveChannelGrid: View {
    let channels: [LiveChannel]
    let resolvedSources: [String: [String]]
    let onChannelTap: (LiveChannel) -> Void
    let onRouteTap: (LiveChannel) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(channels) { channel in
                LiveChannelCard(
                    channel: channel,
                    routeCount: max(1, (resolvedSources[channel.id] ?? []).count),
                    onTap: { onChannelTap(channel) },
                    onRouteTap: { onRouteTap(channel) }
                )
            }
        }
    }
}

// MARK: - 频道卡片（封面图 + logo + 名称 + 线路按钮）
struct LiveChannelCard: View {
    let channel: LiveChannel
    let routeCount: Int
    let onTap: () -> Void
    let onRouteTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                // 16:9 封面图区域
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(uiColor: .secondarySystemBackground))
                        .aspectRatio(16/9, contentMode: .fit)

                    // 占位图标
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(Color(uiColor: .tertiaryLabel))

                    // 直播中角标
                    VStack {
                        HStack {
                            Spacer()
                            Text("直播")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.85))
                                .cornerRadius(4)
                                .padding(6)
                        }
                        Spacer()
                    }

                    // 左下角频道logo小圆
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.9))
                            .frame(width: 24, height: 24)

                        Text(channel.name.prefix(1))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(6)
                }

                // 频道名称 + 线路按钮
                HStack {
                    Text(channel.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(uiColor: .label))
                        .lineLimit(1)

                    Spacer()

                    // 右下角线路选择小按钮
                    Button(action: onRouteTap) {
                        Text("线路\(routeCount)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(uiColor: .secondaryLabel))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(uiColor: .tertiarySystemFill))
                            .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 线路选择弹窗（小巧长方形，居中显示）
struct LiveRoutePickerOverlay: View {
    let channel: LiveChannel
    let sources: [String]
    @Binding var isPresented: Bool
    let onSelect: (Int) -> Void

    /// 显示的线路数量（至少1条默认线路）
    private var routeCount: Int {
        max(1, sources.count)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 半透明背景
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isPresented = false
                        }
                    }

                // 弹窗内容
                VStack(spacing: 0) {
                    // 标题
                    HStack {
                        Text("选择线路")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(uiColor: .label))
                        Spacer()
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isPresented = false
                            }
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Color(uiColor: .secondaryLabel))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    Divider().background(Color(uiColor: .separator))

                    // 线路列表
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(0..<routeCount, id: \.self) { index in
                                Button(action: {
                                    onSelect(index)
                                }) {
                                    HStack {
                                        Text("线路\(index + 1)")
                                            .font(.system(size: 14, weight: .regular))
                                            .foregroundColor(Color(uiColor: .label))
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12))
                                            .foregroundColor(Color(uiColor: .tertiaryLabel))
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(PlainButtonStyle())

                                if index < routeCount - 1 {
                                    Divider()
                                        .background(Color(uiColor: .separator))
                                        .padding(.leading, 14)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
                .frame(width: min(geometry.size.width * 0.55, 220))
                .background(Color(uiColor: .secondarySystemBackground))
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.3), radius: 16, x: 0, y: 8)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            .animation(.easeInOut(duration: 0.2), value: isPresented)
        }
    }
}

// MARK: - 直播播放器（全屏播放）
struct LivePlayerView: View {
    let channel: LiveChannel
    @Environment(\.dismiss) private var dismiss
    @State private var m3u8URL: String?
    @State private var isLoading = true
    @State private var errorMessage: String?

    /// 播放地址：优先使用频道已解析的线路，否则走默认解析
    private var playAddress: String? {
        if !channel.sources.isEmpty {
            return channel.sources[0]
        }
        return m3u8URL
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let urlString = playAddress, let url = URL(string: urlString) {
                VideoPlayer(player: AVPlayer(url: url))
                    .ignoresSafeArea()
            } else if let errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    Text(errorMessage)
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button("重试") {
                        loadStream()
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 10)
                    .background(Color.orange)
                    .cornerRadius(8)
                }
            } else if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("正在解析播放地址...")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.8))
                }
            }

            // 顶部控制栏
            VStack {
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Color.black.opacity(0.4))
                            .clipShape(Circle())
                    }

                    Spacer()

                    Text(channel.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer()
            }
        }
        .onAppear {
            // 如果频道已有线路，直接使用
            if channel.sources.isEmpty {
                loadStream()
            } else {
                isLoading = false
            }
        }
    }

    private func loadStream() {
        isLoading = true
        errorMessage = nil
        Task {
            if let url = await LiveTVService.shared.resolveM3U8(channel: channel) {
                await MainActor.run {
                    m3u8URL = url
                    isLoading = false
                }
            } else {
                await MainActor.run {
                    errorMessage = "无法解析播放地址\n该频道可能暂时不可用"
                    isLoading = false
                }
            }
        }
    }
}
