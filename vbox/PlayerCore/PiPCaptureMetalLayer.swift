import Metal
import UIKit

/// PiP 帧捕获专用 Metal Layer。
/// 继承 MPVKitMetalLayer，重写 present() 方法，在 mpv 渲染完成 present drawable 时，
/// 将当前帧内容 blit 到 staging 纹理供 PiP 帧捕获读取。
///
/// 核心优势：不调用 nextDrawable()，不消耗 drawable 队列，完全不干扰 mpv 渲染。
final class PiPCaptureMetalLayer: MPVKitMetalLayer {

    /// 帧捕获回调：当有新帧可捕获时调用，参数为 staging 纹理的像素数据
    var onFrameCaptured: ((MTLTexture) -> Void)?

    /// Metal 命令队列
    private var commandQueue: MTLCommandQueue?
    /// staging 纹理（CPU 可读，用于帧捕获）
    private var stagingTexture: MTLTexture?
    /// staging 纹理尺寸
    private var stagingSize: CGSize = .zero
    /// 是否正在捕获（避免重入）
    private var isCapturing = false

    override func setNeedsDisplay() {
        super.setNeedsDisplay()
        ensureCommandQueue()
    }

    /// 重写 present()：在 mpv 渲染完成 present drawable 时，缓存当前帧
    override func present(_ drawable: CAMetalDrawable) {
        // 先执行正常 present（不阻塞渲染）
        super.present(drawable)

        // 如果没有帧捕获回调，跳过
        guard onFrameCaptured != nil else { return }
        guard !isCapturing else { return }

        let sourceTexture = drawable.texture
        let width = sourceTexture.width
        let height = sourceTexture.height

        guard width > 0, height > 0 else { return }

        // 确保 staging 纹理尺寸匹配
        if stagingTexture == nil ||
           stagingSize.width != CGFloat(width) ||
           stagingSize.height != CGFloat(height) {
            setupStagingTexture(device: device!, width: width, height: height)
        }

        guard let staging = stagingTexture,
              let queue = commandQueue else { return }

        isCapturing = true

        // 使用 blit command 将源纹理拷贝到 staging 纹理
        if let commandBuffer = queue.makeCommandBuffer(),
           let blitEncoder = commandBuffer.makeBlitCommandEncoder() {

            blitEncoder.copy(from: sourceTexture,
                             sourceSlice: 0,
                             sourceLevel: 0,
                             sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                             sourceSize: MTLSize(width: width, height: height, depth: 1),
                             to: staging,
                             destinationSlice: 0,
                             destinationLevel: 0,
                             destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blitEncoder.endEncoding()

            commandBuffer.addCompletedHandler { [weak self] _ in
                guard let self else { return }
                // 在 Metal 完成回调中通知帧捕获
                self.onFrameCaptured?(staging)
                self.isCapturing = false
            }

            commandBuffer.commit()
        } else {
            isCapturing = false
        }
    }

    // MARK: - 私有方法

    private func ensureCommandQueue() {
        guard commandQueue == nil, let device = device else { return }
        commandQueue = device.makeCommandQueue()
    }

    private func setupStagingTexture(device: MTLDevice, width: Int, height: Int) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .shared  // CPU 可读
        descriptor.cpuCacheMode = .writeCombined

        stagingTexture = device.makeTexture(descriptor: descriptor)
        stagingSize = CGSize(width: width, height: height)
    }
}
