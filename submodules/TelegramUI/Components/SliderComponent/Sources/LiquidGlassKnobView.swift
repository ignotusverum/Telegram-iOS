import UIKit
import MetalKit

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
        static let grayThreshold: CGFloat = 1.08
        // Rendering
        static let capturePadding: CGFloat = 40.0
        static let refractionStrength: Float = 8.0
        static let specularIntensity: Float = 0.2
        static let refractionZonePercent: Float = 0.35
        static let edgeIntensity: Float = 1.0
        // Deformation settings
        static let deformStrength: CGFloat = 0.4
        static let heightDeformRatio: CGFloat = 0.75
        // Shadow
        static let shadowOpacity: Float = 0.2
        static let shadowRadius: CGFloat = 12
        static let shadowOffset: CGSize = CGSize(width: 0, height: 4)
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
    private var renderer: SliderGlassRenderer?
    private var texturePool: SliderIOSurfaceTexturePool?
    private var hasValidBackdrop: Bool = false
    private var lastCapturedKnobX: CGFloat = -1000  // Track position for capture optimization

    // MARK: - Animators

    private var scaleAnimator = SliderScaleAnimator()
    private var wobbleAnimator = SliderWobbleAnimator()
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

        let glassRenderer = SliderGlassRenderer(device: device)
        if glassRenderer == nil {
            print("[LiquidGlassKnobView] Failed to create SliderGlassRenderer")
        }
        mtkView.delegate = glassRenderer

        glassRenderer?.onUpdate = { [weak self] in
            self?.updateUniforms()
        }

        addSubview(mtkView)
        self.metalView = mtkView
        self.renderer = glassRenderer
        self.texturePool = SliderIOSurfaceTexturePool(device: device)
    }

    private func setupAnimators() {
        scaleAnimator.stiffness = 400
        scaleAnimator.damping = 18
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

        // Capture backdrop while expanded, but only when knob moves significantly
        let willBeExpanded = currentScale > Constants.expandedThreshold
        if willBeExpanded && isExpanded {
            let moveThreshold: CGFloat = 2.0  // Only recapture if moved more than 2pt
            if abs(knobCenterX - lastCapturedKnobX) > moveThreshold || !hasValidBackdrop {
                captureBackdrop()
                lastCapturedKnobX = knobCenterX
            }
        }

        if !scaleSettled || !wobbleSettled || isExpanded {
            updateLayout()
            updateShadow()
        }
    }

    // MARK: - Public API

    func expand() {
        guard !isExpanded else { return }
        isExpanded = true

        lastCapturedKnobX = knobCenterX
        captureBackdrop()
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

    // MARK: - Backdrop Capture

    func captureBackdrop() {
        // Find the best view to capture from - go up hierarchy to find a substantial container
        guard let pool = texturePool,
              bounds.width > 0 && bounds.height > 0 else {
            return
        }

        // Go up the view hierarchy to find a good capture source
        // This ensures we capture the full background, not just immediate parent
        var captureView: UIView? = superview
        var depth = 0
        while let parent = captureView?.superview, depth < 3 {
            captureView = parent
            depth += 1
        }

        guard let targetView = captureView else { return }

        let scale = metalView?.contentScaleFactor ?? UIScreen.main.scale
        let capture = captureRect

        guard let context = pool.getContext(size: capture.size, scale: scale) else {
            return
        }

        pool.lockForCPU()

        let captureRectInTarget = convert(capture, to: targetView)

        // Hide our views during capture
        metalView?.isHidden = true
        collapsedKnobView.isHidden = true

        context.saveGState()
        context.translateBy(x: -captureRectInTarget.origin.x * scale, y: -captureRectInTarget.origin.y * scale)
        context.scaleBy(x: scale, y: scale)
        targetView.layer.render(in: context)
        context.restoreGState()

        // Restore visibility using staggered thresholds
        let thumbScale = currentScale
        let showMetal = thumbScale > Constants.metalThreshold && hasValidBackdrop
        metalView?.isHidden = !showMetal
        let showGray = thumbScale < Constants.grayThreshold
        collapsedKnobView.isHidden = !showGray

        pool.unlockForCPU()

        renderer?.backdropTexture = pool.getTexture()
        hasValidBackdrop = true
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
        renderer.glassUniforms.refractionScaleX = 1.0
        renderer.glassUniforms.refractionScaleY = 1.0
        renderer.glassUniforms.chromaticScaleX = 1.0
        renderer.glassUniforms.chromaticScaleY = 1.0
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
