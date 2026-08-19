import UIKit
import Metal
import MetalKit
import CoreVideo
import AVFoundation

#if canImport(swift_mdk)
import swift_mdk
#endif
#if canImport(mdk)
import mdk
#endif

// MARK: - 桥接辅助（与 swift-mdk 内部 bridge 一致）

private func bridge<T: AnyObject>(_ obj: T?) -> UnsafeRawPointer? {
    guard let obj = obj else { return nil }
    return UnsafeRawPointer(Unmanaged.passUnretained(obj).toOpaque())
}

private func bridge<T: AnyObject>(ptr: UnsafeRawPointer) -> T {
    return Unmanaged<T>.fromOpaque(ptr).takeUnretainedValue()
}

// MARK: - MDK Metal 渲染视图

/// 专用于 MDK 的 MTKView 子类。
///
/// 渲染管线：
/// 1. MDK 通过 setRenderAPI 渲染到一个离屏 MTLTexture（renderTexture）。
/// 2. setRenderCallback 触发时：
///    - 若启用 PiP：先在后台解码线程 renderVideo() 并捕获 PiP 帧，再通知主线程刷新；
///    - 若未启用 PiP：只通知 MTKView 需要刷新（setNeedsDisplay）。
/// 3. MTKView 的 draw(in:) 中先调用 renderVideo() 把当前帧写到 renderTexture，
///    再把它 blit 到 currentDrawable；若启用 PiP，同时 blit 到 PiP 纹理。
///    无可用帧时直接显示 clearColor（黑色），避免把未初始化的脏纹理呈现给用户。
final class MDKRenderView: MTKView {

    #if canImport(swift_mdk)
    weak var player: Player?
    #endif

    private var commandQueue: MTLCommandQueue?

    /// 离屏渲染目标（MDK 直接渲染到这里）
    private var renderTexture: MTLTexture?

    /// PiP 输出 CVPixelBuffer
    private var pipPixelBuffer: CVPixelBuffer?
    /// PiP 输出纹理（与 pipPixelBuffer 共享 IOSurface）
    private var pipTexture: MTLTexture?

    private let renderLock = NSLock()
    private var pipEnabled = false
    private var hasSetupRenderAPI = false
    private var currentSize: CGSize = .zero

    /// 加载新资源时的安全标记，期间强制清黑屏，防止旧解码器脏帧被 blit 到屏幕导致紫屏
    private var isReloading = false

    /// 当前画面拉伸模式（默认 .aspectFill，attach 时会从 PlayerState 同步真实值）
    private var videoGravity: PlayerState.VideoGravityMode = .aspectFill
    private var gravityObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    /// 视频原始尺寸（由 MDKPlayerEngine.pollProgress 更新），用于计算 setAspectRatio 参数
    private var videoWidth: Int = 0
    private var videoHeight: Int = 0

    var isPiPEnabled: Bool { pipEnabled }

    /// 标记进入加载过渡期（由 MDKPlayerEngine.load 调用）。
    /// 期间 draw(in:) 强制清黑屏，防止 renderTexture 中的旧解码器脏帧呈现为紫屏。
    func markReloading() {
        isReloading = true
        // 清空 renderTexture 内容为黑色，防止旧帧残留
        clearRenderTextureToBlack()
        // 同步清空当前 drawable，不等待 async dispatch
        if let drawable = currentDrawable, let queue = commandQueue {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = drawable.texture
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rpd.colorAttachments[0].storeAction = .store
            if let cmdBuffer = queue.makeCommandBuffer(),
               let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                encoder.endEncoding()
                cmdBuffer.present(drawable)
                cmdBuffer.commit()
            }
        }
    }

    /// 清空 renderTexture 为纯黑，防止旧帧残留导致紫屏
    private func clearRenderTextureToBlack() {
        guard let tex = renderTexture, let queue = commandQueue else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        if let cmdBuffer = queue.makeCommandBuffer(),
           let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: rpd) {
            encoder.endEncoding()
            cmdBuffer.commit()
        }
    }

    /// 标记加载完成，新首帧已到达（由 MDKPlayerEngine 的 .Playing 回调调用）
    func markReloadComplete() {
        isReloading = false
    }

    init(frame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            // 极老设备不支持 Metal，回退到普通 UIView
            super.init(frame: frame, device: nil)
            return
        }
        super.init(frame: frame, device: device)
        configure()
    }

    required init(coder: NSCoder) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            super.init(coder: coder)
            return
        }
        super.init(coder: coder)
        self.device = device
        configure()
    }

    private func configure() {
        // iOS Metal drawable 原生格式是 BGRA
        // MDK 渲染器适配 colorPixelFormat，使用 bgra8Unorm 避免通道错位导致画面偏紫
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false          // 需要读取/拷贝
        autoResizeDrawable = true
        enableSetNeedsDisplay = true
        isPaused = true                  // 由 MDK render callback 驱动刷新，避免 DisplayLink 把未初始化的纹理反复 blit 到屏幕
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        delegate = self

        // 监听画面拉伸模式变化
        gravityObserver = NotificationCenter.default.addObserver(
            forName: .vboxVideoGravityChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let mode = note.userInfo?["mode"] as? PlayerState.VideoGravityMode else { return }
            self?.videoGravity = mode
            self?.applyGravityToPlayer()
            self?.setNeedsDisplay()
        }

        // 回到前台时强制重绘，修复 PiP 返回后画面卡住
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setNeedsDisplay()
        }
    }

    deinit {
        if let observer = gravityObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        pipTexture = nil
        renderTexture = nil
        pipPixelBuffer = nil
    }

    /// 同步当前画面拉伸模式（由 MDKPlayerEngine.attach 调用）
    func syncVideoGravity(_ mode: PlayerState.VideoGravityMode) {
        videoGravity = mode
        applyGravityToPlayer()
        setNeedsDisplay()
    }

    /// 更新视频原始尺寸（由 MDKPlayerEngine.pollProgress 调用）
    func updateVideoSize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        guard width != videoWidth || height != videoHeight else { return }
        videoWidth = width
        videoHeight = height
        // 视频尺寸变化后需要重新应用 gravity 模式
        applyGravityToPlayer()
    }

    /// 通过 MDK 原生 setAspectRatio API 控制画面拉伸。
    /// renderTexture 与 drawable 尺寸一致，MDK 在纹理内部完成宽高比适配，
    /// 因此 draw() 只需简单 blit，不需要 Metal shader 管线。
    #if canImport(swift_mdk)
    private func applyGravityToPlayer() {
        guard let player = player else { return }
        switch videoGravity {
        case .resize:
            // 拉伸：忽略宽高比，填满整个纹理
            player.setAspectRatio(0)
        case .aspectFit:
            // 适应：保持宽高比，留黑边
            // value > 0 = frame expand inside viewport
            if videoWidth > 0 && videoHeight > 0 {
                let ar = Float(videoWidth) / Float(videoHeight)
                player.setAspectRatio(ar)
            }
        case .aspectFill:
            // 填充：保持宽高比，裁剪超出部分
            // value < 0 = frame expand outside and crop
            if videoWidth > 0 && videoHeight > 0 {
                let ar = Float(videoWidth) / Float(videoHeight)
                player.setAspectRatio(-ar)
            }
        }
        print("[MDK] setAspectRatio: \(videoGravity.rawValue), video=\(videoWidth)x\(videoHeight)")
    }
    #else
    private func applyGravityToPlayer() {}
    #endif

    #if canImport(swift_mdk)
    func attach(player: Player) {
        self.player = player
        guard device != nil else { return }

        commandQueue = device?.makeCommandQueue()
        guard commandQueue != nil else { return }

        // 关键顺序：先确保有 renderTexture，再 setRenderAPI，最后 setVideoSurfaceSize。
        // 若此时 view 还未布局（bounds == 0），则推迟到 layoutSubviews 中完成。
        if bounds.width > 0, bounds.height > 0 {
            let size = drawableSizeForBounds()
            recreateRenderTexture(size: size)
            setupRenderAPIIfNeeded()
            player.setVideoSurfaceSize(CGFloat(size.width), CGFloat(size.height))
        }

        // callback 负责通知刷新；PiP 启用时还要在后台解码线程持续捕获 PiP 帧，
        // 因为进入后台后 MTKView 不再 draw，必须在这里推帧。
        player.setRenderCallback { [weak self] in
            guard let self else { return }
            // 加载过渡期：回调触发意味着新帧已渲染到纹理，解除加载标记
            if self.isReloading {
                DispatchQueue.main.async { [weak self] in
                    self?.isReloading = false
                    self?.setNeedsDisplay()
                }
            }
            if self.pipEnabled {
                self.capturePiPFrameInCallback()
            }
            DispatchQueue.main.async { [weak self] in
                self?.setNeedsDisplay()
            }
        }
    }
    #endif

    func setPiPEnabled(_ enabled: Bool) {
        pipEnabled = enabled
    }

    // MARK: - 尺寸变化

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSurfaceSize()
    }

    private func drawableSizeForBounds() -> CGSize {
        guard bounds.width > 0, bounds.height > 0 else { return currentSize }
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        return CGSize(width: max(1, Int(bounds.width * scale)),
                      height: max(1, Int(bounds.height * scale)))
    }

    private func updateSurfaceSize() {
        guard let player = player, bounds.width > 0, bounds.height > 0 else { return }
        let newSize = drawableSizeForBounds()
        guard newSize != currentSize, newSize.width > 0, newSize.height > 0 else { return }
        currentSize = newSize

        recreateRenderTexture(size: newSize)

        // 确保 MDK 已经拿到 device/queue/texture；纹理重建后也要把新 texture 指针交给 MDK
        #if canImport(swift_mdk)
        setupRenderAPIIfNeeded()
        if let tex = renderTexture, let device = device, let queue = commandQueue {
            var ra = mdkMetalRenderAPI()
            ra.type = MDK_RenderAPI_Metal
            ra.device = bridge(device)!
            ra.cmdQueue = bridge(queue)!
            ra.texture = bridge(tex)!
            player.setRenderAPI(&ra, vid: nil)
        }
        #endif

        // 在 render API 就绪后再设置 surface size，确保 callback 被触发
        player.setVideoSurfaceSize(CGFloat(newSize.width), CGFloat(newSize.height))
    }

    // MARK: - 渲染目标设置

    #if canImport(swift_mdk)
    private func setupRenderAPIIfNeeded() {
        guard !hasSetupRenderAPI, let player = player, let device = device, let queue = commandQueue else { return }
        guard let tex = renderTexture else { return }
        hasSetupRenderAPI = true

        var ra = mdkMetalRenderAPI()
        ra.type = MDK_RenderAPI_Metal
        ra.device = bridge(device)!
        ra.cmdQueue = bridge(queue)!
        ra.texture = bridge(tex)!
        // Render To Texture 模式：MDK 自己管理渲染通道，直接渲染到 ra.texture
        // 不需要 currentRenderTarget 回调，也不需要 layer
        player.setRenderAPI(&ra, vid: nil)
    }
    #endif

    private func recreateRenderTexture(size: CGSize) {
        guard let device = device else { return }
        let width = Int(size.width)
        let height = Int(size.height)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        #if os(iOS)
        desc.storageMode = .private
        #else
        desc.storageMode = .managed
        #endif
        renderTexture = device.makeTexture(descriptor: desc)
    }

    // MARK: - PiP 纹理

    private func ensurePiPTextures(width: Int, height: Int) -> Bool {
        guard let device = device else { return false }
        if let pb = pipPixelBuffer,
           CVPixelBufferGetWidth(pb) == width,
           CVPixelBufferGetHeight(pb) == height {
            return true
        }

        pipTexture = nil
        pipPixelBuffer = nil

        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else {
            print("[MDKRenderView] CVPixelBuffer 创建失败：\(status)")
            return false
        }
        pipPixelBuffer = pb

        guard let iosurface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else {
            print("[MDKRenderView] IOSurface 获取失败")
            return false
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        #if os(iOS)
        desc.storageMode = .shared
        #else
        desc.storageMode = .managed
        #endif
        pipTexture = device.makeTexture(descriptor: desc, iosurface: iosurface, plane: 0)

        guard pipTexture != nil else {
            print("[MDKRenderView] PiP 纹理创建失败")
            return false
        }

        MDKPipManager.shared.initializePiP(videoSize: CGSize(width: width, height: height))
        return true
    }

    // MARK: - 后台 PiP 捕获

    #if canImport(swift_mdk)
    /// 在 MDK render callback（后台解码线程）中完成 PiP 帧捕获。
    /// 进入桌面小窗后 MTKView 不 draw，必须靠这里持续把视频帧推到 PiP 队列。
    /// 屏幕渲染仍由 draw(in:) 自己调用 renderVideo 负责，避免 callback 单独渲染失败导致洋红。
    /// 使用 tryLock 避免后台线程与主线程 draw() 争锁导致主线程渲染卡顿，
    /// 获取不到锁时跳过本帧（PiP 只需 ~10fps，丢帧不可见）。
    private func capturePiPFrameInCallback() {
        guard let player = player, let queue = commandQueue else { return }

        guard renderLock.try() else { return }
        defer { renderLock.unlock() }

        guard renderTexture != nil else { return }

        let pts = player.renderVideo(vid: nil)
        guard pts >= 0 else { return }

        capturePiPFrameLocked(queue: queue)
    }
    #endif

    /// 把当前 renderTexture 内容 blit 到 PiP 纹理，并在 GPU 完成后入队。
    private func capturePiPFrameLocked(queue: MTLCommandQueue) {
        guard pipEnabled, let renderTex = renderTexture else { return }
        let width = renderTex.width
        let height = renderTex.height
        guard width > 0, height > 0,
              ensurePiPTextures(width: width, height: height),
              let pipTex = pipTexture,
              let pb = pipPixelBuffer else { return }

        guard let cmdBuffer = queue.makeCommandBuffer(),
              let blit = cmdBuffer.makeBlitCommandEncoder() else { return }

        blit.copy(
            from: renderTex,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOriginMake(0, 0, 0),
            sourceSize: MTLSizeMake(width, height, 1),
            to: pipTex,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOriginMake(0, 0, 0)
        )
        blit.endEncoding()

        cmdBuffer.addCompletedHandler { _ in
            let pts = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1000)
            // 直接在回调线程入队，避免后台主线程被挂起导致帧不入队
            MDKPipManager.shared.enqueueFrame(pb, presentationTime: pts)
        }
        cmdBuffer.commit()
    }
}

// MARK: - MTKViewDelegate

extension MDKRenderView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 尺寸变化由 layoutSubviews 处理
    }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let queue = commandQueue,
              let player = player else { return }

        renderLock.lock()
        defer { renderLock.unlock() }

        // 加载过渡期：尝试渲染新帧，只有真正可用时才解除标记并 blit。
        // 防止 renderTexture 中的旧解码器脏帧被呈现为紫屏（品红色 #FF00FF）。
        if isReloading {
            // 主动尝试渲染新帧，只有 pts >= 0（新帧真正可用）时才解除标记
            let reloadPts = player.renderVideo(vid: nil)
            if reloadPts >= 0 {
                // 新帧已到达，解除加载标记，继续执行下方的 blit 逻辑
                isReloading = false
            } else {
                // 新帧尚未到达，清黑屏等待
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = drawable.texture
                rpd.colorAttachments[0].loadAction = .clear
                rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                rpd.colorAttachments[0].storeAction = .store
                if let cmdBuffer = queue.makeCommandBuffer(),
                   let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                    encoder.endEncoding()
                    cmdBuffer.present(drawable)
                    cmdBuffer.commit()
                }
                return
            }
        }

        guard let renderTex = renderTexture else { return }

        // 先让 MDK 把当前视频帧渲染到离屏纹理；返回值 < 0 表示尚无可用帧
        let pts = player.renderVideo(vid: nil)

        if pts < 0 {
            // 无可用帧（切集/加载中）：清空 drawable 为黑色，
            // 避免显示未初始化的脏纹理（红色/洋红）
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = drawable.texture
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rpd.colorAttachments[0].storeAction = .store
            if let cmdBuffer = queue.makeCommandBuffer(),
               let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                encoder.endEncoding()
                cmdBuffer.present(drawable)
                cmdBuffer.commit()
            }
            return
        }

        guard let cmdBuffer = queue.makeCommandBuffer() else { return }

        // MDK 已通过 setAspectRatio 在 renderTexture 内部完成宽高比适配，
        // 直接 blit 到 drawable 即可，不需要 Metal shader 管线
        guard let blit = cmdBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(
            from: renderTex,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOriginMake(0, 0, 0),
            sourceSize: MTLSizeMake(renderTex.width, renderTex.height, 1),
            to: drawable.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOriginMake(0, 0, 0)
        )
        blit.endEncoding()

        cmdBuffer.present(drawable)
        cmdBuffer.commit()

        // 前台 PiP 也在这里捕获（后台 PiP 由 render callback 负责）
        if pipEnabled {
            capturePiPFrameLocked(queue: queue)
        }
    }
}
