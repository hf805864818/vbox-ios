import SwiftUI
import AVKit

// MARK: - 直播主页面
struct LiveTVView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var service = LiveTVService.shared
    @State private var selectedCategory: LiveCategory?
    @State private var showChannelList = false
    
    var body: some View {
        NavigationView {
            ZStack {
                // 背景
                Group {
                    if settings.usesLiquidSkin {
                        AppLiquidBackground().ignoresSafeArea()
                    } else if settings.usesFrostedSkin {
                        AppFrostedBackground().ignoresSafeArea()
                    } else {
                        Color(uiColor: .systemBackground).ignoresSafeArea()
                    }
                }
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        // 标题
                        HStack {
                            Text("电视直播")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        
                        // 分类网格
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)
                            ],
                            spacing: 16
                        ) {
                            ForEach(service.categories) { category in
                                LiveCategoryCard(category: category) {
                                    selectedCategory = category
                                    showChannelList = true
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        
                        // 热门频道推荐（央视+卫视）
                        LiveHotSection()
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                    }
                    .padding(.bottom, 30)
                }
            }
            .navigationBarHidden(true)
            .sheet(item: $selectedCategory) { category in
                LiveChannelListView(category: category)
            }
        }
    }
}

// MARK: - 直播分类卡片
struct LiveCategoryCard: View {
    let category: LiveCategory
    let onTap: () -> Void
    @EnvironmentObject private var settings: AppSettings
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "E11D48").opacity(0.15), Color(hex: "F43F5E").opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: 56)
                    
                    Image(systemName: category.icon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                
                Text(category.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 热门频道区块
struct LiveHotSection: View {
    @State private var hotChannels: [LiveChannel] = []
    @State private var isLoading = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("热门频道")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.primary)
                Spacer()
                if isLoading {
                    ProgressView().scaleEffect(0.8)
                }
            }
            
            if hotChannels.isEmpty && !isLoading {
                Text("加载中...")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
                    .padding(.vertical, 20)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(hotChannels.prefix(9)) { channel in
                        LiveChannelCell(channel: channel)
                    }
                }
            }
        }
        .onAppear {
            loadHotChannels()
        }
    }
    
    private func loadHotChannels() {
        guard hotChannels.isEmpty else { return }
        isLoading = true
        Task {
            // 加载央视前几个 + 卫视前几个
            async let ys = LiveTVService.shared.fetchChannels(tid: "ys")
            async let ws = LiveTVService.shared.fetchChannels(tid: "ws")
            let ysChannels = await ys
            let wsChannels = await ws
            await MainActor.run {
                hotChannels = Array(ysChannels.prefix(5)) + Array(wsChannels.prefix(4))
                isLoading = false
            }
        }
    }
}

// MARK: - 频道列表页
struct LiveChannelListView: View {
    let category: LiveCategory
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @State private var channels: [LiveChannel] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var selectedChannel: LiveChannel?
    @State private var showPlayer = false
    
    private var filteredChannels: [LiveChannel] {
        if searchText.isEmpty { return channels }
        return channels.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                // 背景
                Group {
                    if settings.usesLiquidSkin {
                        AppLiquidBackground().ignoresSafeArea()
                    } else if settings.usesFrostedSkin {
                        AppFrostedBackground().ignoresSafeArea()
                    } else {
                        Color(uiColor: .systemBackground).ignoresSafeArea()
                    }
                }
                
                VStack(spacing: 0) {
                    // 搜索栏
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                            .font(.system(size: 16))
                        
                        TextField("搜索频道", text: $searchText)
                            .font(.system(size: 15))
                        
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.gray)
                                    .font(.system(size: 18))
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .cornerRadius(10)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    
                    if isLoading {
                        Spacer()
                        VStack(spacing: 12) {
                            ProgressView().scaleEffect(1.2)
                            Text("正在加载频道...")
                                .font(.system(size: 14))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                    } else if filteredChannels.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "tv.slash")
                                .font(.system(size: 48))
                                .foregroundColor(.gray.opacity(0.5))
                            Text(channels.isEmpty ? "暂无频道数据" : "未找到匹配的频道")
                                .font(.system(size: 15))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                                spacing: 12
                            ) {
                                ForEach(filteredChannels) { channel in
                                    LiveChannelCell(channel: channel) {
                                        selectedChannel = channel
                                        showPlayer = true
                                    }
                                }
                            }
                            .padding(16)
                        }
                    }
                }
            }
            .navigationTitle(category.name)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showPlayer) {
                if let channel = selectedChannel {
                    LivePlayerView(channel: channel)
                }
            }
            .onAppear {
                loadChannels()
            }
        }
    }
    
    private func loadChannels() {
        guard channels.isEmpty else { return }
        isLoading = true
        Task {
            let result = await LiveTVService.shared.fetchChannels(tid: category.tid)
            await MainActor.run {
                channels = result
                isLoading = false
            }
        }
    }
}

// MARK: - 频道单元格
struct LiveChannelCell: View {
    let channel: LiveChannel
    var onTap: (() -> Void)? = nil
    @EnvironmentObject private var settings: AppSettings
    @State private var isPressed = false
    
    var body: some View {
        Button(action: {
            onTap?()
        }) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.8))
                        .frame(height: 70)
                    
                    VStack(spacing: 4) {
                        Image(systemName: "tv.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        
                        Text("直播中")
                            .font(.system(size: 9))
                            .foregroundColor(Color(hex: "E11D48"))
                    }
                }
                
                Text(channel.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isPressed ? 0.95 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
    }
}

// MARK: - 直播播放器
struct LivePlayerView: View {
    let channel: LiveChannel
    @Environment(\.dismiss) private var dismiss
    @State private var m3u8URL: String?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showEPG = false
    @State private var epgList: [(time: String, title: String)] = []
    
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
                    .background(Color(hex: "E11D48"))
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
                    
                    Button(action: { showEPG = true }) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Color.black.opacity(0.4))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                
                Spacer()
            }
        }
        .sheet(isPresented: $showEPG) {
            LiveEPGView(channel: channel, epgList: epgList)
        }
        .onAppear {
            loadStream()
            loadEPG()
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
    
    private func loadEPG() {
        Task {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            let day = formatter.string(from: Date())
            let epg = await LiveTVService.shared.fetchEPG(channel: channel, day: day)
            await MainActor.run {
                epgList = epg
            }
        }
    }
}

// MARK: - 节目单视图
struct LiveEPGView: View {
    let channel: LiveChannel
    let epgList: [(time: String, title: String)]
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                if epgList.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            Text("暂无节目单数据")
                                .font(.system(size: 15))
                                .foregroundColor(.gray)
                                .padding(.vertical, 20)
                            Spacer()
                        }
                    }
                } else {
                    Section(header: Text("今日节目单")) {
                        ForEach(Array(epgList.enumerated()), id: \.offset) { _, item in
                            HStack(spacing: 12) {
                                Text(item.time)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color(hex: "E11D48"))
                                    .frame(width: 50, alignment: .leading)
                                
                                Text(item.title)
                                    .font(.system(size: 15))
                                    .foregroundColor(.primary)
                                
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle(channel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
