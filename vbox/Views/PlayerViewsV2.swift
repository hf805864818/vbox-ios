import SwiftUI
import AVKit
import AVFoundation
import Combine
import UIKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

extension Notification.Name {
    static let vboxVLCPlay = Notification.Name("vbox.vlc.play")
    static let vboxVLCPause = Notification.Name("vbox.vlc.pause")
    static let vboxVLCSeek = Notification.Name("vbox.vlc.seek")
    static let vboxVLCSpeed = Notification.Name("vbox.vlc.speed")
    static let vboxMPVPlay = Notification.Name("vbox.mpv.play")
    static let vboxMPVPause = Notification.Name("vbox.mpv.pause")
    static let vboxMPVSeek = Notification.Name("vbox.mpv.seek")
    static let vboxMPVSpeed = Notification.Name("vbox.mpv.speed")
    static let vboxMPVStop = Notification.Name("vbox.mpv.stop")
}

// 屏幕方向辅助类
class OrientationHelper {
    static var currentOrientationMask: UIInterfaceOrientationMask = .all

    static func lockOrientation(_ orientation: UIInterfaceOrientationMask) {
        currentOrientationMask = orientation
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
            // 根据当前设备方向决定锁定哪个横屏方向
            let currentDeviceOrientation = UIDevice.current.orientation
            let targetOrientation: UIInterfaceOrientation
            if orientation == .landscape {
                if currentDeviceOrientation == .landscapeLeft {
                    targetOrientation = .landscapeLeft
                } else {
                    targetOrientation = .landscapeRight
                }
            } else {
                targetOrientation = .portrait
            }
            UIDevice.current.setValue(targetOrientation.rawValue, forKey: "orientation")
            UINavigationController.attemptRotationToDeviceOrientation()
        }
    }

    static func unlockOrientation() {
        currentOrientationMask = [.portrait, .landscapeLeft, .landscapeRight]
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: [.portrait, .landscapeLeft, .landscapeRight]))
        }
    }

    static func rotateToLandscape() {
        // 支持左右两种横屏方向，根据设备当前方向自动选择
        let currentOrientation = UIDevice.current.orientation
        let targetOrientation: UIInterfaceOrientation
        switch currentOrientation {
        case .landscapeLeft:
            targetOrientation = .landscapeLeft
        case .landscapeRight:
            targetOrientation = .landscapeRight
        case .portrait, .portraitUpsideDown, .faceUp, .faceDown, .unknown:
            targetOrientation = .landscapeRight
        @unknown default:
            targetOrientation = .landscapeRight
        }
        UIDevice.current.setValue(targetOrientation.rawValue, forKey: "orientation")
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let mask: UIInterfaceOrientationMask = (targetOrientation == .landscapeLeft) ? .landscapeLeft : .landscapeRight
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
        UINavigationController.attemptRotationToDeviceOrientation()
    }

    /// 播放器进入时：允许左右双向横屏+竖屏，自动跟随手机方向
    static func allowAllOrientations() {
        currentOrientationMask = [.portrait, .landscapeLeft, .landscapeRight]
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: [.portrait, .landscapeLeft, .landscapeRight]))
        }
    }
}

// MARK: - 画中画/小窗口辅助类
class PiPHelper: NSObject {
    static let shared = PiPHelper()
    
    private var pipController: AVPictureInPictureController?
    private var pipStatusObserver: Any?
    private var pipPlayerLayer: AVPlayerLayer?
    private var floatingWindow: UIWindow?
    private var floatingPlayerView: UIView?
    private var isFloatingMode = false
    private var pipStartRetries: Int = 0
    
    private override init() {
        super.init()
        // 监听屏幕拉伸模式变化，对所有播放器视图统一设置 contentMode
        NotificationCenter.default.addObserver(self, selector: #selector(handleVideoGravityChanged(_:)), name: .vboxVideoGravityChanged, object: nil)
    }

    @objc private func handleVideoGravityChanged(_ notification: Notification) {
        guard let mode = notification.userInfo?["mode"] as? PlayerState.VideoGravityMode else { return }
        let contentMode: UIView.ContentMode
        switch mode {
        case .aspectFill:
            contentMode = .scaleAspectFill
        case .aspectFit:
            contentMode = .scaleAspectFit
        case .resize:
            contentMode = .scaleToFill
        }

        DispatchQueue.main.async {
            guard let rootView = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first?.windows
                .first(where: { $0.isKeyWindow })?.rootViewController?.view else { return }

            let candidates = ["Player", "Video", "GL", "Metal", "Render", "AliPlayer", "VLC", "IJK", "MPV", "MDK"]
            self.setContentMode(contentMode, for: rootView, classNameHints: candidates)
        }
    }

    private func setContentMode(_ contentMode: UIView.ContentMode, for view: UIView, classNameHints: [String]) {
        let className = String(describing: type(of: view))
        let isPlayerView = classNameHints.contains(where: { className.contains($0) })
            || view is AVPlayerLayer
            || view.layer is AVPlayerLayer
            || String(describing: type(of: view.layer)).contains("Metal")
            || String(describing: type(of: view.layer)).contains("OpenGL")
        if isPlayerView {
            view.contentMode = contentMode
            view.clipsToBounds = true
        }
        for subview in view.subviews {
            setContentMode(contentMode, for: subview, classNameHints: classNameHints)
        }
    }

    /// 保存 AVPlayerViewController 内部的 playerLayer 引用，供画中画使用
    func setPlayerLayer(_ layer: AVPlayerLayer) {
        // 如果 PiP 控制器已存在且使用的是旧 layer，需要重新创建
        if pipPlayerLayer !== layer && pipController != nil {
            cleanupPiPController()
        }
        pipPlayerLayer = layer
    }
    
    // MARK: - AVPlayer 原生画中画
    func setupPiP(for player: AVPlayer) {
        // 清理旧的 PiP 控制器
        cleanupPiPController()
        
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            print("[PiP] 当前设备不支持画中画")
            return
        }
        
        // 激活音频会话（iOS 要求必须有活跃音频会话才能启动 PiP）
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[PiP] 音频会话激活失败: \(error.localizedDescription)")
        }
        
        // 优先使用 AVPlayerViewController 内部的 playerLayer（已挂载在视图层级中）
        let playerLayer: AVPlayerLayer
        if let existingLayer = pipPlayerLayer {
            playerLayer = existingLayer
            print("[PiP] 复用 AVPlayerViewController 内部的 playerLayer")
        } else {
            // 回退：创建独立的 playerLayer，使用标准 16:9 尺寸避免 PiP 画面异常
            let newLayer = AVPlayerLayer(player: player)
            newLayer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            newLayer.videoGravity = .resizeAspect
            pipPlayerLayer = newLayer
            playerLayer = newLayer
            print("[PiP] 创建独立 playerLayer（回退方案）")
        }
        
        let pipContentSource = AVPictureInPictureController.ContentSource(playerLayer: playerLayer)
        
        pipController = AVPictureInPictureController(contentSource: pipContentSource)
        pipController?.delegate = self
        
        pipStartRetries = 0
        
        pipStatusObserver = pipController?.observe(\AVPictureInPictureController.isPictureInPicturePossible, options: .new) { [weak self] _, change in
            DispatchQueue.main.async {
                if let isPossible = change.newValue, isPossible {
                    print("[PiP] isPictureInPicturePossible 变为 true")
                    self?.tryStartPiP()
                }
                NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: nil)
            }
        }
        
        // 先检查是否已经可以启动
        if pipController?.isPictureInPicturePossible == true {
            tryStartPiP()
        } else {
            schedulePiPStartRetry()
        }
    }
    
    private func tryStartPiP() {
        guard pipStartRetries < 5 else {
            print("[PiP] 超过最大重试次数，放弃启动 PiP")
            return
        }
        pipController?.startPictureInPicture()
        pipStartRetries += 1
    }
    
    private func schedulePiPStartRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if self.pipController?.isPictureInPicturePossible == true {
                self.tryStartPiP()
            } else if self.pipStartRetries < 5 {
                self.schedulePiPStartRetry()
            }
        }
    }
    
    func stopPiP() {
        pipController?.stopPictureInPicture()
        cleanupPiPController()
    }
    
    private func cleanupPiPController() {
        pipController?.stopPictureInPicture()
        if pipStatusObserver != nil {
            pipStatusObserver = nil
        }
        pipController = nil
        // 注意：不释放 pipPlayerLayer，因为它属于 AVPlayerViewController 的视图层级
    }
    
    var isPiPPossible: Bool {
        return pipController?.isPictureInPicturePossible ?? false
    }
    
    // MARK: - 浮动小窗口（用于 VLC/MPV 等非 AVPlayer 内核）
    func showFloatingWindow(sourceView: UIView) {
        guard !isFloatingMode else { return }
        isFloatingMode = true
        
        let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        guard let scene = windowScene else { return }
        
        let window = UIWindow(windowScene: scene)
        // 使用 alert 层级以上，确保浮窗不会被系统 PiP/Alert 遮挡
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 10)
        window.backgroundColor = .clear
        window.isHidden = false
        window.makeKeyAndVisible()
        
        let containerView = UIView(frame: CGRect(x: scene.screen.bounds.width - 220, y: 80, width: 200, height: 112))
        containerView.backgroundColor = .black
        containerView.layer.cornerRadius = 12
        containerView.layer.masksToBounds = true
        containerView.layer.shadowColor = UIColor.black.cgColor
        containerView.layer.shadowOpacity = 0.5
        containerView.layer.shadowOffset = CGSize(width: 0, height: 4)
        containerView.layer.shadowRadius = 12
        
        // 将源视图的播放器层复制到浮动窗口中
        // 找到sourceView中的播放器子视图并复制
        let playerSubviews = sourceView.subviews.filter { subview in
            // 识别播放器视图：通常是全屏的黑色背景视图或包含视频内容的视图
            return subview.frame.equalTo(sourceView.bounds) || subview.backgroundColor == .black
        }
        if let playerView = playerSubviews.first {
            // 创建截图作为初始显示
            if let snapshot = playerView.snapshotView(afterScreenUpdates: true) {
                snapshot.frame = containerView.bounds
                snapshot.tag = 1001 // 标记为截图视图
                containerView.addSubview(snapshot)
            }
            // 启动定时器更新截图，模拟视频播放效果
            startSnapshotTimer(sourceView: playerView)
        } else {
            // 回退：使用整个sourceView的截图，并启动定时更新
            if let snapshot = sourceView.snapshotView(afterScreenUpdates: true) {
                snapshot.frame = containerView.bounds
                snapshot.tag = 1001
                containerView.addSubview(snapshot)
            }
            startSnapshotTimer(sourceView: sourceView)
        }
        
        // 关闭按钮
        let closeBtn = UIButton(frame: CGRect(x: containerView.bounds.width - 32, y: 4, width: 28, height: 28))
        closeBtn.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeBtn.tintColor = .white
        closeBtn.addTarget(self, action: #selector(hideFloatingWindow), for: .touchUpInside)
        containerView.addSubview(closeBtn)
        
        // 添加拖拽手势
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        containerView.addGestureRecognizer(panGesture)
        
        // 双击恢复全屏
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        containerView.addGestureRecognizer(doubleTap)
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        tapGesture.require(toFail: doubleTap)
        containerView.addGestureRecognizer(tapGesture)
        
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(containerView)
        
        floatingWindow = window
        floatingPlayerView = containerView
        
        NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: nil)
    }
    
    @objc func hideFloatingWindow() {
        stopSnapshotTimer()
        floatingWindow?.isHidden = true
        floatingWindow = nil
        floatingPlayerView = nil
        isFloatingMode = false
        
        NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: nil)
    }
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        let superview = view.superview
        let translation = gesture.translation(in: superview)
        
        view.center = CGPoint(x: view.center.x + translation.x, y: view.center.y + translation.y)
        gesture.setTranslation(.zero, in: superview)
        
        if gesture.state == .ended {
            // 吸附到最近的边缘
            let screenBounds = UIScreen.main.bounds
            var targetX: CGFloat
            if view.center.x < screenBounds.width / 2 {
                targetX = view.bounds.width / 2 + 8
            } else {
                targetX = screenBounds.width - view.bounds.width / 2 - 8
            }
            // 限制 Y 范围
            let minY = view.bounds.height / 2 + 50
            let maxY = screenBounds.height - view.bounds.height / 2 - 50
            let targetY = min(max(view.center.y, minY), maxY)
            
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5) {
                view.center = CGPoint(x: targetX, y: targetY)
            }
        }
    }
    
    @objc private func handleDoubleTap() {
        hideFloatingWindow()
        NotificationCenter.default.post(name: .vboxPiPRestoreFullScreen, object: nil)
    }
    
    @objc private func handleSingleTap() {
        // 单击暂停/播放
        NotificationCenter.default.post(name: .vboxPiPTogglePlayPause, object: nil)
    }
    
    func updateFloatingSnapshot(_ snapshot: UIImage?) {
        guard let containerView = floatingPlayerView else { return }
        // 移除旧的截图视图
        containerView.subviews.first(where: { $0 is UIImageView })?.removeFromSuperview()
        guard let image = snapshot else { return }
        let imageView = UIImageView(image: image)
        imageView.frame = containerView.bounds
        imageView.contentMode = .scaleAspectFill
        containerView.insertSubview(imageView, at: 0)
    }
    
    // MARK: - 定时更新截图，模拟视频播放
    private var snapshotTimer: Timer?
    private var snapshotDisplayLink: CADisplayLink?
    private weak var snapshotSourceView: UIView?
    
    private func startSnapshotTimer(sourceView: UIView) {
        snapshotSourceView = sourceView
        snapshotTimer?.invalidate()
        snapshotDisplayLink?.invalidate()

        // 使用 CADisplayLink 保证进入后台前画面更新更频繁，并加入 common runloop
        let displayLink = CADisplayLink(target: self, selector: #selector(updateSnapshotFrame))
        displayLink.add(to: .main, forMode: .common)
        snapshotDisplayLink = displayLink

        // 额外用 Timer 兜底（后台 CADisplayLink 会暂停）
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateSnapshotFrame()
        }
    }

    @objc private func updateSnapshotFrame() {
        guard let sourceView = snapshotSourceView,
              let containerView = floatingPlayerView,
              !containerView.bounds.isEmpty else { return }

        // 捕获播放器视图当前帧，afterScreenUpdates=false 避免阻塞
        guard let snapshot = sourceView.snapshotView(afterScreenUpdates: false) else { return }

        // 移除旧的截图视图
        containerView.subviews.filter { $0.tag == 1001 }.forEach { $0.removeFromSuperview() }
        snapshot.frame = containerView.bounds
        snapshot.tag = 1001
        containerView.insertSubview(snapshot, at: 0)
    }
    
    private func stopSnapshotTimer() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        snapshotDisplayLink?.invalidate()
        snapshotDisplayLink = nil
        snapshotSourceView = nil
    }
    
    var isFloating: Bool { isFloatingMode }
}

extension PiPHelper: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: nil)
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: nil)
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("[PiP] 启动画中画失败: \(error.localizedDescription)")
        NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: nil)
    }
}

// MARK: - PiP 相关通知
extension Notification.Name {
    static let vboxPiPStatusChanged = Notification.Name("vbox.pip.statusChanged")
    static let vboxPiPRestoreFullScreen = Notification.Name("vbox.pip.restoreFullScreen")
    static let vboxPiPTogglePlayPause = Notification.Name("vbox.pip.togglePlayPause")
    static let vboxVideoGravityChanged = Notification.Name("vbox.videoGravity.changed")
}

// MARK: - 新版本播放器 (爱奇艺风格) - 简化版本，确保编译通过
struct VideoPlayerViewV2: View {
    let video: VodItem
    @StateObject private var playerState = PlayerState()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 播放器主体 - 始终显示，包含加载状态
            PlayerContainerView(
                player: playerState.player,
                playerState: playerState,
                video: video
            )
            
            // 错误提示（附带调试日志）
            if let error = playerState.loadError {
                ErrorViewWithLogs(error: error, logs: playerState.debugLogs, onRetry: { playerState.retry(video: video) })
            }

            // 调试日志浮层（开关控制，加载中+播放中都显示）
            // 放在返回键下方，左右避开按钮区域
            if UserDefaults.standard.bool(forKey: "show_debug_overlay") && !playerState.debugLogs.isEmpty {
                VStack {
                    HStack(alignment: .top, spacing: 0) {
                        // 左侧返回按钮预留区
                        Spacer().frame(width: 96)

                        ScrollView(showsIndicators: true) {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(playerState.debugLogs.enumerated()), id: \.offset) { idx, log in
                                    Text(log)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.green.opacity(0.9))
                                        .id(idx)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxWidth: 560)
                        .frame(height: 126)
                        .background(Color.black.opacity(0.75))
                        .cornerRadius(6)
                        .contentShape(Rectangle())
                        .allowsHitTesting(true)

                        // 右侧锁定按钮预留区
                        Spacer().frame(width: 96)
                    }
                    .padding(.top, 54)  // 返回键下方（返回键高度约44pt + 间距）
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear {
            // 进入播放器：先强制横屏，然后允许所有方向（自动跟随手机）
            OrientationHelper.rotateToLandscape()
            playerState.isPortrait = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                OrientationHelper.allowAllOrientations()
            }
            playerState.setupPlayer(video: video)
            
            // 监听PiP恢复全屏和暂停/播放通知
            NotificationCenter.default.addObserver(forName: .vboxPiPRestoreFullScreen, object: nil, queue: .main) { _ in
                playerState.isPiPActive = false
            }
            NotificationCenter.default.addObserver(forName: .vboxPiPTogglePlayPause, object: nil, queue: .main) { _ in
                playerState.togglePlayback(player: playerState.player)
            }
        }
        .onDisappear {
            // 恢复竖屏
            OrientationHelper.lockOrientation(.portrait)
            OrientationHelper.unlockOrientation()
            playerState.cleanup()
            NotificationCenter.default.removeObserver(self, name: .vboxPiPRestoreFullScreen, object: nil)
            NotificationCenter.default.removeObserver(self, name: .vboxPiPTogglePlayPause, object: nil)
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background, .inactive:
                playerState.handleSceneBackground()
            case .active:
                // 关闭系统画中画 + 异步恢复播放（带超时保护）
                if playerState.isPiPActive {
                    #if canImport(Libmpv)
                    MPVPiPManager.shared.stopPiP()
                    #endif
                    #if canImport(swift_mdk)
                    MDKPipManager.shared.stopPiP()
                    #endif
                    playerState.isPiPActive = false
                }
                playerState.handleSceneForeground()
            @unknown default:
                break
            }
        }
    }

}

// MARK: - 通用集数项
struct EpisodeItem: Identifiable {
    let id: Int
    let name: String
    let url: String
    /// 资源类型标记（用于切集时选择不同播放逻辑）
    var sourceType: EpisodeSourceType
    /// 百度文件索引（仅百度网盘使用）
    var baiduFileIndex: Int?
    /// 夸克文件索引（仅夸克网盘使用）
    var quarkFileIndex: Int?
    /// UC 文件 fid（仅 UC 网盘切换集数使用）
    var ucFileFid: String?
    /// UC 文件 shareFidToken（仅 UC 网盘切换集数使用）
    var ucShareFidToken: String?
    /// 播放头信息
    var headers: [String: String] = [:]
    /// 是否需要兼容内核
    var useCompatibility: Bool = false

    enum EpisodeSourceType: String {
        case normal = "normal"       // 普通资源
        case baidu = "baidu"         // 百度网盘
        case quark = "quark"         // 夸克网盘
        case drive = "drive"        // 其他网盘
    }
}

// MARK: - 播放器状态管理
class PlayerState: ObservableObject {
    /// 弹幕预设颜色表
    static let presetColors: [Int: Int] = [
        0: 16777215, // 原始颜色（不使用）
        1: 16777215, // 白色 #FFFFFF
        2: 16776960, // 黄色 #FFFF00
        3: 65280,    // 绿色 #00FF00
        4: 255,      // 蓝色 #0000FF
        5: 16711680, // 红色 #FF0000
        6: 16761035  // 粉色 #FF69B4
    ]

    enum PlaybackEngineMode: String {
        case system = "系统内核"
        case compatibility = "兼容内核"
    }

    enum PlaybackEnginePreference: String, CaseIterable, Identifiable {
        case auto = "自动"
        case system = "系统"
        case mdk = "MDK"
        case vlc = "VLC"
        case mpv = "MPV"
        case ijk = "IJK"
        case ali = "阿里"

        var id: String { rawValue }

        var subtitle: String {
            switch self {
            case .auto:
                return "普通资源走系统内核，特殊格式自动走兼容内核"
            case .system:
                return "强制使用 AVPlayer，适合普通 MP4"
            case .mdk:
                return "MDK 内核，Metal 硬解，支持系统画中画"
            case .vlc:
                return "优先使用 VLC，不支持系统画中画"
            case .mpv:
                return "MPV 内核，支持系统画中画"
            case .ijk:
                return "IJKPlayer 内核，适合网盘直链"
            case .ali:
                return "阿里云播放器内核，原生系统画中画，夸克直链首选"
            }
        }
    }

    enum VideoGravityMode: String, CaseIterable {
        case aspectFill = "填充"
        case aspectFit = "适应"
        case resize = "拉伸"

        var avGravity: AVLayerVideoGravity {
            switch self {
            case .aspectFill: return .resizeAspectFill
            case .aspectFit: return .resizeAspect
            case .resize: return .resize
            }
        }

        var icon: String {
            switch self {
            case .aspectFill: return "arrow.up.left.and.arrow.down.right"
            case .aspectFit: return "aspectratio"
            case .resize: return "arrow.left.and.right"
            }
        }
    }

    @Published var player: AVPlayer?
    @Published var isPlaying = true
    @Published var showControls = true
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isSeeking = false
    @Published var seekPreviewTime: Double = 0
    @Published var isLoading = true
    @Published var loadError: String?
    @Published var showSettings = false
    @Published var showEpisodePicker = false
    @Published var showQualityPicker = false
    @Published var showDanmakuSettings = false
    @Published var showEnginePicker = false
    @Published var showDanmakuInput = false
    @Published var currentDanmakuEpisodeId: Int? = nil
    @Published var loadingMessage = "正在解析播放地址..."
    @Published var selectedQuality = 1
    @Published var playbackSpeed: Double = 1.0
    @Published var showDanmaku = false
    @Published var isPortrait = false
    @Published var danmakuOpacity: Double = 0.8
    @Published var danmakuFontSize: CGFloat = 16
    @Published var danmakuArea: Double = 0.25       // 弹幕显示区域比例 0.25/0.5/0.75/1.0
    @Published var danmakuSpeed: Double = 1.0       // 弹幕滚动速度倍率 0.5/0.75/1.0/1.5/2.0
    @Published var danmakuColorMode: Int = 0       // 0=原始颜色, 1=白色, 2=黄色, 3=绿色, 4=蓝色, 5=红色, 6=粉色
    @Published var isOrientationLocked = false
    @Published var isPiPActive = false
    @Published var videoGravity: VideoGravityMode = .aspectFill {
        didSet {
            if oldValue != videoGravity {
                NotificationCenter.default.post(name: .vboxVideoGravityChanged, object: nil, userInfo: ["mode": videoGravity])
            }
        }
    }
    @Published var volume: Double = 0.5
    @Published var brightness: Double = 0.5
    @Published var danmakuItems: [DanmakuRenderItem] = []
    @Published var danmakuLoadedCount = 0
    @Published var currentEpisodeIndex = 0
    @Published var debugLogs: [String] = []  // 可视化调试日志
    @Published var playbackEngineMode: PlaybackEngineMode = .system
    @Published var compatibilityHint: String?
    @Published var compatibilityURL: URL?
    @Published var compatibilityHeaders: [String: String] = [:]
    @Published var compatibilityEngineName: String = "VLC"
    @Published var enginePreference: PlaybackEnginePreference = .auto
    @Published var baiduFileList: [BaiduFileItem] = [] // 百度多文件列表
    @Published var baiduShareURL: String = ""    // 百度分享链接
    @Published var baiduCachedTimeRanges: [(start: Double, end: Double)] = []
    /// 场景恢复保护：防止 watchdog 因主线程阻塞杀进程
    @Published var isRestoringFromBackground = false
    private var sceneRestorationTask: Task<Void, Never>?
    @Published var isFavorite: Bool = false  // 当前视频是否已收藏
    
    // 通用集数列表（所有资源类型共用）
    @Published var episodeItems: [EpisodeItem] = []

    /// 当前集资源类型（用于判断走系统画中画还是应用内小窗）
    var currentEpisodeSourceType: EpisodeItem.EpisodeSourceType {
        guard currentEpisodeIndex >= 0, currentEpisodeIndex < episodeItems.count else { return .normal }
        return episodeItems[currentEpisodeIndex].sourceType
    }
    
    var baiduBduss: String = ""                  // 百度Token
    var baiduPcsCookie: String = ""              // 百度PCS下载Cookie
    // 夸克网盘多文件列表
    var quarkFileList: [CloudDriveManager.QuarkShareFile] = []
    var quarkShareURL: String = ""
    var quarkCookie: String = ""
    private var currentVideo: VodItem?
    private var allDanmakuItems: [LogVarDanmakuItem] = []
    private var emittedDanmakuIDs = Set<Int>()
    private var danmakuTask: Task<Void, Never>?
    private var lastProgressSaveAt: Date = .distantPast
    private var baiduStreamRetryCount = 0        // 百度PCS流403后自动刷新直链次数
    private var baiduPrefetchTask: Task<Void, Never>?
    private var baiduPrefetchingIds = Set<String>()
    private var baiduNearEndPrefetchedIndexes = Set<Int>()
    private var quarkFallbackURL: String?
    private var quarkFallbackHeaders: [String: String]?
    private var quarkFallbackSource: String?
    private var quarkFallbackAttempted = false
    private var quarkFallbackTimeoutTask: Task<Void, Never>?
    private var m3u8ProbeCache: [String: M3U8ProbeCacheEntry] = [:]
    private var currentBaiduLocalProxyURL: URL?
    private var currentBaiduStreamId: String?
    private var baiduCacheObserver: NSObjectProtocol?
    private var lastBaiduProgressReportAt: Date = .distantPast

    private enum M3U8PlaylistKind: String {
        case fmp4 = "hls-fmp4"
        case ts = "hls-ts"
        case unknown = "hls-unknown"
    }

    private struct M3U8ProbeCacheEntry {
        let kind: M3U8PlaylistKind
        let expiresAt: Date
    }

    private var isVLCBuildAvailable: Bool {
        #if canImport(MobileVLCKit)
        return true
        #else
        return false
        #endif
    }

    private var isMPVBuildAvailable: Bool {
        #if canImport(Libmpv)
        return true
        #else
        return false
        #endif
    }

    private var isMDKBuildAvailable: Bool {
        #if canImport(swift_mdk)
        return true
        #else
        return false
        #endif
    }

    private var isIJKBuildAvailable: Bool {
        #if canImport(IJKMediaFrameworkWithSSL)
        return true
        #else
        return false
        #endif
    }

    private var isAliPlayerBuildAvailable: Bool {
        // canImport 对手动添加的 framework 可能不生效，改为运行时检测
        return NSClassFromString("AliPlayer") != nil
    }

    private var shouldUseCompatibilityEngine: Bool {
        switch enginePreference {
        case .auto:
            return playbackEngineMode == .compatibility && (isMDKBuildAvailable || isMPVBuildAvailable || isVLCBuildAvailable || isIJKBuildAvailable || isAliPlayerBuildAvailable)
        case .system:
            return false
        case .mdk:
            return isMDKBuildAvailable
        case .vlc:
            return isVLCBuildAvailable
        case .mpv:
            return isMPVBuildAvailable
        case .ijk:
            return isIJKBuildAvailable
        case .ali:
            return isAliPlayerBuildAvailable
        }
    }

    /// 当前使用的兼容内核是否支持系统级画中画
    var isCurrentCompatibilityEngineSupportsPiP: Bool {
        guard playbackEngineMode == .compatibility else { return true }
        // MDK / MPV / IJK 支持帧桥接 PiP，VLC 不支持
        let engineName = compatibilityEngineName
        return engineName.contains("MDK") || engineName.contains("MPV") || engineName.contains("mpv") || engineName.contains("IJK")
    }

    /// 当前引擎是否支持系统级画中画（用于 UI 按钮状态）
    var isPiPSupported: Bool {
        // 所有引擎都支持某种形式的画中画：
        // AVPlayer → 原生 PiP
        // MPV → 帧桥接 PiP
        // VLC → 浮动窗口
        return true
    }

    var currentEngineButtonTitle: String {
        switch enginePreference {
        case .auto:
            if playbackEngineMode == .compatibility {
                // 显示实际使用的兼容内核名称，避免与 EngineResolver 决策不一致
                let shortName = compatibilityEngineName
                    .replacingOccurrences(of: "-MoltenVK", with: "")
                    .replacingOccurrences(of: "Player", with: "")
                return "自动/\(shortName)"
            }
            return "自动"
        case .system:
            return "系统"
        case .mdk:
            return "MDK"
        case .vlc:
            return "VLC"
        case .mpv:
            return "MPV"
        case .ijk:
            return "IJK"
        case .ali:
            return "阿里"
        }
    }

    private func preferredCompatibilityEngineName(for url: URL? = nil) -> String {
        switch enginePreference {
        case .mdk:
            return isMDKBuildAvailable ? "MDK" : "VLC"
        case .mpv:
            return isMPVBuildAvailable ? "MPV-MoltenVK" : "VLC"
        case .vlc:
            return isVLCBuildAvailable ? "VLC" : (isMPVBuildAvailable ? "MPV-MoltenVK" : "VLC")
        case .ijk:
            return isIJKBuildAvailable ? "IJKPlayer" : (isMPVBuildAvailable ? "MPV-MoltenVK" : "VLC")
        case .ali:
            return isAliPlayerBuildAvailable ? "AliPlayer" : (isMPVBuildAvailable ? "MPV-MoltenVK" : "VLC")
        case .auto:
            if isMDKBuildAvailable, shouldPreferMDK(for: url) {
                return "MDK"
            }
            if isAliPlayerBuildAvailable, shouldPreferAliPlayer(for: url) {
                return "AliPlayer"
            }
            if isIJKBuildAvailable, shouldPreferIJK(for: url) {
                return "IJKPlayer"
            }
            if isMPVBuildAvailable, shouldPreferMPV(for: url) {
                return "MPV-MoltenVK"
            }
            if isVLCBuildAvailable {
                return "VLC"
            }
            return isMPVBuildAvailable ? "MPV-MoltenVK" : "VLC"
        case .system:
            return "系统"
        }
    }

    private func shouldPreferMDK(for url: URL?) -> Bool {
        guard isMDKBuildAvailable else { return false }
        guard let url else { return false }
        let text = url.absoluteString.lowercased()
        // 夸克直链优先 MPV，不再走 MDK
        if text.contains("baidu-stream") { return true }
        if text.contains(".mkv") || text.contains("mkv") { return true }
        return false
    }

    private func shouldPreferMPV(for url: URL?) -> Bool {
        guard isMPVBuildAvailable else { return false }
        guard let url else { return compatibilityHint != nil }
        let text = url.absoluteString.lowercased()
        // 百度原画走 MPV，夸克已优先 IJK
        if text.contains("baidu-stream") { return true }
        if text.contains(".mkv") || text.contains("mkv") { return true }
        if compatibilityHint?.contains("MKV") == true { return true }
        if compatibilityHint?.contains("百度原画") == true { return true }
        return false
    }

    private func shouldPreferIJK(for url: URL?) -> Bool {
        guard isIJKBuildAvailable else { return false }
        guard let url else { return false }
        let text = url.absoluteString.lowercased()
        // 夸克/UC/百度直链优先 IJKPlayer
        if text.contains("quark-stream") { return true }
        if text.contains("quark-m3u8") { return true }
        if text.contains("uc-stream") { return true }
        if text.contains("baidu-stream") { return true }
        return false
    }

    private func shouldPreferAliPlayer(for url: URL?) -> Bool {
        guard isAliPlayerBuildAvailable else { return false }
        guard let url else { return false }
        let text = url.absoluteString.lowercased()
        // 云盘本地代理 URL（127.0.0.1:18080）对 AliPlayer 兼容性差，自动模式下不优先。
        // AliPlayer 保留用于普通网络视频或阿里直链场景。
        if text.contains("quark-stream") { return false }
        if text.contains("quark-m3u8") { return false }
        if text.contains("baidu-stream") { return false }
        if text.contains("127.0.0.1") { return false }
        return false
    }

    private func compatibilityReason(for fileName: String) -> String? {
        let lower = fileName.lowercased()
        let rules: [(String, String)] = [
            (".mkv", "MKV 封装"),
            ("hevc", "HEVC/H.265"),
            ("h265", "HEVC/H.265"),
            ("x265", "HEVC/H.265"),
            ("10bit", "10bit 视频"),
            ("hdr", "HDR 视频"),
            ("4k", "4K 高码率"),
            ("高码率", "高码率视频")
        ]
        return rules.first(where: { lower.contains($0.0) })?.1
    }

    func cycleVideoGravity() {
        let allModes = VideoGravityMode.allCases
        if let idx = allModes.firstIndex(of: videoGravity) {
            videoGravity = allModes[(idx + 1) % allModes.count]
        }
        log("[PlayerV2] 屏幕拉伸模式切换为：\(videoGravity.rawValue)")
    }

    func selectPlaybackEngine(_ preference: PlaybackEnginePreference) {
        let oldPreference = enginePreference
        enginePreference = preference
        showEnginePicker = false
        switch preference {
        case .auto:
            log("[PlayerV2] 已切换内核策略：自动")
        case .system:
            log("[PlayerV2] 已切换内核策略：系统内核")
        case .mdk:
            log("[PlayerV2] 已切换内核策略：MDK\(isMDKBuildAvailable ? "" : "（当前构建未包含 MDK）")")
        case .vlc:
            log("[PlayerV2] 已切换内核策略：VLC\(isVLCBuildAvailable ? "" : "（当前构建未包含 VLC）")")
        case .mpv:
            log("[PlayerV2] 已切换内核策略：MPV-MoltenVK\(isMPVBuildAvailable ? "" : "（当前构建未包含 Libmpv）")")
        case .ijk:
            log("[PlayerV2] 已切换内核策略：IJKPlayer\(isIJKBuildAvailable ? "" : "（当前构建未包含 IJKPlayer）")")
        case .ali:
            // 如果当前未检测到 AliPlayer，再次触发运行时加载（应对 TrollStore 等场景下启动时未成功加载的情况）
            if !isAliPlayerBuildAvailable {
                loadAliyunPlayerIfNeeded()
            }
            log("[PlayerV2] 已切换内核策略：AliPlayer\(isAliPlayerBuildAvailable ? "" : "（当前构建未包含 AliyunPlayer）")")
        }

        // 如果正在播放网盘资源（夸克/百度），切换内核后立即用新引擎重新播放当前资源
        if oldPreference != preference, isPlaying || compatibilityURL != nil || player != nil {
            restartCurrentResourceWithNewEngine()
        }

        if !baiduFileList.isEmpty, currentEpisodeIndex < baiduFileList.count {
            switchBaiduFile(index: currentEpisodeIndex)
        }
    }

    /// 切换内核后，用新引擎重新播放当前正在播放的资源
    private func restartCurrentResourceWithNewEngine() {
        // 夸克多文件：重新播放当前集
        if !quarkFileList.isEmpty, currentEpisodeIndex < quarkFileList.count,
           !quarkShareURL.isEmpty {
            currentTask?.cancel()
            currentTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let file = self.quarkFileList[self.currentEpisodeIndex]
                    let result = try await CloudDriveManager.shared.resolvePlayURL(from: "\(self.quarkShareURL)/\(file.fid)")
                    await self.playResolvedDriveVideo(result)
                } catch {
                    self.log("[PlayerV2] 切换内核后重新播放夸克失败: \(error.localizedDescription)")
                }
            }
            return
        }

        // 百度多文件
        if !baiduFileList.isEmpty, currentEpisodeIndex < baiduFileList.count,
           !baiduShareURL.isEmpty {
            switchBaiduFile(index: currentEpisodeIndex)
            return
        }

        // 通用网盘/普通资源：如果有当前播放 URL，直接重新走 playDriveVideo
        if let url = compatibilityURL?.absoluteString, !url.isEmpty {
            currentTask?.cancel()
            currentTask = Task { [weak self] in
                guard let self else { return }
                await self.playDriveVideo(url: url, headers: self.compatibilityHeaders)
            }
            return
        }

        // 系统播放器 AVPlayer 场景：如果正在播放，重新创建播放器以应用新内核选择
        if let url = player?.currentItem?.asset as? AVURLAsset {
            currentTask?.cancel()
            currentTask = Task { [weak self] in
                guard let self else { return }
                await self.playDriveVideo(url: url.url.absoluteString, headers: [:])
            }
        }
    }

    /// 切换百度多文件中的指定文件播放
    func switchBaiduFile(index: Int) {
        guard index >= 0, index < baiduFileList.count else { return }
        let file = baiduFileList[index]
        let url = baiduShareURL
        guard !url.isEmpty else { return }
        
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self = self else { return }
            await self.startBaiduPlayback(
                shareURL: url,
                bduss: self.baiduBduss,
                pcsCookie: self.baiduPcsCookie,
                file: file,
                index: index,
                reason: "选集"
            )
        }
    }

    func seek(to seconds: Double) {
        if compatibilityURL != nil {
            guard duration.isFinite, duration > 0 else { return }
            let target = max(0, min(seconds, duration))
            isSeeking = true
            seekPreviewTime = target
            currentTime = target
            isLoading = false
            log("[PlayerV2] \(compatibilityEngineName) 拖拽进度跳转：\(formatDuration(target)) / \(formatDuration(duration))")
            let notification: Notification.Name = (compatibilityEngineName.contains("MPV") || compatibilityEngineName.contains("IJK")) ? .vboxMPVSeek : .vboxVLCSeek
            NotificationCenter.default.post(name: notification, object: nil, userInfo: ["seconds": target])
            isSeeking = false
            return
        }
        guard let player, duration.isFinite, duration > 0 else { return }
        let target = max(0, min(seconds, duration))
        let cmTime = CMTime(seconds: target, preferredTimescale: 600)
        isSeeking = true
        seekPreviewTime = target
        loadingMessage = "正在跳转到 \(formatDuration(target))..."
        isLoading = true
        log("[PlayerV2] 拖拽进度跳转：\(formatDuration(target)) / \(formatDuration(duration))")
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = target
                self.isSeeking = false
                self.isLoading = false
                if finished, self.isPlaying {
                    self.player?.play()
                }
            }
        }
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func playNextBaiduFile() {
        let next = currentEpisodeIndex + 1
        guard next < baiduFileList.count else {
            log("[Baidu] 已经是最后一集")
            return
        }
        switchBaiduFile(index: next)
    }
    
    /// 是否有下一集（通用）
    var hasNextEpisode: Bool {
        if !episodeItems.isEmpty {
            return currentEpisodeIndex + 1 < episodeItems.count
        }
        return currentEpisodeIndex + 1 < baiduFileList.count
    }
    
    /// 播放下一集（通用）
    func playNextEpisode() {
        if !episodeItems.isEmpty {
            switchToEpisode(index: currentEpisodeIndex + 1)
        } else {
            playNextBaiduFile()
        }
    }

    /// 如果有下一集则自动播放（用于播放结束回调）
    func playNextEpisodeIfAvailable() {
        guard hasNextEpisode else {
            log("[PlayerV2] 已播放到最后一集")
            return
        }
        log("[PlayerV2] 自动播放下一集")
        playNextEpisode()
    }

    func togglePlayback(player: AVPlayer?) {
        if let player {
            isPlaying ? player.pause() : player.play()
            isPlaying.toggle()
            return
        }
        guard compatibilityURL != nil else { return }
        let isMPVorIJK = compatibilityEngineName.contains("MPV") || compatibilityEngineName.contains("IJK")
        if isPlaying {
            NotificationCenter.default.post(name: isMPVorIJK ? .vboxMPVPause : .vboxVLCPause, object: nil)
        } else {
            NotificationCenter.default.post(name: isMPVorIJK ? .vboxMPVPlay : .vboxVLCPlay, object: nil)
        }
        isPlaying.toggle()
    }

    func changePlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        if let player {
            player.rate = isPlaying ? Float(speed) : 0
        }
        if compatibilityURL != nil {
            let isMPVorIJK = compatibilityEngineName.contains("MPV") || compatibilityEngineName.contains("IJK")
            let notification: Notification.Name = isMPVorIJK ? .vboxMPVSpeed : .vboxVLCSpeed
            NotificationCenter.default.post(name: notification, object: nil, userInfo: ["speed": speed])
            log("[PlayerV2] \(compatibilityEngineName) 倍速切换：\(String(format: "%.2f", speed))X")
        }
    }

    func changeQuality(index: Int) {
        selectedQuality = index
        if !baiduFileList.isEmpty {
            log("[Baidu] 当前百度DLNA播放为源文件/原画链路，暂不支持转码清晰度切换")
        }
    }

    /// 从URL中检测视频画质并更新 selectedQuality（0=标清, 1=高清, 2=蓝光）
    func detectVideoQuality(from urlString: String) {
        let lower = urlString.lowercased()
        // 蓝光/4K
        if lower.contains("蓝光") || lower.contains("bd") || lower.contains("bluray") ||
           lower.contains("2160") || lower.contains("4k") || lower.contains("uhd") {
            selectedQuality = 2
            log("[PlayerV2] 画质检测: 蓝光")
            return
        }
        // 高清/1080p
        if lower.contains("高清") || lower.contains("1080") || lower.contains("超清") ||
           lower.contains("hd") || lower.contains("fhd") || lower.contains("full") {
            selectedQuality = 1
            log("[PlayerV2] 画质检测: 高清")
            return
        }
        // 标清/720p及以下
        if lower.contains("标清") || lower.contains("720") || lower.contains("480") ||
           lower.contains("360") || lower.contains("sd") || lower.contains("low") {
            selectedQuality = 0
            log("[PlayerV2] 画质检测: 标清")
            return
        }
        // 默认高清
        log("[PlayerV2] 画质检测: 默认高清")
    }

    private func loadDanmaku(for video: VodItem, fileName: String) {
        danmakuTask?.cancel()
        allDanmakuItems = []
        danmakuItems = []
        emittedDanmakuIDs.removeAll()
        danmakuLoadedCount = 0

        let query = bestDanmakuQuery(video: video, fileName: fileName)
        guard !query.isEmpty else { return }
        log("[Danmaku] 开始匹配：\(query)")
        danmakuTask = Task { [weak self] in
            // 先匹配episodeId，保存到状态
            if let episodeId = await LogVarDanmakuService.shared.matchEpisode(fileName: query) {
                await MainActor.run {
                    self?.currentDanmakuEpisodeId = episodeId
                }
            }
            let items = await LogVarDanmakuService.shared.matchAndFetch(fileName: query)
            await MainActor.run {
                guard let self else { return }
                self.allDanmakuItems = items.sorted { $0.time < $1.time }
                self.danmakuLoadedCount = items.count
                self.emittedDanmakuIDs.removeAll()
                self.danmakuItems = []
                self.log(items.isEmpty ? "[Danmaku] 未匹配到弹幕" : "[Danmaku] 已加载 \(items.count) 条弹幕")
            }
        }
    }

    private func bestDanmakuQuery(video: VodItem, fileName: String) -> String {
        let candidate = (fileName as NSString).deletingPathExtension
        // 网盘资源通常有真实文件名，优先使用
        if candidate.count >= 4,
           candidate != "baidu-stream",
           candidate != "quark-stream",
           candidate != "ali-stream",
           !candidate.hasPrefix("http"),
           !candidate.allSatisfy({ $0.isNumber }) {
            return candidate
        }
        // 切片资源或文件名不规范时，使用视频标题+集数组合
        let episodeNum = extractEpisodeNumber(from: fileName)
        if episodeNum > 1 {
            return "\(video.vodName) E\(String(format: "%02d", episodeNum))"
        }
        return video.vodName
    }
    
    /// 从文件名提取集数（用于弹幕查询增强）
    private func extractEpisodeNumber(from fileName: String) -> Int {
        let name = (fileName as NSString).deletingPathExtension
        let patterns = [
            #"[Ee][Pp]?(\d{1,3})(?:\b|[^0-9])"#,
            #"第\s*(\d{1,3})\s*[集话话期]"#,
            #"\.(\d{1,3})\."#,
            #"_(\d{1,3})_"#,
            #"\s(\d{1,3})\s"#
        ]
        for pattern in patterns {
            if let range = name.range(of: pattern, options: .regularExpression) {
                let numStr = String(name[range]).filter { $0.isNumber }
                if let num = Int(numStr), num > 0 {
                    return num
                }
            }
        }
        return 1
    }

    /// 轨道占用记录：[laneIndex: (最后一条弹幕进入时间, 最后一条弹幕内容长度)]
    private var laneOccupancy: [Int: (time: Double, contentLength: Int)] = [:]
    /// 记录每条弹幕的预估宽度，用于水平碰撞检测
    private var danmakuWidthCache: [Int: CGFloat] = [:]
    /// 限制弹幕刷新频率
    private var lastDanmakuUpdateTime: Double = -1

    func updateDanmaku(at time: Double) {
        guard showDanmaku, !allDanmakuItems.isEmpty, time.isFinite else { return }
        // 限制刷新频率约 20fps，避免频繁计算和 UI 刷新导致卡顿
        if lastDanmakuUpdateTime > 0, time - lastDanmakuUpdateTime < 0.05 {
            return
        }
        lastDanmakuUpdateTime = time
        // 缩小时间窗口并限制单次发射量，避免瞬间大量弹幕涌入导致重叠/卡顿
        let windowStart = max(0, time - 0.05)
        let windowEnd = time + 0.1
        let newItems = allDanmakuItems
            .filter { $0.time >= windowStart && $0.time <= windowEnd && !emittedDanmakuIDs.contains($0.id) }
            .prefix(2)

        guard !newItems.isEmpty || !danmakuItems.isEmpty else { return }
        for item in newItems {
            emittedDanmakuIDs.insert(item.id)
        }
        // 弹幕持续时间：速度越快持续时间越短
        let baseDuration = 8.0
        let duration = baseDuration / max(danmakuSpeed, 0.25)
        // 动态计算轨道数：根据字体大小和显示区域
        let laneHeight = danmakuFontSize + 22
        // 使用更合理的预估高度，竖屏约 400pt，横屏约 220pt
        let areaHeight = isPortrait ? 400.0 * danmakuArea : 220.0 * danmakuArea
        let maxLanes = max(4, Int(areaHeight / laneHeight))
        let screenW = isPortrait ? CGFloat(400) : CGFloat(700) // 横屏更宽

        // 清理已过期的轨道占用记录（弹幕已离开屏幕）
        laneOccupancy = laneOccupancy.filter { _, info in
            time - info.time < duration
        }

        let appended = newItems.compactMap { item -> DanmakuRenderItem? in
            let itemWidth = max(80, CGFloat(item.content.count) * danmakuFontSize * (item.content.isASCII ? 0.6 : 0.72))
            danmakuWidthCache[item.id] = itemWidth

            // 水平碰撞检测：计算前一条弹幕当前位置，确保新弹幕不会追上
            let minGap: Double = 1.8 // 同轨道最小时间间隔（秒）
            let minHorizontalGap: CGFloat = 100.0 // 水平最小间距（点）

            var assignedLane = 0
            var foundLane = false

            for lane in 0..<maxLanes {
                if let lastInfo = laneOccupancy[lane] {
                    let timeGap = time - lastInfo.time
                    // 时间间隔必须足够
                    guard timeGap >= minGap else { continue }

                    // 水平碰撞检测：使用当前 lane 上一条弹幕的宽度
                    let lastWidth = max(80, CGFloat(lastInfo.contentLength) * danmakuFontSize * (item.content.isASCII ? 0.6 : 0.72))
                    let lastProgress = min(max(timeGap / duration, 0), 1)
                    let lastXPos = screenW - lastProgress * (screenW + lastWidth)
                    let lastRightEdge = lastXPos + lastWidth

                    // 新弹幕从右侧进入的位置
                    let newStartX = screenW

                    // 如果前一条弹幕尾部还在屏幕右侧足够远，新弹幕可以安全进入
                    if lastRightEdge < newStartX - minHorizontalGap {
                        assignedLane = lane
                        foundLane = true
                        break
                    }
                } else {
                    assignedLane = lane
                    foundLane = true
                    break
                }
            }

            // 找不到安全轨道直接丢弃该弹幕，避免重叠
            guard foundLane else { return nil }

            // 更新轨道占用时间和内容长度
            laneOccupancy[assignedLane] = (time: time, contentLength: item.content.count)

            return DanmakuRenderItem(
                id: item.id,
                content: item.content,
                time: max(time, item.time),
                lane: assignedLane,
                color: danmakuColorMode == 0 ? item.color : Self.presetColors[danmakuColorMode] ?? item.color,
                duration: duration
            )
        }
        danmakuItems = (danmakuItems + appended)
            .filter { time - $0.time < $0.duration }
            .suffix(15) // 限制同时渲染的弹幕数量，避免卡顿
    }

    private func playbackProgressKey(for video: VodItem) -> String {
        "playback_progress_v2_\(video.vodId)_\(currentEpisodeIndex)"
    }

    private func restorePlaybackProgress(for video: VodItem) {
        let key = playbackProgressKey(for: video)
        let saved = UserDefaults.standard.double(forKey: key)
        guard saved > 10 else { return }
        currentTime = saved
        seekPreviewTime = saved
        log("[Progress] 已恢复上次进度：\(formatDuration(saved))")
    }

    func savePlaybackProgress(force: Bool = false) {
        guard let video = currentVideo, currentTime.isFinite, currentTime > 5 else { return }
        if duration > 0, duration - currentTime < 15 {
            UserDefaults.standard.removeObject(forKey: playbackProgressKey(for: video))
            // 同步清除 SQLite 历史记录
            let favorites = DatabaseManager.shared.queryFavorites()
            if let record = favorites.first(where: { $0.detailurl == video.vodId }),
               let fid = record.id {
                DatabaseManager.shared.removeFavorite(id: fid)
            }
            return
        }
        guard force || Date().timeIntervalSince(lastProgressSaveAt) > 5 else { return }
        lastProgressSaveAt = Date()
        UserDefaults.standard.set(currentTime, forKey: playbackProgressKey(for: video))
        // 同步写入 SQLite 历史记录
        let record = HistoryRecord(
            name: video.vodName,
            laiyuan: video.vodRemarks ?? "",
            imgurl: video.vodPic ?? "",
            detailurl: video.vodId,
            detailua: "",
            xianlu: currentEpisodeIndex,
            jishu: 0,
            progress: currentTime,
            lastPlayedAt: Int64(Date().timeIntervalSince1970)
        )
        DatabaseManager.shared.addOrUpdateHistory(record)
    }

    // MARK: - 收藏功能

    /// 检查当前视频是否已收藏
    func checkFavoriteStatus() {
        guard let video = currentVideo else { return }
        isFavorite = DatabaseManager.shared.isFavorite(
            detailurl: video.vodId,
            xianlu: currentEpisodeIndex,
            jishu: 0
        )
    }

    /// 切换收藏状态
    func toggleFavorite() {
        guard let video = currentVideo else { return }
        if isFavorite {
            // 取消收藏：从数据库中查找并删除
            let favorites = DatabaseManager.shared.queryFavorites()
            if let record = favorites.first(where: {
                $0.detailurl == video.vodId &&
                $0.xianlu == currentEpisodeIndex
            }) {
                if let id = record.id {
                    DatabaseManager.shared.removeFavorite(id: id)
                    isFavorite = false
                    log("[Favorite] 已取消收藏: \(video.vodName)")
                }
            }
        } else {
            // 添加收藏
            let record = FavoriteRecord(
                name: video.vodName,
                laiyuan: video.vodRemarks ?? "",
                imgurl: video.vodPic ?? "",
                detailurl: video.vodId,
                detailua: "",
                xianlu: currentEpisodeIndex,
                jishu: 0,
                addedAt: Int64(Date().timeIntervalSince1970)
            )
            DatabaseManager.shared.addFavorite(record)
            isFavorite = true
            log("[Favorite] 已收藏: \(video.vodName)")
        }
    }

    private func formatDuration(_ time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "00:00" }
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
    }

    /// 百度网盘统一播放入口：
    /// - 进入播放器：解析出文件列表后立即调用，默认播放第一集
    /// - 手动选集：带指定 fs_id 调用
    /// 这样不会只停在“文件列表成功”而不继续触发 Worker /play。
    private func startBaiduPlayback(
        shareURL: String,
        bduss: String,
        pcsCookie: String = "",
        file: BaiduFileItem,
        index: Int,
        reason: String
    ) async {
        let episodeNo = index + 1
        log("[Baidu] ②\(reason)第\(episodeNo)集：\(file.name)，主路链→原有链路兜底...")
        await MainActor.run {
            currentEpisodeIndex = index
            if let video = currentVideo {
                loadDanmaku(for: video, fileName: file.name)
                restorePlaybackProgress(for: video)
            }
            isLoading = true
            loadingMessage = "正在获取百度视频地址..."
            loadError = nil
            if let reason = compatibilityReason(for: file.name) {
                playbackEngineMode = .compatibility
                compatibilityHint = reason
                log("[PlayerV2] 当前资源疑似需要兼容内核：\(reason)")
            } else {
                playbackEngineMode = .system
                compatibilityHint = nil
            }
        }

        do {
            let resolveStart = Date()
            let result = try await CloudDriveManager.shared.resolveBaiduPlayURLViaMainRoute(
                shareURL: shareURL,
                bduss: bduss,
                fsId: file.fsId,
                fileName: file.name,
                pcsCookie: pcsCookie
            )
            log("[Baidu-iBoxRoute] ✅ 第\(episodeNo)集 iBox-style 路链播放地址获取成功，耗时=\(Int(Date().timeIntervalSince(resolveStart) * 1000))ms")
            if !reason.contains("刷新") && !reason.contains("重试") {
                baiduStreamRetryCount = 0
            }
            let source = result.source ?? "未知路链"
            log("[Baidu] 第\(episodeNo)集命中路链：\(source)")
            if source.contains("m3u8") || result.url.lowercased().contains(".m3u8") || result.url.contains("/share/streaming") {
                await MainActor.run {
                    playbackEngineMode = .system
                    compatibilityHint = nil
                }
                log("[Baidu] M3U8 兜底路链使用系统 HLS 内核")
            }
            let streamHeaders = mergedBaiduStreamHeaders(result.headers)
            await playDriveVideo(url: result.url, headers: streamHeaders)
        } catch let error as DriveError {
            let specificMsg: String
            switch error {
            case .noPlayURL(let reason): specificMsg = reason
            case .saveFailed: specificMsg = "转存失败"
            case .invalidResponse: specificMsg = "服务器响应异常"
            default: specificMsg = error.localizedDescription
            }
            log("[Baidu] ❌ 第\(episodeNo)集：\(specificMsg)")
            await MainActor.run {
                loadError = specificMsg
                isLoading = false
            }
        } catch {
            log("[Baidu] ❌ 第\(episodeNo)集：\(error.localizedDescription)")
            await MainActor.run {
                loadError = "百度播放失败: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }

    /// 添加调试日志（同时打印到控制台和UI）
    func log(_ msg: String) {
        print(msg)
        let short = msg.replacingOccurrences(of: "[PlayerV2] ", with: "")
        Task { @MainActor in
            debugLogs.append(short)
            // 保留最近 500 条，便于从头回溯完整播放/清理链路
            if debugLogs.count > 500 { debugLogs.removeFirst(debugLogs.count - 500) }
        }
    }

    private func bindBaiduCacheProgress(for localURL: URL?) {
        currentBaiduLocalProxyURL = localURL
        baiduCachedTimeRanges = []
        currentBaiduStreamId = URLComponents(url: localURL ?? URL(fileURLWithPath: ""), resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "id" })?
            .value
        if baiduCacheObserver == nil {
            baiduCacheObserver = NotificationCenter.default.addObserver(
                forName: .vboxBaiduStreamCacheProgress,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleBaiduCacheProgress(notification)
            }
        }
    }

    private func handleBaiduCacheProgress(_ notification: Notification) {
        guard let id = notification.userInfo?["id"] as? String,
              id == currentBaiduStreamId,
              duration.isFinite,
              duration > 0,
              let totalBytes = notification.userInfo?["totalBytes"] as? Int64,
              totalBytes > 0,
              let ranges = notification.userInfo?["ranges"] as? [[String: Int64]]
        else { return }

        let total = Double(totalBytes)
        baiduCachedTimeRanges = ranges.compactMap { item in
            guard let start = item["start"], let end = item["end"], end >= start else { return nil }
            let startTime = max(0, min(Double(start) / total * duration, duration))
            let endTime = max(0, min(Double(end + 1) / total * duration, duration))
            return (start: startTime, end: endTime)
        }

        // 计算预加载缓冲信息并输出到调试日志
        let cachedBytes = ranges.reduce(Int64(0)) { acc, item in
            guard let start = item["start"], let end = item["end"] else { return acc }
            return acc + max(0, end - start + 1)
        }
        let cachedMB = Double(cachedBytes) / 1024.0 / 1024.0
        let aheadRanges = baiduCachedTimeRanges.filter { $0.start > currentTime }
        let aheadSeconds = aheadRanges.reduce(0.0) { $0 + max(0, $1.end - max($1.start, currentTime)) }
        let bufferStatus: String
        if aheadSeconds < 10 {
            bufferStatus = "⚠️不足"
        } else if aheadSeconds < 30 {
            bufferStatus = "🟡一般"
        } else {
            bufferStatus = "🟢充足"
        }
        log("[预加载] 缓冲:\(String(format: "%.0f", aheadSeconds))秒\(bufferStatus) | 缓存:\(String(format: "%.1f", cachedMB))MB")
    }

    func reportBaiduCacheProgressIfNeeded(force: Bool = false) {
        guard let currentBaiduLocalProxyURL else { return }
        guard duration.isFinite, duration > 0, currentTime.isFinite else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastBaiduProgressReportAt) >= 4 else { return }
        lastBaiduProgressReportAt = now
        DoubanImageProxyServer.shared.reportBaiduStreamProgress(
            localURL: currentBaiduLocalProxyURL,
            currentTime: currentTime,
            duration: duration
        )
    }

    private func logDrivePlayResult(_ result: PlayResult) {
        if result.driveType == .quark {
            log("[Quark] 主线路：\(result.source ?? "未知")，host=\(URL(string: result.url)?.host ?? "unknown")")
            if let fallbackURL = result.fallbackURL {
                log("[Quark] 兜底线路：\(result.fallbackSource ?? "未知")，host=\(URL(string: fallbackURL)?.host ?? "unknown")")
            } else {
                log("[Quark] 兜底线路：暂无")
            }
        }
    }

    private func playResolvedDriveVideo(_ result: PlayResult) async {
        if result.driveType == .quark {
            quarkFallbackTimeoutTask?.cancel()
            quarkFallbackAttempted = false
            quarkFallbackURL = result.fallbackURL
            quarkFallbackHeaders = result.fallbackHeaders
            quarkFallbackSource = result.fallbackSource
            logDrivePlayResult(result)
            await playDriveVideo(url: result.url, headers: result.headers)
        } else {
            quarkFallbackTimeoutTask?.cancel()
            quarkFallbackAttempted = false
            quarkFallbackURL = nil
            quarkFallbackHeaders = nil
            quarkFallbackSource = nil
            await playDriveVideo(url: result.url, headers: result.headers)
        }
    }

    @discardableResult
    private func switchToQuarkFallback(reason: String) -> Bool {
        guard !quarkFallbackAttempted,
              let url = quarkFallbackURL,
              !url.isEmpty else {
            log("[Quark] 兜底线路不可用，无法切换：\(reason)")
            return false
        }

        quarkFallbackAttempted = true
        quarkFallbackTimeoutTask?.cancel()
        let headers = quarkFallbackHeaders ?? [:]
        let source = quarkFallbackSource ?? "v2-play-m3u8"
        log("[Quark] 原画线路失败，切换兜底线路：\(source)，原因：\(reason)")

        Task { [weak self] in
            guard let self else { return }
            await self.playDriveVideo(url: url, headers: headers)
        }
        return true
    }

    private func scheduleQuarkPrimaryFallbackTimeout(playerItem: AVPlayerItem, startedAt: Date) {
        guard quarkFallbackURL != nil, !quarkFallbackAttempted else { return }
        quarkFallbackTimeoutTask?.cancel()
        quarkFallbackTimeoutTask = Task { [weak self, weak playerItem] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, let playerItem, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.player?.currentItem === playerItem,
                      self.isLoading,
                      playerItem.status != .readyToPlay,
                      !self.quarkFallbackAttempted else { return }
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                self.log("[Quark] 原画线路首帧超时 \(elapsed)ms，准备切换 m3u8 兜底")
                self.switchToQuarkFallback(reason: "首帧超时")
            }
        }
    }

    private func prefetchNextBaiduFile(after index: Int) {
        let nextIndex = index + 1
        guard nextIndex < baiduFileList.count else { return }
        guard !baiduShareURL.isEmpty else { return }
        let nextFile = baiduFileList[nextIndex]
        guard !nextFile.fsId.isEmpty, !baiduPrefetchingIds.contains(nextFile.fsId) else { return }
        baiduPrefetchingIds.insert(nextFile.fsId)
        let shareURL = baiduShareURL
        let bduss = baiduBduss
        let pcsCookie = baiduPcsCookie

        baiduPrefetchTask?.cancel()
        baiduPrefetchTask = Task { [weak self] in
            guard let self else { return }
            self.log("[Baidu-MainRoute] 开始预取下一集主路链 PlayItem：第\(nextIndex + 1)集 \(nextFile.name)")
            do {
                _ = try await CloudDriveManager.shared.resolveBaiduPlayURLViaMainRoute(
                    shareURL: shareURL,
                    bduss: bduss,
                    fsId: nextFile.fsId,
                    fileName: nextFile.name,
                    pcsCookie: pcsCookie
                )
                self.log("[Baidu-MainRoute] ✅ 第\(nextIndex + 1)集主路链 PlayItem 已准备")
            } catch {
                self.log("[Baidu-MainRoute] ⚠️ 第\(nextIndex + 1)集主路链预取失败，保留原链路兜底：\(error.localizedDescription)")
            }
            await MainActor.run {
                self.baiduPrefetchingIds.remove(nextFile.fsId)
            }
        }
    }

    private func mergedBaiduStreamHeaders(_ headers: [String: String]) -> [String: String] {
        var merged = headers
        let resultCookie = headerValue(headers, named: "Cookie") ?? ""
        let webCookie = normalizeBaiduCookie(baiduBduss)
        let finalCookie = mergeCookieStrings([resultCookie, webCookie])

        if !finalCookie.isEmpty {
            merged["Cookie"] = finalCookie
        }

        if headerValue(merged, named: "User-Agent") == nil {
            merged["User-Agent"] = "Mozilla/5.0 (Linux; Android 12; HD1900 Build/SKQ1.211113.001) AppleWebKit/537.36 (KHTML, like Gecko)&channel=android_12_HD1900_bdnetdisktv_1025538l&version=1.21.1&network_type=wifi&app_id=250528&size=c1080_u1600"
        }
        if headerValue(merged, named: "Referer") == nil {
            merged["Referer"] = "https://pan.baidu.com/"
        }

        let lowerCookie = finalCookie.lowercased()
        log("[Baidu] 本地代理合并Cookie：hasBDUSS=\(lowerCookie.contains("bduss=")), hasSTOKEN=\(lowerCookie.contains("stoken=")), hasPANPSC=\(lowerCookie.contains("panpsc=")), hasPTOKEN=\(lowerCookie.contains("ptoken"))")
        return merged
    }

    private func headerValue(_ headers: [String: String], named name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }

    private func normalizeBaiduCookie(_ raw: String) -> String {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return "" }
        if input.lowercased().hasPrefix("cookie:") {
            input = String(input.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if input.range(of: #"BDUSS=|PANPSC=|PTOKEN|STOKEN=|BAIDUID="#, options: [.regularExpression, .caseInsensitive]) != nil {
            return input
                .replacingOccurrences(of: "\n", with: "; ")
                .replacingOccurrences(of: "\r", with: "; ")
                .replacingOccurrences(of: #"\s*;\s*"#, with: "; ", options: .regularExpression)
                .replacingOccurrences(of: #";+\s*$"#, with: "", options: .regularExpression)
        }

        if input.contains("|") {
            let cleaned = input.replacingOccurrences(of: #"^BDUSS="#, with: "", options: [.regularExpression, .caseInsensitive])
            let parts = cleaned.components(separatedBy: "|")
            var cookie = "BDUSS=\(parts[0].trimmingCharacters(in: .whitespacesAndNewlines))"
            if parts.count >= 2 {
                let stoken = parts[1]
                    .replacingOccurrences(of: #"^STOKEN="#, with: "", options: [.regularExpression, .caseInsensitive])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !stoken.isEmpty {
                    cookie += "; STOKEN=\(stoken)"
                }
            }
            return cookie
        }

        return "BDUSS=\(input.replacingOccurrences(of: "BDUSS=", with: "").trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private func mergeCookieStrings(_ cookies: [String]) -> String {
        var orderedKeys: [String] = []
        var values: [String: (name: String, value: String)] = [:]

        for cookie in cookies where !cookie.isEmpty {
            for part in cookie.split(separator: ";") {
                let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let eq = item.firstIndex(of: "=") else { continue }
                let name = String(item[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(item[item.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !value.isEmpty else { continue }
                let key = name.lowercased()
                if values[key] == nil {
                    orderedKeys.append(key)
                }
                values[key] = (name, value)
            }
        }

        return orderedKeys.compactMap { key in
            guard let item = values[key] else { return nil }
            return "\(item.name)=\(item.value)"
        }.joined(separator: "; ")
    }

    private var timeObserver: Any?
    private var statusObserver: AnyCancellable?
    private var failureObserver: AnyCancellable?
    private var hasRetriedNoReferer = false
    private var endObserver: AnyCancellable?
    private var currentTask: Task<Void, Never>?
    
    func setupPlayer(video: VodItem) {
        currentTask?.cancel()
        // 场景恢复期间不启动新播放器，避免主线程阻塞触发 watchdog
        if isRestoringFromBackground {
            log("[PlayerV2] 场景恢复中，延迟播放器初始化")
            sceneRestorationTask?.cancel()
            sceneRestorationTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run { self?.setupPlayer(video: video) }
            }
            return
        }
        currentVideo = video
        brightness = UIScreen.main.brightness
        volume = Double(AVAudioSession.sharedInstance().outputVolume)
        restorePlaybackProgress(for: video)
        loadDanmaku(for: video, fileName: video.vodName)

        // 监听 CloudDriveManager 的日志广播，显示在播放器 Debug Overlay
        NotificationCenter.default.addObserver(
            forName: .cloudDriveLog,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let msg = notification.object as? String else { return }
            self?.log(msg)
        }

        currentTask = Task { [weak self] in
            guard let self = self else { return }
            await resolvePlayUrl(video: video)
        }
    }

    // MARK: - 场景生命周期保护（防止 watchdog 超时杀进程）

    /// 进入后台时调用：暂停播放器，取消耗时任务
    func handleSceneBackground() {
        sceneRestorationTask?.cancel()
        sceneRestorationTask = nil
        currentTask?.cancel()
        currentTask = nil
        player?.pause()
        isPlaying = false
        savePlaybackProgress(force: true)
        log("[PlayerV2] 进入后台，已暂停播放器并取消任务")
    }

    /// 回到前台时调用：异步恢复播放器，带超时保护
    func handleSceneForeground() {
        guard !isRestoringFromBackground else { return }
        isRestoringFromBackground = true
        sceneRestorationTask?.cancel()
        sceneRestorationTask = Task { [weak self] in
            guard let self = self else { return }
            // 给场景更新 2 秒宽限期，避免主线程阻塞触发 watchdog
            try? await Task.sleep(nanoseconds: 200_000_000)
            await MainActor.run {
                self.isRestoringFromBackground = false
                // 只恢复播放，不做任何重解析/网络请求
                if self.player?.currentItem != nil, self.player?.rate == 0 {
                    self.player?.play()
                    self.isPlaying = true
                    self.log("[PlayerV2] 回到前台，已恢复播放")
                }
            }
        }
    }

    func cleanup() {
        currentTask?.cancel()
        currentTask = nil
        sceneRestorationTask?.cancel()
        sceneRestorationTask = nil
        danmakuTask?.cancel()
        danmakuTask = nil
        savePlaybackProgress(force: true)
        quarkFallbackTimeoutTask?.cancel()
        quarkFallbackTimeoutTask = nil
        quarkFallbackURL = nil
        quarkFallbackHeaders = nil
        quarkFallbackSource = nil
        quarkFallbackAttempted = false
        baiduPrefetchTask?.cancel()
        baiduPrefetchTask = nil
        baiduPrefetchingIds.removeAll()
        baiduNearEndPrefetchedIndexes.removeAll()
        if let baiduCacheObserver {
            NotificationCenter.default.removeObserver(baiduCacheObserver)
            self.baiduCacheObserver = nil
        }
        currentBaiduLocalProxyURL = nil
        currentBaiduStreamId = nil
        baiduCachedTimeRanges = []
        cleanupObservers()
        player?.pause()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player = nil
        compatibilityURL = nil
        compatibilityHeaders = [:]
        NotificationCenter.default.removeObserver(self, name: .cloudDriveLog, object: nil)
        // 清理 PiP 控制器（异步到主线程，避免 @MainActor 隔离冲突）
        Task { @MainActor in
            #if canImport(Libmpv)
            MPVPiPManager.shared.cleanupPiPController()
            #endif
            #if canImport(swift_mdk)
            MDKPipManager.shared.cleanupPiPController()
            #endif
        }
    }
    
    // MARK: - 网盘视频处理
    private func handleCloudVideo(video: VodItem) async {
        log("[PlayerV2] 处理网盘视频...")
        
        // 检查 vodPlayUrl 是否是 JSON 格式的网盘链接列表
        if let playUrl = video.vodPlayUrl, playUrl.hasPrefix("[") {
            do {
                if let data = playUrl.data(using: .utf8),
                   let links = try JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                    log("[PlayerV2] 解析到 \(links.count) 个网盘链接")
                    
                    // 尝试播放第一个有可用token的网盘链接
                    for link in links {
                        guard let url = link["url"], !url.isEmpty else { continue }
                        
                        if let driveType = CloudDriveManager.detectDrive(from: url) {
                            let tokens = CloudDriveManager.shared.tokens(for: driveType)
                            if !tokens.isEmpty {
                                log("[PlayerV2] 尝试播放 \(driveType.displayName)")
                                do {
                                    let result = try await CloudDriveManager.shared.resolvePlayURL(from: url)
                                    await playResolvedDriveVideo(result)
                                    return
                                } catch {
                                    log("[PlayerV2] \(driveType.displayName) 播放失败: \(error.localizedDescription)")
                                    continue
                                }
                            }
                        }
                    }
                    
                    await MainActor.run {
                        loadError = "网盘资源播放失败：请检查网盘Token配置"
                        isLoading = false
                    }
                    return
                }
            } catch {
                log("[PlayerV2] JSON解析失败: \(error)")
            }
        }
        
        // 检查 vodPlayUrl 是否是单个网盘链接
        if let playUrl = video.vodPlayUrl, !playUrl.isEmpty,
           let driveType = CloudDriveManager.detectDrive(from: playUrl) {
            log("[PlayerV2] 单个网盘链接: \(driveType.displayName)")
            await handleDriveUrl(playUrl, driveType: driveType)
            return
        }
        
        // 如果 vodId 是详情页URL，重新解析
        if video.vodId.hasPrefix("http") {
            log("[PlayerV2] 从详情页解析网盘链接...")
            if let result = await SpiderManager.shared.resolveCloudPlay(from: video.vodId), !result.links.isEmpty {
                log("[PlayerV2] 解析到 \(result.links.count) 个链接")
                
                for link in result.links {
                    if let driveType = CloudDriveManager.detectDrive(from: link.url) {
                        let tokens = CloudDriveManager.shared.tokens(for: driveType)
                        if !tokens.isEmpty {
                            do {
                                let playResult = try await CloudDriveManager.shared.resolvePlayURL(from: link.url)
                                await playResolvedDriveVideo(playResult)
                                return
                            } catch {
                                log("[PlayerV2] \(link.name) 失败: \(error.localizedDescription)")
                                continue
                            }
                        }
                    }
                }
            }
        }
        
        await MainActor.run {
            loadError = "网盘资源解析失败：未找到可播放链接"
            isLoading = false
        }
    }
    
    private func splitVboxFragment(from url: String) -> (baseURL: String, params: [String: String]) {
        let parts = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return (url, [:]) }
        let fragment = String(parts[1])
        var params: [String: String] = [:]
        var passthrough: [String] = []
        for item in fragment.split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else {
                passthrough.append(String(item))
                continue
            }
            let key = String(pair[0])
            let value = String(pair[1]).removingPercentEncoding ?? String(pair[1])
            if key.hasPrefix("vbox_") {
                params[key] = value
            } else {
                passthrough.append(String(item))
            }
        }
        let base = passthrough.isEmpty ? String(parts[0]) : "\(parts[0])#\(passthrough.joined(separator: "&"))"
        return (base, params)
    }

    private func appendVboxFragment(to url: String, params: [String: String]) -> String {
        let payload = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        return url.contains("#") ? "\(url)&\(payload)" : "\(url)#\(payload)"
    }

    private func handleDriveUrl(_ urlString: String, driveType: CloudDriveManager.DriveType) async {
        let split = splitVboxFragment(from: urlString)
        let cleanShareURL = split.baseURL
        let vboxParams = split.params
        if !vboxParams.isEmpty {
            log("[PlayerV2] 检测到详情页指定网盘文件参数，已分离干净分享链接")
        }
        let tokens = CloudDriveManager.shared.tokens(for: driveType)
        guard !tokens.isEmpty else {
            await MainActor.run {
                loadError = "未配置\(driveType.displayName) Token"
                isLoading = false
            }
            return
        }
        
        // 百度网盘：先获取文件列表，多文件则展示选择列表
        if driveType == .baidu {
            guard let pair = CloudDriveManager.shared.baiduTokenPair() else {
                await MainActor.run {
                    loadError = "缺少百度 Web Cookie：需要 BDUSS/STOKEN，PCS Cookie 不能替代"
                    isLoading = false
                }
                return
            }
            // 注册百度日志回调到悬浮日志
            CloudDriveManager.onLog = { [weak self] msg in
                self?.log("[PlayerV2] \(msg)")
            }
            log("[Baidu] ①请求分享页... WebToken=\(pair.web.name), PCSToken=\(pair.pcs?.name ?? "未配置")")
            do {
                let files = try await CloudDriveManager.shared.baiduGetFileList(shareURL: cleanShareURL, bduss: pair.web.value)
                log("[Baidu] ✅ 成功，共\(files.count)个文件: \(files.map { $0.name }.joined(separator: ", "))")
                await MainActor.run {
                    baiduFileList = files
                    baiduShareURL = cleanShareURL
                    baiduBduss = pair.web.value
                    baiduPcsCookie = pair.pcs?.value ?? ""
                    // 填充通用集数列表
                    episodeItems = files.enumerated().map { idx, f in
                        EpisodeItem(id: idx, name: f.name, url: "", sourceType: .baidu, baiduFileIndex: idx)
                    }
                }
                guard !files.isEmpty else {
                    await MainActor.run {
                        loadError = "百度文件列表为空"
                        isLoading = false
                    }
                    return
                }

                let selectedIndex = vboxParams["vbox_fsid"].flatMap { fsId in
                    files.firstIndex(where: { $0.fsId == fsId })
                } ?? 0
                let targetFile = files[selectedIndex]
                let reason = vboxParams["vbox_fsid"] != nil ? "详情页指定剧集" : (files.count == 1 ? "自动播放单文件" : "自动播放")
                await startBaiduPlayback(
                    shareURL: cleanShareURL,
                    bduss: pair.web.value,
                    pcsCookie: pair.pcs?.value ?? "",
                    file: targetFile,
                    index: selectedIndex,
                    reason: reason
                )
                return
            } catch let error as DriveError {
                let specificMsg: String
                switch error {
                case .noPlayURL(let reason): specificMsg = reason
                case .invalidShareURL: specificMsg = "无效的分享链接"
                case .invalidResponse: specificMsg = "服务器响应异常"
                default: specificMsg = error.localizedDescription
                }
                log("[Baidu] ❌ ①出错: \(specificMsg)")
                await MainActor.run { loadError = specificMsg; isLoading = false }
                return
            } catch {
                log("[Baidu] ❌ ①出错: \(error.localizedDescription)")
                await MainActor.run { loadError = "百度解析失败: \(error.localizedDescription)"; isLoading = false }
                return
            }
        }
        
        // 夸克网盘：先获取完整文件列表，多文件则展示选择列表
        if driveType == .quark {
            guard let token = CloudDriveManager.shared.tokens(for: .quark).first else {
                await MainActor.run {
                    loadError = "未配置夸克网盘 Cookie"
                    isLoading = false
                }
                return
            }
            log("[Quark] ①获取完整文件列表...")
            do {
                let files = try await CloudDriveManager.shared.quarkGetFileList(shareURL: cleanShareURL, cookie: token.value)
                log("[Quark] ✅ 成功，共\(files.count)个可播放文件")

                let selectedIndex = vboxParams["vbox_fid"].flatMap { fid in
                    files.firstIndex(where: { $0.fid == fid })
                } ?? 0
                await MainActor.run {
                    quarkFileList = files
                    quarkShareURL = cleanShareURL
                    quarkCookie = token.value
                    currentEpisodeIndex = selectedIndex
                    // 填充通用集数列表
                    episodeItems = files.enumerated().map { idx, f in
                        EpisodeItem(id: idx, name: f.fileName, url: "\(cleanShareURL)/\(f.fid)", sourceType: .quark, quarkFileIndex: idx)
                    }
                }
                
                guard !files.isEmpty else {
                    await MainActor.run {
                        loadError = "夸克文件列表为空"
                        isLoading = false
                    }
                    return
                }

                let resolveURL: String
                if selectedIndex < files.count {
                    resolveURL = appendVboxFragment(to: cleanShareURL, params: ["vbox_fid": files[selectedIndex].fid])
                } else {
                    resolveURL = cleanShareURL
                }
                let result = try await CloudDriveManager.shared.resolvePlayURL(from: resolveURL)
                await playResolvedDriveVideo(result)
                return
            } catch {
                log("[Quark] ❌ 获取文件列表失败: \(error.localizedDescription)")
                // 降级到单文件解析
                do {
                    let result = try await CloudDriveManager.shared.resolvePlayURL(from: urlString)
                    await playResolvedDriveVideo(result)
                } catch {
                    await MainActor.run { loadError = "夸克解析失败: \(error.localizedDescription)"; isLoading = false }
                }
                return
            }
        }
        
        // UC 网盘：先获取完整文件列表，多文件则展示选集列表
        if driveType == .uc {
            guard let token = tokens.first else {
                await MainActor.run {
                    loadError = "未配置UC网盘 Cookie"
                    isLoading = false
                }
                return
            }
            log("[UC] ①获取完整文件列表...")
            do {
                let files = try await CloudDriveManager.shared.ucGetFileList(shareURL: cleanShareURL, cookie: token.value)
                log("[UC] ✅ 成功，共\(files.count)个可播放文件")

                let selectedIndex = vboxParams["vbox_fid"].flatMap { fid in
                    files.firstIndex(where: { $0.fid == fid })
                } ?? 0
                await MainActor.run {
                    currentEpisodeIndex = selectedIndex
                    episodeItems = files.enumerated().map { idx, f in
                        EpisodeItem(id: idx, name: f.fileName, url: cleanShareURL,
                                    sourceType: .drive, ucFileFid: f.fid, ucShareFidToken: f.shareFidToken)
                    }
                }

                if vboxParams["vbox_fid"] != nil, selectedIndex < files.count {
                    let targetFile = files[selectedIndex]
                    let result = try await CloudDriveManager.shared.resolveUCPlayURLForFile(
                        shareURL: cleanShareURL,
                        cookie: token.value,
                        fileFid: targetFile.fid,
                        shareFidToken: targetFile.shareFidToken
                    )
                    await playResolvedDriveVideo(result)
                    return
                }
            } catch {
                log("[UC] ⚠️ 获取文件列表失败，降级到单文件: \(error.localizedDescription)")
            }
            
            // 播放第一个文件
            do {
                let result = try await CloudDriveManager.shared.resolvePlayURL(from: urlString)
                await playResolvedDriveVideo(result)
            } catch let error as DriveError {
                let msg: String
                switch error {
                case .tokenNotConfigured: msg = "未配置UC网盘 Token"
                case .noPlayURL(let reason): msg = reason
                case .invalidShareURL: msg = "无效的分享链接"
                case .saveFailed: msg = "转存失败"
                case .invalidResponse: msg = "服务器响应异常"
                case .notImplemented: msg = "暂不支持"
                }
                log("[PlayerV2] ❌ UC网盘 播放失败: \(msg)")
                await MainActor.run { loadError = msg; isLoading = false }
            } catch {
                log("[PlayerV2] ❌ UC网盘 解析异常: \(error.localizedDescription)")
                await MainActor.run { loadError = "UC解析异常: \(error.localizedDescription)"; isLoading = false }
            }
            return
        }
        
        do {
            let result = try await CloudDriveManager.shared.resolvePlayURL(from: urlString)
            await playResolvedDriveVideo(result)
        } catch let error as DriveError {
            let msg: String
            switch error {
            case .tokenNotConfigured: msg = "未配置\(driveType.displayName) Token"
            case .noPlayURL(let reason): msg = reason
            case .invalidShareURL: msg = "无效的分享链接"
            case .saveFailed: msg = "转存失败"
            case .invalidResponse: msg = "服务器响应异常"
            case .notImplemented: msg = "暂不支持"
            }
            log("[PlayerV2] ❌ \(driveType.displayName) 播放失败: \(msg)")
            await MainActor.run {
                loadError = msg
                isLoading = false
            }
        } catch {
            let msg = "解析异常: \(error.localizedDescription)"
            log("[PlayerV2] ❌ \(driveType.displayName) \(msg)")
            await MainActor.run {
                loadError = msg
                isLoading = false
            }
        }
    }
    
    private func playDriveVideo(url: String, headers: [String: String]) async {
        let playStartTime = Date()
        await MainActor.run {
            isLoading = true
            loadingMessage = "正在缓冲首帧..."
        }
        let finalURLString: String
        if url.contains("baidupcs.com") || url.contains("d.pcs.baidu.com") {
            if let localURL = DoubanImageProxyServer.shared.proxiedStreamURL(for: url, headers: headers, provider: "baidu") {
                finalURLString = localURL.absoluteString
                log("[PlayerV2] 百度PCS走本地代理: \(finalURLString)")
            } else {
                log("[PlayerV2] ❌ 百度本地代理创建失败，iBox-style 路线不回退直连")
                await MainActor.run {
                    loadError = "百度本地代理创建失败"
                    isLoading = false
                }
                return
            }
        } else if isQuarkM3U8PlaybackURL(url) {
            if let localURL = DoubanImageProxyServer.shared.proxiedQuarkM3U8URL(for: url, headers: headers) {
                finalURLString = localURL.absoluteString
                log("[PlayerV2] 夸克 m3u8 走本地代理: \(finalURLString)")
            } else {
                finalURLString = url
                log("[PlayerV2] ⚠️ 夸克 m3u8 本地代理创建失败，回退直连")
            }
        } else if isQuarkDirectPlaybackURL(url) {
            if let localURL = DoubanImageProxyServer.shared.proxiedStreamURL(for: url, headers: headers, provider: "quark") {
                finalURLString = localURL.absoluteString
                log("[PlayerV2] 夸克直链走本地代理: \(finalURLString)")
            } else {
                finalURLString = url
                log("[PlayerV2] ⚠️ 夸克本地代理创建失败，回退直连")
            }
        } else if isAliPlaybackURL(url) {
            if let localURL = DoubanImageProxyServer.shared.proxiedStreamURL(for: url, headers: headers, provider: "ali") {
                finalURLString = localURL.absoluteString
                log("[PlayerV2] 阿里云盘走本地代理: \(finalURLString)")
            } else {
                finalURLString = url
                log("[PlayerV2] ⚠️ 阿里云盘本地代理创建失败，回退直连")
            }
        } else if isUCPlaybackURL(url) {
            // UC CDN 直链不走本地代理，本地代理注入的 Android UA + Referer 会导致 CDN 拒绝 Range 请求
            // 播放器原生网络栈直接请求 CDN，兼容性更好
            finalURLString = url
            log("[PlayerV2] UC网盘直连 (不走代理)")
        } else if is115PlaybackURL(url) {
            if let localURL = DoubanImageProxyServer.shared.proxiedStreamURL(for: url, headers: headers, provider: "115") {
                finalURLString = localURL.absoluteString
                log("[PlayerV2] 115网盘走本地代理: \(finalURLString)")
            } else {
                finalURLString = url
                log("[PlayerV2] ⚠️ 115本地代理创建失败，回退直连")
            }
        } else {
            finalURLString = url
        }

        guard let urlObj = createURL(from: finalURLString) else {
            await MainActor.run {
                loadError = "播放地址格式错误"
                isLoading = false
            }
            return
        }
        let isBaiduLocalProxy = urlObj.host == "127.0.0.1" && urlObj.path.contains("baidu-stream")
        let isQuarkLocalProxy = urlObj.host == "127.0.0.1" && urlObj.path.contains("quark-stream")
        let isQuarkM3U8LocalProxy = urlObj.host == "127.0.0.1" && urlObj.path.contains("quark-m3u8")
        let resourceName = currentPlaybackResourceName(fallbackURL: urlObj, originalURL: url)
        let playlistKind = await probeM3U8IfNeeded(url: urlObj, headers: headers)
        let isUCLocalProxy = urlObj.host == "127.0.0.1" && urlObj.path.contains("uc-stream")
        let isCloudLocalProxy = urlObj.host == "127.0.0.1"
            && (urlObj.path.contains("ali-stream") || isUCLocalProxy || urlObj.path.contains("115-stream"))
        await MainActor.run {
            bindBaiduCacheProgress(for: isBaiduLocalProxy ? urlObj : nil)
        }

        // 夸克直链和m3u8：优先 IJKPlayer，其次 MPV/MDK/VLC。
        // AliPlayer 对本地代理 URL（127.0.0.1:18080/quark-stream）兼容性差，自动模式下不优先选择，
        // 仍保留在手动选择中用于普通网络视频。
        if (isQuarkLocalProxy || isQuarkM3U8LocalProxy) && enginePreference == .auto {
            let proxyType = isQuarkLocalProxy ? "quark-stream" : "quark-m3u8"
            await MainActor.run {
                playbackEngineMode = .compatibility
                compatibilityHint = isQuarkLocalProxy ? "夸克网盘直链" : "夸克网盘转码"
            }
            if isIJKBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "IJKPlayer", reason: "\(proxyType) 优先 IJKPlayer")
                log("[Quark] 自动模式下\(proxyType)优先使用 IJKPlayer")
            } else if isMPVBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "MPV-MoltenVK", reason: "\(proxyType)（IJKPlayer 不可用）")
                log("[Quark] IJKPlayer 不可用，\(proxyType)降级使用 MPV-MoltenVK")
            } else if isMDKBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "MDK", reason: "\(proxyType)（IJK/MPV 不可用）")
                log("[Quark] IJK/MPV 不可用，\(proxyType)降级使用 MDK")
            } else if isVLCBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "VLC", reason: "\(proxyType) IJK/MPV/MDK 均不可用")
                log("[Quark] IJK/MPV/MDK 均不可用，\(proxyType)降级使用 VLC")
            }
        } else if isUCLocalProxy && enginePreference == .auto {
            // UC网盘直链：优先 IJKPlayer，其次 MPV/MDK/VLC
            await MainActor.run {
                playbackEngineMode = .compatibility
                compatibilityHint = "UC网盘直链"
            }
            if isIJKBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "IJKPlayer", reason: "uc-stream 优先 IJKPlayer")
                log("[UC] 自动模式下 uc-stream 优先使用 IJKPlayer")
            } else if isMPVBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "MPV-MoltenVK", reason: "uc-stream（IJKPlayer 不可用）")
                log("[UC] IJKPlayer 不可用，uc-stream 降级使用 MPV-MoltenVK")
            } else if isMDKBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "MDK", reason: "uc-stream（IJK/MPV 不可用）")
                log("[UC] IJK/MPV 不可用，uc-stream 降级使用 MDK")
            } else if isVLCBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "VLC", reason: "uc-stream IJK/MPV/MDK 均不可用")
                log("[UC] IJK/MPV/MDK 均不可用，uc-stream 降级使用 VLC")
            }
        } else if isBaiduLocalProxy && enginePreference == .auto {
            // 百度原画：保持原有 MPV → MDK → VLC 降级链
            await MainActor.run {
                playbackEngineMode = .compatibility
                compatibilityHint = "百度原画本地代理"
            }
            if isMPVBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "MPV-MoltenVK", reason: "baidu-stream 本地代理原画流")
                log("[Baidu] 自动模式下百度本地代理优先使用 MPV-MoltenVK")
            } else if isMDKBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "MDK", reason: "baidu-stream 本地代理原画流（MPV 不可用）")
                log("[Baidu] MPV 不可用，降级使用 MDK")
            } else if isVLCBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "VLC", reason: "baidu-stream MPV/MDK 均不可用降级 VLC")
                log("[Baidu] MPV/MDK 均不可用，降级使用 VLC 兼容内核")
            }
        } else if enginePreference == .auto, isM3U8URL(urlObj) || playlistKind != nil {
            await MainActor.run {
                playbackEngineMode = .system
                compatibilityHint = nil
            }
            let kind = playlistKind ?? .unknown
            let reason = kind == .fmp4 ? "#EXT-X-MAP/.m4s" : (kind == .ts ? "TS切片" : "m3u8未探测到fMP4特征")
            logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: kind, engine: "AVPlayer", reason: reason)
        } else if enginePreference == .auto, shouldPreferIJK(for: urlObj) {
            await MainActor.run {
                playbackEngineMode = .compatibility
                compatibilityHint = "夸克网盘直链"
            }
            logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "IJKPlayer", reason: "真实文件名/URL命中夸克直链")
            log("[Quark] 自动模式下夸克直链使用 IJKPlayer")
        } else if enginePreference == .auto, shouldPreferMPV(for: urlObj) {
            await MainActor.run {
                playbackEngineMode = .compatibility
                compatibilityHint = compatibilityReason(for: resourceName) ?? "复杂封装"
            }
            logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "MPV-MoltenVK", reason: "真实文件名/URL命中复杂封装")
        } else if enginePreference == .auto {
            logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "AVPlayer", reason: "默认系统内核")
        }

        if shouldUseCompatibilityEngine {
            let engineName = preferredCompatibilityEngineName(for: urlObj)
            log("[PlayerV2] 使用 \(engineName) 兼容内核播放：\(compatibilityHint ?? "特殊格式")")
            await MainActor.run {
                player?.pause()
                player = nil
                compatibilityEngineName = engineName
                compatibilityURL = urlObj
                compatibilityHeaders = urlObj.host == "127.0.0.1" ? [:] : headers
                detectVideoQuality(from: urlObj.absoluteString)
                isPlaying = true
                isLoading = false
            }
            return
        } else if playbackEngineMode == .compatibility {
            if enginePreference == .mpv {
                log("[PlayerV2] 已选择 MPV，但当前构建未包含 Libmpv，暂用系统内核尝试")
            } else {
                log("[PlayerV2] 资源需要兼容内核，但当前构建未包含可用兼容内核或已强制系统内核，暂用系统内核尝试")
            }
        }
        
        let assetHeaders = urlObj.host == "127.0.0.1" ? [:] : headers
        let asset = AVURLAsset(url: urlObj, options: ["AVURLAssetHTTPHeaderFieldsKey": assetHeaders])
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = urlObj.host == "127.0.0.1" ? 0.5 : 10.0

        var localStatusObserver: AnyCancellable?
        localStatusObserver = playerItem.publisher(for: \.status)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    if isQuarkLocalProxy || isQuarkM3U8LocalProxy {
                        self.quarkFallbackTimeoutTask?.cancel()
                    }
                    let size = playerItem.presentationSize
                    let elapsed = Int(Date().timeIntervalSince(playStartTime) * 1000)
                    self.log("[PlayerV2] 网盘 PlayerItem 准备就绪，耗时=\(elapsed)ms，画面=\(Int(size.width))x\(Int(size.height))")
                    Task { @MainActor in
                        self.isLoading = false
                    }
                    // 对夸克/百度本地代理都执行首帧黑屏检测（红色封面/和谐文件会返回尺寸为0）
                    self.scheduleVideoTrackCheck(
                        for: playerItem,
                        startedAt: playStartTime,
                        isBaiduLocalProxy: isBaiduLocalProxy,
                        isQuarkLocalProxy: isQuarkLocalProxy || isQuarkM3U8LocalProxy,
                        fallbackURL: urlObj,
                        fallbackHeaders: assetHeaders
                    )
                case .failed:
                    let nsError = playerItem.error as? NSError
                    let errorDesc = playerItem.error?.localizedDescription ?? "未知错误"
                    self.log("[PlayerV2] ❌ 网盘 PlayerItem 失败: code=\(nsError?.code ?? -1) domain=\(nsError?.domain ?? "") desc=\(errorDesc)")
                    let underlyingDesc: String
                    if let underlying = nsError?.userInfo[NSUnderlyingErrorKey] as? Error {
                        underlyingDesc = underlying.localizedDescription
                        self.log("[PlayerV2] ❌ 网盘底层错误: \(underlyingDesc)")
                    } else {
                        underlyingDesc = ""
                    }

                    if isBaiduLocalProxy && self.isHTTPForbidden(errorDesc: errorDesc, underlyingDesc: underlyingDesc) {
                        self.log("[Baidu] ⚠️ 百度PCS流返回403，准备刷新直链后重试一次")
                        self.retryCurrentBaiduPlaybackAfterForbidden()
                        return
                    }
                    if isCloudLocalProxy && self.isHTTPForbidden(errorDesc: errorDesc, underlyingDesc: underlyingDesc) {
                        self.log("[PlayerV2] ⚠️ 网盘本地代理返回403，建议重新进入播放刷新直链")
                    }
                    if isQuarkLocalProxy && self.isHTTPForbidden(errorDesc: errorDesc, underlyingDesc: underlyingDesc) {
                        self.log("[Quark] ⚠️ 夸克本地代理返回403，后续需要重新刷新 download_url")
                        if self.switchToQuarkFallback(reason: "原画线路 403") { return }
                    }
                    // 夸克常见失败：NSURLErrorDomain code=-1 / "The network connection was lost"。
                    // 一般是上游签名失效或 UA/Cookie 不匹配被风控，提示用户重新进入触发刷新。
                    if isQuarkLocalProxy && self.isQuarkConnectionLost(error: nsError, errorDesc: errorDesc, underlyingDesc: underlyingDesc) {
                        self.log("[Quark] ⚠️ 夸克播放连接被中断 (network connection lost)，疑似签名/风控，建议返回重新播放刷新直链")
                        if self.switchToQuarkFallback(reason: "原画线路连接中断") { return }
                    }
                    if self.isUnsupportedMediaError(nsError, errorDesc: errorDesc, underlyingDesc: underlyingDesc) {
                        self.log("[PlayerV2] ⚠️ 当前资源疑似 AVPlayer 不支持，建议后续使用兼容内核")
                        if isQuarkLocalProxy {
                            if self.switchToQuarkFallback(reason: "系统内核不支持原画格式") { return }
                        } else {
                            Task { @MainActor in
                                self.loadError = "当前资源格式/编码不受系统播放器支持，建议使用兼容内核"
                                self.isLoading = false
                            }
                            return
                        }
                    }
                    Task { @MainActor in
                        self.failPlayback("网盘播放失败: \(errorDesc)")
                    }
                case .unknown:
                    self.log("[PlayerV2] 网盘 PlayerItem 状态未知")
                @unknown default:
                    break
                }
            }

        let localFailureObserver = NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
            .sink { [weak self] notification in
                if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                    guard let self else { return }
                    self.log("[PlayerV2] ❌ 网盘播放中断: \(error.localizedDescription)")
                    if isBaiduLocalProxy && self.isHTTPForbidden(errorDesc: error.localizedDescription, underlyingDesc: "") {
                        self.log("[Baidu] ⚠️ 百度PCS播放中断疑似403，清理旧直链后重试一次")
                        self.retryCurrentBaiduPlaybackAfterForbidden()
                    } else if isQuarkLocalProxy && self.isHTTPForbidden(errorDesc: error.localizedDescription, underlyingDesc: "") {
                        self.log("[Quark] ⚠️ 夸克播放中断疑似403，准备切换 m3u8 兜底")
                        self.switchToQuarkFallback(reason: "原画播放中断 403")
                    } else if isQuarkLocalProxy && self.isQuarkConnectionLost(error: error as NSError, errorDesc: error.localizedDescription, underlyingDesc: "") {
                        self.log("[Quark] ⚠️ 夸克播放中断疑似连接丢失，准备切换 m3u8 兜底")
                        self.switchToQuarkFallback(reason: "原画播放中断")
                    } else {
                        Task { @MainActor in
                            self.failPlayback("网盘播放失败: \(error.localizedDescription)")
                        }
                    }
                }
            }

        let p = AVPlayer(playerItem: playerItem)
        p.automaticallyWaitsToMinimizeStalling = !(isBaiduLocalProxy || isQuarkLocalProxy || isQuarkM3U8LocalProxy)
        if isQuarkLocalProxy {
            scheduleQuarkPrimaryFallbackTimeout(playerItem: playerItem, startedAt: playStartTime)
        } else if isQuarkM3U8LocalProxy {
            quarkFallbackTimeoutTask?.cancel()
        }
        
        await MainActor.run {
            if let observer = timeObserver { player?.removeTimeObserver(observer) }
            cleanupObservers()
            statusObserver = localStatusObserver
            failureObserver = localFailureObserver
            player?.pause()
            player = p
            isPlaying = true
            isLoading = true
            loadingMessage = "正在缓冲首帧..."
        }
        
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            if let d = p.currentItem?.duration {
                self.duration = d.seconds.isFinite ? d.seconds : 0
            }
            if isBaiduLocalProxy {
                self.prefetchNextBaiduFileNearEnd(current: self.currentTime, duration: self.duration)
                self.reportBaiduCacheProgressIfNeeded()
            }
        }
        
        p.play()
    }

    private func prefetchNextBaiduFileNearEnd(current: Double, duration: Double) {
        guard duration.isFinite, duration > 0, current.isFinite, current > 0 else { return }
        guard currentEpisodeIndex + 1 < baiduFileList.count else { return }
        guard !baiduNearEndPrefetchedIndexes.contains(currentEpisodeIndex) else { return }

        let remaining = duration - current
        let threshold = duration >= 20 * 60 ? 180.0 : max(30.0, duration * 0.15)
        guard remaining <= threshold else { return }

        baiduNearEndPrefetchedIndexes.insert(currentEpisodeIndex)
        log("[Baidu-Preload] 当前集接近结尾，剩余\(Int(max(0, remaining)))秒，开始预取下一集")
        prefetchNextBaiduFile(after: currentEpisodeIndex)
    }

    private func isHTTPForbidden(errorDesc: String, underlyingDesc: String) -> Bool {
        let text = "\(errorDesc) \(underlyingDesc)".lowercased()
        return text.contains("403") || text.contains("forbidden")
    }

    private func currentPlaybackResourceName(fallbackURL: URL, originalURL: String) -> String {
        if currentEpisodeIndex >= 0, currentEpisodeIndex < baiduFileList.count {
            return baiduFileList[currentEpisodeIndex].name
        }
        if let decoded = fallbackURL.lastPathComponent.removingPercentEncoding, !decoded.isEmpty {
            return decoded
        }
        if let original = URL(string: originalURL)?.lastPathComponent.removingPercentEncoding, !original.isEmpty {
            return original
        }
        return fallbackURL.absoluteString
    }

    private func shouldPreferMPVByResourceName(_ resourceName: String, url: URL) -> Bool {
        let text = "\(resourceName) \(url.absoluteString)".lowercased()
        if text.contains(".mp4") || text.contains(".m3u8") || text.contains(".m4v") || text.contains(".mov") {
            return false
        }
        return text.contains(".mkv")
            || text.contains("mkv")
            || text.contains("hevc")
            || text.contains("h265")
            || text.contains("x265")
            || text.contains("10bit")
            || text.contains("hdr")
            || text.contains("4k")
    }

    private func isM3U8URL(_ url: URL) -> Bool {
        url.absoluteString.lowercased().contains(".m3u8") || url.path.lowercased().contains("m3u8")
    }

    private func logEngineResolver(resourceName: String, url: URL, playlistKind: M3U8PlaylistKind?, engine: String, reason: String) {
        let kindText = playlistKind?.rawValue ?? "none"
        log("[EngineResolver] resource=\(resourceName), kind=\(kindText), engine=\(engine), reason=\(reason), url=\(url.absoluteString.prefix(80))")
    }

    private func probeM3U8IfNeeded(url: URL, headers: [String: String]) async -> M3U8PlaylistKind? {
        guard isM3U8URL(url) else { return nil }
        let key = url.absoluteString
        if let cached = m3u8ProbeCache[key], cached.expiresAt > Date() {
            log("[EngineResolver] m3u8探测缓存命中：\(cached.kind.rawValue)")
            return cached.kind
        }

        do {
            let kind = try await probeM3U8Playlist(url: url, headers: headers)
            m3u8ProbeCache[key] = M3U8ProbeCacheEntry(kind: kind, expiresAt: Date().addingTimeInterval(5 * 60))
            log("[EngineResolver] m3u8探测完成：\(kind.rawValue)")
            return kind
        } catch {
            log("[EngineResolver] m3u8探测失败，默认系统内核：\(error.localizedDescription)")
            m3u8ProbeCache[key] = M3U8ProbeCacheEntry(kind: .unknown, expiresAt: Date().addingTimeInterval(60))
            return .unknown
        }
    }

    private func probeM3U8Playlist(url: URL, headers: [String: String]) async throws -> M3U8PlaylistKind {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.setValue("bytes=0-131071", forHTTPHeaderField: "Range")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, _) = try await URLSession.shared.data(for: request)
        let sample = String(data: data.prefix(131_072), encoding: .utf8)?.lowercased() ?? ""
        if sample.contains("#ext-x-map") || sample.contains(".m4s") {
            return .fmp4
        }
        if sample.contains(".ts") || sample.contains("mpegts") {
            return .ts
        }
        return .unknown
    }

    /// 判断是否是夸克侧常见的"连接被中断"。AVPlayer 在签名失效或 TLS 被风控关闭时通常返回
    /// NSURLErrorDomain code=-1（NSURLErrorUnknown）或 -1005（NSURLErrorNetworkConnectionLost），
    /// 描述里会带 "network connection was lost" / "未知错误"。
    private func isQuarkConnectionLost(error: NSError?, errorDesc: String, underlyingDesc: String) -> Bool {
        let text = "\(errorDesc) \(underlyingDesc)".lowercased()
        if let error, error.domain == NSURLErrorDomain {
            if [-1, -1005, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost].contains(error.code) {
                return true
            }
        }
        return text.contains("network connection was lost")
            || text.contains("connection was lost")
            || text.contains("未知错误")
    }

    /// 夸克 download_url 实际跳转后域名波动较大（drive、dl、cdn、pcs、video 等多种 host）。
    /// 这里只要落在 *.quark.cn 且不属于 API/页面域，都认为是真实播放直链，需要走本地代理补 Header。
    private func isQuarkDirectPlaybackURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else { return false }
        guard host == "quark.cn" || host.hasSuffix(".quark.cn") else { return false }
        let excluded: Set<String> = [
            "pan.quark.cn",
            "drive-pc.quark.cn",
            "drive-h.quark.cn",
            "drive-m.quark.cn",
            "uop.quark.cn",
            "su.quark.cn",
            "www.quark.cn"
        ]
        return !excluded.contains(host)
    }

    private func isQuarkM3U8PlaybackURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else { return false }
        guard rawURL.lowercased().contains(".m3u8") else { return false }
        guard host == "quark.cn" || host.hasSuffix(".quark.cn") else { return false }
        let excluded: Set<String> = [
            "pan.quark.cn",
            "uop.quark.cn",
            "su.quark.cn",
            "www.quark.cn"
        ]
        return !excluded.contains(host)
    }

    private func isAliPlaybackURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else { return false }
        if host.contains("aliyundrive.com") || host.contains("alipan.com") || host.contains("aliyunpds.com") {
            return true
        }
        return host.hasSuffix(".aliyuncs.com") || host.contains("aliyun")
    }

    private func isUCPlaybackURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else { return false }
        if host == "uc.cn" || host.hasSuffix(".uc.cn") {
            let excluded: Set<String> = ["drive.uc.cn", "pc-api.uc.cn", "www.uc.cn"]
            return !excluded.contains(host)
        }
        return host.contains("ucdl") || host.contains("ucloud")
    }

    private func is115PlaybackURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else { return false }
        return host == "115.com"
            || host.hasSuffix(".115.com")
            || host.contains("115cdn.com")
            || host.contains("anxia.com")
    }

    private func isUnsupportedMediaError(_ error: NSError?, errorDesc: String, underlyingDesc: String) -> Bool {
        let text = "\(errorDesc) \(underlyingDesc) \(error?.domain ?? "")".lowercased()
        if error?.domain == AVFoundationErrorDomain && [-11828, -11833].contains(error?.code ?? 0) {
            return true
        }
        return text.contains("-11828") || text.contains("-12847") || text.contains("无法打开") || text.contains("not open")
    }

    private func scheduleVideoTrackCheck(
        for item: AVPlayerItem,
        startedAt: Date,
        isBaiduLocalProxy: Bool,
        isQuarkLocalProxy: Bool,
        fallbackURL: URL,
        fallbackHeaders: [String: String]
    ) {
        // 对百度和夸克本地代理都进行首帧检测
        guard isBaiduLocalProxy || isQuarkLocalProxy else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard self.player?.currentItem === item, self.loadError == nil else { return }
            let size = item.presentationSize
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            let seconds = self.player?.currentTime().seconds ?? 0
            self.log("[PlayerV2] 首帧检测：耗时=\(elapsed)ms，进度=\(String(format: "%.1f", seconds))s，画面=\(Int(size.width))x\(Int(size.height))")
            if seconds > 2, size.width <= 1 || size.height <= 1 {
                if isQuarkLocalProxy {
                    self.log("[PlayerV2] ⚠️ 夸克视频有播放进度但无画面，疑似文件已被和谐或转码失败")
                    self.loadError = "该视频在夸克网盘中已失效（可能被和谐或转码失败），请尝试其他资源"
                    self.isLoading = false
                } else {
                    self.log("[PlayerV2] ⚠️ 有播放进度但画面尺寸为0，疑似视频轨/编码不兼容")
                    self.switchAVPlayerVideoTrackFailureToMPV(url: fallbackURL, headers: fallbackHeaders)
                }
            }
        }
    }

    private func switchAVPlayerVideoTrackFailureToMPV(url: URL, headers: [String: String]) {
        guard enginePreference != .system, isMPVBuildAvailable else {
            log("[PlayerV2] 当前构建/策略无法自动切 MPV，保留系统内核")
            return
        }

        log("[PlayerV2] 自动切换到 MPV-MoltenVK：系统内核有进度但无视频画面")
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        cleanupObservers()
        player?.pause()
        player = nil
        compatibilityEngineName = "MPV-MoltenVK"
        compatibilityURL = url
        compatibilityHeaders = headers
        detectVideoQuality(from: url.absoluteString)
        playbackEngineMode = .compatibility
        compatibilityHint = "系统内核无视频画面"
        isPlaying = true
        isLoading = true
        loadingMessage = "正在切换 MPV-MoltenVK..."
    }

    private func retryCurrentBaiduPlaybackAfterForbidden() {
        guard baiduStreamRetryCount < 1 else {
            log("[Baidu] ❌ 百度PCS流403重试后仍失败，请更新PCS Cookie或重新扫码登录")
            Task { @MainActor in
                self.loadError = "百度PCS返回403：请更新PCS Cookie或重新扫码登录"
                self.isLoading = false
            }
            return
        }

        guard !baiduShareURL.isEmpty,
              currentEpisodeIndex >= 0,
              currentEpisodeIndex < baiduFileList.count
        else {
            log("[Baidu] ❌ 无法重试：缺少分享链接或当前集信息")
            return
        }

        baiduStreamRetryCount += 1
        let file = baiduFileList[currentEpisodeIndex]
        let index = currentEpisodeIndex
        CloudDriveManager.shared.invalidateBaiduPlaybackCache(
            shareURL: baiduShareURL,
            fsId: file.fsId,
            bduss: baiduBduss,
            pcsCookie: baiduPcsCookie,
            reason: "PCS403刷新直链重试"
        )
        log("[Baidu] ♻️ 已清理当前集旧 dlink/播放缓存，将优先用 path 刷新")
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self.startBaiduPlayback(
                shareURL: self.baiduShareURL,
                bduss: self.baiduBduss,
                pcsCookie: self.baiduPcsCookie,
                file: file,
                index: index,
                reason: "PCS403刷新直链重试"
            )
        }
    }
    
    func retry(video: VodItem) {
        currentTask?.cancel()
        stopPlaybackForFailure()
        loadError = nil
        isLoading = true
        isPlaying = false
        setupPlayer(video: video)
    }
    
    // MARK: - 播放地址解析
    private func resolvePlayUrl(video: VodItem) async {
        log("[PlayerV2] 开始解析播放地址: \(video.vodId)")
        
        // 检查是否是网盘资源（通过 vodRemarks 或 vodId 判断）
        if video.vodRemarks?.contains("网盘") == true || video.vodRemarks?.hasPrefix("☁️") == true {
            log("[PlayerV2] 检测到网盘资源，走网盘播放链路")
            await handleCloudVideo(video: video)
            return
        }
        
        // 如果 vodId 是 HTTP URL，可能是网盘详情页
        if video.vodId.hasPrefix("http://") || video.vodId.hasPrefix("https://") {
            // 检查是否包含网盘域名
            let panDomains = ["aliyundrive.com", "alipan.com", "pan.quark.cn", "pan.baidu.com", 
                              "115.com", "115cdn.com", "drive.uc.cn", "pan.uc.cn",
                              "yun.139.com", "caiyun.139.com", "123pan.com", "123cloud.cn"]
            if panDomains.contains(where: { video.vodId.contains($0) }) {
                log("[PlayerV2] 检测到网盘URL，走网盘播放链路")
                await handleCloudVideo(video: video)
                return
            }
        }

        // MissAV 专属链路：解析详情页得到真实 m3u8/mp4，并透传 Referer/Origin/User-Agent
        if (video.vodPlayFrom ?? "").contains("missav"),
           let source = await MissAVService.shared.resolvePlayableSource(for: video),
           let url = createURL(from: source.url) {
            log("[PlayerV2] MissAV 解析成功，带 header 原生播放")
            await MainActor.run { initPlayer(url: url, customHeaders: source.headers) }
            return
        }
        
        let spider = await SpiderManager.shared
        var playUrl: String? = video.vodPlayUrl
        var playFrom: String? = video.vodPlayFrom
        
        // 步骤1: 先用传入的播放地址尝试播放，同时后台获取详情
        log("[PlayerV2] 步骤1: 先尝试已有地址播放，后台异步获取详情...")
        
        // 先直接用已有地址尝试播放（如果有）
        if let existingUrl = video.vodPlayUrl, !existingUrl.isEmpty {
            // 解析普通资源多集数据，填充通用集数列表
            parseNormalEpisodes(playFrom: video.vodPlayFrom ?? "", playUrl: existingUrl, targetEpisodeName: video.vodName)
            
            let firstUrl: String
            if !episodeItems.isEmpty, currentEpisodeIndex >= 0, currentEpisodeIndex < episodeItems.count {
                firstUrl = episodeItems[currentEpisodeIndex].url
                log("[PlayerV2] 步骤1: 使用当前集[\(currentEpisodeIndex)]: \(firstUrl.prefix(80))...")
            } else {
                firstUrl = extractBestPlayableUrl(playFrom: video.vodPlayFrom ?? "", playUrl: existingUrl)
            }
            let firstUrlClean = firstUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if !firstUrlClean.isEmpty {
                log("[PlayerV2] 步骤1: 先尝试已有地址: \(firstUrlClean.prefix(80))...")
                await handlePlayUrl(firstUrlClean, spider: spider, video: video, customHeaders: video.customHeaders)
            }
        }
        
        // 后台异步获取详情，成功后更新播放地址
        Task { [weak self] in
            guard let self = self else { return }
            log("[PlayerV2] 步骤1: 后台获取详情...")
            if let detail = await spider.getDetail(ids: video.vodId, name: video.vodName),
               let newUrl = detail.vodPlayUrl, !newUrl.isEmpty {
                log("[PlayerV2] 步骤1: 后台详情成功，检查是否需要更新")
                // 后台详情返回后也更新集数列表
                parseNormalEpisodes(playFrom: detail.vodPlayFrom ?? "", playUrl: newUrl, targetEpisodeName: video.vodName)
                let newBest: String
                if !episodeItems.isEmpty, currentEpisodeIndex >= 0, currentEpisodeIndex < episodeItems.count {
                    newBest = episodeItems[currentEpisodeIndex].url
                } else {
                    newBest = extractBestPlayableUrl(playFrom: detail.vodPlayFrom ?? "", playUrl: newUrl)
                }
                if !newBest.isEmpty {
                    await MainActor.run {
                        if self.player == nil || self.loadError != nil {
                            self.loadError = nil
                            Task { await self.handlePlayUrl(newBest, spider: spider, video: video) }
                        } else {
                            log("[PlayerV2] 步骤1: 已有播放器在运行，跳过更新")
                        }
                    }
                }
            } else {
                log("[PlayerV2] 步骤1: 后台详情无结果")
            }
        }
        
        // 如果已有地址不能播放，后面继续等后台详情更新
        if let existingUrl = video.vodPlayUrl, !existingUrl.isEmpty {
            log("[PlayerV2] 步骤1: 等待后台详情更新...")
            return
        }
        
        // 步骤2: 检查 playUrl 的类型并处理
        guard let finalPlayUrl = playUrl, !finalPlayUrl.isEmpty else {
            log("[PlayerV2] 错误: 没有可用的播放地址")
            await MainActor.run {
                loadError = "服务器未返回播放地址（详情页无视频源），请尝试其他资源或站点"
                isLoading = false
            }
            return
        }
        
        log("[PlayerV2] 步骤2: 处理播放地址")
        
        // 从 $$$ 多源格式中提取最佳 URL
        let bestUrl = extractBestPlayableUrl(playFrom: playFrom ?? "", playUrl: finalPlayUrl)
        log("[PlayerV2] 最佳URL: \(bestUrl.prefix(80))...")
        
        await handlePlayUrl(bestUrl, spider: spider, video: video)
    }
    
    // MARK: - 安全创建URL（处理编码）
    private func createURL(from urlString: String) -> URL? {
        // 先尝试直接创建
        if let url = URL(string: urlString) {
            return url
        }
        
        // 如果失败，尝试进行URL编码
        if let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            if let url = URL(string: encoded) {
                log("[PlayerV2] URL编码成功: \(urlString.prefix(50))... -> \(encoded.prefix(50))...")
                return url
            }
        }
        
        // 尝试对路径部分编码
        if let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) {
            if let url = URL(string: encoded) {
                log("[PlayerV2] URL编码成功(2): \(urlString.prefix(50))...")
                return url
            }
        }
        
        log("[PlayerV2] ❌ URL创建失败: \(urlString)")
        return nil
    }
    
    /// 判断 episode.url 是否是不含 http 的占位符/相对路径，需要调用 playerContent 解析
    /// 保持 http/https 直链的原有播放行为，避免影响 CMS/API/网盘等其他资源
    private func shouldCallPlayerContentForEpisode(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // http/https 链接保持原有直接播放逻辑（可能是直链或播放页）
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return false
        }
        // 非 http 链接（如剧迷的 vid-ep_id、相对路径等），尝试 playerContent
        return true
    }
    
    /// 🔧 修复: 判断URL是否为AVPlayer/CoreMedia支持的标准播放协议
    /// 自定义协议（如 xk://）返回 false，避免传给 AVPlayer 报 -1002 错误并卡界面
    private func isStandardPlayScheme(_ urlString: String) -> Bool {
        let lowerUrl = urlString.lowercased()
        return lowerUrl.hasPrefix("http://")
            || lowerUrl.hasPrefix("https://")
            || lowerUrl.hasPrefix("file://")
            || lowerUrl.hasPrefix("rtmp://")
            || lowerUrl.hasPrefix("rtsp://")
            || lowerUrl.hasPrefix("udp://")
            || lowerUrl.hasPrefix("rtp://")
    }
    
    /// 统一处理 playerContent 返回结果并播放（含 parse:1 二次解析和 header 透传）
    private func playFromPlayerContentResult(_ pr: PlayerContentResult, episodeName: String, spider: SpiderManager, baseHeaders: [String: String]? = nil) async {
        let pu = pr.playUrl ?? pr.url
        var mergedHeaders = baseHeaders ?? [:]
        if let spiderHeaders = pr.header {
            for (key, value) in spiderHeaders where !key.isEmpty {
                mergedHeaders[key] = value
            }
        }
        if pr.parse == 1, let rawUrl = pu, !rawUrl.isEmpty {
            log("[PlayerV2] playerContent 返回 parse=1，重新走解析器链路: \(rawUrl.prefix(60))")
            if let reparsedUrl = await spider.parsePlayUrl(from: rawUrl) {
                log("[PlayerV2] ✅ playerContent 二次解析成功: \(reparsedUrl.prefix(60))")
                if let url = createURL(from: reparsedUrl) {
                    await MainActor.run { initPlayer(url: url, customHeaders: mergedHeaders) }
                    return
                }
            }
            log("[PlayerV2] ⚠️ playerContent 二次解析失败")
            // 🔧 修复: 二次解析失败后，若原始URL是自定义协议（如 xk://），
            // 不能当直链传给 AVPlayer（会报 -1002 不支持的URL 并卡界面10秒）
            if let rawUrl = pu, !isStandardPlayScheme(rawUrl) {
                log("[PlayerV2] ❌ playerContent 返回自定义协议且解析失败，不传给播放器: \(rawUrl.prefix(60))")
                await MainActor.run {
                    self.loadError = "播放地址解析失败，请尝试更换源或清晰度"
                    self.isLoading = false
                }
                return
            }
        }
        // 🔧 修复: 直链分支也校验协议，自定义协议不传给 AVPlayer
        if let pu = pu, !pu.isEmpty, isStandardPlayScheme(pu), let url = createURL(from: pu) {
            log("[PlayerV2] ✅ playerContent 直链成功: \(pu.prefix(60))")
            await MainActor.run {
                self.currentTime = 0
                self.initPlayer(url: url, customHeaders: mergedHeaders)
                if let video = self.currentVideo {
                    self.restorePlaybackProgress(for: video)
                    self.loadDanmaku(for: video, fileName: episodeName)
                }
            }
        } else if let pu = pu, !pu.isEmpty {
            log("[PlayerV2] ❌ playerContent 返回非标准协议，不传给播放器: \(pu.prefix(60))")
            await MainActor.run {
                self.loadError = "播放地址格式不支持，请尝试更换源"
                self.isLoading = false
            }
        }
    }
    
    // MARK: - 处理单个播放地址
    private func handlePlayUrl(_ urlString: String, spider: SpiderManager, video: VodItem, customHeaders: [String: String]? = nil) async {
        log("[PlayerV2] 处理地址: \(urlString.prefix(80))...")

        // 🔧 修复: 自定义协议（如 xk://）优先走 playerContent 解析
        // 避免 xk:// 地址被解析器/WKWebView 处理导致失败或卡死
        let lowerUrl = urlString.lowercased()
        let isStandardScheme = lowerUrl.hasPrefix("http://")
                          || lowerUrl.hasPrefix("https://")
                          || lowerUrl.hasPrefix("file://")
                          || lowerUrl.hasPrefix("rtmp://")
                          || lowerUrl.hasPrefix("rtsp://")
        if !isStandardScheme && !urlString.isEmpty {
            log("[PlayerV2] 检测到自定义协议，优先调用 playerContent: \(urlString.prefix(60))")
            if let pr = await spider.getPlayerContent(vodId: video.vodId, flag: "play", url: urlString) {
                await self.playFromPlayerContentResult(pr, episodeName: video.vodName, spider: spider, baseHeaders: customHeaders)
                return
            }
            log("[PlayerV2] ⚠️ 自定义协议 playerContent 无结果，继续尝试解析器")
        }

        // 检测官方平台URL（需要解析器转直链）
        let officialDomains = ["iqiyi.com", "v.qq.com", "youku.com", "mgtv.com", "v.youku.com", "www.mgtv.com", "www.iqiyi.com"]
        let isOfficialPlatform = officialDomains.contains { urlString.contains($0) }

        // 检查是否是直链（官方平台URL永不视为直链）
        let isDirectLink: Bool = {
            if isOfficialPlatform { return false }
            guard urlString.hasPrefix("http") else { return false }
            let cleanPath: String
            if let url = URL(string: urlString) {
                cleanPath = url.path
            } else if let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                      let url = URL(string: encoded) {
                cleanPath = url.path
            } else {
                cleanPath = urlString
            }
            let ext = (cleanPath as NSString).pathExtension.lowercased()
            let videoExts = ["m3u8", "mp4", "flv", "m4v", "ts", "webm", "mkv", "avi", "mov"]
            if videoExts.contains(ext) { return true }
            if cleanPath.contains("/hls/") || cleanPath.contains("/video/") { return true }
            // 兜底：只有福利平台（vodRemarks 含 [福利]）且是 http(s) 直链但无标准后缀时，才尝试直接播放
            if (video.vodRemarks?.contains("[福利]") == true) &&
               (urlString.hasPrefix("http://") || urlString.hasPrefix("https://")) {
                return true
            }
            return false
        }()

        if isDirectLink {
            log("[PlayerV2] 直链模式: 直接使用 URL=\(urlString.prefix(100))")
            if let url = createURL(from: urlString) {
                log("[PlayerV2] ✅ URL创建成功, 协议=\(url.scheme ?? "nil"), 主机=\(url.host ?? "nil")")
                await MainActor.run { initPlayer(url: url, customHeaders: customHeaders) }
                return
            }
            log("[PlayerV2] ❌ 直链URL创建失败, raw=\(urlString.prefix(120))")
        }

        // 需要解析的链接：先试解析器，再试 playerContent
        if isOfficialPlatform {
            log("[PlayerV2] 解析模式: 检测到官方平台URL，强制走解析器")
        } else {
            log("[PlayerV2] 解析模式: 非直链，尝试解析器")
        }

        // 1. 优先用解析器（subManager.parses + customParsers）
        let allParsers = await MainActor.run { SpiderManager.shared.subManager.parses + SpiderManager.shared.customParsers }
        if !allParsers.isEmpty {
            log("[PlayerV2] 尝试 \(allParsers.count) 个解析器...")
            for parser in allParsers {
                let parseURL = parser.url + (urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString)
                guard let reqURL = URL(string: parseURL) else { continue }
                do {
                    var req = URLRequest(url: reqURL)
                    req.timeoutInterval = 8
                    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                    let (data, _) = try await URLSession.shared.data(for: req)
                    if let resp = String(data: data, encoding: .utf8) {
                        let patterns = ["https?://[^\\s\"<>]+\\.m3u8[^\\s\"<>]*", "https?://[^\\s\"<>]+\\.mp4[^\\s\"<>]*"]
                        for pattern in patterns {
                            if let regex = try? NSRegularExpression(pattern: pattern),
                               let match = regex.firstMatch(in: resp, range: NSRange(resp.startIndex..., in: resp)),
                               let r = Range(match.range, in: resp) {
                                let result = String(resp[r])
                                if result.hasPrefix("http"), let url = createURL(from: result) {
                                    log("[PlayerV2] ✅ 解析器[\(parser.name)]成功: \(result.prefix(60))")
                                    await MainActor.run { initPlayer(url: url, customHeaders: customHeaders) }
                                    return
                                }
                            }
                        }
                    }
                } catch { continue }
            }
        }

        // 2. 调用 SpiderManager.parsePlayUrl 兜底（含16个公共解析器+WKWebView回退）
        log("[PlayerV2] 内置解析器失败，尝试 SpiderManager.parsePlayUrl 兜底...")
        if let parsedUrl = await spider.parsePlayUrl(from: urlString) {
            log("[PlayerV2] ✅ SpiderManager 解析成功: \(parsedUrl.prefix(60))")
            if let url = createURL(from: parsedUrl) {
                await MainActor.run { initPlayer(url: url, customHeaders: customHeaders) }
                return
            }
        }

        // 3. 尝试 QuickJS playerContent
        if let pr = await spider.getPlayerContent(vodId: video.vodId, flag: "play", url: urlString) {
            let pu = pr.playUrl ?? pr.url
            // 合并 JS 蜘蛛返回的 header（如剧迷需要 Referer/UA），不覆盖已有自定义头
            var mergedHeaders = customHeaders ?? [:]
            if let spiderHeaders = pr.header {
                for (key, value) in spiderHeaders where !key.isEmpty {
                    mergedHeaders[key] = value
                }
                log("[PlayerV2] 合并 playerContent header: \(mergedHeaders.keys.sorted().joined(separator: ","))")
            }
            // 关键修复：如果 playerContent 返回 parse:1，说明 URL 需要走解析器链路
            // 不能直接传给播放器（如 v.qq.com 网页地址），需要重新走 SpiderManager.parsePlayUrl
            if pr.parse == 1, let rawUrl = pu, !rawUrl.isEmpty {
                log("[PlayerV2] playerContent 返回 parse=1，重新走解析器链路: \(rawUrl.prefix(60))")
                if let reparsedUrl = await spider.parsePlayUrl(from: rawUrl) {
                    log("[PlayerV2] ✅ playerContent 二次解析成功: \(reparsedUrl.prefix(60))")
                    if let url = createURL(from: reparsedUrl) {
                        await MainActor.run { initPlayer(url: url, customHeaders: mergedHeaders) }
                        return
                    }
                }
                log("[PlayerV2] ⚠️ playerContent 二次解析失败，尝试直接使用URL")
                // 🔧 修复: 二次解析失败后，若原始URL是自定义协议（如 xk://），不传给 AVPlayer
                if let rawUrl = pu, !isStandardPlayScheme(rawUrl) {
                    log("[PlayerV2] ❌ 备用路径: 自定义协议且解析失败，跳过: \(rawUrl.prefix(60))")
                    // 跳过此分支，继续尝试后续 nativeDetail 等备选方案
                } else if let pu = pu, !pu.isEmpty, isStandardPlayScheme(pu), let url = createURL(from: pu) {
                    log("[PlayerV2] ✅ playerContent 成功: \(pu.prefix(60))")
                    await MainActor.run { initPlayer(url: url, customHeaders: mergedHeaders) }
                    return
                }
            } else if let pu = pu, !pu.isEmpty, isStandardPlayScheme(pu), let url = createURL(from: pu) {
                log("[PlayerV2] ✅ playerContent 成功: \(pu.prefix(60))")
                await MainActor.run { initPlayer(url: url, customHeaders: mergedHeaders) }
                return
            } else if let pu = pu, !pu.isEmpty {
                log("[PlayerV2] ❌ 备用路径: playerContent 返回非标准协议，跳过: \(pu.prefix(60))")
            }
        }

        // 尝试 nativeDetail 作为备选
        log("[PlayerV2] 备选: 尝试 nativeDetail...")
        let nd = await spider.nativeDetail(ids: video.vodId, name: video.vodName)
        if let nd = nd, let pu = nd.vodPlayUrl, !pu.isEmpty {
            log("[PlayerV2] nativeDetail 成功")
            let urls = parsePlayUrls(playFrom: nd.vodPlayFrom ?? "", playUrl: pu)
            log("[PlayerV2] 解析出 \(urls.count) 个播放地址")
            for (index, videoUrl) in urls.enumerated() {
                log("[PlayerV2] 地址\(index): \(videoUrl.prefix(60))...")
            }
            let du = urls.first(where: { $0.contains(".m3u8") || $0.contains(".mp4") }) ?? urls.first ?? pu
            if !du.isEmpty {
                if let url = createURL(from: du) {
                    await MainActor.run { initPlayer(url: url, customHeaders: customHeaders) }
                    return
                }
                log("[PlayerV2] ❌ nativeDetail URL创建失败")
            }
        }
        
        // 检查是否是网盘链接
        log("[PlayerV2] 步骤5: 检查网盘链接...")
        let playUrlToCheck = video.vodPlayUrl ?? nd?.vodPlayUrl ?? urlString
        log("[PlayerV2] 待检测URL: \(playUrlToCheck.prefix(80))")
        if !playUrlToCheck.isEmpty, let driveType = CloudDriveManager.detectDrive(from: playUrlToCheck) {
            log("[PlayerV2] ✅ 检测到 \(driveType.displayName) 网盘链接")
            // 检查是否配置了Token
            let tokens = CloudDriveManager.shared.tokens(for: driveType)
            log("[PlayerV2] \(driveType.displayName) Token数量: \(tokens.count)")
            if tokens.isEmpty {
                let msg = "未配置\(driveType.displayName) Token，请到 设置→网盘播放 中添加"
                log("[PlayerV2] ❌ \(msg)")
                await MainActor.run { loadError = msg; isLoading = false }
                return
            }
            do {
                log("[PlayerV2] ⏳ 正在调用 \(driveType.displayName) API 解析...")
                let result = try await CloudDriveManager.shared.resolvePlayURL(from: playUrlToCheck)
                log("[PlayerV2] ✅ 网盘解析成功! 播放地址: \(result.url.prefix(80))...")
                log("[PlayerV2] 📋 请求头: \(result.headers.keys.joined(separator: ", "))")
                if URL(string: result.url) != nil {
                    await playResolvedDriveVideo(result)
                    return
                } else {
                    let msg = "\(driveType.displayName) 返回的播放地址无效: \(result.url.prefix(50))"
                    log("[PlayerV2] ❌ \(msg)")
                    await MainActor.run { loadError = msg; isLoading = false }
                    return
                }
            } catch let error as DriveError {
                let msg: String
                switch error {
                case .tokenNotConfigured(let name): msg = "未配置\(name) Token，请到 设置→网盘播放 中添加"
                case .noPlayURL(let reason): msg = "\(driveType.displayName) \(reason)"
                case .invalidShareURL: msg = "无效的\(driveType.displayName)分享链接"
                case .saveFailed: msg = "\(driveType.displayName) 转存失败"
                case .invalidResponse: msg = "\(driveType.displayName) 服务器响应异常"
                case .notImplemented: msg = "\(driveType.displayName) 暂不支持"
                }
                log("[PlayerV2] ❌ DriveError: \(msg)")
                await MainActor.run { loadError = msg; isLoading = false }
                return
            } catch {
                let msg = "\(driveType.displayName) 解析异常: \(error.localizedDescription)"
                log("[PlayerV2] ❌ \(msg)")
                await MainActor.run { loadError = msg; isLoading = false }
                return
            }
        } else {
            log("[PlayerV2] ⚠️ 未识别为网盘链接")
        }
        
        // 所有方式失败
        log("[PlayerV2] ❌ 所有方式都失败")
        await MainActor.run {
            cleanupObservers(); player?.pause()
            if let observer = timeObserver { player?.removeTimeObserver(observer); timeObserver = nil }
            player = nil
            loadError = "无法获取可用播放地址，请检查网络或更换其他资源"
            isLoading = false
        }
    }
    
    // MARK: - 从 $$$ 多源格式中提取最佳播放 URL
    private func extractBestPlayableUrl(playFrom: String, playUrl: String) -> String {
        // 不含 $$$ → 单源，按 # 和 $ 提取第一集
        if !playUrl.contains("$$$") {
            return extractFirstEpisodeUrl(playUrl)
        }
        
        // 含 $$$ → 多源，按 $$$ 分割
        let froms = playFrom.components(separatedBy: "$$$")
        let urlBlocks = playUrl.components(separatedBy: "$$$")
        
        // 为每个源提取第一集URL，按优先级排序：有 http 的 > 有 parse 可解析的 > 其他
        var candidates: [(source: String, url: String, hasHttp: Bool)] = []
        for i in 0..<min(froms.count, urlBlocks.count) {
            let src = froms[i]
            let firstUrl = extractFirstEpisodeUrl(urlBlocks[i])
            let hasHttp = firstUrl.hasPrefix("http")
            if !firstUrl.isEmpty {
                candidates.append((src, firstUrl, hasHttp))
                log("[PlayerV2] 源[\(i)] \(src): \(firstUrl.prefix(60))... http=\(hasHttp)")
            }
        }
        
        // 优先选有 http URL 的源
        if let best = candidates.first(where: { $0.hasHttp }) {
            log("[PlayerV2] 选择源: \(best.source) (http直链)")
            return best.url
        }
        
        // 没有 http 源，返回第一个
        if let first = candidates.first {
            log("[PlayerV2] 使用首个源: \(first.source)")
            return first.url
        }
        
        return playUrl
    }
    
    /// 从单个源块（如 "第1集$url1#第2集$url2"）提取第一集URL
    private func extractFirstEpisodeUrl(_ block: String) -> String {
        if block.contains("#") {
            // 取第一集
            let firstEp = block.components(separatedBy: "#").first ?? block
            if let range = firstEp.range(of: "$") {
                return String(firstEp[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            return firstEp.trimmingCharacters(in: .whitespaces)
        } else if block.contains("$") {
            if let range = block.range(of: "$") {
                return String(block[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return block.trimmingCharacters(in: .whitespaces)
    }
    
    // 保留旧方法供其他地方使用
    private func parsePlayUrls(playFrom: String, playUrl: String) -> [String] {
        var urls: [String] = []
        if playUrl.contains("#") {
            for part in playUrl.components(separatedBy: "#") {
                if let range = part.range(of: "$") {
                    let u = String(part[range.upperBound...])
                    if !u.isEmpty { urls.append(u) }
                } else if !part.isEmpty { urls.append(part) }
            }
        } else {
            urls = [playUrl]
        }
        return urls.filter { !$0.isEmpty }
    }
    
    /// 解析普通资源多集数据，填充通用集数列表 episodeItems
    private func parseNormalEpisodes(playFrom: String, playUrl: String, targetEpisodeName: String? = nil) {
        // 如果已经有百度/夸克集数，不覆盖
        guard episodeItems.isEmpty else { return }
        
        // 确定使用哪个源的URL块
        let urlBlock: String
        if playUrl.contains("$$$") {
            // 多源：选包含最多集数（#最多）的源
            // 修复：支持占位符URL（如剧迷的 vid-ep_id|lineIdx），不只认http/m3u8/mp4
            let urlBlocks = playUrl.components(separatedBy: "$$$")
            var bestBlock = urlBlocks.first ?? ""
            var bestEpisodeCount = 0
            for block in urlBlocks {
                let count = block.components(separatedBy: "#").filter { part in
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return false }
                    // 检查是否包含有效的URL或占位符（支持 http直链、m3u8、mp4、以及剧迷等源的占位符格式）
                    let urlPart = extractFirstEpisodeUrl(trimmed)
                    return !urlPart.isEmpty
                }.count
                if count > bestEpisodeCount {
                    bestEpisodeCount = count
                    bestBlock = block
                }
            }
            if bestEpisodeCount == 0 {
                // 没有有效集数，取第一个非空块
                bestBlock = urlBlocks.first { !$0.isEmpty } ?? ""
            }
            urlBlock = bestBlock
        } else {
            urlBlock = playUrl
        }
        
        // 解析集数
        var items: [EpisodeItem] = []
        if urlBlock.contains("#") {
            let parts = urlBlock.components(separatedBy: "#")
            for (idx, part) in parts.enumerated() {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let name: String
                let url: String
                if let range = trimmed.range(of: "$") {
                    name = String(trimmed[trimmed.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    url = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else {
                    name = "第\(idx + 1)集"
                    url = trimmed
                }
                guard !url.isEmpty else { continue }
                items.append(EpisodeItem(
                    id: idx,
                    name: name.isEmpty ? "第\(idx + 1)集" : name,
                    url: url,
                    sourceType: .normal
                ))
            }
        }
        
        // 修复：单集资源（电影）也要显示，原逻辑 items.count>1 导致单集不显示
        if items.count >= 1 {
            log("[PlayerV2] 解析到 \(items.count) 集普通资源: \(items.map { $0.name }.joined(separator: ", "))")
            episodeItems = items
            // 根据 vodName 自动定位到当前集
            if let target = targetEpisodeName {
                for (idx, item) in items.enumerated() {
                    if target.contains(item.name) {
                        currentEpisodeIndex = idx
                        log("[PlayerV2] 自动定位到集数: \(item.name) (index=\(idx))")
                        break
                    }
                }
            }
        }
    }
    
    /// 通用切集方法（支持所有资源类型）
    func switchToEpisode(index: Int) {
        guard index >= 0, index < episodeItems.count else { return }
        let episode = episodeItems[index]
        currentEpisodeIndex = index
        log("[PlayerV2] 切集: \(episode.name) (index=\(index), type=\(episode.sourceType))")
        
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self = self else { return }
            switch episode.sourceType {
            case .normal:
                // 普通资源：先判断 URL 是否已经是可直接播放的链接
                if !self.shouldCallPlayerContentForEpisode(episode.url), let url = URL(string: episode.url) {
                    await MainActor.run {
                        // 重置当前时间，避免上一集进度影响
                        self.currentTime = 0
                        self.initPlayer(url: url)
                        // 切集后恢复该集进度
                        if let video = self.currentVideo {
                            self.restorePlaybackProgress(for: video)
                        }
                        // 切集后重新加载弹幕（按集名匹配）
                        if let video = self.currentVideo {
                            self.loadDanmaku(for: video, fileName: episode.name)
                        }
                    }
                } else {
                    // 非 http 占位符（如剧迷的 vid-ep_id），调用 playerContent 解析真实地址
                    log("[PlayerV2] 切集URL非直链，尝试 playerContent: \(episode.url.prefix(60))")
                    guard let video = self.currentVideo else { return }
                    if let pr = await SpiderManager.shared.getPlayerContent(vodId: video.vodId, flag: "play", url: episode.url) {
                        await self.playFromPlayerContentResult(pr, episodeName: episode.name, spider: SpiderManager.shared)
                    } else {
                        log("[PlayerV2] ⚠️ 切集 playerContent 无结果")
                    }
                }
            case .baidu:
                // 百度网盘：走原有切换逻辑
                if let baiduIdx = episode.baiduFileIndex {
                    await MainActor.run { self.switchBaiduFile(index: baiduIdx) }
                }
            case .quark:
                // 夸克网盘：解析并播放
                await self.playQuarkEpisode(episode: episode)
            case .drive:
                // UC 网盘：使用专用切集逻辑
                if let ucFid = episode.ucFileFid, let ucToken = episode.ucShareFidToken {
                    await self.playUCEpisode(episode: episode)
                } else {
                    // 其他网盘
                    await self.playDriveVideo(url: episode.url, headers: episode.headers)
                }
            }
        }
    }
    
    /// 播放夸克网盘指定集数
    private func playQuarkEpisode(episode: EpisodeItem) async {
        guard let quarkIdx = episode.quarkFileIndex,
              quarkIdx < quarkFileList.count else { return }
        let file = quarkFileList[quarkIdx]
        let shareURL = quarkShareURL
        guard !shareURL.isEmpty else { return }
        
        log("[Quark] 切集播放: \(file.fileName)")
        await MainActor.run { isLoading = true }
        do {
            let targetURL = appendVboxFragment(to: shareURL, params: ["vbox_fid": file.fid])
            let result = try await CloudDriveManager.shared.resolvePlayURL(from: targetURL)
            await MainActor.run {
                currentEpisodeIndex = episode.id
            }
            await playResolvedDriveVideo(result)
        } catch {
            log("[Quark] 切集失败: \(error.localizedDescription)")
            await MainActor.run {
                loadError = "夸克切集失败: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
    
    /// 播放 UC 网盘指定集数
    private func playUCEpisode(episode: EpisodeItem) async {
        guard let ucFid = episode.ucFileFid,
              let ucShareToken = episode.ucShareFidToken else { return }
        
        log("[UC] 切集播放: \(episode.name) (fid=\(ucFid))")
        await MainActor.run { isLoading = true }
        
        guard let token = CloudDriveManager.shared.tokens(for: .uc).first else {
            await MainActor.run { loadError = "未配置UC网盘 Token"; isLoading = false }
            return
        }
        
        do {
            let result = try await CloudDriveManager.shared.resolveUCPlayURLForFile(
                shareURL: episode.url,
                cookie: token.value,
                fileFid: ucFid,
                shareFidToken: ucShareToken
            )
            await MainActor.run {
                currentEpisodeIndex = episode.id
            }
            await playResolvedDriveVideo(result)
        } catch {
            log("[UC] 切集失败: \(error.localizedDescription)")
            await MainActor.run {
                loadError = "UC切集失败: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
    
    private func initPlayer(url: URL, noReferer: Bool = false, customHeaders: [String: String]? = nil) {
        if !noReferer { hasRetriedNoReferer = false }
        log("[PlayerV2] 初始化播放器: \(url.absoluteString.prefix(100))...")
        detectVideoQuality(from: url.absoluteString)

        // 场景恢复保护：延迟 AVPlayer 创建，避免主线程阻塞触发 watchdog
        if isRestoringFromBackground {
            log("[PlayerV2] 场景恢复中，延迟播放器创建(200ms)")
            sceneRestorationTask?.cancel()
            sceneRestorationTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                await MainActor.run { self?.initPlayer(url: url, noReferer: noReferer, customHeaders: customHeaders) }
            }
            return
        }

        if shouldRouteDirectURLToMPV(url) {
            log("[PlayerV2] 直链资源分流到 MPV-MoltenVK：\(url.pathExtension.lowercased())")
            player?.pause()
            player = nil
            compatibilityEngineName = "MPV-MoltenVK"
            compatibilityURL = url
            compatibilityHeaders = [:]
            playbackEngineMode = .compatibility
            compatibilityHint = "MKV / 复杂封装"
            isPlaying = true
            isLoading = true
            loadingMessage = "正在启动 MPV-MoltenVK..."
            return
        }
        
        // 清理旧的观察者（防止 retry 叠加）
        if let oldObserver = timeObserver {
            player?.removeTimeObserver(oldObserver)
            timeObserver = nil
        }
        cleanupObservers()
        player?.pause()
        player = nil
        
        // 配置Asset选项（针对m3u8切片优化）
        var assetOptions: [String: Any] = [:]
        
        // 设置HTTP头（m3u8播放通常需要正确的User-Agent和Referer）
        var headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
            "Accept": "*/*",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
        if !noReferer {
            var referer = url.absoluteString
            if let host = url.host {
                referer = "https://\(host)/"
            }
            headers["Referer"] = referer
            log("[PlayerV2] HTTP头配置 - Referer: \(referer)")
        } else {
            log("[PlayerV2] HTTP头配置 - 不带Referer（重试模式）")
        }
        if let customHeaders {
            for (key, value) in customHeaders { headers[key] = value }
            log("[PlayerV2] 已合并自定义HTTP头，Referer=\(headers["Referer"] ?? "nil")")
        }
        assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
        
        // 创建Asset和PlayerItem
        let asset = AVURLAsset(url: url, options: assetOptions)
        let playerItem = AVPlayerItem(asset: asset)
        
        // 配置PlayerItem（针对HLS/m3u8优化）
        playerItem.preferredForwardBufferDuration = 10.0 // 预缓冲10秒

        // 创建播放器
        let p = AVPlayer(playerItem: playerItem)
        p.automaticallyWaitsToMinimizeStalling = true
        
        // 监听PlayerItem状态
        var localStatusObserver: AnyCancellable?
        localStatusObserver = playerItem.publisher(for: \.status)
            .sink { [weak self] status in
                guard let self = self else { return }
                switch status {
                case .readyToPlay:
                    self.log("[PlayerV2] PlayerItem 准备就绪")
                    self.isLoading = false
                    self.loadError = nil
                    if self.currentTime > 10 {
                        let resume = self.currentTime
                        self.log("[Progress] 自动跳转到上次进度：\(self.formatDuration(resume))")
                        p.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                case .failed:
                    let errorDesc = playerItem.error?.localizedDescription ?? "未知错误"
                    let errorCode = (playerItem.error as? NSError)?.code ?? -1
                    let errorDomain = (playerItem.error as? NSError)?.domain ?? ""
                    self.log("[PlayerV2] ❌ PlayerItem 失败: code=\(errorCode) domain=\(errorDomain) desc=\(errorDesc)")
                    if let underlying = (playerItem.error as? NSError)?.userInfo[NSUnderlyingErrorKey] as? Error {
                        self.log("[PlayerV2] ❌ 底层错误: \(underlying.localizedDescription)")
                    }
                    // -11850/-12939 可能是Referer校验失败，尝试不带Referer重试
                    if (errorCode == -11850 || errorCode == -12939) && !self.hasRetriedNoReferer {
                        self.hasRetriedNoReferer = true
                        self.log("[PlayerV2] 🔄 疑似Referer校验失败，尝试不带Referer重试...")
                        self.statusObserver = nil
                        self.failureObserver = nil
                        self.initPlayer(url: url, noReferer: true)
                        return
                    }
                    let errMsg = errorDesc.contains("不能") || errorDesc.contains("format") || errorDesc.contains("Invalid") 
                        ? "播放地址格式不支持" : "播放地址加载失败: \(errorDesc)"
                    Task { @MainActor in
                        self.failPlayback(errMsg)
                    }
                case .unknown:
                    self.log("[PlayerV2] PlayerItem 状态未知")
                @unknown default:
                    break
                }
            }
        statusObserver = localStatusObserver
        
        // 监听播放失败
        failureObserver = NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
            .sink { [weak self] notification in
                if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                    self?.log("[PlayerV2] ❌ 播放失败: \(error.localizedDescription)")
                    Task { @MainActor in
                        self?.failPlayback("播放失败: \(error.localizedDescription)")
                    }
                }
            }
        
        // 监听播放结束
        endObserver = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
            .sink { [weak self] _ in
                self?.log("[PlayerV2] 播放结束")
                // 普通资源自动播放下一集
                self?.playNextEpisodeIfAvailable()
            }
        
        self.player = p
        self.isPlaying = true
        self.isLoading = true
        self.loadingMessage = "正在缓冲首帧..."
        
        // 10秒超时保护：如果PlayerItem一直没就绪，显示错误
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self = self else { return }
            if await MainActor.run { self.player != nil && self.loadError == nil } {
                let status = await MainActor.run { p.currentItem?.status }
                let isActuallyPlaying = await MainActor.run { p.rate > 0 || p.timeControlStatus == .playing }
                // 如果视频已经在播放或已就绪，不触发超时
                if status != .readyToPlay && !isActuallyPlaying {
                    await MainActor.run {
                        self.log("[PlayerV2] ⏱️ 播放地址加载超时")
                        self.failPlayback("播放地址加载超时，请检查网络或更换资源")
                    }
                }
            }
        }
        
        // 添加时间观察者
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            if let itemDuration = p.currentItem?.duration {
                self.duration = itemDuration.seconds.isFinite ? itemDuration.seconds : 0
            }
            self.updateDanmaku(at: time.seconds)
            self.savePlaybackProgress()
        }
        
        // 延迟播放确保UI准备好
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            p.play()
            self?.log("[PlayerV2] 播放器开始播放")
        }
    }

    private func shouldRouteDirectURLToMPV(_ url: URL) -> Bool {
        guard enginePreference != .system, isMPVBuildAvailable else { return false }
        if enginePreference == .mpv { return true }
        let text = url.absoluteString.lowercased()
        let ext = url.pathExtension.lowercased()
        if ext == "mp4" || ext == "m4v" || ext == "mov" { return false }
        if ext == "m3u8" { return false }
        return ext == "mkv" || text.contains(".mkv") || text.contains("mkv")
    }
    
    private func cleanupObservers() {
        statusObserver?.cancel()
        failureObserver?.cancel()
        endObserver?.cancel()
        statusObserver = nil
        failureObserver = nil
        endObserver = nil
    }

    func stopPlaybackForFailure() {
        quarkFallbackTimeoutTask?.cancel()
        quarkFallbackTimeoutTask = nil
        cleanupObservers()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        compatibilityURL = nil
        compatibilityHeaders = [:]
        isPlaying = false
        isSeeking = false
        showControls = true
        showSettings = false
        showEpisodePicker = false
        showQualityPicker = false
        showDanmakuSettings = false
        showEnginePicker = false
        showDanmakuInput = false
        NotificationCenter.default.post(name: .vboxMPVStop, object: nil)
        NotificationCenter.default.post(name: .vboxVLCPause, object: nil)
    }

    func failPlayback(_ message: String) {
        stopPlaybackForFailure()
        loadError = message
        isLoading = false
        loadingMessage = "播放失败"
        log("[PlayerV2] 已进入失败态并释放播放器: \(message)")
    }
}

// MARK: - 播放器容器视图
struct PlayerContainerView: View {
    let player: AVPlayer?
    @ObservedObject var playerState: PlayerState
    let video: VodItem
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    // 5秒无触摸自动隐藏控制栏
    @State private var autoHideTask: Task<Void, Never>?

    private var isAliPlayerBuildAvailable: Bool {
        return NSClassFromString("AliPlayer") != nil
    }

    private func resetAutoHideTimer() {
        autoHideTask?.cancel()
        // 弹窗打开时不自动隐藏
        guard !playerState.showSettings,
              !playerState.showEpisodePicker,
              !playerState.showQualityPicker,
              !playerState.showDanmakuSettings,
              !playerState.showEnginePicker,
              !playerState.showDanmakuInput,
              !playerState.isSeeking,
              !playerState.isOrientationLocked else { return }
        guard playerState.showControls, playerState.isPlaying else { return }
        autoHideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    playerState.showControls = false
                }
            }
        }
    }
    
    var body: some View {
        ZStack {
            // 视频层（如果有播放器）
            if let url = playerState.compatibilityURL {
                if playerState.compatibilityEngineName.contains("MDK") {
                    #if canImport(swift_mdk)
                    MDKPlayerRepresentable(url: url, headers: playerState.compatibilityHeaders, playerState: playerState)
                        .ignoresSafeArea()
                    #else
                    CompatibilityUnavailableView(engineName: "MDK", message: "当前构建未包含 MDK，请等待兼容内核构建包")
                    #endif
                } else if playerState.compatibilityEngineName.contains("MPV") {
                    #if canImport(Libmpv)
                    LibmpvMoltenVKPlayerRepresentableV2(url: url, headers: playerState.compatibilityHeaders, playerState: playerState)
                        .ignoresSafeArea()
                    #else
                    CompatibilityUnavailableView(engineName: "MPV-MoltenVK", message: "当前构建未包含 Libmpv")
                    #endif
                } else if playerState.compatibilityEngineName.contains("IJK") {
                    #if canImport(IJKMediaFrameworkWithSSL)
                    IJKPlayerRepresentable(url: url, headers: playerState.compatibilityHeaders, playerState: playerState)
                        .ignoresSafeArea()
                    #else
                    CompatibilityUnavailableView(engineName: "IJKPlayer", message: "当前构建未包含 IJKPlayer")
                    #endif
                } else if playerState.compatibilityEngineName.contains("AliPlayer") {
                    if isAliPlayerBuildAvailable {
                    AliPlayerRepresentable(
                        url: url.absoluteString,
                        headers: playerState.compatibilityHeaders,
                        userAgent: nil as String?,
                        referer: nil as String?,
                        playerState: playerState,
                        onStatusChange: { _ in },
                        onTimeUpdate: { time in playerState.currentTime = time },
                        onDurationChange: { dur in playerState.duration = dur },
                        onBufferUpdate: { _ in },
                        onError: { msg in playerState.failPlayback(msg) },
                        onReady: { playerState.isLoading = false },
                        onSeekDone: { playerState.isSeeking = false }
                    )
                        .ignoresSafeArea()
                    } else {
                    CompatibilityUnavailableView(engineName: "AliPlayer", message: "当前构建未包含 AliyunPlayer")
                    }
                } else {
                #if canImport(MobileVLCKit)
                VLCPlayerRepresentableV2(url: url, headers: playerState.compatibilityHeaders, playerState: playerState)
                    .ignoresSafeArea()
                #else
                CompatibilityUnavailableView(engineName: "VLC", message: "当前构建未包含 VLC，请等待兼容内核构建包")
                #endif
                }
            } else if let player = player {
                AVPlayerControllerRepresentableV2(player: player, videoGravity: playerState.videoGravity)
                    .ignoresSafeArea()
            }
            
            // 加载层：播放器初始化后到首帧出现前也持续显示，避免黑屏无反馈
            if playerState.isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text(playerState.loadingMessage)
                        .foregroundColor(.white.opacity(0.8))
                        .font(.subheadline)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .background(Color.black.opacity(0.45))
                .cornerRadius(14)
            }
            
            // 弹幕层
            if playerState.showDanmaku {
                DanmakuOverlayViewV2(
                    showDanmaku: $playerState.showDanmaku,
                    opacity: playerState.danmakuOpacity,
                    fontSize: playerState.danmakuFontSize,
                    area: playerState.danmakuArea,
                    currentTime: playerState.currentTime,
                    items: playerState.danmakuItems
                )
                .allowsHitTesting(false)
            }
            
            // 手势层
            GestureControlView(playerState: playerState) {
                guard !playerState.isSeeking else { return }
                guard !playerState.showSettings,
                      !playerState.showEpisodePicker,
                      !playerState.showQualityPicker,
                      !playerState.showDanmakuSettings,
                      !playerState.showEnginePicker else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    playerState.showControls.toggle()
                }
                if playerState.showControls {
                    resetAutoHideTimer()
                }
            }
            .ignoresSafeArea()

            // 控制层 - 锁屏时始终显示（仅锁屏按钮），非锁屏时受 showControls 控制
            if playerState.showControls || playerState.isOrientationLocked {
                PlayerControlsView(
                    player: player,
                    playerState: playerState,
                    video: video
                )
            }

            
            // 弹窗层 - 独立于控制栏，即使控制栏隐藏也能显示
            // 弹窗 - 倍数（竖屏：固定在右下角进度条上方 / 横屏：居中弹窗）
            Group {
                if playerState.isPortrait && playerState.showSettings {
                    // 竖屏：倍数弹窗固定在进度条上方，屏幕右侧
                    GeometryReader { geo in
                        PlayerSettingsPanelV2(
                            isPresented: $playerState.showSettings,
                            speed: $playerState.playbackSpeed,
                            onSpeedChange: { speed in
                                playerState.changePlaybackSpeed(speed)
                            }
                        )
                        .environmentObject(settings)
                        .frame(width: 100)
                        // 弹窗放在进度条上方（底部栏约60pt + 进度条约30pt + 间距）
                        .position(x: geo.size.width - 80, y: geo.size.height - 200)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.8)),
                            removal: .opacity.combined(with: .scale(scale: 0.9))
                        ))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !playerState.isPortrait && playerState.showSettings {
                    // 横屏：小竖条弹窗，固定在底部栏"自动"按钮上方
                    GeometryReader { geo in
                        // 点击空白区域关闭弹窗
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    playerState.showSettings = false
                                }
                            }

                        PlayerSettingsPanelV2(
                            isPresented: $playerState.showSettings,
                            speed: $playerState.playbackSpeed,
                            isPortrait: false,
                            onSpeedChange: { speed in
                                playerState.changePlaybackSpeed(speed)
                            }
                        )
                        .environmentObject(settings)
                        .frame(width: 50)
                        // 固定在进度条上方
                        .position(x: geo.size.width - 38, y: geo.size.height - 200)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.8)),
                            removal: .opacity.combined(with: .scale(scale: 0.9))
                        ))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // 弹窗 - 选集（竖屏全屏，横屏小弹窗）
            Group {
                if playerState.isPortrait && playerState.showEpisodePicker {
                    EpisodePickerPopupWrapper(playerState: playerState, isPresented: $playerState.showEpisodePicker)
                } else if !playerState.isPortrait && playerState.showEpisodePicker {
                    // 横屏：小弹窗，带标题栏
                    LandscapeEpisodePickerOverlay(playerState: playerState, isPresented: $playerState.showEpisodePicker)
                }
            }
            // 侧边栏弹窗 - 清晰度
            Group {
                if playerState.showQualityPicker {
                    if playerState.isPortrait {
                        // 竖屏：清晰度小长条弹窗，固定在倍数弹窗位置（右下角进度条上方）
                        GeometryReader { geo in
                            Color.black.opacity(0.3)
                                .ignoresSafeArea()
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        playerState.showQualityPicker = false
                                    }
                                }

                            QualityPickerPanelV2(
                                selectedQuality: $playerState.selectedQuality,
                                isBaiduSourceMode: !playerState.baiduFileList.isEmpty,
                                isPortrait: true,
                                onQualityChange: { index in
                                    playerState.changeQuality(index: index)
                                }
                            )
                            .environmentObject(settings)
                            .frame(width: 110)
                            .position(x: geo.size.width - 75, y: geo.size.height - 260)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.8)),
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            ))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // 横屏：小竖条弹窗，固定在清晰度按键上方
                        GeometryReader { geo in
                            Color.black.opacity(0.3)
                                .ignoresSafeArea()
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        playerState.showQualityPicker = false
                                    }
                                }

                            QualityPickerPanelV2(
                                selectedQuality: $playerState.selectedQuality,
                                isBaiduSourceMode: !playerState.baiduFileList.isEmpty,
                                isPortrait: false,
                                onQualityChange: { index in
                                    playerState.changeQuality(index: index)
                                }
                            )
                            .environmentObject(settings)
                            .frame(width: 100)
                            // 固定在进度条上方（与倍数弹窗同位置区域）
                            .position(x: geo.size.width - 53, y: geo.size.height - 200)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.8)),
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            ))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            // 弹窗 - 弹幕设置（竖屏全屏，横屏小弹窗）
            Group {
                if playerState.isPortrait && playerState.showDanmakuSettings {
                    PortraitPopupView(isPresented: $playerState.showDanmakuSettings, title: "弹幕设置") {
                        DanmakuSettingsPanelV2(
                            showDanmaku: $playerState.showDanmaku,
                            opacity: $playerState.danmakuOpacity,
                            fontSize: $playerState.danmakuFontSize,
                            area: $playerState.danmakuArea,
                            speed: $playerState.danmakuSpeed,
                            colorMode: $playerState.danmakuColorMode,
                            isPortrait: true
                        )
                    }
                } else if !playerState.isPortrait && playerState.showDanmakuSettings {
                    GeometryReader { geo in
                        // 点击空白区域关闭弹窗
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    playerState.showDanmakuSettings = false
                                }
                            }

                        DanmakuSettingsPanelV2(
                            showDanmaku: $playerState.showDanmaku,
                            opacity: $playerState.danmakuOpacity,
                            fontSize: $playerState.danmakuFontSize,
                            area: $playerState.danmakuArea,
                            speed: $playerState.danmakuSpeed,
                            colorMode: $playerState.danmakuColorMode,
                            isPortrait: false
                        )
                        .frame(width: min(geo.size.width * 0.5, 320), height: min(geo.size.height * 0.55, 350))
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(settings.usesFrostedSkin ? Color(uiColor: .secondarySystemBackground) : Color.black.opacity(0.85))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.12), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2 - 40)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // 弹幕输入弹窗
            Group {
                if playerState.showDanmakuInput {
                    GeometryReader { geo in
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    playerState.showDanmakuInput = false
                                }
                            }

                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                TextField("发送弹幕...", text: .constant(""))
                                    .font(.system(size: 15))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 20)
                                            .fill(Color.white.opacity(0.15))
                                    )
                                    .textFieldStyle(PlainTextFieldStyle())

                                Button(action: {
                                    // TODO: 对接弹幕发送功能
                                    playerState.showDanmakuInput = false
                                }) {
                                    Text("发送")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 20)
                                                .fill(Color(hex: "00BE06"))
                                        )
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                            .background(Color(hex: "1A1A1A"))
                            .cornerRadius(12)
                        }
                        .position(x: geo.size.width / 2, y: geo.size.height - 160)
                        .transition(.opacity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // 弹窗 - 播放内核（竖屏全屏，横屏小弹窗）
            Group {
                if playerState.isPortrait && playerState.showEnginePicker {
                    PortraitPopupView(isPresented: $playerState.showEnginePicker, title: "播放内核") {
                        EnginePickerPanelV2(playerState: playerState, isPortrait: true)
                    }
                } else if !playerState.isPortrait && playerState.showEnginePicker {
                    // 横屏：小方形弹窗，固定在内核按键上方
                    GeometryReader { geo in
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    playerState.showEnginePicker = false
                                }
                            }

                        EnginePickerPanelV2(playerState: playerState, isPortrait: false)
                            .environmentObject(settings)
                            .frame(width: 100, height: 260)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(settings.usesFrostedSkin ? Color(uiColor: .secondarySystemBackground) : Color.black.opacity(0.85))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.12), lineWidth: 0.5)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 4)
                            // 固定在进度条上方（与倍数弹窗同位置区域）
                            .position(x: geo.size.width - 38, y: geo.size.height - 200)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.8)),
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            ))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            resetAutoHideTimer()
        }
        .onChange(of: playerState.showControls) { newValue in
            if newValue {
                resetAutoHideTimer()
            } else {
                autoHideTask?.cancel()
            }
        }
        .onChange(of: playerState.isPlaying) { newValue in
            if newValue && playerState.showControls {
                resetAutoHideTimer()
            }
        }
    }
}

// MARK: - 错误视图
struct ErrorView: View {
    let error: String
    let onRetry: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var isRetryable: Bool {
        let lower = error.lowercased()
        return !lower.contains("已失效") && !lower.contains("已被和谐") && !lower.contains("禁止播放") && !lower.contains("转存返回占位")
    }

    var body: some View {
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

                HStack(spacing: 20) {
                    if isRetryable {
                        Button(action: onRetry) {
                            Text("重试")
                                .foregroundColor(.white)
                                .padding(.horizontal, 40)
                                .padding(.vertical, 12)
                                .background(Color.blue)
                                .cornerRadius(8)
                        }
                    }

                    Button(action: { dismiss() }) {
                        Text("返回")
                            .foregroundColor(.white)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 12)
                            .background(Color.gray)
                            .cornerRadius(8)
                    }
                }
            }
            Spacer()
        }
    }
}

// MARK: - 错误视图（简洁版，日志在绿色浮层里看）
struct ErrorViewWithLogs: View {
    let error: String
    let logs: [String]
    let onRetry: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var isRetryable: Bool {
        let lower = error.lowercased()
        return !lower.contains("已失效") && !lower.contains("已被和谐") && !lower.contains("禁止播放") && !lower.contains("转存返回占位")
    }

    var body: some View {
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
                    .foregroundColor(.white.opacity(0.9))
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                HStack(spacing: 20) {
                    if isRetryable {
                        Button(action: onRetry) {
                            Text("重试").foregroundColor(.white)
                                .padding(.horizontal, 40).padding(.vertical, 12)
                                .background(Color.blue).cornerRadius(8)
                        }
                    }
                    Button(action: { dismiss() }) {
                        Text("返回").foregroundColor(.white)
                            .padding(.horizontal, 40).padding(.vertical, 12)
                            .background(Color.gray).cornerRadius(8)
                    }
                }
            }
            Spacer()
        }
    }
}

// MARK: - 播放器控制视图
// MARK: - 播放器顶部栏
struct PlayerTopBarView: View {
    let isPortrait: Bool
    let videoName: String
    @ObservedObject var playerState: PlayerState
    var onTogglePiP: () -> Void
    var onDismiss: () -> Void

    // 时间+电量
    @State private var currentDate = Date()
    @State private var batteryLevel: Float = UIDevice.current.batteryLevel
    private let timeTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    // 名称滚动
    @State private var nameScrollOffset: CGFloat = 0
    @State private var nameNeedsScroll = false
    @State private var nameScrollTask: Task<Void, Never>?

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: currentDate)
    }

    private var batteryString: String {
        let level = batteryLevel < 0 ? 1.0 : batteryLevel
        return "\(Int(level * 100))%"
    }

    var body: some View {
        if isPortrait {
            HStack {
                Button(action: { onDismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
        } else {
            // 横屏状态：返回键 + 资源名称 + 居中时间电量 + 右侧功能按钮
            HStack(spacing: 0) {
                if !playerState.isOrientationLocked {
                    Button(action: { onDismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())

                    // 资源名称（自动滚动长名称，固定宽度避免撑破布局）
                    VideoNameScrollingText(name: videoName, maxWidth: 120)
                        .frame(width: 120, alignment: .leading)
                }

                Spacer()

                // 居中：时间 + 电量
                if !playerState.isOrientationLocked {
                    HStack(spacing: 6) {
                        Text(timeString)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))

                        HStack(spacing: 2) {
                            Image(systemName: batteryIcon)
                                .font(.system(size: 11))
                            Text(batteryString)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .foregroundColor(batteryColor)
                    }
                }

                Spacer()

                if !playerState.isOrientationLocked {
                    // 右侧：小窗口/投屏/屏幕拉伸
                    HStack(spacing: 0) {
                        Button(action: { onTogglePiP() }) {
                            Image(systemName: playerState.isPiPActive ? "pip.exit" : "pip.enter")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(playerState.isPiPSupported ? .white : .white.opacity(0.3))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(!playerState.isPiPSupported)

                        AirPlayViewV2()
                            .frame(width: 44, height: 44)

                        Button(action: {
                            playerState.cycleVideoGravity()
                        }) {
                            Image(systemName: playerState.videoGravity.icon)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .onReceive(timeTimer) { _ in
                currentDate = Date()
                batteryLevel = UIDevice.current.batteryLevel
            }
            .onAppear {
                UIDevice.current.isBatteryMonitoringEnabled = true
                batteryLevel = UIDevice.current.batteryLevel
            }
        }
    }

    private var batteryIcon: String {
        let level = batteryLevel < 0 ? 1.0 : batteryLevel
        if level >= 0.9 { return "battery.100" }
        if level >= 0.6 { return "battery.75" }
        if level >= 0.3 { return "battery.50" }
        return "battery.25"
    }

    private var batteryColor: Color {
        let level = batteryLevel < 0 ? 1.0 : batteryLevel
        if level <= 0.1 { return .red.opacity(0.8) }
        if level <= 0.2 { return .orange.opacity(0.8) }
        return .white.opacity(0.7)
    }
}

// MARK: - 视频名称自动滚动组件
struct VideoNameScrollingText: View {
    let name: String
    let maxWidth: CGFloat
    @State private var animate = false

    init(name: String, maxWidth: CGFloat = 120) {
        self.name = name
        self.maxWidth = maxWidth
    }

    var body: some View {
        let font = UIFont.systemFont(ofSize: 13, weight: .medium)
        let textWidth = (name as NSString).size(withAttributes: [.font: font]).width
        let needsScroll = textWidth > maxWidth

        if needsScroll {
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .fixedSize()
                .frame(width: maxWidth, alignment: .leading)
                .clipped()
                .overlay(alignment: .trailing) {
                    LinearGradient(
                        gradient: Gradient(colors: [.clear, .black]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 20)
                }
                .offset(x: animate ? -(textWidth - maxWidth + 20) : maxWidth)
                .animation(
                    .linear(duration: max(4.0, textWidth / 30.0))
                    .delay(2)
                    .repeatForever(autoreverses: false),
                    value: animate
                )
                .onAppear { animate = true }
                .padding(.leading, 8)
        } else {
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .padding(.leading, 8)
        }
    }
}

// MARK: - 时间格式化（全局）
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

// MARK: - 播放器进度条
struct PlayerProgressBar: View {
    let isPortrait: Bool
    @ObservedObject var playerState: PlayerState

    var body: some View {
        HStack(spacing: 10) {
            Text(formatTime(playerState.isSeeking ? playerState.seekPreviewTime : playerState.currentTime))
                .font(.system(size: isPortrait ? 10 : 12, weight: .medium))
                .foregroundColor(.white)

            GeometryReader { geometry in
                let displayTime = playerState.isSeeking ? playerState.seekPreviewTime : playerState.currentTime
                let progress = playerState.duration > 0 ? max(0, min(displayTime / playerState.duration, 1)) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.3))
                        .frame(height: isPortrait ? 3 : 4)

                    if playerState.duration > 0 {
                        ForEach(Array(playerState.baiduCachedTimeRanges.enumerated()), id: \.offset) { _, range in
                            let start = max(0, min(range.start / playerState.duration, 1))
                            let end = max(start, min(range.end / playerState.duration, 1))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: "00BEFF").opacity(0.28))
                                .frame(width: CGFloat(end - start) * geometry.size.width, height: isPortrait ? 3 : 4)
                                .offset(x: CGFloat(start) * geometry.size.width)
                        }
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(hex: "00BEFF"))
                            .frame(width: CGFloat(progress) * geometry.size.width, height: isPortrait ? 3 : 4)
                        Circle()
                            .fill(Color(hex: "00BEFF"))
                            .frame(width: isPortrait ? 10 : 14, height: isPortrait ? 10 : 14)
                            .offset(x: max(0, min(CGFloat(progress) * geometry.size.width - (isPortrait ? 5 : 7), geometry.size.width - (isPortrait ? 10 : 14))))
                    }
                }
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard playerState.duration > 0 else { return }
                            let x = max(0, min(value.location.x, geometry.size.width))
                            let target = Double(x / geometry.size.width) * playerState.duration
                            playerState.isSeeking = true
                            playerState.seekPreviewTime = target
                        }
                        .onEnded { value in
                            guard playerState.duration > 0 else { return }
                            let x = max(0, min(value.location.x, geometry.size.width))
                            let target = Double(x / geometry.size.width) * playerState.duration
                            playerState.seek(to: target)
                        }
                )
            }
            .frame(height: isPortrait ? 16 : 20)

            Text(formatTime(playerState.duration))
                .font(.system(size: isPortrait ? 10 : 12, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, isPortrait ? 12 : 16)
        .padding(.vertical, isPortrait ? 6 : 8)
    }
}

// MARK: - 竖屏底部按钮栏
struct PortraitBottomBar: View {
    let player: AVPlayer?
    @ObservedObject var playerState: PlayerState

    /// 格式化倍速显示文字（如 "1.0x"）
    private var speedDisplayText: String {
        let s = playerState.playbackSpeed
        let formatted = String(format: "%.2f", s)
        let trimmed = formatted.hasSuffix(".00") ? String(formatted.dropLast(3)) :
                       formatted.hasSuffix("0") ? String(formatted.dropLast(1)) : formatted
        return trimmed + "x"
    }

    /// 当前清晰度显示文字
    private var qualityDisplayText: String {
        let isBaidu = playerState.episodeItems.isEmpty && !playerState.baiduFileList.isEmpty
        if isBaidu {
            return "原画"
        } else {
            let qualities = ["标清", "高清", "蓝光"]
            return qualities.indices.contains(playerState.selectedQuality) ? qualities[playerState.selectedQuality] : "高清"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // === 左侧功能区 ===

            // 1. 暂停/播放按钮 - 两条竖线风格
            Button(action: { playerState.togglePlayback(player: player) }) {
                Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor((player == nil && playerState.compatibilityURL == nil) ? .gray : .white)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(player == nil && playerState.compatibilityURL == nil)
            .buttonStyle(PlainButtonStyle())

            // 2. 下一集按钮 - 左三角箭头风格
            Button(action: { playerState.playNextEpisode() }) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(playerState.hasNextEpisode ? .white : .gray)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!playerState.hasNextEpisode)
            .buttonStyle(PlainButtonStyle())

            // 3. 弹幕开关按钮 - "弹"字图标，开启时右下角绿色对勾
            Button(action: { playerState.showDanmaku.toggle() }) {
                ZStack(alignment: .bottomTrailing) {
                    Text("弹")
                        .font(Font.custom("PingFang SC", size: 15).weight(.bold))
                        .foregroundColor(playerState.showDanmaku ? Color(hex: "00BE06") : .white.opacity(0.6))
                    if playerState.showDanmaku {
                        Image(systemName: "checkmark")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 10, height: 10)
                            .background(Circle().fill(Color(hex: "00BE06")))
                            .offset(x: 6, y: -2)
                    }
                }
                .frame(width: 48, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // 4. 弹幕设置按钮 - "弹"字+齿轮小图标
            Button(action: { playerState.showDanmakuSettings = true }) {
                ZStack(alignment: .bottomTrailing) {
                    Text("弹")
                        .font(Font.custom("PingFang SC", size: 15).weight(.bold))
                        .foregroundColor(.white.opacity(0.6))
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .offset(x: 8, y: -2)
                }
                .frame(width: 48, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()

            // === 右侧功能区 ===

            // 1. 倍速按钮 - 文字显示当前倍速值
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    playerState.showSettings.toggle()
                }
            }) {
                Text(speedDisplayText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(playerState.showSettings ? Color(hex: "00BE06") : .white)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // 2. 清晰度按钮 - 显示当前分辨率
            Button(action: { playerState.showQualityPicker.toggle() }) {
                Text(qualityDisplayText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // 3. 选集按钮
            Button(action: { playerState.showEpisodePicker.toggle() }) {
                Text("选集")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
    }
}

// MARK: - 横屏底部按钮栏
struct LandscapeBottomBar: View {
    let player: AVPlayer?
    @ObservedObject var playerState: PlayerState

    /// 格式化倍速显示文字（如 "1.0x"）
    private var speedDisplayText: String {
        let s = playerState.playbackSpeed
        let formatted = String(format: "%.2f", s)
        let trimmed = formatted.hasSuffix(".00") ? String(formatted.dropLast(3)) :
                       formatted.hasSuffix("0") ? String(formatted.dropLast(1)) : formatted
        return trimmed + "x"
    }

    /// 当前清晰度显示文字
    private var qualityDisplayText: String {
        let isBaidu = playerState.episodeItems.isEmpty && !playerState.baiduFileList.isEmpty
        if isBaidu {
            return "原画"
        } else {
            let qualities = ["标清", "高清", "蓝光"]
            return qualities.indices.contains(playerState.selectedQuality) ? qualities[playerState.selectedQuality] : "高清"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // === 左侧功能区 ===

            // 1. 暂停/播放按钮 - 两条竖线风格
            Button(action: { playerState.togglePlayback(player: player) }) {
                Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor((player == nil && playerState.compatibilityURL == nil) ? .gray : .white)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(player == nil && playerState.compatibilityURL == nil)

            // 2. 下一集按钮 - 左三角箭头风格
            Button(action: { playerState.playNextEpisode() }) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(playerState.hasNextEpisode ? .white : .gray)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!playerState.hasNextEpisode)

            // 3. 弹幕开关按钮 - "弹"字图标，开启时右下角绿色对勾
            Button(action: { playerState.showDanmaku.toggle() }) {
                ZStack(alignment: .bottomTrailing) {
                    Text("弹")
                        .font(Font.custom("PingFang SC", size: 15).weight(.bold))
                        .foregroundColor(playerState.showDanmaku ? Color(hex: "00BE06") : .white.opacity(0.6))
                    if playerState.showDanmaku {
                        Image(systemName: "checkmark")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 10, height: 10)
                            .background(Circle().fill(Color(hex: "00BE06")))
                            .offset(x: 6, y: -2)
                    }
                }
                .frame(width: 48, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // 4. 弹幕设置按钮 - "弹"字+齿轮小图标
            Button(action: { playerState.showDanmakuSettings = true }) {
                ZStack(alignment: .bottomTrailing) {
                    Text("弹")
                        .font(Font.custom("PingFang SC", size: 15).weight(.bold))
                        .foregroundColor(.white.opacity(0.6))
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .offset(x: 8, y: -2)
                }
                .frame(width: 48, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // === 中间输入框区域 ===
            Spacer(minLength: 12)

            // 弹幕输入框 - 深灰底色长条输入框，点击后弹出输入
            Button(action: { playerState.showDanmakuInput = true }) {
                HStack {
                    Text("请文明发送弹幕")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "00BE06"))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 36)
                .frame(maxWidth: 200)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.white.opacity(0.12))
                )
            }
            .buttonStyle(PlainButtonStyle())

            Spacer(minLength: 12)

            // === 右侧功能区 ===

            // 1. 倍速按钮 - 文字显示当前倍速值
            Button(action: { playerState.showSettings.toggle() }) {
                Text(speedDisplayText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(playerState.showSettings ? Color(hex: "00BE06") : .white)
                    .frame(width: 56, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // 2. 清晰度按钮 - 显示当前分辨率文字
            Button(action: { playerState.showQualityPicker.toggle() }) {
                Text(qualityDisplayText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // 3. 选集按钮
            Button(action: { playerState.showEpisodePicker.toggle() }) {
                Text("选集")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // 4. 内核按钮
            Button(action: { playerState.showEnginePicker.toggle() }) {
                Text(playerState.currentEngineButtonTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(playerState.playbackEngineMode == .compatibility ? Color(hex: "00BEFF") : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 78, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }
}

// MARK: - 播放器控制栏主视图
struct PlayerControlsView: View {
    let player: AVPlayer?
    @ObservedObject var playerState: PlayerState
    let video: VodItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            PlayerTopBarView(
                isPortrait: playerState.isPortrait,
                videoName: video.vodName,
                playerState: playerState,
                onTogglePiP: { togglePiP() },
                onDismiss: { dismiss() }
            )

            Spacer()

            // 锁屏状态下隐藏底部控制栏和进度条
            if !playerState.isOrientationLocked {
                VStack(spacing: 0) {
                    PlayerProgressBar(isPortrait: playerState.isPortrait, playerState: playerState)

                    if playerState.isPortrait {
                        PortraitBottomBar(player: player, playerState: playerState)
                    } else {
                        LandscapeBottomBar(player: player, playerState: playerState)
                    }
                }
                .background(
                    Color.clear
                )
            }
        }
        // 锁定按钮覆盖层（固定在左侧屏幕边缘垂直居中，不受VStack布局影响）
        .overlay(
            Group {
                if !playerState.isPortrait {
                    GeometryReader { geometry in
                        Button(action: {
                            playerState.isOrientationLocked.toggle()
                            if playerState.isOrientationLocked {
                                OrientationHelper.lockOrientation(.landscape)
                            } else {
                                OrientationHelper.unlockOrientation()
                            }
                        }) {
                            Image(systemName: playerState.isOrientationLocked ? "lock.fill" : "lock.open")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white.opacity(0.9))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .position(x: 16 + 22, y: geometry.size.height / 2)
                    }
                    .allowsHitTesting(true)
                }
            }
        )
        .onAppear {
            updateOrientation()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateOrientation()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // 回到前台时重新检测方向（faceUp 时 UIDevice.orientation 不会变，但 interfaceOrientation 可能是竖屏）
            updateOrientation()
        }
    }

    private func togglePiP() {
        if playerState.isPiPActive {
            // 当前正在画中画：停止
            #if canImport(Libmpv)
            MPVPiPManager.shared.stopPiP()
            #endif
            #if canImport(swift_mdk)
            MDKPipManager.shared.stopPiP()
            #endif
            PiPHelper.shared.stopPiP()
            playerState.isPiPActive = false
        } else {
            // 启动系统画中画并返回桌面
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

            // 所有内核统一尝试系统画中画（桌面小窗口），失败不再回退截图浮窗。
            // 兼容内核通过 AVURLAsset + 私有 header 字段复用当前播放 headers，让 AVPlayer 也能播放本地代理 URL。
            if let compatURL = playerState.compatibilityURL {
                let avOptions: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": playerState.compatibilityHeaders]
                if let asset = try? AVURLAsset(url: compatURL, options: avOptions) {
                    let avPlayerForPiP = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    avPlayerForPiP.play()
                    PiPHelper.shared.setupPiP(for: avPlayerForPiP)
                    playerState.log("[PlayerV2] 兼容内核尝试走 AVPlayer 系统画中画：\(compatURL.absoluteString.prefix(80))")
                } else {
                    playerState.log("[PlayerV2] 兼容内核系统画中画不可用（无法创建 AVURLAsset）")
                }
            } else if let avPlayer = player {
                // 原生 AVPlayer：使用系统画中画
                PiPHelper.shared.setupPiP(for: avPlayer)
            }

            playerState.isPiPActive = true

            // 返回桌面（等同于按下 Home 键），PiP 小窗留在屏幕上
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
            }
        }
    }

    /// 在 App 视图层级中查找当前播放器视图（兼容 AVPlayerLayer / OpenGL / Metal 等内核）
    private func findCurrentPlayerView() -> UIView? {
        guard let rootView = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows
            .first(where: { $0.isKeyWindow })?.rootViewController?.view else { return nil }

        let candidates = ["Player", "Video", "GL", "Metal", "Render", "AliPlayer", "VLC", "IJK", "MPV", "MDK"]
        var result: UIView?

        func search(_ view: UIView) {
            if result != nil { return }
            let clsName = String(describing: type(of: view))
            for keyword in candidates {
                if clsName.contains(keyword) {
                    result = view
                    return
                }
            }
            for sub in view.subviews {
                search(sub)
            }
        }

        search(rootView)
        return result
    }

    private func updateOrientation() {
        let newIsPortrait = currentInterfaceOrientation?.isPortrait ?? false
        if newIsPortrait != playerState.isPortrait {
            playerState.isPortrait = newIsPortrait
            // 方向变化时关闭所有弹窗，避免横竖屏弹窗互相干扰
            playerState.showEpisodePicker = false
            playerState.showSettings = false
            playerState.showQualityPicker = false
            playerState.showEnginePicker = false
        }
    }

    /// 获取当前 UI 窗口方向（faceUp 时仍返回正确方向，不受物理设备姿态影响）
    private var currentInterfaceOrientation: UIInterfaceOrientation? {
        // 优先使用第一个 foreground active 场景
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            return scene.interfaceOrientation
        }
        // 回退：任意 window scene
        return (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first)?
            .interfaceOrientation
    }
}

// MARK: - 横屏选集弹窗（标题栏 + 排序按钮 + 网格）
struct LandscapeEpisodePickerOverlay: View {
    @ObservedObject var playerState: PlayerState
    @Binding var isPresented: Bool
    @State private var isReversed = false
    @EnvironmentObject private var settings: AppSettings

    private var panelBackground: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .secondarySystemBackground).opacity(0.92)
        }
        return Color.black.opacity(0.85)
    }

    var body: some View {
        GeometryReader { geo in
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPresented = false
                    }
                }

            VStack(spacing: 0) {
                // 标题栏
                HStack {
                    Text("选集")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(settings.usesFrostedSkin ? Color(uiColor: .label) : .white)
                    Spacer()
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isReversed.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: isReversed ? "arrow.up" : "arrow.down")
                                .font(.system(size: 11, weight: .semibold))
                            Text(isReversed ? "倒序" : "正序")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(settings.usesFrostedSkin ? Color(uiColor: .label) : .white.opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(settings.usesFrostedSkin ? Color(uiColor: .tertiarySystemBackground) : Color.white.opacity(0.1))
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 4)

                Divider()
                    .background(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.08))

                EpisodePickerPanelV2(
                    playerState: playerState,
                    isPresented: $isPresented,
                    isPortrait: false,
                    isReversed: $isReversed
                )
                .environmentObject(settings)
            }
            .frame(width: min(geo.size.width * 0.5, 320), height: min(geo.size.height * 0.5, 320))
            .background(panelBackground)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
            .position(x: geo.size.width / 2, y: geo.size.height / 2 - 40)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 竖屏选集弹窗（排序按钮在标题栏右侧，替代关闭按钮）
struct EpisodePickerPopupWrapper: View {
    @ObservedObject var playerState: PlayerState
    @Binding var isPresented: Bool
    @State private var isReversed = false
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        PortraitPopupView(isPresented: $isPresented, title: "选集", content: {
            EpisodePickerPanelV2(
                playerState: playerState,
                isPresented: $isPresented,
                isPortrait: true,
                isReversed: $isReversed
            )
        }, trailing: {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isReversed.toggle()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: isReversed ? "arrow.up" : "arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                    Text(isReversed ? "倒序" : "正序")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(settings.usesFrostedSkin ? Color(uiColor: .label) : .white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(settings.usesFrostedSkin ? Color(uiColor: .tertiarySystemBackground) : Color.white.opacity(0.1))
                )
            }
            .buttonStyle(PlainButtonStyle())
        })
    }
}

// MARK: - 竖屏弹窗容器（河马剧场风格：半透明背景+居中面板，自适应皮肤）
struct PortraitPopupView<Content: View, Trailing: View>: View {
    @Binding var isPresented: Bool
    let title: String
    let content: Content
    let trailingView: Trailing?
    @EnvironmentObject private var settings: AppSettings

    init(isPresented: Binding<Bool>, title: String, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self._isPresented = isPresented
        self.title = title
        self.content = content()
        self.trailingView = trailing()
    }

    init(isPresented: Binding<Bool>, title: String, @ViewBuilder content: () -> Content) where Trailing == EmptyView {
        self._isPresented = isPresented
        self.title = title
        self.content = content()
        self.trailingView = nil
    }

    /// 自适应皮肤的面板背景色
    private var panelBackground: Color {
        if settings.usesLiquidSkin {
            return Color(hex: "1A1A2E").opacity(0.85)
        } else if settings.usesFrostedSkin {
            return Color(uiColor: .secondarySystemBackground).opacity(0.92)
        }
        return Color.black.opacity(0.75)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isPresented {
                    // 半透明遮罩
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isPresented = false
                            }
                        }

                    // 小尺寸居中面板（类似河马剧场风格）
                    VStack(spacing: 0) {
                        // 标题栏
                        HStack {
                            Text(title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(settings.usesFrostedSkin ? Color(uiColor: .label) : .white)
                            Spacer()
                            if let trailing = trailingView {
                                trailing
                            } else {
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isPresented = false
                                    }
                                }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(settings.usesFrostedSkin ? Color(uiColor: .secondaryLabel) : .white.opacity(0.7))
                                        .frame(width: 28, height: 28)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(width: min(geometry.size.width * 0.75, 300))
                    .frame(maxHeight: min(geometry.size.height * 0.5, 380))
                    .background(panelBackground)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.12), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 6)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.8)),
                        removal: .opacity.combined(with: .scale(scale: 0.9))
                    ))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isPresented)
        }
    }
}

// MARK: - AVPlayer 控制器封装 V2
struct AVPlayerControllerRepresentableV2: UIViewControllerRepresentable {
    let player: AVPlayer
    let videoGravity: PlayerState.VideoGravityMode

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = videoGravity.avGravity
        // 将 playerLayer 引用保存到 PiPHelper，供画中画使用
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let playerLayer = controller.view.layer.sublayers?.first(where: { $0 is AVPlayerLayer }) as? AVPlayerLayer {
                PiPHelper.shared.setPlayerLayer(playerLayer)
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
        // 同步画面拉伸模式
        if uiViewController.videoGravity != videoGravity.avGravity {
            uiViewController.videoGravity = videoGravity.avGravity
        }
    }
}

struct CompatibilityUnavailableView: View {
    let engineName: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.slash")
                .font(.system(size: 42))
                .foregroundColor(.white.opacity(0.85))
            Text("当前资源需要\(engineName)兼容内核")
                .foregroundColor(.white)
                .font(.headline)
            Text(message)
                .foregroundColor(.white.opacity(0.7))
                .font(.subheadline)
        }
    }
}

#if canImport(Libmpv)
// MARK: - Libmpv-MoltenVK 正式播放层 V2
struct LibmpvMoltenVKPlayerRepresentableV2: UIViewRepresentable {
    let url: URL
    let headers: [String: String]
    @ObservedObject var playerState: PlayerState

    func makeCoordinator() -> Coordinator {
        Coordinator(playerState: playerState)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        context.coordinator.attach(to: view, url: url, headers: headers)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.attach(to: uiView, url: url, headers: headers)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private let core = LibmpvMoltenVKPlayerCore.shared
        private var observers: [NSObjectProtocol] = []
        private weak var playerState: PlayerState?
        private var isStopped = false
        private var initTimeoutWorkItem: DispatchWorkItem?
        var currentURL: URL?

        private static let initTimeoutSeconds: TimeInterval = 15

        init(playerState: PlayerState) {
            self.playerState = playerState
            core.onLog = { [weak playerState] message in
                guard playerState?.compatibilityURL != nil else { return }
                playerState?.log("[MPV-MoltenVK] \(message)")
            }
            core.onStateChange = { [weak self, weak playerState] state in
                guard let self, let playerState else { return }
                guard playerState.compatibilityURL != nil else { return }
                playerState.currentTime = state.currentTime
                if state.duration.isFinite, state.duration > 0 {
                    playerState.duration = state.duration
                }
                playerState.updateDanmaku(at: state.currentTime)
                playerState.savePlaybackProgress()
                playerState.reportBaiduCacheProgressIfNeeded()
                playerState.isLoading = state.isBuffering
                playerState.isPlaying = state.isPlaying
                if let error = state.errorMessage {
                    self.cancelInitTimeout()
                    playerState.failPlayback(error)
                }
                if !state.isBuffering && state.currentTime > 0 {
                    self.cancelInitTimeout()
                }
            }

            observers.append(NotificationCenter.default.addObserver(forName: .vboxMPVPlay, object: nil, queue: .main) { [weak self] _ in
                self?.core.play()
            })
            observers.append(NotificationCenter.default.addObserver(forName: .vboxMPVPause, object: nil, queue: .main) { [weak self] _ in
                self?.core.pause()
            })
            observers.append(NotificationCenter.default.addObserver(forName: .vboxMPVSeek, object: nil, queue: .main) { [weak self] note in
                guard let seconds = note.userInfo?["seconds"] as? Double else { return }
                self?.core.seek(to: seconds)
            })
            observers.append(NotificationCenter.default.addObserver(forName: .vboxMPVSpeed, object: nil, queue: .main) { [weak self] note in
                guard let speed = note.userInfo?["speed"] as? Double else { return }
                self?.core.setRate(speed)
            })

            // PiP 帧捕获控制：监听 PiP 状态变化通知，控制 Metal 帧捕获
            observers.append(NotificationCenter.default.addObserver(forName: .vboxPiPStatusChanged, object: nil, queue: .main) { [weak self] note in
                guard let isActive = note.object as? Bool else { return }
                if isActive {
                    self?.core.startPiPCapture()
                } else {
                    self?.core.stopPiPCapture()
                }
            })
            // PiP 跳转控制
            observers.append(NotificationCenter.default.addObserver(forName: .vboxMPVPiPSkip, object: nil, queue: .main) { [weak self] note in
                guard let skipInterval = note.object as? CMTime else { return }
                let seconds = CMTimeGetSeconds(skipInterval)
                let current = self?.core.state.currentTime ?? 0
                self?.core.seek(to: current + seconds)
            })
            // PiP 播放/暂停控制
            observers.append(NotificationCenter.default.addObserver(forName: .vboxPiPTogglePlayPause, object: nil, queue: .main) { [weak self] note in
                guard let playing = note.object as? Bool else { return }
                if playing {
                    self?.core.play()
                } else {
                    self?.core.pause()
                }
            })
        }

        deinit {
            stop()
        }

        func attach(to view: UIView, url: URL, headers: [String: String]) {
            guard !isStopped else { return }
            currentURL = url
            core.attach(to: view)
            core.load(url: url, headers: headers, profile: inferredProfile(for: url))
            core.setRate(playerState?.playbackSpeed ?? 1.0)
            core.play()
            if let resume = playerState?.currentTime, resume > 10 {
                core.seek(to: resume)
                playerState?.log("[Progress] MPV 自动跳转到上次进度：\(Int(resume))s")
            }
            playerState?.isLoading = true
            playerState?.loadingMessage = "正在启动 MPV-MoltenVK..."
            startInitTimeout()
        }

        private func startInitTimeout() {
            cancelInitTimeout()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, !self.isStopped else { return }
                self.playerState?.log("[MPV-MoltenVK] 初始化超时(\(Int(Self.initTimeoutSeconds))s)，停止等待")
                self.playerState?.failPlayback("MPV-MoltenVK 初始化超时，请尝试切换到 VLC 或系统内核")
                self.core.stop()
            }
            initTimeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.initTimeoutSeconds, execute: workItem)
        }

        private func cancelInitTimeout() {
            initTimeoutWorkItem?.cancel()
            initTimeoutWorkItem = nil
        }

        func stop() {
            guard !isStopped else { return }
            isStopped = true
            cancelInitTimeout()
            core.stopPiPCapture()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            core.onLog = nil
            core.onStateChange = nil

            // 如果还在系统画中画，不要销毁 mpv，让播放继续
            if !(playerState?.isPiPActive ?? false) {
                core.stop()
                core.teardown()
            }

            currentURL = nil
            playerState = nil
        }

        private func inferredProfile(for url: URL) -> LibmpvMoltenVKPlayerCore.PlaybackProfile {
            let text = url.absoluteString.lowercased()
            let ext = url.pathExtension.lowercased()
            if text.contains("baidu-stream") || text.contains("quark-stream") { return .httpStream }
            if ext == "mkv" || text.contains("mkv") { return .mkvLarge }
            if ext == "m3u8" { return .hlsFast }
            if ext == "mp4" || ext == "m4v" || ext == "mov" { return .mp4 }
            return .generic
        }
    }
}
#endif

#if canImport(MobileVLCKit)
// MARK: - VLC 兼容播放内核封装 V2
struct VLCPlayerRepresentableV2: UIViewRepresentable {
    let url: URL
    let headers: [String: String]
    @ObservedObject var playerState: PlayerState

    func makeCoordinator() -> VLCPlayerCoordinatorV2 {
        VLCPlayerCoordinatorV2(playerState: playerState)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        context.coordinator.attach(to: view, url: url, headers: headers)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.attach(to: uiView, url: url, headers: headers)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: VLCPlayerCoordinatorV2) {
        coordinator.stop()
    }

    final class VLCPlayerCoordinatorV2 {
        private let mediaPlayer = VLCMediaPlayer()
        private var observers: [NSObjectProtocol] = []
        private var progressTimer: Timer?
        private weak var playerState: PlayerState?
        private var didFinish = false
        var currentURL: URL?

        init(playerState: PlayerState) {
            self.playerState = playerState
            observers.append(
                NotificationCenter.default.addObserver(forName: .vboxVLCPlay, object: nil, queue: .main) { [weak self] _ in
                    self?.mediaPlayer.play()
                }
            )
            observers.append(
                NotificationCenter.default.addObserver(forName: .vboxVLCPause, object: nil, queue: .main) { [weak self] _ in
                    self?.mediaPlayer.pause()
                }
            )
            observers.append(
                NotificationCenter.default.addObserver(forName: .vboxVLCSeek, object: nil, queue: .main) { [weak self] note in
                    guard let seconds = note.userInfo?["seconds"] as? Double else { return }
                    self?.seek(to: seconds)
                }
            )
            observers.append(
                NotificationCenter.default.addObserver(forName: .vboxVLCSpeed, object: nil, queue: .main) { [weak self] note in
                    guard let speed = note.userInfo?["speed"] as? Double else { return }
                    self?.mediaPlayer.rate = Float(speed)
                }
            )
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            progressTimer?.invalidate()
        }

        func attach(to view: UIView, url: URL, headers: [String: String]) {
            currentURL = url
            mediaPlayer.drawable = view
            let media = VLCMedia(url: url)
            var options: [AnyHashable: Any] = [:]
            // 增加网络缓存，减少夸克/百度直链播放时的卡顿（默认300ms太小）
            options["network-caching"] = 20000
            options["file-caching"] = 20000
            if let ua = headers.first(where: { $0.key.lowercased() == "user-agent" })?.value {
                options["http-user-agent"] = ua
            }
            if let referer = headers.first(where: { $0.key.lowercased() == "referer" })?.value {
                options["http-referrer"] = referer
            }
            if !options.isEmpty {
                media.addOptions(options)
            }
            mediaPlayer.media = media
            mediaPlayer.play()
            mediaPlayer.rate = Float(playerState?.playbackSpeed ?? 1.0)
            didFinish = false
            startProgressTimer()
        }

        func stop() {
            progressTimer?.invalidate()
            progressTimer = nil
            mediaPlayer.stop()
            mediaPlayer.drawable = nil
            currentURL = nil
        }

        private func seek(to seconds: Double) {
            let duration = Double(mediaPlayer.media?.length.intValue ?? 0) / 1000.0
            guard duration.isFinite, duration > 0 else { return }
            mediaPlayer.position = Float(max(0, min(seconds / duration, 1)))
        }

        private func startProgressTimer() {
            progressTimer?.invalidate()
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                let current = Double(self.mediaPlayer.time.intValue) / 1000.0
                let total = Double(self.mediaPlayer.media?.length.intValue ?? 0) / 1000.0
                guard current.isFinite, total.isFinite, total > 0 else { return }

                self.playerState?.currentTime = max(0, current)
                self.playerState?.duration = max(0, total)
                self.playerState?.reportBaiduCacheProgressIfNeeded()

                if !self.didFinish, current >= max(0, total - 0.8), total > 1 {
                    self.didFinish = true
                    self.playerState?.isPlaying = false
                    self.playerState?.currentTime = total
                    self.playerState?.log("[PlayerV2] VLC 播放结束")
                }
            }
        }
    }
}
#endif

// MARK: - 弹幕设置视图
struct DanmakuSettingsViewV2: View {
    @Binding var showDanmaku: Bool
    @Binding var opacity: Double
    @Binding var fontSize: CGFloat
    @Binding var area: Double
    @Binding var speed: Double
    @Binding var colorMode: Int

    @Environment(\.dismiss) private var dismiss

    private let areaLabels = ["25%", "50%", "75%", "100%"]
    private let areaValues: [Double] = [0.25, 0.5, 0.75, 1.0]
    private let speedLabels = ["0.5x 慢", "0.75x", "1.0x 正常", "1.5x", "2.0x 快"]
    private let speedValues: [Double] = [0.5, 0.75, 1.0, 1.5, 2.0]
    private let colorLabels = ["原始", "白色", "黄色", "绿色", "蓝色", "红色", "粉色"]
    private let colorValues: [Int] = [0, 1, 2, 3, 4, 5, 6]

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

                Section("弹幕显示区域") {
                    Picker("显示区域", selection: $area) {
                        ForEach(Array(areaValues.enumerated()), id: \.offset) { idx, val in
                            Text(areaLabels[idx]).tag(val)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("弹幕显示速度") {
                    Picker("显示速度", selection: $speed) {
                        ForEach(Array(speedValues.enumerated()), id: \.offset) { idx, val in
                            Text(speedLabels[idx]).tag(val)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("弹幕颜色") {
                    Picker("颜色", selection: $colorMode) {
                        ForEach(Array(colorValues.enumerated()), id: \.offset) { idx, val in
                            Text(colorLabels[idx]).tag(val)
                        }
                    }
                    .pickerStyle(.segmented)
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

// MARK: - AirPlay 视图

// MARK: - 播放设置视图
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

// MARK: - 选集选择视图
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

// MARK: - 清晰度选择视图
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

// MARK: - 小巧居中弹窗容器（用于选集/倍数）
struct SmallPopupView<Content: View>: View {
    @Binding var isPresented: Bool
    let content: Content

    init(isPresented: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self._isPresented = isPresented
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isPresented {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isPresented = false
                            }
                        }

                    content
                        .frame(width: min(geometry.size.width * 0.5, 300), height: min(geometry.size.height * 0.55, 420))
                        .background(Color(uiColor: .secondarySystemBackground))
                        .cornerRadius(10)
                        .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isPresented)
        }
    }
}

// MARK: - 侧边栏弹窗容器（用于其他设置）
struct SidePanelView<Content: View>: View {
    @Binding var isPresented: Bool
    let title: String
    let content: Content

    init(isPresented: Binding<Bool>, title: String, @ViewBuilder content: () -> Content) {
        self._isPresented = isPresented
        self.title = title
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isPresented {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isPresented = false
                            }
                        }

                    HStack {
                        Spacer()

                        VStack(spacing: 0) {
                            HStack {
                                Text(title)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)

                                Spacer()

                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        isPresented = false
                                    }
                                }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundColor(.white)
                                        .frame(width: 36, height: 36)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color.black.opacity(0.9))

                            content
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(hex: "1A1A1A"))
                        }
                        .frame(width: geometry.size.width * 0.45)
                        .background(Color(hex: "1A1A1A"))
                        .cornerRadius(12, corners: [.topLeft, .bottomLeft])
                        .transition(.move(edge: .trailing))
                    }
                    .ignoresSafeArea()
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isPresented)
        }
    }
}

// MARK: - 播放设置面板 (竖屏：从按钮上方弹出的紧凑列表)
struct PlayerSettingsPanelV2: View {
    @Binding var isPresented: Bool
    @Binding var speed: Double
    var isPortrait: Bool = true
    var onSpeedChange: (Double) -> Void
    @EnvironmentObject private var settings: AppSettings

    let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    /// 自适应皮肤的面板背景色
    private var panelBackground: Color {
        if settings.usesLiquidSkin {
            return Color(hex: "1A1A2E").opacity(0.88)
        } else if settings.usesFrostedSkin {
            return Color(uiColor: .secondarySystemBackground).opacity(0.92)
        }
        return Color.black.opacity(0.8)
    }

    /// 自适应皮肤的文字颜色
    private var textPrimary: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .label)
        }
        return .white.opacity(0.85)
    }

    private var textSecondary: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .secondaryLabel)
        }
        return .white.opacity(0.5)
    }

    var body: some View {
        if isPortrait {
            // 竖屏：垂直列表
            portraitLayout
        } else {
            // 横屏：水平一行排列
            landscapeLayout
        }
    }

    // MARK: - 竖屏布局（垂直列表）
    private var portraitLayout: some View {
        VStack(spacing: 0) {
            ForEach(speeds, id: \.self) { s in
                Button(action: {
                    speed = s
                    onSpeedChange(s)
                    isPresented = false
                }) {
                    HStack {
                        let speedText = s == floor(s) ? String(format: "%.0f", s) : String(format: "%.2f", s)
                        Text(speedText + "x")
                            .font(.system(size: 14, weight: speed == s ? .semibold : .regular))
                            .foregroundColor(speed == s ? Color(hex: "2196F3") : textPrimary)
                        Spacer()
                        if speed == s {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Color(hex: "2196F3"))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(
                        speed == s ? Color(hex: "2196F3").opacity(0.15) : Color.clear
                    )
                }
                .buttonStyle(PlainButtonStyle())

                if s != speeds.last {
                    Divider()
                        .background(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.1))
                        .padding(.leading, 16)
                }
            }
        }
        .background(panelBackground)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 4)
    }

    // MARK: - 横屏布局（小竖条，同竖屏垂直列表但更紧凑）
    private var landscapeLayout: some View {
        VStack(spacing: 0) {
            ForEach(speeds, id: \.self) { s in
                Button(action: {
                    speed = s
                    onSpeedChange(s)
                    isPresented = false
                }) {
                    HStack {
                        let speedText = s == floor(s) ? String(format: "%.0f", s) : String(format: "%.2f", s)
                        Text(speedText + "x")
                            .font(.system(size: 12, weight: speed == s ? .semibold : .regular))
                            .foregroundColor(speed == s ? Color(hex: "2196F3") : textPrimary)
                        Spacer()
                        if speed == s {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Color(hex: "2196F3"))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        speed == s ? Color(hex: "2196F3").opacity(0.15) : Color.clear
                    )
                }
                .buttonStyle(PlainButtonStyle())

                if s != speeds.last {
                    Divider()
                        .background(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.1))
                        .padding(.leading, 10)
                }
            }
        }
        .frame(width: 90)
        .background(panelBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 2)
    }
}

// MARK: - 选集面板 (侧边栏版本)

// MARK: - 清晰度面板 (侧边栏版本)
struct QualityPickerPanelV2: View {
    @Binding var selectedQuality: Int
    var isBaiduSourceMode: Bool = false
    var isPortrait: Bool = true
    var onQualityChange: (Int) -> Void
    @EnvironmentObject private var settings: AppSettings

    private var qualities: [String] {
        isBaiduSourceMode ? ["原画"] : ["标清", "高清", "蓝光"]
    }

    /// 自适应皮肤颜色
    private var textPrimary: Color {
        if settings.usesFrostedSkin { return Color(uiColor: .label) }
        return .white.opacity(0.85)
    }
    private var selectedColor: Color { Color(hex: "00BEFF") }
    private var unselectedBg: Color {
        if settings.usesFrostedSkin { return Color(uiColor: .tertiarySystemBackground) }
        return Color.white.opacity(0.15)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<qualities.count, id: \.self) { index in
                Button(action: {
                    selectedQuality = index
                    onQualityChange(index)
                }) {
                    HStack {
                        Text(qualities[index])
                            .font(.system(size: isPortrait ? 16 : 13, weight: selectedQuality == index ? .semibold : .regular))
                            .foregroundColor(selectedQuality == index ? selectedColor : textPrimary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer()
                        if selectedQuality == index {
                            Image(systemName: "checkmark")
                                .font(.system(size: isPortrait ? 14 : 11, weight: .semibold))
                                .foregroundColor(selectedColor)
                        }
                    }
                    .padding(.horizontal, isPortrait ? 16 : 10)
                    .padding(.vertical, isPortrait ? 16 : 10)
                    .background(
                        selectedQuality == index ? selectedColor.opacity(0.15) : Color.clear
                    )
                }
                .buttonStyle(PlainButtonStyle())

                if index != qualities.count - 1 {
                    Divider()
                        .background(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.1))
                        .padding(.leading, isPortrait ? 16 : 10)
                }
            }
        }
    }
}

// MARK: - 播放内核面板 (侧边栏版本)
struct EnginePickerPanelV2: View {
    @ObservedObject var playerState: PlayerState
    var isPortrait: Bool = true
    @EnvironmentObject private var settings: AppSettings

    /// 自适应皮肤颜色
    private var textPrimary: Color {
        if settings.usesFrostedSkin { return Color(uiColor: .label) }
        return .white.opacity(0.85)
    }
    private var selectedColor: Color { Color(hex: "00BEFF") }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(PlayerState.PlaybackEnginePreference.allCases) { engine in
                    Button(action: {
                        playerState.selectPlaybackEngine(engine)
                    }) {
                        HStack {
                            Text(engine.rawValue)
                                .font(.system(size: isPortrait ? 16 : 13, weight: playerState.enginePreference == engine ? .semibold : .regular))
                                .foregroundColor(playerState.enginePreference == engine ? selectedColor : textPrimary)
                            Spacer()
                            // PiP 支持状态标注（仅竖屏显示，横屏弹窗宽度有限不展示）
                            if isPortrait {
                                if engine == .vlc {
                                    Text("无画中画")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.4))
                                } else if engine == .mpv || engine == .ali {
                                    Text("画中画")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(hex: "00BEFF").opacity(0.7))
                                }
                            }
                            if playerState.enginePreference == engine {
                                Image(systemName: "checkmark")
                                    .font(.system(size: isPortrait ? 14 : 11, weight: .semibold))
                                    .foregroundColor(selectedColor)
                            }
                        }
                        .background(
                            playerState.enginePreference == engine ? selectedColor.opacity(0.15) : Color.clear
                        )
                        .padding(.horizontal, isPortrait ? 16 : 12)
                        .padding(.vertical, isPortrait ? 14 : 10)
                    }
                    .buttonStyle(PlainButtonStyle())

                    if engine != PlayerState.PlaybackEnginePreference.allCases.last {
                        Divider()
                            .background(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.1))
                            .padding(.horizontal, isPortrait ? 16 : 12)
                    }
                }
            }
        }
    }
}

// MARK: - 弹幕设置面板 (侧边栏版本)
struct DanmakuSettingsPanelV2: View {
    @Binding var showDanmaku: Bool
    @Binding var opacity: Double
    @Binding var fontSize: CGFloat
    @Binding var area: Double
    @Binding var speed: Double
    @Binding var colorMode: Int
    var isPortrait: Bool = true
    @EnvironmentObject private var settings: AppSettings

    private let areaOptions: [(Double, String)] = [
        (0.25, "25%"),
        (0.5, "50%"),
        (0.75, "75%"),
        (1.0, "100%")
    ]
    private let speedOptions: [(Double, String)] = [
        (0.5, "0.5x"),
        (0.75, "0.75x"),
        (1.0, "1.0x"),
        (1.5, "1.5x"),
        (2.0, "2.0x")
    ]
    private let colorOptions: [(mode: Int, color: Int, label: String)] = [
        (0, 16777215, "原始"),
        (1, 16777215, "白色"),
        (2, 16776960, "黄色"),
        (3, 65280,    "绿色"),
        (4, 255,      "蓝色"),
        (5, 16711680, "红色"),
        (6, 16761035, "粉色")
    ]

    /// 自适应皮肤的面板背景色
    private var panelBackground: Color {
        if settings.usesLiquidSkin {
            return Color(hex: "1A1A2E").opacity(0.88)
        } else if settings.usesFrostedSkin {
            return Color(uiColor: .secondarySystemBackground).opacity(0.92)
        }
        return Color.black.opacity(0.8)
    }

    /// 自适应皮肤的文字颜色
    private var textPrimary: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .label)
        }
        return .white.opacity(0.85)
    }

    private var textSecondary: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .secondaryLabel)
        }
        return .white.opacity(0.5)
    }

    /// 选中状态颜色
    private var selectedColor: Color {
        Color(hex: "00BEFF")
    }

    /// 未选中按钮背景
    private var unselectedBackground: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .tertiarySystemBackground)
        }
        return Color.white.opacity(0.15)
    }

    var body: some View {
        ScrollView(showsIndicators: true) {
            VStack(spacing: isPortrait ? 24 : 16) {
                // 开启弹幕开关
                HStack {
                    Text("开启弹幕")
                        .font(.system(size: isPortrait ? 16 : 14))
                        .foregroundColor(textPrimary)

                    Spacer()

                    Toggle("弹幕", isOn: $showDanmaku)
                        .labelsHidden()
                        .tint(selectedColor)
                }
                .padding(.horizontal, isPortrait ? 16 : 12)
                .padding(.top, isPortrait ? 16 : 12)

                // 透明度滑块
                VStack(spacing: 6) {
                    HStack {
                        Text("弹幕透明度")
                            .font(.system(size: isPortrait ? 16 : 14))
                            .foregroundColor(textPrimary)
                        Spacer()
                        Text("\(Int(opacity * 100))%")
                            .font(.system(size: isPortrait ? 14 : 12))
                            .foregroundColor(textSecondary)
                    }
                    .padding(.horizontal, isPortrait ? 16 : 12)

                    Slider(value: $opacity, in: 0...1, step: 0.1)
                        .padding(.horizontal, isPortrait ? 16 : 12)
                        .tint(selectedColor)
                }

                // 字体大小滑块
                VStack(spacing: 6) {
                    HStack {
                        Text("弹幕字体大小")
                            .font(.system(size: isPortrait ? 16 : 14))
                            .foregroundColor(textPrimary)
                        Spacer()
                        Text("\(Int(fontSize))px")
                            .font(.system(size: isPortrait ? 14 : 12))
                            .foregroundColor(textSecondary)
                    }
                    .padding(.horizontal, isPortrait ? 16 : 12)

                    Slider(value: $fontSize, in: 12...24, step: 1)
                        .padding(.horizontal, isPortrait ? 16 : 12)
                        .tint(selectedColor)
                }

                // 显示区域选项
                VStack(spacing: 6) {
                    HStack {
                        Text("弹幕显示区域")
                            .font(.system(size: isPortrait ? 16 : 14))
                            .foregroundColor(textPrimary)
                        Spacer()
                        Text(areaOptions.first(where: { $0.0 == area })?.1 ?? "\(Int(area * 100))%")
                            .font(.system(size: isPortrait ? 14 : 12))
                            .foregroundColor(textSecondary)
                    }
                    .padding(.horizontal, isPortrait ? 16 : 12)

                    HStack(spacing: isPortrait ? 0 : 4) {
                        ForEach(areaOptions, id: \.0) { option in
                            Button {
                                area = option.0
                            } label: {
                                Text(option.1)
                                    .font(.system(size: isPortrait ? 13 : 11))
                                    .foregroundColor(area == option.0 ? .white : textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, isPortrait ? 8 : 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(area == option.0 ? selectedColor : unselectedBackground)
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, isPortrait ? 16 : 12)
                }

                // 速度选项
                VStack(spacing: 6) {
                    HStack {
                        Text("弹幕显示速度")
                            .font(.system(size: isPortrait ? 16 : 14))
                            .foregroundColor(textPrimary)
                        Spacer()
                        Text(speedOptions.first(where: { $0.0 == speed })?.1 ?? "\(speed)x")
                            .font(.system(size: isPortrait ? 14 : 12))
                            .foregroundColor(textSecondary)
                    }
                    .padding(.horizontal, isPortrait ? 16 : 12)

                    HStack(spacing: isPortrait ? 0 : 4) {
                        ForEach(speedOptions, id: \.0) { option in
                            Button {
                                speed = option.0
                            } label: {
                                Text(option.1)
                                    .font(.system(size: isPortrait ? 12 : 11))
                                    .foregroundColor(speed == option.0 ? .white : textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, isPortrait ? 8 : 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(speed == option.0 ? selectedColor : unselectedBackground)
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, isPortrait ? 16 : 12)
                }

                // 颜色选项
                VStack(spacing: 6) {
                    HStack {
                        Text("弹幕颜色")
                            .font(.system(size: isPortrait ? 16 : 14))
                            .foregroundColor(textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, isPortrait ? 16 : 12)

                    // 颜色圆圈 - 横屏时改为2行或缩小
                    if isPortrait {
                        HStack(spacing: 10) {
                            ForEach(Array(colorOptions.enumerated()), id: \.offset) { _, option in
                                colorButton(option: option)
                            }
                        }
                        .padding(.horizontal, 16)

                        HStack(spacing: 0) {
                            ForEach(Array(colorOptions.enumerated()), id: \.offset) { _, option in
                                Button {
                                    colorMode = option.mode
                                } label: {
                                    Text(option.label)
                                        .font(.system(size: 11))
                                        .foregroundColor(colorMode == option.mode ? textPrimary : textSecondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 4)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                    } else {
                        // 横屏：颜色选项改为紧凑布局
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                            ForEach(Array(colorOptions.enumerated()), id: \.offset) { _, option in
                                Button {
                                    colorMode = option.mode
                                } label: {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(Color(hexRGB: option.color))
                                            .frame(width: 16, height: 16)
                                        Text(option.label)
                                            .font(.system(size: 11))
                                            .foregroundColor(colorMode == option.mode ? textPrimary : textSecondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(colorMode == option.mode ? selectedColor.opacity(0.2) : unselectedBackground)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(colorMode == option.mode ? selectedColor : Color.clear, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }

                Spacer(minLength: 20)
            }
        }
    }

    @ViewBuilder
    private func colorButton(option: (mode: Int, color: Int, label: String)) -> some View {
        Button {
            colorMode = option.mode
        } label: {
            Circle()
                .fill(Color(hexRGB: option.color))
                .frame(width: 28, height: 28)
                .overlay(
                    Circle()
                        .stroke(colorMode == option.mode ? selectedColor : Color.white.opacity(0.3), lineWidth: colorMode == option.mode ? 3 : 1)
                )
                .overlay(
                    Group {
                        if colorMode == option.mode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - View Extension for Corner Radius
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}
