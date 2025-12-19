import UIKit
import MetalKit
import CustomLiquidGlass

final class LiquidGlassKnobView: UIView {

    // MARK: - Constants

    private enum Constants {
        // Pill shape dimensions
        static let thumbWidth: CGFloat = 38
        static let thumbHeight: CGFloat = 24
        // Scale animation
        static let expandedScale: CGFloat = 1.5
        static let collapsedScale: CGFloat = 1.0
        // Staggered visibility thresholds
        static let expandedThreshold: CGFloat = 1.01
        static let metalThreshold: CGFloat = 1.03
        static let grayThreshold: CGFloat = 1.04
        // Rendering
        static let capturePadding: CGFloat = 40.0
        static let refractionStrength: Float = 10.0
        static let specularIntensity: Float = 0.2
        static let refractionZonePercent: Float = 0.45
        static let edgeIntensity: Float = 1.0
        // Deformation settings
        static let deformStrength: CGFloat = 0.35
        static let heightDeformRatio: CGFloat = 0.45
        // Shadow
        static let shadowOpacity: Float = 0.2
        static let shadowRadius: CGFloat = 12
        static let shadowOffset: CGSize = CGSize(width: 0, height: 4)
        // Border
        static let borderOuter: Float = 0
        static let borderInner: Float = 0
    }

    // MARK: - Properties

    var knobWidth: CGFloat = Constants.thumbWidth {
        didSet { updateLayout() }
    }

    var knobHeight: CGFloat = Constants.thumbHeight {
        didSet { updateLayout() }
    }

    /// Convenience setter for backward compatibility
    var knobSize: CGFloat {
        get { knobWidth }
        set {
            knobWidth = newValue
            knobHeight = newValue * (Constants.thumbHeight / Constants.thumbWidth)
        }
    }

    var knobCenterX: CGFloat = 0 {
        didSet { updateLayout() }
    }

    private(set) var isExpanded: Bool = false

    // MARK: - Views

    private var collapsedKnobView: UIView!

    // MARK: - Metal Components

    private var metalView: MTKView?
    private var renderer: LegacyLensRenderer?
    private var hasValidBackdrop: Bool = false

    // MARK: - BackdropClient Support

    private lazy var _backdropClientID = UUID()
    private var _captureState: (metalHidden: Bool, collapsedHidden: Bool) = (true, true)

    // MARK: - Animators

    private var scaleAnimator = LegacyScaleAnimator()
    private var wobbleAnimator = SpringWobbleAnimator()
    private var displayLink: CADisplayLink?

    // MARK: - Computed Properties

    private var currentScale: CGFloat {
        scaleAnimator.current
    }

    /// Current deformation value from wobble animator (-1 to 1 range normalized)
    private var currentDeform: CGFloat {
        CGFloat(wobbleAnimator.normalizedVelocity.x)
    }

    /// Scale progress from collapsed (0.0) to expanded (1.0)
    private var scaleProgress: CGFloat {
        let range = Constants.expandedScale - Constants.collapsedScale
        return (currentScale - Constants.collapsedScale) / range
    }

    /// Width multiplier based on deformation (stretches when moving fast)
    private var widthMultiplier: CGFloat {
        1.0 + currentDeform * Constants.deformStrength
    }

    /// Height multiplier based on deformation (squashes when stretching)
    private var heightMultiplier: CGFloat {
        1.0 - currentDeform * Constants.deformStrength * Constants.heightDeformRatio
    }

    /// Current knob width with scale and deformation applied
    private var currentKnobWidth: CGFloat {
        knobWidth * currentScale * widthMultiplier
    }

    /// Current knob height with scale and deformation applied
    private var currentKnobHeight: CGFloat {
        knobHeight * currentScale * heightMultiplier
    }

    /// The area to capture for backdrop (knob + padding for expanded state)
    private var captureRect: CGRect {
        let maxWidth = knobWidth * Constants.expandedScale * 1.5  // Extra room for deformation
        let maxHeight = knobHeight * Constants.expandedScale * 1.5
        let padding = Constants.capturePadding
        let totalWidth = bounds.width + padding * 2
        let totalHeight = max(maxWidth, maxHeight) + padding * 2
        return CGRect(
            x: -padding,
            y: (bounds.height - totalHeight) / 2,
            width: totalWidth,
            height: totalHeight
        )
    }

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        displayLink?.invalidate()
        BackdropCoordinator.shared.unregister(self)
    }

    // MARK: - Setup

    private func setup() {
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = false

        setupCollapsedKnob()
        setupMetal()
        setupAnimators()
        setupDisplayLink()
    }

    private func setupCollapsedKnob() {
        collapsedKnobView = UIView()
        collapsedKnobView.backgroundColor = .white
        collapsedKnobView.layer.cornerCurve = .continuous
        collapsedKnobView.isUserInteractionEnabled = false

        // Drop shadow
        collapsedKnobView.layer.shadowColor = UIColor.black.cgColor
        collapsedKnobView.layer.shadowOffset = CGSize(width: 0, height: 2)
        collapsedKnobView.layer.shadowRadius = 4
        collapsedKnobView.layer.shadowOpacity = 0.15

        addSubview(collapsedKnobView)
    }

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[LiquidGlassKnobView] Metal not available")
            return
        }

        let mtkView = MTKView(frame: bounds, device: device)
        mtkView.isOpaque = false
        mtkView.backgroundColor = .clear
        mtkView.framebufferOnly = false
        mtkView.preferredFramesPerSecond = 120
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = false
        mtkView.clipsToBounds = false
        mtkView.isUserInteractionEnabled = false

        let glassRenderer = LegacyLensRenderer(device: device)
        if glassRenderer == nil {
            print("[LiquidGlassKnobView] Failed to create LegacyLensRenderer")
        }
        mtkView.delegate = glassRenderer

        glassRenderer?.onUpdate = { [weak self] in
            self?.updateUniforms()
        }

        addSubview(mtkView)
        self.metalView = mtkView
        self.renderer = glassRenderer

        BackdropCoordinator.shared.register(self)
    }

    private func setupAnimators() {
        scaleAnimator.stiffness = 400
        scaleAnimator.damping = 18  // Faster response for slider
        scaleAnimator.setValue(Constants.collapsedScale, animated: false)

        // Use default limits for slider knob (more visible deformation)
        wobbleAnimator.limits = .default
        wobbleAnimator.stiffness = 400   // Higher = faster response
        wobbleAnimator.damping = 18      // Lower = more wobble
        wobbleAnimator.maxVelocity = 800 // Lower = more sensitive
    }

    private func setupDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        if #available(iOS 15.0, *) {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        } else {
            displayLink?.preferredFramesPerSecond = 60
        }
        displayLink?.add(to: .main, forMode: .common)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        updateLayout()
    }

    private func updateLayout() {
        let scale = currentScale
        let width = currentKnobWidth
        let height = currentKnobHeight

        // Knob frame centered at knobCenterX with deformation applied
        let knobFrame = CGRect(
            x: knobCenterX - width / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )

        // Staggered visibility
        let showCollapsed = scale < Constants.grayThreshold
        let showMetal = scale > Constants.metalThreshold && hasValidBackdrop

        // Update collapsed knob (pill shape with deformation already in frame)
        collapsedKnobView.frame = knobFrame
        collapsedKnobView.layer.cornerRadius = min(width, height) / 2
        collapsedKnobView.isHidden = !showCollapsed

        // Update Metal view
        if showMetal {
            let capture = captureRect
            metalView?.frame = capture
            metalView?.isPaused = false
        } else {
            metalView?.isPaused = true
        }
        metalView?.isHidden = !showMetal
    }

    // MARK: - Display Link

    @objc private func displayLinkFired() {
        scaleAnimator.step()
        wobbleAnimator.update(dt: 1.0 / 120.0)

        let scaleSettled = scaleAnimator.isSettled
        let wobbleSettled = wobbleAnimator.isSettled

        // Request continuous capture while expanded (track fill changes as knob moves)
        if isExpanded {
            BackdropCoordinator.shared.setNeedsCapture()
        }
        BackdropCoordinator.shared.captureIfNeeded()

        if !scaleSettled || !wobbleSettled || isExpanded {
            updateLayout()
            updateShadow()
        }
    }

    // MARK: - Public API

    func expand() {
        guard !isExpanded else { return }
        isExpanded = true

        BackdropCoordinator.shared.setNeedsCapture()
        scaleAnimator.target = Constants.expandedScale
        wobbleAnimator.triggerLift()
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false

        scaleAnimator.target = Constants.collapsedScale
        wobbleAnimator.triggerDrop()
        wobbleAnimator.release()
    }

    func trackVelocity(_ velocity: CGFloat) {
        wobbleAnimator.trackVelocity(velocity)
    }

    func releaseVelocity() {
        wobbleAnimator.release()
    }

    /// Handle pan gesture directly to track velocity (like original)
    func handlePan(_ gesture: UIPanGestureRecognizer, in view: UIView) {
        wobbleAnimator.handlePan(gesture, in: view)
    }

    // MARK: - Uniforms Update

    private func updateUniforms() {
        guard let renderer = renderer else { return }

        let capture = captureRect
        guard capture.width > 0 && capture.height > 0 else { return }

        let displayScale = metalView?.contentScaleFactor ?? UIScreen.main.scale
        let width = currentKnobWidth
        let height = currentKnobHeight

        // Knob center in capture area coordinates
        let knobCenterInCapture = CGPoint(
            x: knobCenterX - capture.origin.x,
            y: bounds.height / 2 - capture.origin.y
        )

        // Knob origin (top-left) in capture area
        let knobOriginInCapture = CGPoint(
            x: knobCenterInCapture.x - width / 2,
            y: knobCenterInCapture.y - height / 2
        )

        renderer.glassUniforms.viewSize = SIMD2<Float>(
            Float(capture.width * displayScale),
            Float(capture.height * displayScale)
        )

        renderer.glassUniforms.glassOrigin = SIMD2<Float>(
            Float(knobOriginInCapture.x * displayScale),
            Float(knobOriginInCapture.y * displayScale)
        )

        renderer.glassUniforms.glassSize = SIMD2<Float>(
            Float(width * displayScale),
            Float(height * displayScale)
        )

        // Corner radius based on the smaller dimension (height) for pill shape
        renderer.glassUniforms.cornerRadius = Float(height * displayScale / 2)
        renderer.glassUniforms.refractionStrength = Constants.refractionStrength
        renderer.glassUniforms.specularIntensity = Constants.specularIntensity
        renderer.glassUniforms.refractionZonePercent = Constants.refractionZonePercent
        renderer.glassUniforms.scrollVelocity = wobbleAnimator.normalizedVelocity
        renderer.glassUniforms.time = Float(CACurrentMediaTime())
        renderer.glassUniforms.edgeIntensity = Constants.edgeIntensity
        renderer.glassUniforms.borderOuter = Constants.borderOuter
        renderer.glassUniforms.borderInner = Constants.borderInner
    }

    // MARK: - Shadow

    private func updateShadow() {
        let progress = scaleProgress
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = Constants.shadowOpacity * Float(progress)
        layer.shadowRadius = Constants.shadowRadius * progress
        layer.shadowOffset = CGSize(
            width: Constants.shadowOffset.width * progress,
            height: Constants.shadowOffset.height * progress
        )

        if progress > 0.01 {
            let knobFrame = CGRect(
                x: knobCenterX - currentKnobWidth / 2,
                y: (bounds.height - currentKnobHeight) / 2,
                width: currentKnobWidth,
                height: currentKnobHeight
            )
            layer.shadowPath = UIBezierPath(
                roundedRect: knobFrame,
                cornerRadius: min(currentKnobWidth, currentKnobHeight) / 2
            ).cgPath
        } else {
            layer.shadowPath = nil
        }
    }
}

// MARK: - BackdropClient

extension LiquidGlassKnobView: BackdropClient {

    public var backdropClientID: UUID {
        _backdropClientID
    }

    public var captureFrame: CGRect {
        guard let window = window else { return .zero }
        return convert(captureRect, to: window)
    }

    public var capturePadding: CGFloat {
        Constants.capturePadding
    }

    public var needsBackdrop: Bool {
        isExpanded
    }

    public var backdropWindow: UIWindow? {
        window
    }

    public func prepareForCapture() {
        _captureState = (
            metalHidden: metalView?.isHidden ?? true,
            collapsedHidden: collapsedKnobView.isHidden
        )
        metalView?.isHidden = true
        collapsedKnobView.isHidden = true
    }

    public func restoreAfterCapture() {
        // Restore visibility using staggered thresholds
        let thumbScale = currentScale
        let showMetal = thumbScale > Constants.metalThreshold && hasValidBackdrop
        metalView?.isHidden = !showMetal
        let showGray = thumbScale < Constants.grayThreshold
        collapsedKnobView.isHidden = !showGray
    }

    public func didReceiveBackdrop(_ texture: MTLTexture, unionRect: CGRect, screenScale: CGFloat) {
        renderer?.backdropTexture = texture
        hasValidBackdrop = true

        // Update uniforms based on capture rect
        guard let window = window else { return }
        let knobFrame = CGRect(
            x: knobCenterX - currentKnobWidth / 2,
            y: (bounds.height - currentKnobHeight) / 2,
            width: currentKnobWidth,
            height: currentKnobHeight
        )
        let glassFrameInWindow = convert(knobFrame, to: window)
        renderer?.updateForBackdrop(unionRect: unionRect, glassFrame: glassFrameInWindow, screenScale: screenScale)
    }
}
