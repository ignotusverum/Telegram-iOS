import UIKit
import Display
import ComponentFlow
import CustomLiquidGlass
import GlassBackgroundComponent

final class LiquidGlassKnobView: UIView {

    private enum Constants {
        static let thumbWidth: CGFloat = 38
        static let thumbHeight: CGFloat = 24
        static let expandedScale: CGFloat = 1.5
        static let collapsedScale: CGFloat = 1.0
        static let expandedThreshold: CGFloat = 1.01
        static let glassThreshold: CGFloat = 1.03
        static let grayThreshold: CGFloat = 1.04
        static let deformStrength: CGFloat = 0.6
        static let heightDeformRatio: CGFloat = 0.45
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

    let customBlurRadius: CGFloat = 4.0

    private var collapsedKnobView: UIView!
    private var glassBackdropView: GlassBackgroundView!

    private var scaleAnimator = LegacyScaleAnimator()
    private var wobbleAnimator = SpringWobbleAnimator()
    private var displayLink: CADisplayLink?

    private var currentScale: CGFloat {
        scaleAnimator.current
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

    private var currentKnobWidth: CGFloat {
        knobWidth * currentScale * widthMultiplier
    }

    private var currentKnobHeight: CGFloat {
        knobHeight * currentScale * heightMultiplier
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
    }

    private func setup() {
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = false

        setupCollapsedKnob()
        setupGlassBackdrop()
        setupAnimators()
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

    private func setupGlassBackdrop() {
        glassBackdropView = GlassBackgroundView(frame: .zero, customBlurRadius: customBlurRadius)
        glassBackdropView.isUserInteractionEnabled = false
        glassBackdropView.isHidden = true
        addSubview(glassBackdropView)
    }

    private func setupAnimators() {
        scaleAnimator.stiffness = 400
        scaleAnimator.damping = 18
        scaleAnimator.setValue(Constants.collapsedScale, animated: false)

        wobbleAnimator.limits = .default
        wobbleAnimator.stiffness = 280
        wobbleAnimator.damping = 11
        wobbleAnimator.maxVelocity = 1200
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
        let showGlass = scale > Constants.glassThreshold

        collapsedKnobView.frame = knobFrame
        collapsedKnobView.layer.cornerRadius = min(width, height) / 2
        collapsedKnobView.isHidden = !showCollapsed

        glassBackdropView.frame = knobFrame
        glassBackdropView.update(
            size: knobFrame.size,
            cornerRadius: min(width, height) / 2,
            isDark: false,
            tintColor: GlassBackgroundView.TintColor(kind: .panel, color: .clear),
            transition: .immediate
        )
        glassBackdropView.isHidden = !showGlass
    }

    @objc private func displayLinkFired() {
        scaleAnimator.step()
        wobbleAnimator.update(dt: 1.0 / 120.0)

        let scaleSettled = scaleAnimator.isSettled
        let wobbleSettled = wobbleAnimator.isSettled
        let settled = scaleSettled && wobbleSettled

        updateLayout()
        onTick?()

        if settled && !isExpanded {
            stopDisplayLink()
        }
    }

    func expand() {
        guard !isExpanded else { return }
        isExpanded = true

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
}
