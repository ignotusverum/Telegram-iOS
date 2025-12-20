import UIKit
import MetalKit

public final class TripleMorphOverlayView: UIView {

    private var metalView: MTKView?
    private var renderer: TripleMorphRenderer?

    public var shape1: MorphShape = .circle(center: .zero, radius: 20) {
        didSet { updateShapes() }
    }
    public var shape2: MorphShape = .pill(center: .zero, size: CGSize(width: 200, height: 40)) {
        didSet { updateShapes() }
    }
    public var shape3: MorphShape = .circle(center: .zero, radius: 20) {
        didSet { updateShapes() }
    }

    public var scale1: CGFloat = 1.0 {
        didSet { renderer?.uniforms.scale1 = Float(scale1) }
    }
    public var scale2: CGFloat = 1.0 {
        didSet { renderer?.uniforms.scale2 = Float(scale2) }
    }
    public var scale3: CGFloat = 1.0 {
        didSet { renderer?.uniforms.scale3 = Float(scale3) }
    }

    public var velocity1: CGPoint = .zero {
        didSet { renderer?.uniforms.velocity1 = SIMD2<Float>(Float(velocity1.x), Float(velocity1.y)) }
    }
    public var velocity2: CGPoint = .zero {
        didSet { renderer?.uniforms.velocity2 = SIMD2<Float>(Float(velocity2.x), Float(velocity2.y)) }
    }
    public var velocity3: CGPoint = .zero {
        didSet { renderer?.uniforms.velocity3 = SIMD2<Float>(Float(velocity3.x), Float(velocity3.y)) }
    }

    public var blendSoftness: CGFloat = 25.0 {
        didSet { renderer?.uniforms.blendSoftness = Float(blendSoftness) }
    }

    public var onUpdate: (() -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false

        setupMetal()
    }

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[TripleMorphOverlay] No Metal device")
            return
        }

        let mtkView = MTKView(frame: bounds, device: device)
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false
        mtkView.isOpaque = false
        mtkView.backgroundColor = .clear
        mtkView.layer.isOpaque = false
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 120
        addSubview(mtkView)
        metalView = mtkView

        guard let renderer = TripleMorphRenderer(device: device) else {
            print("[TripleMorphOverlay] Failed to create renderer")
            return
        }
        self.renderer = renderer
        mtkView.delegate = renderer

        renderer.onUpdate = { [weak self] in
            self?.updateUniforms()
        }
    }

    private func updateUniforms() {
        guard let renderer = renderer else { return }

        renderer.uniforms.viewSize = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
        renderer.uniforms.scale1 = Float(scale1)
        renderer.uniforms.scale2 = Float(scale2)
        renderer.uniforms.scale3 = Float(scale3)
        renderer.uniforms.blendSoftness = Float(blendSoftness)

        onUpdate?()
    }

    private func updateShapes() {
        renderer?.setShapes(shape1, shape2, shape3)
    }

    public func setShapes(_ s1: MorphShape, _ s2: MorphShape, _ s3: MorphShape) {
        shape1 = s1
        shape2 = s2
        shape3 = s3
        renderer?.setShapes(s1, s2, s3)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        metalView?.frame = bounds
    }
}
