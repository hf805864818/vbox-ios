import UIKit
import Metal

class MPVKitMetalLayer: CAMetalLayer {

    /// 最近一次通过 nextDrawable() 返回的 drawable，用于 PiP 纹理 blit 捕获。
    /// 注意：这里仅保留引用，读取时机由上层控制；MPV 渲染并 present 后该纹理仍可能可读。
    private(set) var lastDrawable: CAMetalDrawable?

    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                // 使用 async 避免后台线程与主线程死锁（HDR 标志延迟几毫秒生效不影响播放）
                DispatchQueue.main.async {
                    super.wantsExtendedDynamicRangeContent = newValue
                }
            }
        }
    }

    override func nextDrawable() -> CAMetalDrawable? {
        let drawable = super.nextDrawable()
        if let drawable {
            lastDrawable = drawable
        }
        return drawable
    }
}
