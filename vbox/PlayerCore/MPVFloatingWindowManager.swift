import UIKit

#if canImport(Libmpv)

/// MPV 应用内小窗画中画管理器
/// 把 LibmpvMoltenVKPlayerCore.shared 的渲染视图移动到悬浮 UIWindow 上，
/// 实现“软件内小窗口播放视频”。
final class MPVFloatingWindowManager: NSObject {
    static let shared = MPVFloatingWindowManager()
    private override init() {}

    private var floatingWindow: UIWindow?
    private var containerView: UIView?
    private var controlsContainer: UIView?
    private var progressView: UIProgressView?
    private var playPauseButton: UIButton?
    private var displayLink: CADisplayLink?

    private var offscreenWindow: UIWindow?

    private(set) var isFloating = false
    private(set) var isBackgroundPiPActive = false
    private(set) var wasFloatingBeforeBackground = false

    /// 只要还在任何一种画中画里，就不让 Coordinator teardown mpv
    var isKeepingCoreAlive: Bool { isFloating || isBackgroundPiPActive }

    // MARK: - 打开小窗

    func showFloatingWindow() {
        guard !isFloating else { return }

        let core = LibmpvMoltenVKPlayerCore.shared
        guard core.hasActivePlayback, core.videoRenderView.superview != nil else {
            print("[MPVFloating] 没有正在播放的 MPV 视频")
            return
        }

        isFloating = true

        let renderView = core.videoRenderView
        renderView.removeFromSuperview()

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            isFloating = false
            return
        }

        let safe = windowScene.windows.first?.safeAreaInsets ?? .zero
        let width: CGFloat = 200
        let height: CGFloat = 112
        let x = windowScene.screen.bounds.width - width - 16 - safe.right
        let y = safe.top + 16

        let container = UIView(frame: CGRect(x: x, y: y, width: width, height: height))
        container.backgroundColor = .black
        container.layer.cornerRadius = 12
        container.layer.masksToBounds = true
        container.layer.borderWidth = 0.5
        container.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor

        renderView.frame = container.bounds
        renderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(renderView)

        let controls = makeControlsOverlay(in: container)
        container.addSubview(controls)

        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = .statusBar + 1
        window.backgroundColor = .clear
        window.rootViewController = FloatingRootViewController()
        window.rootViewController?.view.addSubview(container)
        window.isHidden = false

        self.floatingWindow = window
        self.containerView = container
        self.controlsContainer = controls

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        container.addGestureRecognizer(pan)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(expandFloatingWindow))
        doubleTap.numberOfTapsRequired = 2
        container.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        tap.require(toFail: doubleTap)
        container.addGestureRecognizer(tap)

        startProgressUpdates()
        updatePlayPauseIcon()

        NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: true)
    }

    // MARK: - 关闭小窗

    func hideFloatingWindow(restoreFullscreen: Bool = false) {
        guard isFloating else { return }
        stopProgressUpdates()

        LibmpvMoltenVKPlayerCore.shared.videoRenderView.removeFromSuperview()

        if restoreFullscreen {
            NotificationCenter.default.post(name: .vboxPiPRestoreFullScreen, object: nil)
        }

        floatingWindow?.isHidden = true
        floatingWindow = nil
        containerView = nil
        controlsContainer = nil
        progressView = nil
        playPauseButton = nil
        isFloating = false

        NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: false)
    }

    // MARK: - 应用内小窗 ↔ 系统画中画切换

    /// 从应用内小窗切换到系统画中画（返回桌面时调用）
    func transitionToSystemPiP() {
        guard isFloating else { return }

        wasFloatingBeforeBackground = true
        isFloating = false
        stopProgressUpdates()

        // 把渲染视图从悬浮窗容器移出来
        let renderView = LibmpvMoltenVKPlayerCore.shared.videoRenderView
        renderView.removeFromSuperview()

        // 隐藏应用内小窗窗口
        floatingWindow?.isHidden = true
        floatingWindow = nil
        containerView = nil
        controlsContainer = nil
        progressView = nil
        playPauseButton = nil

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }

        // 创建离屏窗口，让渲染视图仍在视图层级中，否则截图帧捕获会黑屏
        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = UIWindow.Level(rawValue: -1)
        window.backgroundColor = .clear
        window.isHidden = false
        window.alpha = 0.01
        window.isUserInteractionEnabled = false

        let container = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 640, height: 360)))
        renderView.frame = container.bounds
        renderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(renderView)

        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(container)
        self.offscreenWindow = window

        isBackgroundPiPActive = true
        print("[MPVFloating] 已切换到离屏窗口，准备启动系统画中画")
    }

    /// 回前台时，从系统画中画恢复到应用内小窗
    func restoreFromSystemPiP() {
        guard isBackgroundPiPActive else { return }

        // 销毁离屏窗口，渲染视图重新 detach
        LibmpvMoltenVKPlayerCore.shared.videoRenderView.removeFromSuperview()
        offscreenWindow?.isHidden = true
        offscreenWindow?.rootViewController = nil
        offscreenWindow = nil

        isBackgroundPiPActive = false

        if wasFloatingBeforeBackground {
            // 恢复应用内小窗
            wasFloatingBeforeBackground = false
            showFloatingWindow()
        } else {
            // 之前不是小窗状态，触发恢复全屏通知
            NotificationCenter.default.post(name: .vboxPiPRestoreFullScreen, object: nil)
        }
    }

    // MARK: - 控制层

    private func makeControlsOverlay(in container: UIView) -> UIView {
        let overlay = UIView(frame: container.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isUserInteractionEnabled = true
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.001) // 接收点击，几乎透明

        // 关闭
        let close = makeButton(image: "xmark", target: self, action: #selector(closeFloatingWindow))
        close.frame = CGRect(x: 8, y: 8, width: 28, height: 28)
        overlay.addSubview(close)

        // 展开
        let expand = makeButton(image: "arrow.up.left.and.arrow.down.right", target: self, action: #selector(expandFloatingWindow))
        expand.frame = CGRect(x: container.bounds.width - 36, y: 8, width: 28, height: 28)
        expand.autoresizingMask = [.flexibleLeftMargin]
        overlay.addSubview(expand)

        // 底部控制
        let bottomY = container.bounds.height - 40
        let bw: CGFloat = 36
        let spacing: CGFloat = 8
        let totalWidth = bw * 3 + spacing * 2
        let startX = (container.bounds.width - totalWidth) / 2

        let backward = makeButton(image: "gobackward.10", target: self, action: #selector(skipBackward))
        backward.frame = CGRect(x: startX, y: bottomY, width: bw, height: bw)
        overlay.addSubview(backward)

        let play = makeButton(image: "pause.fill", target: self, action: #selector(togglePlayPause))
        play.frame = CGRect(x: startX + bw + spacing, y: bottomY, width: bw, height: bw)
        overlay.addSubview(play)
        self.playPauseButton = play

        let forward = makeButton(image: "goforward.10", target: self, action: #selector(skipForward))
        forward.frame = CGRect(x: startX + (bw + spacing) * 2, y: bottomY, width: bw, height: bw)
        overlay.addSubview(forward)

        let progress = UIProgressView(progressViewStyle: .bar)
        progress.progressTintColor = .white
        progress.trackTintColor = UIColor.white.withAlphaComponent(0.3)
        progress.frame = CGRect(x: 8, y: container.bounds.height - 6, width: container.bounds.width - 16, height: 2)
        progress.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        overlay.addSubview(progress)
        self.progressView = progress

        return overlay
    }

    private func makeButton(image: String, target: Any, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setImage(UIImage(systemName: image), for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        btn.layer.cornerRadius = 6
        btn.clipsToBounds = true
        btn.addTarget(target, action: action, for: .touchUpInside)
        return btn
    }

    // MARK: - 动作

    @objc private func closeFloatingWindow() {
        hideFloatingWindow(restoreFullscreen: false)
        LibmpvMoltenVKPlayerCore.shared.stop()
        LibmpvMoltenVKPlayerCore.shared.teardown()
    }

    @objc private func expandFloatingWindow() {
        hideFloatingWindow(restoreFullscreen: true)
    }

    @objc private func togglePlayPause() {
        LibmpvMoltenVKPlayerCore.shared.togglePause()
        updatePlayPauseIcon()
    }

    @objc private func skipBackward() {
        LibmpvMoltenVKPlayerCore.shared.seekRelative(seconds: -10)
    }

    @objc private func skipForward() {
        LibmpvMoltenVKPlayerCore.shared.seekRelative(seconds: 10)
    }

    @objc private func toggleControls() {
        guard let controls = controlsContainer else { return }
        controls.isHidden = !controls.isHidden
    }

    private func updatePlayPauseIcon() {
        let isPlaying = LibmpvMoltenVKPlayerCore.shared.currentState.isPlaying
        let name = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton?.setImage(UIImage(systemName: name), for: .normal)
    }

    // MARK: - 进度刷新

    private func startProgressUpdates() {
        displayLink = CADisplayLink(target: self, selector: #selector(updateProgress))
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopProgressUpdates() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func updateProgress() {
        let state = LibmpvMoltenVKPlayerCore.shared.currentState
        guard state.duration > 0 else { return }
        progressView?.setProgress(Float(state.currentTime / state.duration), animated: false)
        updatePlayPauseIcon()
    }

    // MARK: - 拖拽 & 贴边

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let container = containerView else { return }
        let translation = gesture.translation(in: container.superview)
        var center = container.center
        center.x += translation.x
        center.y += translation.y
        container.center = center
        gesture.setTranslation(.zero, in: container.superview)

        if gesture.state == .ended {
            snapToEdge()
        }
    }

    private func snapToEdge() {
        guard let container = containerView,
              let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let bounds = windowScene.screen.bounds
        let safe = windowScene.windows.first?.safeAreaInsets ?? .zero
        let halfW = container.frame.width / 2
        let halfH = container.frame.height / 2
        var center = container.center

        center.x = max(halfW + safe.left, min(bounds.width - halfW - safe.right, center.x))
        center.y = max(halfH + safe.top, min(bounds.height - halfH - safe.bottom, center.y))

        let leftDist = center.x - halfW - safe.left
        let rightDist = bounds.width - halfW - safe.right - center.x
        center.x = (leftDist < rightDist) ? (halfW + safe.left) : (bounds.width - halfW - safe.right)

        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut, animations: {
            container.center = center
        })
    }
}

private class FloatingRootViewController: UIViewController {
    override var prefersStatusBarHidden: Bool { false }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { [] }
}

#endif
