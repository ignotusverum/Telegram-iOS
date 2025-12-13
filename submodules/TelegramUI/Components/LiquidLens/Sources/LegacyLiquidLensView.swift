import UIKit
import MetalKit

public final class LegacyLiquidLensView: UIView {

    // MARK: - Public Properties

    public weak var liftedContainerView: UIView?
    public weak var liftedContentView: UIView?
    public weak var overridePunchoutView: UIView?

    public var warpsContentBelow: Bool = true
    public var style: Int32 = 1
    public var liftedContentMode: Int32 = 1
    public var restingBackgroundColor: UIColor? {
        didSet { updateRestingBackground() }
    }

    // MARK: - Private Properties

    private var isLifted: Bool = false
    private let backgroundLayer = CALayer()

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
        layer.addSublayer(backgroundLayer)
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
        backgroundLayer.frame = bounds
        backgroundLayer.cornerRadius = bounds.height / 2
        metalContainerView?.frame = bounds
    }

    private func updateRestingBackground() {
        backgroundLayer.backgroundColor = restingBackgroundColor?.cgColor
    }

    // MARK: - Backdrop Capture

    private func captureBackdrop() {
        guard let texturePool = texturePool,
              let window = window,
              let containerView = liftedContainerView else {
            return
        }

        let tabBarInWindow = containerView.convert(containerView.bounds, to: window)

        let expansion: CGFloat = 60.0
        captureRect = CGRect(
            x: tabBarInWindow.origin.x - expansion,
            y: tabBarInWindow.origin.y - expansion,
            width: tabBarInWindow.width + expansion * 2,
            height: tabBarInWindow.height + expansion * 2
        )

        let scale = window.screen.scale

        let wasHidden = isHidden
        let contentWasHidden = liftedContentView?.isHidden ?? true
        isHidden = true
        liftedContentView?.isHidden = true

        texturePool.lockForCPU()

        if let context = texturePool.getContext(size: captureRect.size, scale: scale) {
            context.saveGState()
            context.translateBy(x: -captureRect.origin.x * scale, y: -captureRect.origin.y * scale)
            context.scaleBy(x: scale, y: scale)
            window.layer.render(in: context)
            context.restoreGState()
        }

        texturePool.unlockForCPU()

        isHidden = wasHidden
        liftedContentView?.isHidden = contentWasHidden

        renderer?.backdropTexture = texturePool.getTexture()
        updateMetalViewFrame()
    }

    private func updateMetalViewFrame() {
        guard let window = window, captureRect != .zero else { return }
        let frameInSelf = window.convert(captureRect, to: self)
        metalContainerView?.frame = bounds
        metalView?.frame = frameInSelf
    }

    // MARK: - Uniforms Update

    private func updateUniforms() {
        guard let renderer = renderer,
              let window = window,
              captureRect != .zero else { return }

        liftAnimator.step()

        let now = CACurrentMediaTime()
        let dt = lastFrameTime == 0 ? 1.0 / 120.0 : min(now - lastFrameTime, 1.0 / 30.0)
        lastFrameTime = now

        let currentX = frame.origin.x
        let deltaX = currentX - lastFrameX
        lastFrameX = currentX

        let instantVelocity = dt > 0 ? deltaX / CGFloat(dt) : 0
        wobbleAnimator.trackVelocity(instantVelocity)
        wobbleAnimator.update(dt: CGFloat(dt))

        let scale = window.screen.scale

        let lensInWindow = convert(bounds, to: window)
        let lensOriginInCapture = CGPoint(
            x: lensInWindow.origin.x - captureRect.origin.x,
            y: lensInWindow.origin.y - captureRect.origin.y
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
        renderer.glassUniforms.refractionStrength = 5
        renderer.glassUniforms.specularIntensity = 0.4
        renderer.glassUniforms.refractionZonePercent = 0.40
        renderer.glassUniforms.edgeIntensity = 0.8
        renderer.glassUniforms.verticalEdgeRefractionScale = 1.0
        renderer.glassUniforms.scrollVelocity = SIMD2<Float>(Float(wobbleAnimator.normalizedValue), 0)
        renderer.glassUniforms.time = Float(CACurrentMediaTime() - startTime)

        updateMetalViewFrame()

        if !isLifted && liftAnimator.isSettled && wobbleAnimator.isSettled {
            stopDisplayLink()
        }
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

        if lifted {
            captureBackdrop()
            liftAnimator.setValue(1.0, animated: animated)
            startDisplayLink()
        } else {
            liftAnimator.setValue(0.0, animated: animated)
        }

        alongsideAnimations?()
        completion?(true)
    }
}
