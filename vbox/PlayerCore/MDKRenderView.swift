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

private func bridge<T: AnyObject>(_ obj: T?) -> UnsafeMutableRawPointer? {
    guard let obj = obj else { return nil }
    return UnsafeMutableRawPointer(Unmanaged.passUnretained(obj).toOpaque())
}

private func bridge<T: AnyObject>(ptr: UnsafeRawPointer) -> T {
    return Unmanaged<T>.fromOpaque(ptr).takeUnretainedValue()
}

// MARK: - MDK Metal 渲染视图

/// 专用于 MDK 的 MTKView 子类。
///
/// 渲染管线：
/// 1. MDK 通过 setRenderAPI 渲染到一个离屏 MTLTexture（renderTexture）。
/// 2. setRenderCallback 触发时，在 MDK 线程调用 renderVideo() 更新 renderTexture。
///    如果 PiP 已启用，再把 renderTexture blit 到 CVPixelBuffer-backed 纹理，
///    完成后推给 MDKPipManager。
/// 3. MTKView 的 draw(in:) 只负责把 renderTexture blit 到 currentDrawable，
///    不做额外渲染，保证前后台都能继续出帧。
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
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false          // 需要读取/拷贝
        autoResizeDrawable = true
        enableSetNeedsDisplay = true
        isPaused = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        delegate = self
    }

    #if canImport(swift_mdk)
    func attach(player: Player) {
        self.player = player
        guard device != nil else { return }

        commandQueue = device?.makeCommandQueue()
        guard commandQueue != nil else { return }

        setupRenderAPIIfNeeded()
        updateSurfaceSize()

        player.setRenderCallback { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.renderFrame()
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

    private func updateSurfaceSize() {
        guard let player = player, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        let newSize = CGSize(width: width, height: height)
        guard newSize != currentSize else { return }
        currentSize = newSize

        player.setVideoSurfaceSize(CGFloat(width), CGFloat(height))
        recreateRenderTexture(size: newSize)
    }

    // MARK: - 渲染目标设置

    #if canImport(swift_mdk)
    private func setupRenderAPIIfNeeded() {
        guard !hasSetupRenderAPI, let player = player, let device = device, let queue = commandQueue else { return }
        hasSetupRenderAPI = true

        var ra = mdkMetalRenderAPI()
        ra.type = MDK_RenderAPI_Metal
        ra.device = bridge(device)
        ra.cmdQueue = bridge(queue)
        ra.opaque = bridge(self)
        ra.currentRenderTarget = { opaque in
            guard let opaque = opaque else { return nil }
            let view = bridge(ptr: opaque) as MDKRenderView
            guard let tex = view.renderTexture else { return nil }
            return bridge(tex)
        }
        ra.layer = nil  // 我们自己 present，不需要 MDK 操作 layer
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

    // MARK: - 帧渲染与捕获

    #if canImport(swift_mdk)
    private func renderFrame() {
        guard let player = player, let queue = commandQueue else { return }

        renderLock.lock()
        defer { renderLock.unlock() }

        guard renderTexture != nil else { return }

        _ = player.renderVideo(vid: nil)

        // 触发 UI 刷新
        DispatchQueue.main.async { [weak self] in
            self?.setNeedsDisplay()
        }

        // PiP 捕获
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

        cmdBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            let pts = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1000)
            MDKPipManager.shared.enqueueFrame(pb, presentationTime: pts)
        }
        cmdBuffer.commit()
    }
    #endif

    deinit {
        pipTexture = nil
        renderTexture = nil
        if let pb = pipPixelBuffer {
            CVPixelBufferRelease(pb)
            pipPixelBuffer = nil
        }
    }
}

// MARK: - MTKViewDelegate

extension MDKRenderView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 尺寸变化由 layoutSubviews 处理
    }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let queue = commandQueue else { return }

        renderLock.lock()
        defer { renderLock.unlock() }

        guard let renderTex = renderTexture else { return }

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
