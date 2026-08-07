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

    /// 当前画面拉伸模式
    private var videoGravity: PlayerState.VideoGravityMode = .aspectFill
    private var gravityObserver: NSObjectProtocol?

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

        // 监听画面拉伸模式变化
        gravityObserver = NotificationCenter.default.addObserver(
            forName: .vboxVideoGravityChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let mode = note.userInfo?["mode"] as? PlayerState.VideoGravityMode else { return }
            self?.videoGravity = mode
        }
    }

    deinit {
        if let observer = gravityObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        scaledPipelineState = nil
        scaledSamplerState = nil
        pipTexture = nil
        renderTexture = nil
        pipPixelBuffer = nil
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

        guard let cmdBuffer = queue.makeCommandBuffer() else { return }

        if videoGravity == .resize {
            // 拉伸模式：直接 blit 整个纹理到 drawable（填满屏幕，不保持比例）
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
        } else {
            // 填充/适应模式：用渲染管线缩放，保持视频宽高比
            blitTextureToDrawable(
                cmdBuffer: cmdBuffer,
                source: renderTex,
                destination: drawable.texture
            )
        }

        cmdBuffer.present(drawable)
        cmdBuffer.commit()

        // 前台 PiP 也在这里捕获（后台 PiP 由 render callback 负责）
        if pipEnabled {
            capturePiPFrameLocked(queue: queue)
        }
    }

    // MARK: - 带宽高比的纹理缩放渲染

    /// 缓存的渲染管线状态（拉伸模式下用 blit，不需要）
    private var scaledPipelineState: MTLRenderPipelineState?
    private var scaledSamplerState: MTLSamplerState?

    private func getScaledPipelineState() -> MTLRenderPipelineState? {
        if let state = scaledPipelineState { return state }
        guard let device = device, let library = makeShaderLibrary() else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "mdk_gravity_vertex")
        desc.fragmentFunction = library.makeFunction(name: "mdk_gravity_fragment")
        desc.colorAttachments[0].pixelFormat = colorPixelFormat

        guard let state = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        scaledPipelineState = state
        return state
    }

    private func getSamplerState() -> MTLSamplerState? {
        if let state = scaledSamplerState { return state }
        guard let device = device else { return nil }
        let desc = MTLSamplerDescriptor()
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        guard let state = device.makeSamplerState(descriptor: desc) else { return nil }
        scaledSamplerState = state
        return state
    }

    /// 动态创建 Metal shader library（内嵌源码，不依赖外部 .metal 文件）
    private func makeShaderLibrary() -> MTLLibrary? {
        guard let device = device else { return nil }
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VertexOut mdk_gravity_vertex(uint vid [[vertex_id]],
                                             constant float4 *rect [[buffer(0)]]) {
            // 两个三角形覆盖 rect 区域（x, y, w, h 均为 0~1 归一化坐标）
            float2 positions[6] = {
                {rect[0].x, rect[0].y},
                {rect[0].x + rect[0].z, rect[0].y},
                {rect[0].x, rect[0].y + rect[0].w},
                {rect[0].x, rect[0].y + rect[0].w},
                {rect[0].x + rect[0].z, rect[0].y},
                {rect[0].x + rect[0].z, rect[0].y + rect[0].w},
            };
            float2 uvs[6] = {
                {0, 0}, {1, 0}, {0, 1},
                {0, 1}, {1, 0}, {1, 1},
            };
            float2 pos = positions[vid];
            float2 uv = uvs[vid];
            // Metal 坐标系：y 轴向上，翻转
            VertexOut out;
            out.position = float4(pos.x * 2 - 1, -(pos.y * 2 - 1), 0, 1);
            out.uv = uv;
            return out;
        }

        fragment float4 mdk_gravity_fragment(VertexOut in [[stage_in]],
                                              texture2d<float> tex [[texture(0)]],
                                              sampler smp [[sampler(0)]]) {
            return tex.sample(smp, in.uv);
        }
        """
        return try? device.makeLibrary(source: source, options: nil)
    }

    /// 用渲染管线将 source 纹理按宽高比缩放绘制到 destination
    private func blitTextureToDrawable(cmdBuffer: MTLCommandBuffer,
                                        source: MTLTexture,
                                        destination: MTLTexture) {
        guard let pipelineState = getScaledPipelineState(),
              let samplerState = getSamplerState() else {
            // 降级：直接 blit
            guard let blit = cmdBuffer.makeBlitCommandEncoder() else { return }
            blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOriginMake(0, 0, 0),
                      sourceSize: MTLSizeMake(source.width, source.height, 1),
                      to: destination, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOriginMake(0, 0, 0))
            blit.endEncoding()
            return
        }

        // 计算目标区域（归一化 0~1），保持视频宽高比
        let videoW = CGFloat(source.width)
        let videoH = CGFloat(source.height)
        let viewW = CGFloat(destination.width)
        let viewH = CGFloat(destination.height)

        var rect = SIMD4<Float>(0, 0, 1, 1) // x, y, w, h

        if videoW > 0 && videoH > 0 && viewW > 0 && viewH > 0 {
            let videoAspect = videoW / videoH
            let viewAspect = viewW / viewH

            if videoGravity == .aspectFill {
                // 填充：视频填满屏幕，可能裁剪
                if videoAspect > viewAspect {
                    // 视频更宽，左右裁剪
                    let scale = viewH / videoH
                    let drawW = videoW * scale / viewW
                    rect.x = (1 - drawW) / 2
                    rect.z = drawW
                } else {
                    // 视频更高，上下裁剪
                    let scale = viewW / videoW
                    let drawH = videoH * scale / viewH
                    rect.y = (1 - drawH) / 2
                    rect.w = drawH
                }
            } else {
                // 适应：视频完整显示，可能有黑边
                if videoAspect > viewAspect {
                    // 视频更宽，上下留黑边
                    let scale = viewW / videoW
                    let drawH = videoH * scale / viewH
                    rect.y = (1 - drawH) / 2
                    rect.w = drawH
                } else {
                    // 视频更高，左右留黑边
                    let scale = viewH / videoH
                    let drawW = videoW * scale / viewW
                    rect.x = (1 - drawW) / 2
                    rect.z = drawW
                }
            }
        }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = destination
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store

        guard let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }
}
