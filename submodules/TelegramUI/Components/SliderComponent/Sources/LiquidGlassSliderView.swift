import UIKit
import LegacyComponents

final class LiquidGlassSliderView: TGPhotoEditorSliderView {

    private enum Constants {
        static let trackHeight: CGFloat = 8
        static let thumbWidth: CGFloat = 38
        static let thumbHeight: CGFloat = 24
    }

    private var trackContainer: UIView!
    private var trackTintLayer: CALayer!
    private var trackFillMaskLayer: CALayer!
    private var glassKnobView: LiquidGlassKnobView!

    var onTrackingChanged: ((Bool) -> Void)?

    private var isCurrentlyTracking: Bool = false
    private var lastKnobX: CGFloat = 0
    private var lastUpdateTime: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLiquidGlass()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLiquidGlass()
    }

    private func setupLiquidGlass() {
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false

        knobView.isHidden = true
        knobView.alpha = 0

        trackContainer = UIView()
        trackContainer.isUserInteractionEnabled = false
        trackContainer.layer.masksToBounds = true
        insertSubview(trackContainer, at: 0)

        trackTintLayer = CALayer()
        trackTintLayer.masksToBounds = true
        trackContainer.layer.addSublayer(trackTintLayer)

        trackFillMaskLayer = CALayer()
        trackFillMaskLayer.backgroundColor = UIColor.white.cgColor
        trackTintLayer.mask = trackFillMaskLayer

        glassKnobView = LiquidGlassKnobView()
        glassKnobView.knobWidth = Constants.thumbWidth
        glassKnobView.knobHeight = Constants.thumbHeight
        glassKnobView.onTick = { [weak self] in
            guard let self else { return }
            self.updateTrackFill()
            self.trackVelocityIfNeeded()
        }
        glassKnobView.onPrepareForCapture = { [weak self] in
            self?.prepareTrackForCapture()
        }
        glassKnobView.onRestoreAfterCapture = { [weak self] in
            self?.restoreTrackAfterCapture()
        }
        addSubview(glassKnobView)

        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0
        longPressGesture.delegate = self
        addGestureRecognizer(longPressGesture)

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

    private func trackVelocityIfNeeded() {
        guard isCurrentlyTracking else { return }

        let currentX = knobView.center.x
        let currentTime = CACurrentMediaTime()
        let dt = currentTime - lastUpdateTime

        if dt > 0.001 {
            let velocity = (currentX - lastKnobX) / CGFloat(dt)
            glassKnobView.trackVelocity(velocity)
        }

        lastKnobX = currentX
        lastUpdateTime = currentTime
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let trackY = (bounds.height - Constants.trackHeight) / 2
        let padding = Constants.thumbWidth / 2

        trackContainer.frame = CGRect(
            x: padding,
            y: trackY,
            width: bounds.width - padding * 2,
            height: Constants.trackHeight
        )
        trackContainer.layer.cornerRadius = Constants.trackHeight / 2

        trackTintLayer.frame = trackContainer.bounds
        trackTintLayer.cornerRadius = Constants.trackHeight / 2
        trackFillMaskLayer.frame = trackContainer.bounds

        glassKnobView.frame = bounds
        glassKnobView.trackFrame = trackContainer.frame
        glassKnobView.trackHeight = Constants.trackHeight

        updateKnobPosition()
        updateTrackFill()
    }

    override func draw(_ rect: CGRect) {
    }

    private func expectedKnobCenterX() -> CGFloat {
        let normalizedValue: CGFloat
        if maximumValue > minimumValue {
            normalizedValue = (value - minimumValue) / (maximumValue - minimumValue)
        } else {
            normalizedValue = 0
        }
        let padding = Constants.thumbWidth / 2
        let totalLength = bounds.width - padding * 2
        return padding + totalLength * normalizedValue
    }

    private func updateTrackFill() {
        guard trackContainer.bounds.width > 0 else { return }

        let knobCenterX = expectedKnobCenterX()

        let padding = Constants.thumbWidth / 2
        let fillWidth = knobCenterX - padding

        trackFillMaskLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)
        trackFillMaskLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: max(0, fillWidth),
            height: Constants.trackHeight
        )
        CATransaction.commit()
    }

    private func prepareTrackForCapture() {
        trackContainer.isHidden = true
    }

    private func restoreTrackAfterCapture() {
        trackContainer.isHidden = false
    }

    private func updateKnobPosition() {
        glassKnobView.knobCenterX = expectedKnobCenterX()
    }

    override var value: CGFloat {
        didSet {
            updateTrackFill()
            updateKnobPosition()
        }
    }

    func configureColors(trackBackground: UIColor, trackForeground: UIColor) {
        trackContainer.backgroundColor = trackBackground
        trackTintLayer.backgroundColor = trackForeground.cgColor
        glassKnobView.trackFillColor = trackForeground.cgColor
    }
}

extension LiquidGlassSliderView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}
