import SwiftUI
import AVKit
import AVFoundation

// MARK: - 新版本播放器 (爱奇艺风格)
struct VideoPlayerViewV2: View {
    let video: VodItem
    @State private var player: AVPlayer?
    @State private var isPlaying = true
    @State private var showControls = true
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showSettings = false
    @State private var showEpisodePicker = false
    @State private var showQualityPicker = false
    @State private var showDanmakuSettings = false
    @State private var selectedQuality = 1
    @State private var playbackSpeed: Double = 1.0
    @State private var showDanmaku = true
    @State private var danmakuOpacity: Double = 0.8
    @State private var danmakuFontSize: CGFloat = 16
    @State private var loadTimeoutTask: Task<Void, Never>?

    @Environment(\.dismiss) private var dismiss

    private let qualities = ["标清", "高清", "蓝光"]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 播放器主体 - 始终显示（即使没有视频也显示黑屏）
            if let player = player {
                ZStack {
                    AVPlayerControllerRepresentableV2(player: player)
                        .ignoresSafeArea()
                    
                    if showDanmaku {
                        DanmakuOverlayViewV2(
                            showDanmaku: $showDanmaku,
                            opacity: danmakuOpacity,
                            fontSize: danmakuFontSize
                        )
                        .allowsHitTesting(false)
                    }

                    if showControls {
                        playerControlsView
                    }
                }
                .onTapGesture {
                    showControls.toggle()
                }
            }
            
            // 加载指示器 - 叠加在播放器上方
            if isLoading {
                VStack {
                    Spacer()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("正在解析播放地址...")
                            .foregroundColor(.white.opacity(0.8))
                            .font(.subheadline)
                    }
                    Spacer()
                }
                // 顶部返回按钮
                VStack {
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "chevron.left")
                                .foregroundColor(.white)
                                .font(.title2)
                                .padding()
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        .padding()
                        Spacer()
                    }
                    Spacer()
                }
            }
            
            // 错误提示 - 叠加在播放器上方
            if let error = loadError {
                VStack {
                    Spacer()
                    VStack(spacing: 20) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 50))
                            .foregroundColor(.orange)
                        Text("加载失败")
                            .foregroundColor(.white)
                            .font(.title2)
                        Text(error)
                            .foregroundColor(.white.opacity(0.7))
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button(action: { 
                            loadError = nil
                            isLoading = true
                            setupPlayer() 
                        }) {
                            Text("重试")
                                .foregroundColor(.white)
                                .padding(.horizontal, 40)
                                .padding(.vertical, 12)
                                .background(Color.blue)
                                .cornerRadius(8)
                        }
                    }
                    Spacer()
                }
                // 顶部返回按钮
                VStack {
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "chevron.left")
                                .foregroundColor(.white)
                                .font(.title2)
                                .padding()
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        .padding()
                        Spacer()
                    }
                    Spacer()
                }
            }
        }
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            player?.pause()
        }
        .sheet(isPresented: $showSettings) {
            PlayerSettingsViewV2(speed: $playbackSpeed, onSpeedChange: { _ in })
        }
        .sheet(isPresented: $showEpisodePicker) {
            EpisodePickerViewV2(video: video)
        }
        .sheet(isPresented: $showQualityPicker) {
            QualityPickerViewV2(selectedQuality: $selectedQuality, onQualityChange: { _ in })
        }
        .sheet(isPresented: $showDanmakuSettings) {
            DanmakuSettingsViewV2(
                showDanmaku: $showDanmaku,
                opacity: $danmakuOpacity,
                fontSize: $danmakuFontSize
            )
        }
    }

    private var playerControlsView: some View {
        VStack {
            // 顶部返回栏
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.3))
                        .clipShape(Circle())
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            
            Spacer()
            
            // 底部控制栏
            VStack(spacing: 0) {
                // 进度条区域
                HStack(spacing: 12) {
                    Text(formatTime(currentTime))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .monospacedDigit()
                    
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // 背景轨道
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.3))
                                .frame(height: 4)
                            
                            // 进度条
                            if duration > 0 {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(hex: "#00BEFF"))
                                    .frame(width: max(0, min(CGFloat(currentTime / duration) * geometry.size.width, geometry.size.width)), height: 4)
                            }
                        }
                    }
                    .frame(height: 20)
                    
                    Text(formatTime(duration))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .monospacedDigit()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                
                // 按钮控制栏
                HStack(spacing: 20) {
                    // 播放/暂停
                    Button(action: { isPlaying.toggle() }) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                    }
                    
                    // 下一个（如果是多集）
                    Button(action: { /* 下一集 */ }) {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                    }
                    
                    Spacer()
                    
                    // 选集
                    Button(action: { showEpisodePicker = true }) {
                        VStack(spacing: 2) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 18))
                            Text("选集")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                    }
                    
                    // 清晰度
                    Button(action: { showQualityPicker = true }) {
                        Text(qualities[selectedQuality])
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
                            )
                    }
                    
                    // AirPlay
                    AirPlayViewV2()
                        .frame(width: 44, height: 44)
                    
                    // 弹幕
                    Button(action: { showDanmakuSettings = true }) {
                        VStack(spacing: 2) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 18))
                            Text("弹幕")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(showDanmaku ? Color(hex: "#00BEFF") : .white)
                        .frame(width: 44, height: 44)
                    }
                    
                    // 更多设置
                    Button(action: { showSettings = true }) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.black.opacity(0),
                        Color.black.opacity(0.6),
                        Color.black.opacity(0.8)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }
    
    private func formatTime(_ time: Double) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    private func setupPlayer() {
        Task { await resolvePlayUrl() }
    }
    
    private func resolvePlayUrl() async {
        print("开始解析播放地址: \(video.vodId)")
        
        // 方式0: 直接使用 video.vodPlayUrl（普通资源通常已有播放地址）
        if let pu = video.vodPlayUrl, !pu.isEmpty {
            // 如果是直接的视频链接，直接使用
            if pu.hasPrefix("http") && (pu.contains(".m3u8") || pu.contains(".mp4") || pu.contains(".flv")) {
                if let url = URL(string: pu) {
                    print("使用直接播放地址: \(pu.prefix(60))")
                    await MainActor.run { initPlayer(url: url) }; return
                }
            }
            // 如果是多集格式，解析并提取第一集
            if pu.contains("$") || pu.contains("#") {
                let urls = parsePlayUrls(playFrom: video.vodPlayFrom ?? "", playUrl: pu)
                if let firstUrl = urls.first, !firstUrl.isEmpty, let url = URL(string: firstUrl) {
                    print("使用解析后的播放地址: \(firstUrl.prefix(60))")
                    await MainActor.run { initPlayer(url: url) }; return
                }
            }
        }
        
        let spider = SpiderManager.shared
        
        // 方式1: 通过 getDetail 获取详情
        if let detail = await spider.getDetail(ids: video.vodId, name: video.vodName) {
            if let pu = detail.vodPlayUrl, !pu.isEmpty, let url = URL(string: pu) {
                await MainActor.run { initPlayer(url: url) }; return
            }
            if let pf = detail.vodPlayFrom, let pu = detail.vodPlayUrl {
                let urls = parsePlayUrls(playFrom: pf, playUrl: pu)
                let du = urls.first(where: { $0.contains(".m3u8") || $0.contains(".mp4") }) ?? urls.first ?? ""
                if !du.isEmpty, let url = URL(string: du) { await MainActor.run { initPlayer(url: url) }; return }
            }
        }
        
        // 方式2: 通过 getPlayerContent 获取
        if let pr = await spider.getPlayerContent(vodId: video.vodId, flag: "play", url: video.vodPlayUrl ?? "") {
            let pu = pr.playUrl ?? pr.url
            if let pu = pu, !pu.isEmpty, let url = URL(string: pu) {
                await MainActor.run { initPlayer(url: url) }; return
            }
        }
        
        // 方式3: 通过 nativeDetail 获取
        let nd = await spider.nativeDetail(ids: video.vodId, name: video.vodName)
        if let nd = nd, let pu = nd.vodPlayUrl, !pu.isEmpty {
            if let url = URL(string: pu) { await MainActor.run { initPlayer(url: url) }; return }
            let urls = parsePlayUrls(playFrom: nd.vodPlayFrom ?? "", playUrl: pu)
            let du = urls.first(where: { $0.contains(".m3u8") || $0.contains(".mp4") }) ?? urls.first ?? ""
            if !du.isEmpty, let url = URL(string: du) { await MainActor.run { initPlayer(url: url) }; return }
        }
        
        // 方式4: 检测网盘链接并解析
        let playUrlToCheck = video.vodPlayUrl ?? nd?.vodPlayUrl ?? ""
        if !playUrlToCheck.isEmpty, let driveType = CloudDriveManager.detectDrive(from: playUrlToCheck) {
            print("检测到 \(driveType.displayName) 分享链接，尝试网盘解析...")
            do {
                let result = try await CloudDriveManager.shared.resolvePlayURL(from: playUrlToCheck)
                print("网盘解析成功: \(result.url.prefix(60))...")
                if let url = URL(string: result.url) {
                    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": result.headers])
                    let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    await MainActor.run {
                        p.play()
                        player = p
                        isPlaying = true
                        isLoading = false
                    }
                    return
                }
            } catch {
                print("网盘解析失败: \(error)")
            }
        }
        
        // 解析失败
        await MainActor.run {
            loadError = "无法解析播放地址"
            isLoading = false
        }
    }
    
    private func parsePlayUrls(playFrom: String, playUrl: String) -> [String] {
        var urls: [String] = []
        if playUrl.contains("#") {
            let parts = playUrl.components(separatedBy: "#")
            for part in parts {
                if let range = part.range(of: "$") {
                    let u = String(part[range.upperBound...])
                    if !u.isEmpty { urls.append(u) }
                } else if !part.isEmpty { urls.append(part) }
            }
        } else if playUrl.contains("$$$") {
            urls = playUrl.components(separatedBy: "$$$")
        } else {
            urls = [playUrl]
        }
        return urls
    }
    
    private func initPlayer(url: URL) {
        print("初始化播放器，URL: \(url.absoluteString.prefix(80))")
        
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        
        // 创建播放器
        let p = AVPlayer(playerItem: playerItem)
        p.automaticallyWaitsToMinimizeStalling = true
        
        // 设置播放器
        self.player = p
        self.isPlaying = true
        self.isLoading = false
        
        // 添加时间观察者更新进度条
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let strongSelf = self else { return }
            DispatchQueue.main.async {
                strongSelf.currentTime = time.seconds
                if let itemDuration = p.currentItem?.duration {
                    strongSelf.duration = itemDuration.seconds.isFinite ? itemDuration.seconds : 0
                }
            }
        }
        
        // 延迟播放确保UI准备好
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            p.play()
            print("播放器开始播放")
        }
    }
}

// MARK: - AVPlayer 控制器封装 V2
struct AVPlayerControllerRepresentableV2: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspectFill
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // 确保播放器更新
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

struct DanmakuSettingsViewV2: View {
    @Binding var showDanmaku: Bool
    @Binding var opacity: Double
    @Binding var fontSize: CGFloat

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("弹幕开关") {
                    Toggle("开启弹幕", isOn: $showDanmaku)
                }

                Section("弹幕透明度") {
                    Slider(value: $opacity, in: 0...1, step: 0.1)
                }

                Section("弹幕字体大小") {
                    Slider(value: $fontSize, in: 12...24, step: 2)
                }
            }
            .navigationTitle("弹幕设置")
        }
    }
}

// MARK: - 弹幕数据模型
private struct DanmakuItemData: Identifiable {
    let text: String
    var x: CGFloat
    let y: CGFloat
    let id: Int
}

// MARK: - 弹幕覆盖层
struct DanmakuOverlayViewV2: View {
    @Binding var showDanmaku: Bool
    let opacity: Double
    let fontSize: CGFloat

    @State private var danmakuItems: [DanmakuItemData] = []
    @State private var itemPositions: [Int: CGFloat] = [:]
    @State private var currentIndex = 0
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ForEach(danmakuItems) { item in
                let xPos = itemPositions[item.id] ?? item.x
                Text(item.text)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(.white.opacity(opacity))
                    .shadow(color: .black, radius: 2)
                    .position(x: xPos, y: item.y)
            }
        }
        .onReceive(timer) { _ in
            if showDanmaku {
                // 添加新弹幕
                if currentIndex < 20 && currentIndex % 3 == 0 {
                    let y = CGFloat.random(in: 50...200)
                    let newItem = DanmakuItemData(
                        text: "弹幕 \(currentIndex)",
                        x: UIScreen.main.bounds.width + 50,
                        y: y,
                        id: currentIndex
                    )
                    danmakuItems.append(newItem)
                    itemPositions[currentIndex] = UIScreen.main.bounds.width + 50
                }
                currentIndex += 1
                
                // 移动弹幕
                for id in itemPositions.keys {
                    if let currentX = itemPositions[id] {
                        itemPositions[id] = currentX - 3
                    }
                }
                
                // 移除屏幕外的弹幕
                danmakuItems.removeAll { item in
                    let x = itemPositions[item.id] ?? 0
                    return x < -200
                }
                itemPositions = itemPositions.filter { $0.value > -200 }
            }
        }
    }
}

struct AirPlayViewV2: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        AVRoutePickerView()
    }
    
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - 其他组件
struct PlayerSettingsViewV2: View {
    @Binding var speed: Double
    var onSpeedChange: (Double) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("播放速度") {
                    ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { s in
                        Button("\(s)x") {
                            speed = s
                            onSpeedChange(s)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("播放设置")
        }
    }
}

struct EpisodePickerViewV2: View {
    let video: VodItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(1..<21, id: \.self) { ep in
                    Button("第\(ep)集") {
                        dismiss()
                    }
                }
            }
            .navigationTitle("选集")
        }
    }
}

struct QualityPickerViewV2: View {
    @Binding var selectedQuality: Int
    var onQualityChange: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(0..<3, id: \.self) { index in
                    Button(["标清", "高清", "蓝光"][index]) {
                        selectedQuality = index
                        onQualityChange(index)
                        dismiss()
                    }
                }
            }
            .navigationTitle("清晰度")
        }
    }
}
