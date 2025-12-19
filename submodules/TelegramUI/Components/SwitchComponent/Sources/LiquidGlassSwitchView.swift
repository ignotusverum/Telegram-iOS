import UIKit
import MetalKit
import CustomLiquidGlass

private final class LiquidGlassSwitchViewLayer: CALayer {
    override func setNeedsDisplay() {
        // Override to prevent unnecessary redraws with AsyncDisplayKit
    }
}

public final class LiquidGlassSwitchView: UIControl {

    public override class var layerClass: AnyClass {
        if #available(iOS 26.0, *) {
            return super.layerClass
        } else {
            return LiquidGlassSwitchViewLayer.self
        }
    }

    // MARK: - Constants

    private enum Constants {
        static let trackWidth: CGFloat = 64
        static let trackHeight: CGFloat = 28
        static let thumbWidth: CGFloat = 39
        static let thumbHeight: CGFloat = 24
        static let thumbPadding: CGFloat = 3
        static let expandedScaleX: CGFloat = 1.6
        static let expandedScaleY: CGFloat = 1.6
        static let expandedThreshold: CGFloat = 1.3
        static let metalThreshold: CGFloat = 1.03
        static let grayThreshold: CGFloat = 1.04
        static let capturePadding: CGFloat = 40.0
        static let refractionStrength: Float = 10.0
        static let specularIntensity: Float = 0.2
        static let refractionZonePercent: Float = 0.25
        static let edgeIntensity: Float = 1.0
        static let deformStrength: CGFloat = 0.35
        static let heightDeformRatio: CGFloat = 0.75
    }

    // MARK: - Public Properties

    public private(set) var isOn: Bool = false {
        didSet {
            if oldValue != isOn {
                sendActions(for: .valueChanged)
            }
        }
    }

    public var onTintColor: UIColor = UIColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1.0) {
        didSet { updateTrackColor() }
    }

    public var offTintColor: UIColor = UIColor(white: 0.9, alpha: 0.3) {
        didSet { updateTrackColor() }
    }

    // MARK: - Views

    private var trackContainer: UIView!
    private var trackTintLayer: CALayer!
    private var thumbBackground: UIView!
    private var metalContainerView: UIView!
    private var metalView: MTKView?
    private var renderer: SwitchGlassRenderer?
    private var hasValidBackdrop: Bool = false

    // MARK: - BackdropClient Support

    private lazy var _backdropClientID = UUID()
    private var _captureState: (metalHidden: Bool, thumbHidden: Bool) = (true, true)

    // MARK: - Animation

    private var positionAnimator = SwitchScaleAnimator()
    private var thumbScaleAnimator = SwitchScaleAnimator()
    private var wobbleAnimator = SwitchWobbleAnimator()
    private var displayLink: CADisplayLink?
    private var pendingCollapseWork: DispatchWorkItem?

    // MARK: - Computed Properties

    private var thumbMinX: CGFloat {
        Constants.thumbPadding + Constants.thumbWidth / 2
    }

    private var thumbMaxX: CGFloat {
        Constants.trackWidth - Constants.thumbWidth / 2 - Constants.thumbPadding
    }

    private var currentDeform: CGFloat {
        CGFloat(wobbleAnimator.normalizedVelocity.x)
    }

    private var widthMultiplier: CGFloat {
        1.0 + currentDeform * Constants.deformStrength
    }

    private var heightMultiplier: CGFloat {
        1.0 - currentDeform * Constants.deformStrength * Constants.heightDeformRatio
    }

    private var captureRect: CGRect {
        let maxScaledSize = max(Constants.thumbWidth * Constants.expandedScaleX, Constants.thumbHeight * Constants.expandedScaleY)
        let padding = (maxScaledSize * 1.5 - Constants.thumbHeight) / 2 + 10
        return bounds.insetBy(dx: -padding, dy: -padding)
    }

    // MARK: - Initialization

    public override init(frame: CGRect) {
        super.init(frame: frame)
        print("[LiquidGlassSwitchView] init with frame: \(frame)")
        setup()
    }

    public required init?(coder: NSCoder) {
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
        clipsToBounds = false
        setupTrack()
        setupThumbBackground()
        setupMetalView()
        setupGestures()
        setupAnimators()
        setupDisplayLink()
    }

    private func setupTrack() {
        trackContainer = UIView()
        trackContainer.backgroundColor = .clear
        trackContainer.layer.cornerCurve = .continuous
        trackContainer.clipsToBounds = true
        trackContainer.isUserInteractionEnabled = false
        addSubview(trackContainer)

        trackTintLayer = CALayer()
        trackTintLayer.backgroundColor = offTintColor.cgColor
        trackContainer.layer.addSublayer(trackTintLayer)
    }

    private func setupThumbBackground() {
        thumbBackground = UIView()
        thumbBackground.backgroundColor = .white
        thumbBackground.layer.cornerCurve = .continuous
        thumbBackground.isUserInteractionEnabled = false
        thumbBackground.layer.shadowColor = UIColor.black.cgColor
        thumbBackground.layer.shadowOffset = CGSize(width: 0, height: 2)
        thumbBackground.layer.shadowRadius = 4
        thumbBackground.layer.shadowOpacity = 0.15
        addSubview(thumbBackground)
    }

    private func setupMetalView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return
        }

        metalContainerView = UIView()
        metalContainerView.clipsToBounds = false
        metalContainerView.backgroundColor = .clear
        metalContainerView.isUserInteractionEnabled = false
        metalContainerView.isHidden = true
        metalContainerView.frame = .zero  // Will be set in updateThumbFrame when needed
        insertSubview(metalContainerView, at: 0)  // Behind other views

        let mtkView = MTKView(frame: .zero, device: device)
        mtkView.isOpaque = false
        mtkView.backgroundColor = .clear
        mtkView.framebufferOnly = false
        mtkView.preferredFramesPerSecond = 120
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = false
        mtkView.clipsToBounds = false
        mtkView.isUserInteractionEnabled = false

        renderer = SwitchGlassRenderer(device: device)
        mtkView.delegate = renderer

        renderer?.onUpdate = { [weak self] in
            self?.updateUniforms()
        }

        metalContainerView.addSubview(mtkView)
        self.metalView = mtkView

        BackdropCoordinator.shared.register(self)
    }

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }

    private func setupAnimators() {
        positionAnimator.stiffness = 400
        positionAnimator.damping = 18
        positionAnimator.setValue(thumbMinX, animated: false)

        thumbScaleAnimator.stiffness = 400
        thumbScaleAnimator.damping = 18
        thumbScaleAnimator.setValue(1.0, animated: false)

        wobbleAnimator.limits = .subtle
    }

    private func setupDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        if #available(iOS 15.0, *) {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        }
        displayLink?.add(to: .main, forMode: .common)
    }

    // MARK: - Layout

    public override var intrinsicContentSize: CGSize {
        CGSize(width: Constants.trackWidth, height: Constants.trackHeight)
    }

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: Constants.trackWidth, height: Constants.trackHeight)
    }

    public override var frame: CGRect {
        didSet {
            print("[LiquidGlassSwitchView] frame changed from \(oldValue) to \(frame)")
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()

        print("[LiquidGlassSwitchView] layoutSubviews - frame: \(frame), bounds: \(bounds), superview: \(String(describing: superview))")

        // Use intrinsic size if bounds are empty
        let effectiveWidth = bounds.width > 0 ? bounds.width : Constants.trackWidth
        let effectiveHeight = bounds.height > 0 ? bounds.height : Constants.trackHeight

        let trackFrame = CGRect(
            x: (effectiveWidth - Constants.trackWidth) / 2,
            y: (effectiveHeight - Constants.trackHeight) / 2,
            width: Constants.trackWidth,
            height: Constants.trackHeight
        )

        print("[LiquidGlassSwitchView] trackFrame: \(trackFrame)")
        trackContainer.frame = trackFrame
        trackContainer.layer.cornerRadius = Constants.trackHeight / 2

        trackTintLayer.frame = trackContainer.bounds
        trackTintLayer.cornerRadius = Constants.trackHeight / 2

        updateThumbFrame()
    }

    private func updateThumbFrame() {
        let thumbX = positionAnimator.current
        let trackFrame = trackContainer.frame
        let animatorScale = thumbScaleAnimator.current

        let progress = (animatorScale - 1.0) / (Constants.expandedScaleX - 1.0)
        let scaleX = animatorScale
        let scaleY = 1.0 + progress * (Constants.expandedScaleY - 1.0)

        let deform = currentDeform
        let wMult = 1.0 + deform * Constants.deformStrength
        let hMult = 1.0 - deform * Constants.deformStrength * Constants.heightDeformRatio

        let scaledWidth = Constants.thumbWidth * scaleX * wMult
        let scaledHeight = Constants.thumbHeight * scaleY * hMult

        let thumbY = trackFrame.minY + (trackFrame.height - scaledHeight) / 2

        let thumbFrame = CGRect(
            x: trackFrame.minX + thumbX - scaledWidth / 2,
            y: thumbY,
            width: scaledWidth,
            height: scaledHeight
        )

        let showGray = animatorScale < Constants.grayThreshold
        let showMetal = animatorScale > Constants.metalThreshold && hasValidBackdrop

        thumbBackground.frame = thumbFrame
        thumbBackground.layer.cornerRadius = scaledHeight / 2
        thumbBackground.isHidden = !showGray

        metalContainerView?.isHidden = !showMetal
        metalView?.isPaused = !showMetal

        if showMetal {
            let captureArea = captureRect
            metalContainerView?.frame = captureArea
            metalView?.frame = metalContainerView?.bounds ?? captureArea
            updateUniformsGeometry(thumbFrame: thumbFrame)
        }

        updateTrackColor()
    }

    private func updateTrackColor() {
        let thumbX = positionAnimator.current
        let colorProgress = max(0, min(1, (thumbX - thumbMinX) / (thumbMaxX - thumbMinX)))

        var offR: CGFloat = 0, offG: CGFloat = 0, offB: CGFloat = 0, offA: CGFloat = 0
        var onR: CGFloat = 0, onG: CGFloat = 0, onB: CGFloat = 0, onA: CGFloat = 0
        offTintColor.getRed(&offR, green: &offG, blue: &offB, alpha: &offA)
        onTintColor.getRed(&onR, green: &onG, blue: &onB, alpha: &onA)

        let blendedColor = UIColor(
            red: offR + (onR - offR) * colorProgress,
            green: offG + (onG - offG) * colorProgress,
            blue: offB + (onB - offB) * colorProgress,
            alpha: offA + (onA - offA) * colorProgress
        )
        trackTintLayer.backgroundColor = blendedColor.cgColor
    }

    // MARK: - Display Link

    @objc private func displayLinkFired() {
        positionAnimator.step()
        thumbScaleAnimator.step()
        wobbleAnimator.update(dt: 1.0 / 120.0)

        let positionSettled = positionAnimator.isSettled
        let scaleSettled = thumbScaleAnimator.isSettled
        let wobbleSettled = wobbleAnimator.isSettled

        let willBeExpanded = thumbScaleAnimator.current > Constants.expandedThreshold
        if willBeExpanded && !hasValidBackdrop {
            BackdropCoordinator.shared.setNeedsCapture()
        }

        BackdropCoordinator.shared.captureIfNeeded()

        if !positionSettled || !scaleSettled || !wobbleSettled {
            updateThumbFrame()
        }
    }

    // MARK: - Gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        pendingCollapseWork?.cancel()

        thumbScaleAnimator.target = Constants.expandedScaleX

        isOn = !isOn
        let targetX = isOn ? thumbMaxX : thumbMinX
        positionAnimator.target = targetX

        scheduleCollapse(delay: 0.2)
    }

    private func scheduleCollapse(delay: TimeInterval) {
        pendingCollapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.thumbScaleAnimator.target = 1.0
        }
        pendingCollapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: trackContainer)
        let progress = (location.x / Constants.trackWidth).clamped(to: 0...1)

        wobbleAnimator.handlePan(gesture, in: self)

        switch gesture.state {
        case .began:
            pendingCollapseWork?.cancel()
            thumbScaleAnimator.target = Constants.expandedScaleX
        case .changed:
            let targetX = thumbMinX + progress * (thumbMaxX - thumbMinX)
            positionAnimator.target = targetX
        case .ended, .cancelled:
            let shouldBeOn = progress > 0.5
            isOn = shouldBeOn
            let targetX = shouldBeOn ? thumbMaxX : thumbMinX
            positionAnimator.target = targetX
            scheduleCollapse(delay: 0.2)
        default:
            break
        }
    }

    // MARK: - Public API

    public func setOn(_ on: Bool, animated: Bool) {
        let changed = isOn != on
        isOn = on
        let targetX = on ? thumbMaxX : thumbMinX

        if animated {
            pendingCollapseWork?.cancel()
            thumbScaleAnimator.target = Constants.expandedScaleX
            positionAnimator.target = targetX
            scheduleCollapse(delay: 0.2)
        } else {
            positionAnimator.setValue(targetX, animated: false)
            thumbScaleAnimator.setValue(1.0, animated: false)
            updateThumbFrame()
        }

        if changed {
            sendActions(for: .valueChanged)
        }
    }

    // MARK: - Metal Uniforms

    private func updateUniforms() {
        guard renderer != nil else { return }
        // Updated in updateUniformsGeometry
    }

    private func updateUniformsGeometry(thumbFrame: CGRect) {
        guard let renderer = renderer else { return }

        let captureArea = captureRect
        guard captureArea.width > 0 && captureArea.height > 0 else { return }
        guard thumbFrame.width > 0 && thumbFrame.height > 0 else { return }

        let scale = metalView?.contentScaleFactor ?? UIScreen.main.scale
        let pillRadius = thumbFrame.height / 2

        renderer.glassUniforms.viewSize = SIMD2<Float>(
            Float(captureArea.width * scale),
            Float(captureArea.height * scale)
        )

        let thumbOriginInCapture = CGPoint(
            x: thumbFrame.origin.x - captureArea.origin.x,
            y: thumbFrame.origin.y - captureArea.origin.y
        )
        renderer.glassUniforms.glassOrigin = SIMD2<Float>(
            Float(thumbOriginInCapture.x * scale),
            Float(thumbOriginInCapture.y * scale)
        )

        renderer.glassUniforms.glassSize = SIMD2<Float>(
            Float(thumbFrame.width * scale),
            Float(thumbFrame.height * scale)
        )

        renderer.glassUniforms.cornerRadius = Float(pillRadius * scale)
        renderer.glassUniforms.refractionStrength = Constants.refractionStrength
        renderer.glassUniforms.specularIntensity = Constants.specularIntensity
        renderer.glassUniforms.refractionZonePercent = Constants.refractionZonePercent
        renderer.glassUniforms.scrollVelocity = wobbleAnimator.normalizedVelocity
        renderer.glassUniforms.time = Float(CACurrentMediaTime())
        renderer.glassUniforms.edgeIntensity = Constants.edgeIntensity
        renderer.glassUniforms.refractionScaleY = 0.5
    }

}

// MARK: - BackdropClient

extension LiquidGlassSwitchView: BackdropClient {

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
        thumbScaleAnimator.current > Constants.expandedThreshold
    }

    public var backdropWindow: UIWindow? {
        window
    }

    public func prepareForCapture() {
        _captureState = (
            metalHidden: metalContainerView?.isHidden ?? true,
            thumbHidden: thumbBackground?.isHidden ?? true
        )
        metalContainerView?.isHidden = true
        thumbBackground?.isHidden = true
    }

    public func restoreAfterCapture() {
        let thumbScale = thumbScaleAnimator.current
        let isExpanded = thumbScale > Constants.expandedThreshold
        metalContainerView?.isHidden = !(isExpanded && hasValidBackdrop)
        thumbBackground?.isHidden = thumbScale >= Constants.grayThreshold
    }

    public func didReceiveBackdrop(_ texture: MTLTexture, unionRect: CGRect, screenScale: CGFloat) {
        renderer?.backdropTexture = texture
        hasValidBackdrop = true
    }
}

// MARK: - Comparable Extension

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
