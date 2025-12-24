import UIKit
import MetalKit
import CustomLiquidGlass

public final class LegacyLiquidLensView: UIView {

    public struct Config {
        public var collapsedScale: CGFloat = 1.0
        public var expandedScale: CGFloat = 1.3

        public var metalShowThreshold: CGFloat = 1.02
        public var fillHideThreshold: CGFloat = 1.06

        public var collapsedInset: CGFloat = -4.0
        public var liftedInsetX: CGFloat = 8.0
        public var liftedInsetY: CGFloat = 8.0

        public var liftStiffness: CGFloat = 250.0
        public var liftDamping: CGFloat = 14.0

        public var fillStiffness: CGFloat = 280.0
        public var fillDamping: CGFloat = 16.0

        public var deformStiffness: CGFloat = 200.0
        public var deformDamping: CGFloat = 12.0

        public var hDeformWidthFactor: CGFloat = 0.70
        public var hDeformHeightFactor: CGFloat = 0.50

        public var vDeformWidthFactor: CGFloat = 0.55
        public var vDeformHeightFactor: CGFloat = 0.70

        public var refractionStrength: Float = 8
        public var specularIntensity: Float = 0
        public var refractionZonePercent: Float = 0.35
        public var edgeIntensity: Float = 0.5
        public var refractionScaleX: Float = 1.0
        public var refractionScaleY: Float = 0.5
        public var chromaticScaleX: Float = 1.0
        public var chromaticScaleY: Float = 0.15
        public var capturePadding: CGFloat = 60.0

        public var shadowOpacity: Float = 0.2
        public var shadowRadius: CGFloat = 12
        public var shadowOffset: CGSize = CGSize(width: 0, height: 4)

        public static let `default` = Config()
    }

    public var config: Config = .default {
        didSet { applyAnimatorConfig() }
    }

    public weak var liftedContainerView: UIView?
    public weak var liftedContentView: UIView?
    public weak var liftedContentMaskView: UIView?

    private let restingBackgroundView: UIView

    public var baseFrame: CGRect = .zero {
        didSet {
            guard baseFrame != oldValue else { return }

            if isLifted && !isTransitioning {
                let deltaX = baseFrame.midX - oldValue.midX
                let deltaY = baseFrame.midY - oldValue.midY
                let now = CACurrentMediaTime()
                let dt = lastFrameTime > 0 ? min(now - lastFrameTime, 1.0/30.0) : 1.0/120.0
                let velocityX = deltaX / CGFloat(dt)
                let velocityY = deltaY / CGFloat(dt)
                wobbleAnimator.trackVelocity(CGPoint(x: velocityX, y: velocityY))
            }

            let newPosition = CGPoint(x: baseFrame.midX, y: baseFrame.midY)
            if !isLifted && !isTransitioning {
                positionAnimator.setPosition(newPosition, animated: false)
            } else {
                positionAnimator.target = newPosition
            }

            if !isTransitioning {
                updateFrameFromScale()
                updateVisibility()
                updateRestingFillFrame()
            }
        }
    }

    public var fillColor: UIColor = UIColor(white: 0.0, alpha: 0.1)

    public private(set) var isLifted = false
    public private(set) var isActivated = false

    private let liftAnimator = LegacyScaleAnimator()
    private let fillAlphaAnimator = LegacyScaleAnimator()
    private let fillScaleAnimator = LegacyScaleAnimator()
    private let fillDeformAnimator = LegacyScaleAnimator()
    private let wobbleAnimator = LegacyWobbleAnimator()
    private let positionAnimator = LegacySpringAnimator()

    var isTransitioning = false
    private var transitionTargetFrame: CGRect = .zero

    private var hasValidBackdrop = false
    private var lastCapturedHDeform: CGFloat = 0
    private var lastCapturedVDeform: CGFloat = 0
    private var pendingCompletion: ((Bool) -> Void)?

    private var lastFrameTime: CFTimeInterval = 0
    private var startTime: CFTimeInterval = 0

    private var captureRect: CGRect = .zero
    private var captureRectInWindow: CGRect = .zero

    private var cachedBounds: CGRect = .zero
    private var cachedCenter: CGPoint = .zero
    private var cachedFillFrame: CGRect = .zero
    private var cachedFillCornerRadius: CGFloat = 0
    private var cachedMetalHidden: Bool = true


    private var metalContainerView: UIView?
    private var metalView: MTKView?
    private var renderer: LegacyLensRenderer?
    private var displayLink: CADisplayLink?

    private lazy var _backdropClientID = UUID()
    private var _captureState: (metalHidden: Bool, restingHidden: Bool, mask: UIView?) = (true, true, nil)

    private var isAnimating: Bool {
        !liftAnimator.isSettled ||
        !fillAlphaAnimator.isSettled ||
        !fillScaleAnimator.isSettled ||
        !fillDeformAnimator.isSettled
    }

    private var scaleProgress: CGFloat {
        (liftAnimator.current - config.collapsedScale) / (config.expandedScale - config.collapsedScale)
    }

    public init(frame: CGRect, restingBackgroundView: UIView) {
        self.restingBackgroundView = restingBackgroundView
        super.init(frame: frame)
        setup()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        clipsToBounds = false
        layer.masksToBounds = false
        addSubview(restingBackgroundView)
        setupMetal()
        applyAnimatorConfig()
        resetAnimatorValues()

        positionAnimator.stiffness = 400.0
        positionAnimator.damping = 25.0
        positionAnimator.mass = 0.5

    }

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        let container = UIView()
        container.clipsToBounds = false
        container.isUserInteractionEnabled = false
        container.layer.zPosition = 10
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
        BackdropCoordinator.shared.register(self)
        BackdropCoordinator.shared.setNeedsCapture()
        startDisplayLink()
    }

    deinit {
        BackdropCoordinator.shared.unregister(self)
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

    public func transitionToFrame(_ newFrame: CGRect, animated: Bool, delay: TimeInterval = 0.0) {
        if isTransitioning {
            transitionTargetFrame = newFrame
            baseFrame = newFrame
            positionAnimator.setPosition(CGPoint(x: newFrame.midX, y: newFrame.midY), animated: animated)
            return
        }

        let currentCenter = CGPoint(x: baseFrame.midX, y: baseFrame.midY)

        isTransitioning = true
        transitionTargetFrame = newFrame

        positionAnimator.setPosition(currentCenter, animated: false)

        baseFrame = newFrame

        let startAnimation = { [weak self] in
            guard let self else { return }

            self.positionAnimator.setPosition(CGPoint(x: newFrame.midX, y: newFrame.midY), animated: animated)

            self.isLifted = true
            self.expandAnimation(animated: animated)

            self.updateFrameFromScale()
            self.updateVisibility()
            self.updateRestingFillFrame()

            self.startDisplayLink()
        }

        if delay > 0 {
            updateFrameFromScale()
            updateVisibility()
            updateRestingFillFrame()
            startDisplayLink()

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                startAnimation()
            }
        } else {
            startAnimation()
        }
    }

    public func cancelTransition() {
        guard isTransitioning else { return }

        isTransitioning = false

        positionAnimator.setPosition(CGPoint(x: baseFrame.midX, y: baseFrame.midY), animated: false)

    }

    private func expandAnimation(animated: Bool) {
        wobbleAnimator.reset()
        fillAlphaAnimator.setValue(0, animated: false)
        fillScaleAnimator.target = 0.9
        fillDeformAnimator.setValue(0, animated: false)
        wobbleAnimator.triggerLift()
        BackdropCoordinator.shared.setNeedsCapture()
        liftAnimator.setValue(config.expandedScale, animated: animated)
        startDisplayLink()
    }

    private func collapseAnimation(animated: Bool) {
        wobbleAnimator.release()
        liftAnimator.stiffness = config.liftStiffness
        liftAnimator.damping = config.liftDamping
        liftAnimator.setValue(config.collapsedScale, animated: animated)
        fillScaleAnimator.target = 1.0
        fillAlphaAnimator.target = 1.0
        fillDeformAnimator.target = 0
    }

    private func completeAnimation() {
        pendingCompletion?(true)
        pendingCompletion = nil
    }

    private func update() {
        guard let renderer = renderer, let window = window, captureRectInWindow != .zero else { return }

        let frameTimestamp = CACurrentMediaTime()
        let dt = lastFrameTime == 0 ? 1.0 / 120.0 : min(frameTimestamp - lastFrameTime, 1.0 / 30.0)
        lastFrameTime = frameTimestamp

        stepAnimators()
        positionAnimator.step()
        wobbleAnimator.update(dt: CGFloat(dt))

        if isTransitioning {
            let displacement = hypot(positionAnimator.current.x - positionAnimator.target.x,
                                     positionAnimator.current.y - positionAnimator.target.y)
            let positionNearlySettled = displacement < 8.0
            let fullyExpanded = liftAnimator.current >= config.expandedScale * 0.95

            if positionNearlySettled && fullyExpanded && isLifted {

                isTransitioning = false

                isLifted = false
                collapseAnimation(animated: true)
            }
        }

        let settled = !isAnimating && wobbleAnimator.isSettled && positionAnimator.isSettled
        if settled && !isLifted {
            checkCompletion()
            stopDisplayLink()
            return
        }

        updateFrameFromScale()
        updateVisibility()
        updateRestingFillFrame()
        updateMetalFrame()
        updateShaderUniforms(renderer: renderer, screenScale: window.screen.scale)
        updateShadow()
        checkCompletion()
    }

    private func stepAnimators() {
        liftAnimator.step()
        fillAlphaAnimator.step()
        fillScaleAnimator.step()
        fillDeformAnimator.step()

        if isLifted {
            lastCapturedHDeform = wobbleAnimator.horizontalValue
            lastCapturedVDeform = wobbleAnimator.verticalValue
        }
    }

    private func updateVisibility() {
        let scale = liftAnimator.current

        let showMetal = scale > config.metalShowThreshold && hasValidBackdrop
        let showFill = scale < config.fillHideThreshold

        if showMetal != !cachedMetalHidden {
            cachedMetalHidden = !showMetal
            metalContainerView?.isHidden = !showMetal
            metalView?.isPaused = !showMetal
        }

        restingBackgroundView.alpha = showFill ? fillAlphaAnimator.current : 0
    }

    private func updateFrameFromScale() {
        guard baseFrame.width > 0 else { return }

        let insetX = config.collapsedInset + (config.liftedInsetX - config.collapsedInset) * scaleProgress
        let insetY = config.collapsedInset + (config.liftedInsetY - config.collapsedInset) * scaleProgress

        let newBounds = CGRect(
            origin: .zero,
            size: CGSize(
                width: baseFrame.width + insetX * 2,
                height: baseFrame.height + insetY * 2
            )
        )

        let newCenter = positionAnimator.current

        if newBounds != cachedBounds {
            cachedBounds = newBounds
            bounds = newBounds
        }
        if newCenter != cachedCenter {
            cachedCenter = newCenter
            center = newCenter
        }

        if let maskView = liftedContentMaskView {
            let maskFrame = frame.insetBy(dx: 4.0, dy: 4.0)
            maskView.frame = maskFrame
            maskView.layer.cornerRadius = maskFrame.height / 2
        }
    }

    private func updateRestingFillFrame() {
        guard baseFrame.width > 0, (restingBackgroundView.alpha > 0 || !fillAlphaAnimator.isSettled) else { return }

        let hDeform = wobbleAnimator.horizontalValue
        let vDeform = wobbleAnimator.verticalValue

        let widthMult: CGFloat
        let heightMult: CGFloat

        if abs(hDeform) > 0.001 || abs(vDeform) > 0.001 {
            widthMult = 1.0 - hDeform * config.hDeformWidthFactor - abs(vDeform) * config.vDeformWidthFactor
            heightMult = 1.0 + hDeform * config.hDeformHeightFactor + abs(vDeform) * config.vDeformHeightFactor
        } else {
            widthMult = 1.0
            heightMult = 1.0
        }

        let width = bounds.width * widthMult
        let height = bounds.height * heightMult

        let newFrame = CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
        let newRadius = height / 2

        if newFrame != cachedFillFrame {
            cachedFillFrame = newFrame
            restingBackgroundView.frame = newFrame
        }
        if newRadius != cachedFillCornerRadius {
            cachedFillCornerRadius = newRadius
            restingBackgroundView.layer.cornerRadius = newRadius
        }
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
        u.refractionScaleX = config.refractionScaleX
        u.refractionScaleY = config.refractionScaleY
        u.chromaticScaleX = config.chromaticScaleX
        u.chromaticScaleY = config.chromaticScaleY
        u.scrollVelocity = wobbleAnimator.normalizedVelocity
        u.time = Float(CACurrentMediaTime() - startTime)
        renderer.glassUniforms = u
    }

    private func updateShadow() {
        let progress = scaleProgress
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = config.shadowOpacity * Float(progress)
        layer.shadowRadius = config.shadowRadius * progress
        layer.shadowOffset = CGSize(
            width: config.shadowOffset.width * progress,
            height: config.shadowOffset.height * progress
        )

        if progress > 0.01 {
            layer.shadowPath = UIBezierPath(
                roundedRect: bounds,
                cornerRadius: bounds.height / 2
            ).cgPath
        } else {
            layer.shadowPath = nil
        }
    }

    private func checkCompletion() {
        guard !isAnimating else { return }

        if let completion = pendingCompletion {
            pendingCompletion = nil
            completion(true)
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        startTime = CACurrentMediaTime()
        lastFrameTime = 0
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
        BackdropCoordinator.shared.captureIfNeeded()
        metalView?.draw()
    }
}

extension LegacyLiquidLensView: BackdropClient {

    public var backdropClientID: UUID {
        _backdropClientID
    }

    public var captureFrame: CGRect {
        guard let window = window, let container = liftedContainerView else { return .zero }
        return container.convert(container.bounds, to: window)
    }

    public var capturePadding: CGFloat {
        config.capturePadding
    }

    public var needsBackdrop: Bool {
        isLifted || isAnimating
    }

    public var backdropWindow: UIWindow? {
        window
    }

    public func prepareForCapture() {
        _captureState = (
            metalHidden: metalContainerView?.isHidden ?? true,
            restingHidden: restingBackgroundView.isHidden,
            mask: liftedContentView?.mask
        )
        metalContainerView?.isHidden = true
        restingBackgroundView.isHidden = true
        liftedContentView?.mask = nil
    }

    public func restoreAfterCapture() {
        metalContainerView?.isHidden = _captureState.metalHidden
        restingBackgroundView.isHidden = _captureState.restingHidden
        liftedContentView?.mask = _captureState.mask
    }

    public func didReceiveBackdrop(_ texture: MTLTexture, unionRect: CGRect, screenScale: CGFloat) {
        captureRectInWindow = unionRect
        captureRect = CGRect(origin: .zero, size: unionRect.size)
        renderer?.backdropTexture = texture
        hasValidBackdrop = true
        updateMetalFrame()
    }
}
