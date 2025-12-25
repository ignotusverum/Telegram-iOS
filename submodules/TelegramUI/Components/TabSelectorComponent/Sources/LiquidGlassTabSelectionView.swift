import UIKit
import MetalKit
import CustomLiquidGlass

final class LiquidGlassTabSelectionView: UIView {

    struct Config {
        var collapsedScale: CGFloat = 1.0
        var expandedScale: CGFloat = 1.15

        var metalShowThreshold: CGFloat = 1.02
        var fillHideThreshold: CGFloat = 1.06

        var collapsedInset: CGFloat = 0.0
        var liftedInsetX: CGFloat = 4.0
        var liftedInsetY: CGFloat = 4.0

        var liftStiffness: CGFloat = 400.0
        var liftDamping: CGFloat = 18.0

        var fillStiffness: CGFloat = 280.0
        var fillDamping: CGFloat = 16.0

        var hDeformWidthFactor: CGFloat = 0.35
        var hDeformHeightFactor: CGFloat = 0.25

        var refractionStrength: Float = 0
        var specularIntensity: Float = 0
        var refractionZonePercent: Float = 0.35
        var edgeIntensity: Float = 0
        var refractionScaleX: Float = 1.0
        var refractionScaleY: Float = 0.5
        var chromaticScaleX: Float = 1.0
        var chromaticScaleY: Float = 0.15
        var capturePadding: CGFloat = 100.0

        var shadowOpacity: Float = 0.15
        var shadowRadius: CGFloat = 8
        var shadowOffset: CGSize = CGSize(width: 0, height: 3)

        static let `default` = Config()
    }

    var config: Config = .default {
        didSet { applyAnimatorConfig() }
    }

    private let restingBackgroundView: UIImageView

    var baseFrame: CGRect = .zero {
        didSet {
            guard baseFrame != oldValue else { return }

            if isLifted && !isTransitioning {
                let deltaX = baseFrame.midX - oldValue.midX
                let now = CACurrentMediaTime()
                let dt = lastFrameTime > 0 ? min(now - lastFrameTime, 1.0/30.0) : 1.0/120.0
                let velocityX = deltaX / CGFloat(dt)
                wobbleAnimator.trackVelocity(CGPoint(x: velocityX, y: 0))
            }

            let newPosition = CGPoint(x: baseFrame.midX, y: baseFrame.midY)
            if !isLifted && !isTransitioning {
                positionAnimator.setPosition(newPosition, animated: false)
            } else {
                positionAnimator.target = newPosition
            }

            updateFrameFromScale()
            updateVisibility()
            updateRestingFillFrame()
            updateMetalFrame()
            updateShadow()
            if let renderer = renderer, let window = window {
                updateShaderUniforms(renderer: renderer, screenScale: window.screen.scale)
                metalView?.draw()
            }
        }
    }

    var fillColor: UIColor = UIColor(white: 0.0, alpha: 0.05) {
        didSet {
            restingBackgroundView.backgroundColor = fillColor
        }
    }

    public private(set) var isLifted = false
    private(set) var isActivated = false

    private let liftAnimator = LegacyScaleAnimator()
    private let fillAlphaAnimator = LegacyScaleAnimator()
    private let wobbleAnimator = LegacyWobbleAnimator()
    private let positionAnimator = LegacySpringAnimator()

    var isTransitioning = false
    private var transitionTargetFrame: CGRect = .zero

    private var hasValidBackdrop = false

    var fullContentArea: CGRect = .zero

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
    private var _captureState: (metalHidden: Bool, restingHidden: Bool) = (true, false)

    private var isAnimating: Bool {
        !liftAnimator.isSettled || !fillAlphaAnimator.isSettled || !positionAnimator.isSettled
    }

    private var scaleProgress: CGFloat {
        (liftAnimator.current - config.collapsedScale) / (config.expandedScale - config.collapsedScale)
    }

    var onLayoutUpdate: (() -> Void)?

    override init(frame: CGRect) {
        self.restingBackgroundView = UIImageView()
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        self.restingBackgroundView = UIImageView()
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        clipsToBounds = false
        layer.masksToBounds = false
        isUserInteractionEnabled = false

        restingBackgroundView.layer.cornerCurve = .continuous
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
    }

    private func resetAnimatorValues() {
        liftAnimator.setValue(config.collapsedScale, animated: false)
        fillAlphaAnimator.setValue(1.0, animated: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalContainerView?.frame = bounds
    }

    func activate() {
        guard !isActivated else { return }
        isActivated = true
        BackdropCoordinator.shared.register(self)
        BackdropCoordinator.shared.setNeedsCapture()
        startDisplayLink()
    }

    func deactivate() {
        guard isActivated else { return }
        isActivated = false
        BackdropCoordinator.shared.unregister(self)
        stopDisplayLink()
    }

    deinit {
        BackdropCoordinator.shared.unregister(self)
    }

    func expand() {
        guard !isLifted else { return }
        isLifted = true
        expandAnimation()
    }

    private func expandAnimation() {
        activate()
        wobbleAnimator.reset()
        fillAlphaAnimator.setValue(0, animated: false)
        wobbleAnimator.triggerLift()
        BackdropCoordinator.shared.setNeedsCapture()
        liftAnimator.setValue(config.expandedScale, animated: true)
        startDisplayLink()

        if hasValidBackdrop {
            metalContainerView?.isHidden = false
            metalView?.isPaused = false
            cachedMetalHidden = false
        }
    }

    private func collapseAnimation() {
        wobbleAnimator.release()
        liftAnimator.stiffness = config.liftStiffness
        liftAnimator.damping = config.liftDamping
        liftAnimator.setValue(config.collapsedScale, animated: true)
        fillAlphaAnimator.target = 1.0
    }

    func requestBackdropCapture() {
        BackdropCoordinator.shared.setNeedsCapture()
    }

    func collapse() {
        guard isLifted else { return }
        isLifted = false

        wobbleAnimator.release()
        liftAnimator.setValue(config.collapsedScale, animated: true)
        fillAlphaAnimator.target = 1.0
    }

    func transitionToFrame(_ newFrame: CGRect, animated: Bool, delay: TimeInterval = 0.0) {
        if isTransitioning {
            transitionTargetFrame = newFrame
            baseFrame = newFrame
            positionAnimator.setPosition(CGPoint(x: newFrame.midX, y: newFrame.midY), animated: animated)
            return
        }

        let wasAlreadyLifted = isLifted
        let currentCenter = wasAlreadyLifted ? self.center : CGPoint(x: baseFrame.midX, y: baseFrame.midY)

        isTransitioning = true
        transitionTargetFrame = newFrame
        baseFrame = newFrame

        positionAnimator.setPosition(currentCenter, animated: false)

        let startAnimation = { [weak self] in
            guard let self else { return }
            self.positionAnimator.setPosition(CGPoint(x: newFrame.midX, y: newFrame.midY), animated: animated)

            if !wasAlreadyLifted {
                self.isLifted = true
                self.expandAnimation()
            }

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

    func cancelTransition() {
        guard isTransitioning else { return }
        isTransitioning = false
        positionAnimator.setPosition(CGPoint(x: baseFrame.midX, y: baseFrame.midY), animated: false)
    }

    func trackVelocity(_ velocity: CGFloat) {
        wobbleAnimator.trackVelocity(CGPoint(x: velocity, y: 0))
    }

    func releaseVelocity() {
        wobbleAnimator.release()
    }

    func updateAppearance(image: UIImage?, tintColor: UIColor, isDark: Bool) {
        restingBackgroundView.image = image
        fillColor = tintColor
    }

    private func update() {
        let frameTimestamp = CACurrentMediaTime()
        let dt = lastFrameTime == 0 ? 1.0 / 120.0 : min(frameTimestamp - lastFrameTime, 1.0 / 30.0)
        lastFrameTime = frameTimestamp

        liftAnimator.step()
        fillAlphaAnimator.step()
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
                collapseAnimation()
            }
        }

        let settled = !isAnimating && wobbleAnimator.isSettled && positionAnimator.isSettled
        if settled && !isLifted {
            stopDisplayLink()
            return
        }

        updateFrameFromScale()
        updateVisibility()
        updateRestingFillFrame()

        guard let renderer = renderer, let window = window, captureRectInWindow != .zero else { return }

        updateMetalFrame()
        updateShaderUniforms(renderer: renderer, screenScale: window.screen.scale)
        updateShadow()
        onLayoutUpdate?()
    }

    private func updateVisibility() {
        let scale = liftAnimator.current

        let showMetal = (scale > config.metalShowThreshold || isLifted) && hasValidBackdrop

        // Hide blob completely when lifted - only show when fully collapsed
        let showFill = !isLifted && scale < config.fillHideThreshold

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
    }

    private func updateRestingFillFrame() {
        guard baseFrame.width > 0, (restingBackgroundView.alpha > 0 || !fillAlphaAnimator.isSettled) else { return }

        let hDeform = wobbleAnimator.horizontalValue

        let widthMult: CGFloat
        let heightMult: CGFloat

        if abs(hDeform) > 0.001 {
            widthMult = 1.0 - hDeform * config.hDeformWidthFactor
            heightMult = 1.0 + hDeform * config.hDeformHeightFactor
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

extension LiquidGlassTabSelectionView: BackdropClient {

    var backdropClientID: UUID {
        _backdropClientID
    }

    var captureFrame: CGRect {
        guard let window = window, let superview = superview else { return .zero }
        let frame = fullContentArea.isEmpty ? baseFrame : fullContentArea
        return superview.convert(frame, to: window)
    }

    var capturePadding: CGFloat {
        config.capturePadding
    }

    var needsBackdrop: Bool {
        isLifted || isAnimating
    }

    var backdropWindow: UIWindow? {
        window
    }

    func prepareForCapture() {
        _captureState = (
            metalHidden: metalContainerView?.isHidden ?? true,
            restingHidden: restingBackgroundView.isHidden
        )
        metalContainerView?.isHidden = true
        restingBackgroundView.isHidden = true
    }

    func restoreAfterCapture() {
        metalContainerView?.isHidden = _captureState.metalHidden
        restingBackgroundView.isHidden = _captureState.restingHidden
    }

    func didReceiveBackdrop(_ texture: MTLTexture, unionRect: CGRect, screenScale: CGFloat) {
        captureRectInWindow = unionRect
        captureRect = CGRect(origin: .zero, size: unionRect.size)
        renderer?.backdropTexture = texture
        hasValidBackdrop = true
        updateMetalFrame()
        updateVisibility()

        if isLifted, let renderer = renderer {
            metalContainerView?.isHidden = false
            metalView?.isPaused = false
            cachedMetalHidden = false
            updateShaderUniforms(renderer: renderer, screenScale: screenScale)
            metalView?.draw()
        }
    }
}
