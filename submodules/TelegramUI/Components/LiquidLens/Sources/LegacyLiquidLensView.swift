import UIKit
import MetalKit
import IOSurface

public final class LegacyLiquidLensView: UIView {

    // MARK: - Constants

    private enum Constants {
        // Scale-based thresholds (matching LiquidGlassComponents)
        static let collapsedScale: CGFloat = 1.0         // Base scale when collapsed
        static let expandedScale: CGFloat = 1.4          // Scale when lifted/expanded
        static let metalThreshold: CGFloat = 1.05        // Metal shows above this scale
        static let fillHideThreshold: CGFloat = 1.08     // Fill hides above this scale
        // Overlap between 1.05-1.08: both visible briefly during transition

        // Insets for collapsed vs lifted states
        static let collapsedInset: CGFloat = -4.0
        static let liftedInset: CGFloat = 10.0

        // Deformation strength (matches shader formula)
        static let deformWidthFactor: CGFloat = 0.35
        static let deformHeightFactor: CGFloat = 0.35 * 0.75
    }

    // MARK: - Public Properties

    public weak var liftedContainerView: UIView?
    public weak var liftedContentView: UIView?

    public var warpsContentBelow: Bool = true
    public var style: Int32 = 1
    public var liftedContentMode: Int32 = 1
    public var restingBackgroundColor: UIColor? {
        didSet { updateRestingBackground() }
    }

    /// Base frame set by parent - used to calculate interpolated bounds
    public var baseFrame: CGRect = .zero {
        didSet {
            if baseFrame != oldValue {
                updateFrameFromScale()
            }
        }
    }

    // MARK: - Private Properties

    private var isLifted: Bool = false
    private var isActivated: Bool = false
    private let backgroundLayer = CALayer()

    // Resting fill view (gray pill shown when collapsed)
    private let restingFillView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor(white: 0.0, alpha: 0.1)
        view.layer.cornerCurve = .continuous
        view.isUserInteractionEnabled = false
        return view
    }()

    // Fill animators for smooth transitions (matching LiquidGlassComponents)
    private let fillAlphaAnimator = LegacyScaleAnimator()   // 0.0 = hidden, 1.0 = visible
    private let fillScaleAnimator = LegacyScaleAnimator()   // Fill scale during transition
    private let fillDeformAnimator = LegacyScaleAnimator()  // Deformation handoff
    private var lastCapturedDeform: CGFloat = 0
    private var hasValidBackdrop: Bool = false

    // When true, uses internal backgroundLayer for resting state
    // When false, relies on LiquidLensView.restingBackgroundView (iOS 26 style)
    private let useInternalRestingBackground = false

    private var metalDevice: MTLDevice?
    private var metalContainerView: UIView?
    private var metalView: MTKView?
    private var renderer: LegacyLensRenderer?
    private var texturePool: IOSurfaceTexturePool?
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0

    private let liftAnimator = LegacyScaleAnimator()
    private let wobbleAnimator = LegacyWobbleAnimator()
    private var lastFrameX: CGFloat = 0
    private var lastFrameTime: CFTimeInterval = 0

    private var captureRect: CGRect = .zero
    private var captureRectInWindow: CGRect = .zero
    private let capturePadding: CGFloat = 60.0

    // Callback storage for proper timing
    private var pendingCompletion: ((Bool) -> Void)?
    private var wasSettled: Bool = true

    // MARK: - Initialization

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
        setupMetal()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupView() {
        clipsToBounds = false
        layer.masksToBounds = false
        if useInternalRestingBackground {
            layer.addSublayer(backgroundLayer)
        }

        // Add resting fill view (below metal)
        addSubview(restingFillView)

        // Initialize scale animator at collapsed state (1.0)
        liftAnimator.setValue(Constants.collapsedScale, animated: false)
        liftAnimator.stiffness = 300.0
        liftAnimator.damping = 25.0

        // Initialize fill animators (matching LiquidGlassComponents)
        fillAlphaAnimator.setValue(1.0, animated: false)  // Fill visible initially
        fillAlphaAnimator.stiffness = 400.0
        fillAlphaAnimator.damping = 25.0

        fillScaleAnimator.setValue(1.0, animated: false)  // Fill at full scale initially
        fillScaleAnimator.stiffness = 400.0
        fillScaleAnimator.damping = 25.0

        fillDeformAnimator.setValue(0, animated: false)   // No deformation initially
        fillDeformAnimator.stiffness = 300.0
        fillDeformAnimator.damping = 20.0
    }

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        self.metalDevice = device

        let container = UIView()
        container.clipsToBounds = false
        container.isUserInteractionEnabled = false
        addSubview(container)
        self.metalContainerView = container

        let metalView = MTKView(frame: .zero, device: device)
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.framebufferOnly = false
        metalView.isOpaque = false
        metalView.backgroundColor = .clear
        metalView.layer.isOpaque = false
        metalView.clipsToBounds = false
        metalView.isUserInteractionEnabled = false
        self.metalView = metalView
        container.addSubview(metalView)

        if let renderer = LegacyLensRenderer(device: device) {
            self.renderer = renderer
            metalView.delegate = renderer
            renderer.onUpdate = { [weak self] in
                self?.updateUniforms()
            }
        }

        self.texturePool = IOSurfaceTexturePool(device: device)
    }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        if useInternalRestingBackground {
            backgroundLayer.frame = bounds
            backgroundLayer.cornerRadius = bounds.height / 2
        }
        metalContainerView?.frame = bounds
    }

    private func updateRestingBackground() {
        if useInternalRestingBackground {
            backgroundLayer.backgroundColor = restingBackgroundColor?.cgColor
        }
    }

    // MARK: - Backdrop Capture

    private func captureBackdrop() {
        guard let texturePool = texturePool,
              let window = window,
              let containerView = liftedContainerView else {
            return
        }

        let scale = window.screen.scale

        let containerInWindow = containerView.convert(containerView.bounds, to: window)
        captureRectInWindow = containerInWindow.insetBy(dx: -capturePadding, dy: -capturePadding)
        captureRect = CGRect(origin: .zero, size: captureRectInWindow.size)

        // Hide lens and its content during capture
        let wasHidden = isHidden
        let contentWasHidden = liftedContentView?.isHidden ?? true
        isHidden = true
        liftedContentView?.isHidden = true

        texturePool.lockForCPU()

        if let context = texturePool.getContext(size: captureRect.size, scale: scale) {
            context.saveGState()
            context.translateBy(x: -captureRectInWindow.origin.x * scale, y: -captureRectInWindow.origin.y * scale)
            context.scaleBy(x: scale, y: scale)
            window.layer.render(in: context)
            context.restoreGState()
        }

        texturePool.unlockForCPU()

        isHidden = wasHidden
        liftedContentView?.isHidden = contentWasHidden

        renderer?.backdropTexture = texturePool.getTexture()
        hasValidBackdrop = true
        updateMetalViewFrame()
    }

    private func updateMetalViewFrame() {
        guard let window = window, captureRectInWindow != .zero else { return }
        let frameInSelf = window.convert(captureRectInWindow, to: self)
        metalContainerView?.frame = bounds
        metalView?.frame = frameInSelf
    }

    // MARK: - Uniforms Update

    private func updateUniforms() {
        guard let renderer = renderer,
              let window = window,
              captureRectInWindow != .zero else { return }

        // Step all animators
        liftAnimator.step()
        fillAlphaAnimator.step()
        fillScaleAnimator.step()
        fillDeformAnimator.step()

        let blobScale = liftAnimator.current

        // Track deformation while lifted (for handoff when collapsing)
        if isLifted {
            lastCapturedDeform = wobbleAnimator.normalizedValue
        }

        // Check if animation just settled (all animators)
        let isSettled = liftAnimator.isSettled && fillAlphaAnimator.isSettled && fillScaleAnimator.isSettled && fillDeformAnimator.isSettled
        if isSettled && !wasSettled {
            // Animation just completed
            pendingCompletion?(true)
            pendingCompletion = nil
        }
        wasSettled = isSettled

        let now = CACurrentMediaTime()
        let dt = lastFrameTime == 0 ? 1.0 / 120.0 : min(now - lastFrameTime, 1.0 / 30.0)
        lastFrameTime = now

        let currentX = frame.origin.x
        let deltaX = currentX - lastFrameX
        lastFrameX = currentX

        let instantVelocity = dt > 0 ? deltaX / CGFloat(dt) : 0
        wobbleAnimator.trackVelocity(instantVelocity)
        wobbleAnimator.update(dt: CGFloat(dt))

        // Update frame based on scale (scale-based like LiquidGlassComponents)
        updateFrameFromScale()

        // Scale-based visibility (matching LiquidGlassComponents thresholds)
        let showMetal = blobScale > Constants.metalThreshold && hasValidBackdrop
        let showFill = blobScale < Constants.fillHideThreshold

        metalContainerView?.isHidden = !showMetal
        metalView?.isPaused = !showMetal

        // Fill alpha controlled by animator (allows instant show/hide)
        restingFillView.alpha = showFill ? fillAlphaAnimator.current : 0.0

        // Update resting fill frame with scale and deformation
        updateRestingFillFrame()

        let scale = window.screen.scale

        let lensInWindow = convert(bounds, to: window)
        let lensOriginInCapture = CGPoint(
            x: lensInWindow.origin.x - captureRectInWindow.origin.x,
            y: lensInWindow.origin.y - captureRectInWindow.origin.y
        )

        renderer.glassUniforms.viewSize = SIMD2<Float>(
            Float(captureRect.width * scale),
            Float(captureRect.height * scale)
        )
        renderer.glassUniforms.glassOrigin = SIMD2<Float>(
            Float(lensOriginInCapture.x * scale),
            Float(lensOriginInCapture.y * scale)
        )
        renderer.glassUniforms.glassSize = SIMD2<Float>(
            Float(bounds.width * scale),
            Float(bounds.height * scale)
        )

        renderer.glassUniforms.cornerRadius = Float(bounds.height * scale / 2)
        renderer.glassUniforms.refractionStrength = 6
        renderer.glassUniforms.specularIntensity = 0.4
        renderer.glassUniforms.refractionZonePercent = 0.4
        renderer.glassUniforms.edgeIntensity = 0.8
        renderer.glassUniforms.verticalEdgeRefractionScale = 1
        renderer.glassUniforms.scrollVelocity = SIMD2<Float>(Float(wobbleAnimator.normalizedValue), 0)
        renderer.glassUniforms.time = Float(CACurrentMediaTime() - startTime)

        updateMetalViewFrame()
    }

    // MARK: - Frame Interpolation

    /// Updates view bounds based on blob scale (1.0 = collapsed, 1.4 = lifted)
    private func updateFrameFromScale() {
        guard baseFrame.width > 0 else { return }

        let blobScale = liftAnimator.current

        // Map scale to inset: 1.0 → collapsedInset, expandedScale → liftedInset
        let scaleProgress = (blobScale - Constants.collapsedScale) / (Constants.expandedScale - Constants.collapsedScale)
        let currentInset = Constants.collapsedInset + (Constants.liftedInset - Constants.collapsedInset) * scaleProgress

        let newBounds = CGRect(
            origin: .zero,
            size: CGSize(
                width: baseFrame.width + currentInset * 2,
                height: baseFrame.height + currentInset * 2
            )
        )
        let newCenter = CGPoint(x: baseFrame.midX, y: baseFrame.midY)

        bounds = newBounds
        center = newCenter
    }

    /// Updates resting fill view frame with scale and deformation (for shape handoff)
    private func updateRestingFillFrame() {
        guard baseFrame.width > 0 else { return }

        let fillScale = fillScaleAnimator.current
        let deform = fillDeformAnimator.current

        // Deformation multipliers (for shape wobble)
        let widthMult = 1.0 + deform * Constants.deformWidthFactor
        let heightMult = 1.0 - deform * Constants.deformHeightFactor

        // Use collapsed size as base (fill is shown when collapsed)
        let baseWidth = baseFrame.width + Constants.collapsedInset * 2
        let baseHeight = baseFrame.height + Constants.collapsedInset * 2

        // Apply both scale and deformation
        let width = baseWidth * fillScale * widthMult
        let height = baseHeight * fillScale * heightMult

        restingFillView.frame = CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
        restingFillView.layer.cornerRadius = height / 2
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        startTime = CACurrentMediaTime()
        lastFrameX = frame.origin.x
        lastFrameTime = 0
        wobbleAnimator.reset()
        metalView?.isPaused = false
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        metalView?.isPaused = true
    }

    @objc private func displayLinkFired() {
        metalView?.draw()
    }

    // MARK: - Public API

    public func activate() {
        guard !isActivated else { return }
        isActivated = true
        captureBackdrop()
        startDisplayLink()
    }

    public func setLifted(
        _ lifted: Bool,
        animated: Bool,
        alongsideAnimations: (() -> Void)?,
        completion: ((Bool) -> Void)?
    ) {
        guard lifted != isLifted else {
            completion?(true)
            return
        }
        isLifted = lifted

        // Store completion for later (called when animation settles)
        pendingCompletion = completion
        wasSettled = false

        if lifted {
            // EXPANDING (matching LiquidGlassComponents startExpandAnimation):
            // 1. INSTANTLY hide fill (prevents flash during transition)
            fillAlphaAnimator.setValue(0, animated: false)
            fillScaleAnimator.target = 0.9  // Fill shrinks during expand
            fillDeformAnimator.setValue(0, animated: false)

            // 2. Re-capture backdrop when lifting to get fresh content
            captureBackdrop()

            // 3. Expand blob scale (1.0 → 1.4)
            liftAnimator.setValue(Constants.expandedScale, animated: animated)
            startDisplayLink()
        } else {
            // COLLAPSING (matching LiquidGlassComponents startCollapseAnimation):
            // 1. Capture current deformation for handoff
            let currentDeform = lastCapturedDeform

            // 2. Shrink blob scale (1.4 → 1.0)
            liftAnimator.setValue(Constants.collapsedScale, animated: animated)

            // 3. Fill appears INSTANTLY with inherited deformation
            fillScaleAnimator.setValue(1.0, animated: false)
            fillAlphaAnimator.setValue(1.0, animated: false)
            fillDeformAnimator.setValue(currentDeform, animated: false)

            // 4. Only deform animates back to 0 (shape stabilizes)
            fillDeformAnimator.target = 0
        }

        // Call alongside animations immediately (like native behavior)
        alongsideAnimations?()

        // If not animated, complete immediately
        if !animated {
            pendingCompletion?(true)
            pendingCompletion = nil
        }
    }

    /// Update resting background color for fill view
    public func updateRestingFillColor(_ color: UIColor?) {
        restingFillView.backgroundColor = color ?? UIColor(white: 0.0, alpha: 0.1)
    }
}
