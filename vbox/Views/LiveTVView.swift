import SwiftUI
import AVKit

// MARK: - 直播主页面（新版：参考截图设计）
struct LiveTVView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedCategory: LiveCategory?
    @State private var showChannelList = false
    @State private var selectedChannel: LiveChannel?
    @State private var showPlayer = false

    private var service: LiveTVService { LiveTVService.shared }

    var body: some View {
        NavigationView {
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        // 顶部导航栏
                        HStack {
                            Button(action: {}) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(.primary)
                            }

                            Spacer()

                            Text("全部频道")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.primary)

                            Spacer()

                            // 右侧占位保持居中
                            Color.clear.frame(width: 20, height: 20)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                        // 提示文字
                        Text("长按可编辑频道顺序")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                            .padding(.top, 8)
                            .padding(.bottom, 16)

                        // 分类网格（3列，大图标）
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 0),
                                GridItem(.flexible(), spacing: 0),
                                GridItem(.flexible(), spacing: 0)
                            ],
                            spacing: 20
                        ) {
                            ForEach(service.categories) { category in
                                LiveCategoryGridItem(category: category) {
                                    selectedCategory = category
                                    showChannelList = true
                                }
                            }
                        }
                        .padding(.horizontal, 20)

                        Spacer(minLength: 40)
                    }
                }
            }
            .navigationBarHidden(true)
            .sheet(item: $selectedCategory) { category in
                LiveChannelListView(category: category)
            }
            .fullScreenCover(item: $selectedChannel) { channel in
                LivePlayerView(channel: channel)
            }
        }
    }
}

// MARK: - 分类网格项（大图标+文字，参考截图）
struct LiveCategoryGridItem: View {
    let category: LiveCategory
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                // 图标区域（大图标，无背景或浅色背景）
                ZStack {
                    Circle()
                        .fill(category.backgroundColor.opacity(0.12))
                        .frame(width: 56, height: 56)

                    Image(systemName: category.icon)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(category.tintColor)
                }

                Text(category.name)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 频道列表页（参考截图：顶部横向分类 + 精选推荐 + 频道网格）
struct LiveChannelListView: View {
    let category: LiveCategory
    @Environment(\.dismiss) private var dismiss
    @State private var channels: [LiveChannel] = []
    @State private var isLoading = true
    @State private var selectedChannel: LiveChannel?
    @State private var showPlayer = false

    // 所有分类用于顶部横向切换
    private var allCategories: [LiveCategory] { LiveTVService.shared.categories }
    @State private var currentCategory: LiveCategory

    init(category: LiveCategory) {
        self.category = category
        _currentCategory = State(initialValue: category)
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    // 顶部横向分类标签
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            ForEach(allCategories) { cat in
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        currentCategory = cat
                                    }
                                    loadChannels(for: cat)
                                }) {
                                    VStack(spacing: 4) {
                                        Text(cat.name)
                                            .font(.system(size: 16, weight: currentCategory.id == cat.id ? .bold : .regular))
                                            .foregroundColor(currentCategory.id == cat.id ? .primary : .gray)

                                        // 选中下划线
                                        if currentCategory.id == cat.id {
                                            Rectangle()
                                                .fill(Color(hex: "FF6B00"))
                                                .frame(width: 20, height: 3)
                                                .cornerRadius(1.5)
                                        } else {
                                            Color.clear.frame(width: 20, height: 3)
                                        }
                                    }
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    }

                    if isLoading {
                        Spacer()
                        VStack(spacing: 12) {
                            ProgressView().scaleEffect(1.2)
                            Text("正在加载...")
                                .font(.system(size: 14))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                    } else if channels.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "tv.slash")
                                .font(.system(size: 48))
                                .foregroundColor(.gray.opacity(0.5))
                            Text("暂无频道数据")
                                .font(.system(size: 15))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                    } else {
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 16) {
                                // 精选推荐（横向滚动，圆形图标+直播中标签）
                                if let featured = channels.prefix(5).shuffled().prefix(5) as? ArraySlice<LiveChannel>, !featured.isEmpty {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("精选推荐")
                                            .font(.system(size: 18, weight: .bold))
                                            .foregroundColor(.primary)
                                            .padding(.horizontal, 16)

                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 16) {
                                                ForEach(featured) { channel in
                                                    FeaturedChannelItem(channel: channel) {
                                                        selectedChannel = channel
                                                        showPlayer = true
                                                    }
                                                }
                                            }
                                            .padding(.horizontal, 16)
                                        }
                                    }
                                    .padding(.top, 8)
                                }

                                // 频道直播（2列网格，大图+台标+节目名）
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("\(currentCategory.name)直播")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundColor(.primary)
                                        .padding(.horizontal, 16)

                                    LazyVGrid(
                                        columns: [
                                            GridItem(.flexible(), spacing: 12),
                                            GridItem(.flexible(), spacing: 12)
                                        ],
                                        spacing: 12
                                    ) {
                                        ForEach(channels) { channel in
                                            LiveChannelGridItem(channel: channel) {
                                                selectedChannel = channel
                                                showPlayer = true
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }

                                Spacer(minLength: 30)
                            }
                        }
                    }
                }
            }
            .navigationBarHidden(true)
            .fullScreenCover(item: $selectedChannel) { channel in
                LivePlayerView(channel: channel)
            }
            .onAppear {
                loadChannels(for: currentCategory)
            }
        }
    }

    private func loadChannels(for cat: LiveCategory) {
        isLoading = true
        channels = []
        Task {
            let result = await LiveTVService.shared.fetchChannels(tid: cat.tid)
            await MainActor.run {
                channels = result
                isLoading = false
            }
        }
    }
}

// MARK: - 精选推荐项（圆形图标+直播中标签）
struct FeaturedChannelItem: View {
    let channel: LiveChannel
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 60, height: 60)
                        .overlay(
                            Circle()
                                .stroke(Color.orange.opacity(0.4), lineWidth: 1.5)
                        )

                    Text(channel.name.prefix(4))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: 50)

                    // 直播中标签
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text("直播中")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color(hex: "FF6B00"))
                                .cornerRadius(3)
                        }
                    }
                    .frame(width: 60, height: 60)
                }

                Text(channel.name)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(width: 70)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 频道网格项（2列大图，参考截图）
struct LiveChannelGridItem: View {
    let channel: LiveChannel
    let onTap: () -> Void
    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                // 视频缩略图区域
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(uiColor: .secondarySystemBackground))
                        .aspectRatio(16/9, contentMode: .fit)

                    if let thumbnail = thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .aspectRatio(16/9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        // 占位图
                        VStack(spacing: 4) {
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.gray.opacity(0.5))
                        }
                    }

                    // 直播中角标
                    VStack {
                        HStack {
                            Spacer()
                            Text("直播中")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color(hex: "FF6B00").opacity(0.9))
                                .cornerRadius(4)
                                .padding(6)
                        }
                        Spacer()
                    }
                }

                // 频道信息
                HStack(spacing: 6) {
                    // 小台标
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.15))
                            .frame(width: 22, height: 22)

                        Text(channel.name.prefix(1))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.orange)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Text("精彩节目热播中")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }

                    Spacer()
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 直播播放器（简化版）
struct LivePlayerView: View {
    let channel: LiveChannel
    @Environment(\.dismiss) private var dismiss
    @State private var m3u8URL: String?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let urlString = m3u8URL, let url = URL(string: urlString) {
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
                    .background(Color(hex: "FF6B00"))
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
            loadStream()
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
