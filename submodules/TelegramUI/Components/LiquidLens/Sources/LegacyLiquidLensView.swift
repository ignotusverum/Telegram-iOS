import UIKit
import MetalKit
import IOSurface

public final class LegacyLiquidLensView: UIView {

    public struct Config {
        public var collapsedScale: CGFloat = 1.0
        public var expandedScale: CGFloat = 1.4
        public var metalShowThreshold: CGFloat = 1.05
        public var fillHideThreshold: CGFloat = 1.08
        public var collapsedInset: CGFloat = -4.0
        public var liftedInset: CGFloat = 10.0
        public var deformWidthFactor: CGFloat = 0.35
        public var deformHeightFactor: CGFloat = 0.2625
        public var liftStiffness: CGFloat = 300.0
        public var liftDamping: CGFloat = 25.0
        public var fillStiffness: CGFloat = 400.0
        public var fillDamping: CGFloat = 25.0
        public var deformStiffness: CGFloat = 300.0
        public var deformDamping: CGFloat = 20.0
        public var refractionStrength: Float = 6
        public var specularIntensity: Float = 0.4
        public var refractionZonePercent: Float = 0.4
        public var edgeIntensity: Float = 0.8
        public var verticalEdgeRefractionScale: Float = 1
        public var capturePadding: CGFloat = 60.0
        public static let `default` = Config()
    }

    public var config: Config = .default {
        didSet { applyAnimatorConfig() }
    }

    public weak var liftedContainerView: UIView?
    public weak var liftedContentView: UIView?

    public var baseFrame: CGRect = .zero {
        didSet {
            guard baseFrame != oldValue else { return }
            updateFrameFromScale()
        }
    }

    public var fillColor: UIColor = UIColor(white: 0.0, alpha: 0.1) {
        didSet { restingFillView.backgroundColor = fillColor }
    }

    public private(set) var isLifted = false
    public private(set) var isActivated = false

    private let liftAnimator = LegacyScaleAnimator()
    private let fillAlphaAnimator = LegacyScaleAnimator()
    private let fillScaleAnimator = LegacyScaleAnimator()
    private let fillDeformAnimator = LegacyScaleAnimator()
    private let wobbleAnimator = LegacyWobbleAnimator()

    private var hasValidBackdrop = false
    private var lastCapturedDeform: CGFloat = 0
    private var pendingCompletion: ((Bool) -> Void)?

    private var lastFrameX: CGFloat = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var startTime: CFTimeInterval = 0

    private var captureRect: CGRect = .zero
    private var captureRectInWindow: CGRect = .zero

    private lazy var restingFillView: UIView = {
        let view = UIView()
        view.backgroundColor = fillColor
        view.layer.cornerCurve = .continuous
        view.isUserInteractionEnabled = false
        return view
    }()

    private var metalContainerView: UIView?
    private var metalView: MTKView?
    private var renderer: LegacyLensRenderer?
    private var texturePool: IOSurfaceTexturePool?
    private var displayLink: CADisplayLink?

    private var isAnimating: Bool {
        !liftAnimator.isSettled ||
        !fillAlphaAnimator.isSettled ||
        !fillScaleAnimator.isSettled ||
        !fillDeformAnimator.isSettled
    }

    private var scaleProgress: CGFloat {
        (liftAnimator.current - config.collapsedScale) / (config.expandedScale - config.collapsedScale)
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        clipsToBounds = false
        layer.masksToBounds = false
        addSubview(restingFillView)
        setupMetal()
        applyAnimatorConfig()
        resetAnimatorValues()
    }

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        let container = UIView()
        container.clipsToBounds = false
        container.isUserInteractionEnabled = false
        addSubview(container)
        metalContainerView = container

        let mtkView = MTKView(frame: .zero, device: device)
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = false
        mtkView.framebufferOnly = false
        mtkView.isOpaque = false
        mtkView.backgroundColor = .clear
        mtkView.layer.isOpaque = false
        mtkView.clipsToBounds = false
        mtkView.isUserInteractionEnabled = false
        metalView = mtkView
        container.addSubview(mtkView)

        guard let renderer = LegacyLensRenderer(device: device) else { return }
        self.renderer = renderer
        mtkView.delegate = renderer
        renderer.onUpdate = { [weak self] in self?.update() }

        texturePool = IOSurfaceTexturePool(device: device)
    }

    private func applyAnimatorConfig() {
        liftAnimator.stiffness = config.liftStiffness
        liftAnimator.damping = config.liftDamping
        fillAlphaAnimator.stiffness = config.fillStiffness
        fillAlphaAnimator.damping = config.fillDamping
        fillScaleAnimator.stiffness = config.fillStiffness
        fillScaleAnimator.damping = config.fillDamping
        fillDeformAnimator.stiffness = config.deformStiffness
        fillDeformAnimator.damping = config.deformDamping
    }

    private func resetAnimatorValues() {
        liftAnimator.setValue(config.collapsedScale, animated: false)
        fillAlphaAnimator.setValue(1.0, animated: false)
        fillScaleAnimator.setValue(1.0, animated: false)
        fillDeformAnimator.setValue(0, animated: false)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        metalContainerView?.frame = bounds
    }

    public func activate() {
        guard !isActivated else { return }
        isActivated = true
        captureBackdrop()
        startDisplayLink()
    }

    public func setLifted(
        _ lifted: Bool,
        animated: Bool,
        alongsideAnimations: (() -> Void)? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard lifted != isLifted else {
            completion?(true)
            return
        }

        isLifted = lifted
        pendingCompletion = completion

        if lifted {
            expandAnimation(animated: animated)
        } else {
            collapseAnimation(animated: animated)
        }

        alongsideAnimations?()

        if !animated {
            completeAnimation()
        }
    }

    private func expandAnimation(animated: Bool) {
        fillAlphaAnimator.setValue(0, animated: false)
        fillScaleAnimator.target = 0.9
        fillDeformAnimator.setValue(0, animated: false)
        captureBackdrop()
        liftAnimator.setValue(config.expandedScale, animated: animated)
        startDisplayLink()
    }

    private func collapseAnimation(animated: Bool) {
        let currentDeform = lastCapturedDeform
        liftAnimator.setValue(config.collapsedScale, animated: animated)
        fillScaleAnimator.setValue(1.0, animated: false)
        fillAlphaAnimator.setValue(1.0, animated: false)
        fillDeformAnimator.setValue(currentDeform, animated: false)
        fillDeformAnimator.target = 0
    }

    private func completeAnimation() {
        pendingCompletion?(true)
        pendingCompletion = nil
    }

    private func update() {
        guard let renderer = renderer, let window = window, captureRectInWindow != .zero else { return }

        stepAnimators()
        trackMotion()
        updateFrameFromScale()
        updateVisibility()
        updateRestingFillFrame()
        updateMetalFrame()
        updateShaderUniforms(renderer: renderer, screenScale: window.screen.scale)
        checkCompletion()
    }

    private func stepAnimators() {
        liftAnimator.step()
        fillAlphaAnimator.step()
        fillScaleAnimator.step()
        fillDeformAnimator.step()

        if isLifted {
            lastCapturedDeform = wobbleAnimator.normalizedValue
        }
    }

    private func trackMotion() {
        let now = CACurrentMediaTime()
        let dt = lastFrameTime == 0 ? 1.0 / 120.0 : min(now - lastFrameTime, 1.0 / 30.0)
        lastFrameTime = now

        let currentX = frame.origin.x
        let velocity = dt > 0 ? (currentX - lastFrameX) / CGFloat(dt) : 0
        lastFrameX = currentX

        wobbleAnimator.trackVelocity(velocity)
        wobbleAnimator.update(dt: CGFloat(dt))
    }

    private func updateVisibility() {
        let scale = liftAnimator.current
        let showMetal = scale > config.metalShowThreshold && hasValidBackdrop
        let showFill = scale < config.fillHideThreshold

        metalContainerView?.isHidden = !showMetal
        metalView?.isPaused = !showMetal
        restingFillView.alpha = showFill ? fillAlphaAnimator.current : 0
    }

    private func updateFrameFromScale() {
        guard baseFrame.width > 0 else { return }

        let inset = config.collapsedInset + (config.liftedInset - config.collapsedInset) * scaleProgress

        bounds = CGRect(
            origin: .zero,
            size: CGSize(
                width: baseFrame.width + inset * 2,
                height: baseFrame.height + inset * 2
            )
        )
        center = CGPoint(x: baseFrame.midX, y: baseFrame.midY)
    }

    private func updateRestingFillFrame() {
        guard baseFrame.width > 0 else { return }

        let scale = fillScaleAnimator.current
        let deform = fillDeformAnimator.current

        let widthMult = 1.0 + deform * config.deformWidthFactor
        let heightMult = 1.0 - deform * config.deformHeightFactor

        let baseWidth = baseFrame.width + config.collapsedInset * 2
        let baseHeight = baseFrame.height + config.collapsedInset * 2

        let width = baseWidth * scale * widthMult
        let height = baseHeight * scale * heightMult

        restingFillView.frame = CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
        restingFillView.layer.cornerRadius = height / 2
    }

    private func updateMetalFrame() {
        guard let window = window, captureRectInWindow != .zero else { return }
        metalContainerView?.frame = bounds
        metalView?.frame = window.convert(captureRectInWindow, to: self)
    }

    private func updateShaderUniforms(renderer: LegacyLensRenderer, screenScale: CGFloat) {
        guard let window = window else { return }

        let lensInWindow = convert(bounds, to: window)
        let origin = CGPoint(
            x: lensInWindow.origin.x - captureRectInWindow.origin.x,
            y: lensInWindow.origin.y - captureRectInWindow.origin.y
        )

        var u = renderer.glassUniforms
        u.viewSize = SIMD2(Float(captureRect.width * screenScale), Float(captureRect.height * screenScale))
        u.glassOrigin = SIMD2(Float(origin.x * screenScale), Float(origin.y * screenScale))
        u.glassSize = SIMD2(Float(bounds.width * screenScale), Float(bounds.height * screenScale))
        u.cornerRadius = Float(bounds.height * screenScale / 2)
        u.refractionStrength = config.refractionStrength
        u.specularIntensity = config.specularIntensity
        u.refractionZonePercent = config.refractionZonePercent
        u.edgeIntensity = config.edgeIntensity
        u.verticalEdgeRefractionScale = config.verticalEdgeRefractionScale
        u.scrollVelocity = SIMD2(Float(wobbleAnimator.normalizedValue), 0)
        u.time = Float(CACurrentMediaTime() - startTime)
        renderer.glassUniforms = u
    }

    private func checkCompletion() {
        guard !isAnimating, let completion = pendingCompletion else { return }
        pendingCompletion = nil
        completion(true)
    }

    private func captureBackdrop() {
        guard let texturePool = texturePool,
              let window = window,
              let containerView = liftedContainerView else { return }

        let screenScale = window.screen.scale
        let containerInWindow = containerView.convert(containerView.bounds, to: window)
        captureRectInWindow = containerInWindow.insetBy(dx: -config.capturePadding, dy: -config.capturePadding)
        captureRect = CGRect(origin: .zero, size: captureRectInWindow.size)

        let wasHidden = isHidden
        let contentWasHidden = liftedContentView?.isHidden ?? true
        isHidden = true
        liftedContentView?.isHidden = true
        defer {
            isHidden = wasHidden
            liftedContentView?.isHidden = contentWasHidden
        }

        texturePool.lockForCPU()
        defer { texturePool.unlockForCPU() }

        if let ctx = texturePool.getContext(size: captureRect.size, scale: screenScale) {
            ctx.saveGState()
            ctx.translateBy(x: -captureRectInWindow.origin.x * screenScale, y: -captureRectInWindow.origin.y * screenScale)
            ctx.scaleBy(x: screenScale, y: screenScale)
            window.layer.render(in: ctx)
            ctx.restoreGState()
        }

        renderer?.backdropTexture = texturePool.getTexture()
        hasValidBackdrop = true
        updateMetalFrame()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        startTime = CACurrentMediaTime()
        lastFrameX = frame.origin.x
        lastFrameTime = 0
        wobbleAnimator.reset()
        metalView?.isPaused = false

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        metalView?.isPaused = true
    }

    @objc private func tick() {
        metalView?.draw()
    }
}
