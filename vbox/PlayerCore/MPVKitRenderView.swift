import UIKit

final class MPVKitRenderView: UIView {
    var metalLayer = MPVKitMetalLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.frame = bounds
        metalLayer.contentsScale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        metalLayer.drawableSize = CGSize(
            width: bounds.width * metalLayer.contentsScale,
            height: bounds.height * metalLayer.contentsScale
        )
    }

    private func configure() {
        backgroundColor = .black
        metalLayer.frame = bounds
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(metalLayer)
    }
}
