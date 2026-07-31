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

    var isPiPEnabled: Bool { pipEnabled }

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
    }

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
            DispatchQueue.main.async {
                MDKPipManager.shared.enqueueFrame(pb, presentationTime: pts)
            }
        }
        cmdBuffer.commit()
    }

    deinit {
        pipTexture = nil
        renderTexture = nil
        pipPixelBuffer = nil
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
              let renderTex = renderTexture,
              let player = player else { return }

        renderLock.lock()
        defer { renderLock.unlock() }

        // 先让 MDK 把当前视频帧渲染到离屏纹理；返回值 < 0 表示尚无可用帧
        let pts = player.renderVideo(vid: nil)
        guard pts >= 0 else { return }

        guard let cmdBuffer = queue.makeCommandBuffer(),
              let blit = cmdBuffer.makeBlitCommandEncoder() else { return }

        // 拷贝到屏幕 drawable
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
