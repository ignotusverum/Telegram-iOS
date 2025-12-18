import UIKit
import LegacyComponents

final class LiquidGlassSliderView: TGPhotoEditorSliderView {

    // MARK: - Constants

    private enum Constants {
        static let trackHeight: CGFloat = 8
        static let thumbWidth: CGFloat = 38
        static let thumbHeight: CGFloat = 24
    }

    // MARK: - Views

    private var trackContainer: UIView!
    private var trackTintLayer: CALayer!
    private var glassKnobView: LiquidGlassKnobView!

    // MARK: - Properties

    var onTrackingChanged: ((Bool) -> Void)?

    private var isCurrentlyTracking: Bool = false
    private var lastKnobX: CGFloat = 0
    private var lastUpdateTime: CFTimeInterval = 0
    private var displayLink: CADisplayLink?

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLiquidGlass()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLiquidGlass()
    }

    // MARK: - Setup

    private func setupLiquidGlass() {
        // Hide original drawing
        backgroundColor = .clear
        isOpaque = false

        // Hide original knob
        knobView.isHidden = true
        knobView.alpha = 0

        // Setup track container
        trackContainer = UIView()
        trackContainer.isUserInteractionEnabled = false
        trackContainer.layer.masksToBounds = true
        insertSubview(trackContainer, at: 0)

        // Setup track tint layer (filled portion)
        trackTintLayer = CALayer()
        trackTintLayer.masksToBounds = true
        trackContainer.layer.addSublayer(trackTintLayer)

        // Setup glass knob
        glassKnobView = LiquidGlassKnobView()
        glassKnobView.knobWidth = Constants.thumbWidth
        glassKnobView.knobHeight = Constants.thumbHeight
        addSubview(glassKnobView)

        // Setup display link for velocity tracking
        setupDisplayLink()

        // Setup long press gesture for tap & hold expand (like LegacyLiquidLensView)
        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0
        longPressGesture.delegate = self
        addGestureRecognizer(longPressGesture)

        // Setup interaction callbacks
        interactionBegan = { [weak self] in
            guard let self else { return }
            self.isCurrentlyTracking = true
            self.lastKnobX = self.knobView.center.x
            self.lastUpdateTime = CACurrentMediaTime()
            self.glassKnobView.expand()
            self.onTrackingChanged?(true)
        }
        interactionEnded = { [weak self] in
            guard let self else { return }
            self.isCurrentlyTracking = false
            self.glassKnobView.collapse()
            self.glassKnobView.releaseVelocity()
            self.onTrackingChanged?(false)
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            if !isCurrentlyTracking {
                glassKnobView.expand()
            }
        case .ended, .cancelled:
            if !isCurrentlyTracking {
                glassKnobView.collapse()
            }
        default:
            break
        }
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

    @objc private func displayLinkFired() {
        // Update track fill every frame to stay in sync with knob
        updateTrackFill()

        guard isCurrentlyTracking else { return }

        let currentX = knobView.center.x
        let currentTime = CACurrentMediaTime()
        let dt = currentTime - lastUpdateTime

        if dt > 0.001 {  // Avoid division by zero
            let velocity = (currentX - lastKnobX) / CGFloat(dt)
            glassKnobView.trackVelocity(velocity)
        }

        lastKnobX = currentX
        lastUpdateTime = currentTime
    }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        let trackY = (bounds.height - Constants.trackHeight) / 2
        let trackInset = Constants.thumbWidth / 2

        // Track container spans the usable width
        trackContainer.frame = CGRect(
            x: trackInset,
            y: trackY,
            width: bounds.width - trackInset * 2,
            height: Constants.trackHeight
        )
        trackContainer.layer.cornerRadius = Constants.trackHeight / 2

        // Track tint layer
        trackTintLayer.frame = trackContainer.bounds
        trackTintLayer.cornerRadius = Constants.trackHeight / 2

        // Glass knob view spans full bounds
        glassKnobView.frame = bounds

        // Sync knob position with parent's knobView
        updateKnobPosition()
        updateTrackFill()
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        // Override to prevent parent's drawing
        // We handle all rendering with our custom views/layers
    }

    // MARK: - Track Updates

    /// Calculate expected knob center X from value (no animation lag)
    private func expectedKnobCenterX() -> CGFloat {
        let normalizedValue: CGFloat
        if maximumValue > minimumValue {
            normalizedValue = (value - minimumValue) / (maximumValue - minimumValue)
        } else {
            normalizedValue = 0
        }
        // Knob center moves from thumbWidth/2 to (bounds.width - thumbWidth/2)
        let trackInset = Constants.thumbWidth / 2
        return trackInset + (bounds.width - Constants.thumbWidth) * normalizedValue
    }

    private func updateTrackFill() {
        guard trackContainer.bounds.width > 0 else { return }

        let knobCenterX: CGFloat
        if isCurrentlyTracking {
            // During tracking, use calculated position to avoid animation lag
            knobCenterX = expectedKnobCenterX()
        } else {
            // When not tracking, follow the actual knob position
            knobCenterX = knobView.center.x
        }

        // Fill extends from track start to knob center
        let trackInset = Constants.thumbWidth / 2
        let fillWidth = knobCenterX - trackInset

        // Remove ALL animations and set frame immediately
        trackTintLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)
        trackTintLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: max(0, fillWidth),
            height: Constants.trackHeight
        )
        CATransaction.commit()
    }

    private func updateKnobPosition() {
        if isCurrentlyTracking {
            // During tracking, use calculated position to match fill exactly
            glassKnobView.knobCenterX = expectedKnobCenterX()
        } else {
            // When not tracking, follow the actual knob position
            glassKnobView.knobCenterX = knobView.center.x
        }
    }

    // MARK: - Value Changes

    override var value: CGFloat {
        didSet {
            updateTrackFill()
            updateKnobPosition()
        }
    }

    // MARK: - Color Configuration

    func configureColors(trackBackground: UIColor, trackForeground: UIColor) {
        trackContainer.backgroundColor = trackBackground
        trackTintLayer.backgroundColor = trackForeground.cgColor
    }
}

// MARK: - UIGestureRecognizerDelegate

extension LiquidGlassSliderView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}
