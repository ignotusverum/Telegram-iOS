import UIKit
import MetalKit
import simd

public final class ShapeMorphView: UIView, BackdropClient {

    public let backdropClientID = UUID()

    public var shape1: MorphShape = .circle(center: .zero, radius: 28) {
        didSet { updateShapes() }
    }

    public var shape2: MorphShape = .pill(center: .zero, size: CGSize(width: 200, height: 52)) {
        didSet { updateShapes() }
    }

    public var morphProgress: CGFloat {
        get { CGFloat(morphAnimator.current) }
        set { morphAnimator.setValue(newValue, animated: false) }
    }

    public var blendSoftness: CGFloat = 30.0 {
        didSet { renderer?.morphUniforms.blendSoftness = Float(blendSoftness) }
    }

    public var liftScale: CGFloat = 1.15
    public var enableDragDeformation: Bool = true
    public var deformIntensity: CGFloat = 1.0

    public var onMorphProgressChanged: ((CGFloat) -> Void)?
    public var onDragBegan: (() -> Void)?
    public var onDragEnded: (() -> Void)?

    private var metalView: MTKView?
    private var renderer: ShapeMorphRenderer?

    private let morphAnimator = LegacyScaleAnimator()
    private let scaleAnimator = LegacyScaleAnimator()
    private let wobbleAnimator = SpringWobbleAnimator()
    private let positionAnimator = LegacySpringAnimator()

    private var displayLink: CADisplayLink?
    private var isPressed: Bool = false
    private var isDragging: Bool = false
    private var dragStartLocation: CGPoint = .zero
    private var dragStartCenter: CGPoint = .zero

    private var captureRect: CGRect = .zero

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

        setupMetal()
        setupGestures()
        setupAnimators()
        startDisplayLink()
    }

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }

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

        guard let renderer = ShapeMorphRenderer(device: device) else { return }
        self.renderer = renderer
        mtkView.delegate = renderer

        renderer.onUpdate = { [weak self] in
            self?.updateUniforms()
        }
    }

    private func setupGestures() {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.15
        addGestureRecognizer(longPress)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    private func setupAnimators() {
        morphAnimator.stiffness = 350
        morphAnimator.damping = 26

        scaleAnimator.stiffness = 400
        scaleAnimator.damping = 28
        scaleAnimator.setValue(1.0, animated: false)

        positionAnimator.stiffness = 350
        positionAnimator.damping = 25

        wobbleAnimator.limits = .subtle
    }

    private func startDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func tick() {
        let dt: CGFloat = 1.0 / 120.0

        morphAnimator.step()
        scaleAnimator.step()
        positionAnimator.step()
        wobbleAnimator.update(dt: dt)

        onMorphProgressChanged?(CGFloat(morphAnimator.current))
    }

    private func updateUniforms() {
        guard let renderer = renderer else { return }

        let scale = CGFloat(scaleAnimator.current)
        let scaledShape1 = shape1.scaled(by: scale)
        let scaledShape2 = shape2.scaled(by: scale)

        renderer.setShapes(scaledShape1, scaledShape2)
        renderer.morphUniforms.viewSize = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
        renderer.morphUniforms.morphProgress = Float(morphAnimator.current)
        renderer.morphUniforms.blendSoftness = Float(blendSoftness)

        if enableDragDeformation {
            let normalizedVel = wobbleAnimator.normalizedVelocity
            renderer.morphUniforms.velocity = SIMD2<Float>(
                normalizedVel.x * Float(deformIntensity),
                normalizedVel.y * Float(deformIntensity)
            )
        } else {
            renderer.morphUniforms.velocity = .zero
        }

        renderer.useSingleShape = false
    }

    private func updateShapes() {
        updateUniforms()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            isPressed = true
            scaleAnimator.setValue(liftScale, animated: true)
            wobbleAnimator.triggerLift()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        case .ended, .cancelled:
            if !isDragging {
                isPressed = false
                scaleAnimator.setValue(1.0, animated: true)
                wobbleAnimator.triggerDrop()
            }

        default:
            break
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let superview = superview else { return }

        switch gesture.state {
        case .began:
            isDragging = true
            dragStartLocation = gesture.location(in: superview)
            dragStartCenter = center
            onDragBegan?()

        case .changed:
            let location = gesture.location(in: superview)
            let delta = CGPoint(
                x: location.x - dragStartLocation.x,
                y: location.y - dragStartLocation.y
            )

            let newCenter = CGPoint(
                x: dragStartCenter.x + delta.x,
                y: dragStartCenter.y + delta.y
            )
            center = newCenter

            let velocity = gesture.velocity(in: superview)
            wobbleAnimator.trackVelocity(velocity)

        case .ended, .cancelled:
            isDragging = false
            isPressed = false

            let velocity = gesture.velocity(in: superview)
            wobbleAnimator.release(withVelocity: velocity)
            scaleAnimator.setValue(1.0, animated: true)
            onDragEnded?()

        default:
            break
        }
    }

    public func setMorphProgress(_ progress: CGFloat, animated: Bool) {
        morphAnimator.setValue(progress, animated: animated)
    }

    public func setScale(_ scale: CGFloat, animated: Bool) {
        scaleAnimator.setValue(scale, animated: animated)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        metalView?.frame = bounds
        updateCaptureRect()
    }

    private func updateCaptureRect() {
        guard let window = window else { return }
        let padding: CGFloat = 40
        let frameInWindow = convert(bounds, to: window)
        captureRect = frameInWindow.insetBy(dx: -padding, dy: -padding)
    }

    public var captureFrame: CGRect { captureRect }
    public var capturePadding: CGFloat { 40 }
    public var needsBackdrop: Bool { !isHidden && alpha > 0 }
    public var backdropWindow: UIWindow? { window }

    public func prepareForCapture() {
        metalView?.isHidden = true
    }

    public func restoreAfterCapture() {
        metalView?.isHidden = false
    }

    public func didReceiveBackdrop(_ texture: MTLTexture, unionRect: CGRect, screenScale: CGFloat) {
        renderer?.backdropTexture = texture
        renderer?.updateForBackdrop(unionRect: unionRect, clientCaptureFrame: captureRect, screenScale: screenScale)
    }

    deinit {
        displayLink?.invalidate()
    }
}

extension ShapeMorphView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}
