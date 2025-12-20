import UIKit
import MetalKit
import CustomLiquidGlass

final class LiquidGlassKnobView: UIView {

    private enum Constants {
        static let thumbWidth: CGFloat = 38
        static let thumbHeight: CGFloat = 24
        static let expandedScale: CGFloat = 1.5
        static let collapsedScale: CGFloat = 1.0
        static let expandedThreshold: CGFloat = 1.01
        static let metalThreshold: CGFloat = 1.03
        static let grayThreshold: CGFloat = 1.04
        static let capturePadding: CGFloat = 40.0
        static let refractionStrength: Float = 10.0
        static let specularIntensity: Float = 0.2
        static let refractionZonePercent: Float = 0.45
        static let edgeIntensity: Float = 1.0
        static let deformStrength: CGFloat = 0.35
        static let heightDeformRatio: CGFloat = 0.45
        static let shadowOpacity: Float = 0.2
        static let shadowRadius: CGFloat = 12
        static let shadowOffset: CGSize = CGSize(width: 0, height: 4)
        static let borderOuter: Float = 0
        static let borderInner: Float = 0
    }

    var knobWidth: CGFloat = Constants.thumbWidth {
        didSet { updateLayout() }
    }

    var knobHeight: CGFloat = Constants.thumbHeight {
        didSet { updateLayout() }
    }

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

    var onTick: (() -> Void)?
    var onPrepareForCapture: (() -> Void)?
    var onRestoreAfterCapture: (() -> Void)?

    // Track info for lifted fill
    var trackFillColor: CGColor? {
        didSet { liftedFillLayer?.backgroundColor = trackFillColor }
    }
    var trackFrame: CGRect = .zero {
        didSet { updateLiftedFill() }
    }
    var trackHeight: CGFloat = 8

    private var collapsedKnobView: UIView!
    private var liftedFillContainer: UIView!
    private var liftedFillLayer: CALayer!

    private var metalView: MTKView?
    private var renderer: LegacyLensRenderer?
    private var hasValidBackdrop: Bool = false

    private lazy var _backdropClientID = UUID()
    private var _captureState: (metalHidden: Bool, collapsedHidden: Bool) = (true, true)

    private var scaleAnimator = LegacyScaleAnimator()
    private var wobbleAnimator = SpringWobbleAnimator()
    private var displayLink: CADisplayLink?

    private var currentScale: CGFloat {
        scaleAnimator.current
    }

    private var currentDeform: CGFloat {
        CGFloat(wobbleAnimator.normalizedVelocity.x)
    }

    private var scaleProgress: CGFloat {
        let range = Constants.expandedScale - Constants.collapsedScale
        return (currentScale - Constants.collapsedScale) / range
    }

    private var widthMultiplier: CGFloat {
        1.0 + currentDeform * Constants.deformStrength
    }

    private var heightMultiplier: CGFloat {
        1.0 - currentDeform * Constants.deformStrength * Constants.heightDeformRatio
    }

    private var currentKnobWidth: CGFloat {
        knobWidth * currentScale * widthMultiplier
    }

    private var currentKnobHeight: CGFloat {
        knobHeight * currentScale * heightMultiplier
    }

    private var captureRect: CGRect {
        let maxWidth = knobWidth * Constants.expandedScale * 1.5
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

    private func setup() {
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = false

        setupCollapsedKnob()
        setupMetal()
        setupLiftedFill()
        setupAnimators()
    }

    private func setupLiftedFill() {
        liftedFillContainer = UIView()
        liftedFillContainer.clipsToBounds = true
        liftedFillContainer.isUserInteractionEnabled = false
        liftedFillContainer.layer.cornerCurve = .continuous
        addSubview(liftedFillContainer)

        liftedFillLayer = CALayer()
        liftedFillLayer.cornerRadius = trackHeight / 2
        liftedFillContainer.layer.addSublayer(liftedFillLayer)
    }

    private func setupCollapsedKnob() {
        collapsedKnobView = UIView()
        collapsedKnobView.backgroundColor = .white
        collapsedKnobView.layer.cornerCurve = .continuous
        collapsedKnobView.isUserInteractionEnabled = false

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
        scaleAnimator.damping = 18
        scaleAnimator.setValue(Constants.collapsedScale, animated: false)

        wobbleAnimator.limits = .default
        wobbleAnimator.stiffness = 400
        wobbleAnimator.damping = 18
        wobbleAnimator.maxVelocity = 800
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        if #available(iOS 15.0, *) {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        } else {
            displayLink?.preferredFramesPerSecond = 60
        }
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateLayout()
    }

    private func updateLayout() {
        let scale = currentScale
        let width = currentKnobWidth
        let height = currentKnobHeight

        let knobFrame = CGRect(
            x: knobCenterX - width / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )

        let showCollapsed = scale < Constants.grayThreshold
        let showMetal = scale > Constants.metalThreshold && hasValidBackdrop

        collapsedKnobView.frame = knobFrame
        collapsedKnobView.layer.cornerRadius = min(width, height) / 2
        collapsedKnobView.isHidden = !showCollapsed

        if showMetal {
            let capture = captureRect
            metalView?.frame = capture
            metalView?.isPaused = false
        } else {
            metalView?.isPaused = true
        }
        metalView?.isHidden = !showMetal

        updateLiftedFill()
        liftedFillContainer.isHidden = !showMetal
    }

    private func updateLiftedFill() {
        guard trackFrame.width > 0 else { return }

        let width = currentKnobWidth
        let height = currentKnobHeight

        // Position container at knob frame (pill shape mask)
        let containerFrame = CGRect(
            x: knobCenterX - width / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )
        liftedFillContainer.frame = containerFrame
        liftedFillContainer.layer.cornerRadius = min(width, height) / 2

        // Position fill layer to align with track
        // Fill extends from track start to knob center
        let trackY = (height - trackHeight) / 2
        let fillStartX = trackFrame.minX - containerFrame.minX
        let fillWidth = knobCenterX - trackFrame.minX

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liftedFillLayer.frame = CGRect(
            x: fillStartX,
            y: trackY,
            width: max(0, fillWidth),
            height: trackHeight
        )
        liftedFillLayer.cornerRadius = trackHeight / 2
        liftedFillLayer.backgroundColor = trackFillColor
        CATransaction.commit()
    }

    @objc private func displayLinkFired() {
        scaleAnimator.step()
        wobbleAnimator.update(dt: 1.0 / 120.0)

        let scaleSettled = scaleAnimator.isSettled
        let wobbleSettled = wobbleAnimator.isSettled
        let settled = scaleSettled && wobbleSettled

        BackdropCoordinator.shared.captureIfNeeded()

        updateLayout()
        updateShadow()
        metalView?.draw()
        onTick?()

        if settled && !isExpanded {
            stopDisplayLink()
        }
    }

    func expand() {
        guard !isExpanded else { return }
        isExpanded = true

        BackdropCoordinator.shared.setNeedsCapture()
        scaleAnimator.target = Constants.expandedScale
        wobbleAnimator.triggerLift()
        startDisplayLink()
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

    func handlePan(_ gesture: UIPanGestureRecognizer, in view: UIView) {
        wobbleAnimator.handlePan(gesture, in: view)
    }

    private func updateUniforms() {
        guard let renderer = renderer else { return }

        let capture = captureRect
        guard capture.width > 0 && capture.height > 0 else { return }

        let displayScale = metalView?.contentScaleFactor ?? UIScreen.main.scale
        let width = currentKnobWidth
        let height = currentKnobHeight

        let knobCenterInCapture = CGPoint(
            x: knobCenterX - capture.origin.x,
            y: bounds.height / 2 - capture.origin.y
        )

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
        onPrepareForCapture?()
    }

    public func restoreAfterCapture() {
        let thumbScale = currentScale
        let showMetal = thumbScale > Constants.metalThreshold && hasValidBackdrop
        metalView?.isHidden = !showMetal
        let showGray = thumbScale < Constants.grayThreshold
        collapsedKnobView.isHidden = !showGray
        onRestoreAfterCapture?()
    }

    public func didReceiveBackdrop(_ texture: MTLTexture, unionRect: CGRect, screenScale: CGFloat) {
        renderer?.backdropTexture = texture
        hasValidBackdrop = true

        renderer?.updateForBackdrop(unionRect: unionRect, clientCaptureFrame: captureFrame, screenScale: screenScale)
    }
}
