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
/// 2. setRenderCallback 在 MDK 解码线程触发：调用 renderVideo() 更新 renderTexture，
///    若启用 PiP 则把 renderTexture blit 到 PiP 纹理，最后 dispatch main 调用 setNeedsDisplay()。
/// 3. MTKView 的 draw(in:) 只在主线程把 renderTexture blit 到 currentDrawable。
///    无可用帧时不会触发 draw，保持 clearColor（黑色）。
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

        // callback 在 MDK 解码线程触发：先 renderVideo 更新 renderTexture，
        // 再捕获 PiP 帧，最后通知主线程刷新。这样即使 MTKView 进入后台不 draw，
        // PiP 仍能源源不断拿到新帧。
        player.setRenderCallback { [weak self] in
            self?.renderFrame()
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

    // MARK: - 帧渲染与 PiP 捕获

    #if canImport(swift_mdk)
    /// 由 MDK render callback 调用：解码线程中完成 renderVideo + PiP 捕获，再通知 UI 刷新。
    private func renderFrame() {
        guard let player = player, let queue = commandQueue else { return }

        renderLock.lock()
        defer { renderLock.unlock() }

        guard renderTexture != nil else { return }

        let pts = player.renderVideo(vid: nil)
        guard pts >= 0 else { return }

        // PiP 捕获：后台播放时 MTKView 不 draw，必须在这里持续推帧
        if pipEnabled {
            capturePiPFrameLocked(queue: queue)
        }

        DispatchQueue.main.async { [weak self] in
            self?.setNeedsDisplay()
        }
    }
    #endif

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
              let renderTex = renderTexture else { return }

        renderLock.lock()
        defer { renderLock.unlock() }

        // renderVideo 已在 render callback 中调用，这里只做屏幕呈现
        guard let cmdBuffer = queue.makeCommandBuffer(),
              let blit = cmdBuffer.makeBlitCommandEncoder() else { return }

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
    }
}
