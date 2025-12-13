import UIKit
import MetalKit

private var metalLibraryValue: MTLLibrary?
private func metalLibrary(device: MTLDevice) -> MTLLibrary? {
    if let metalLibraryValue {
        return metalLibraryValue
    }

    let mainBundle = Bundle(for: LegacyLiquidLensView.self)
    guard let path = mainBundle.path(forResource: "LiquidLensBundle", ofType: "bundle") else {
        return nil
    }
    guard let bundle = Bundle(path: path) else {
        return nil
    }
    guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
        return nil
    }

    metalLibraryValue = library
    return library
}

public final class LegacyLiquidLensView: UIView {

    public weak var liftedContainerView: UIView?
    public weak var liftedContentView: UIView?
    public weak var overridePunchoutView: UIView?

    public var warpsContentBelow: Bool = true
    public var style: Int32 = 1
    public var liftedContentMode: Int32 = 1
    public var restingBackgroundColor: UIColor? {
        didSet { updateRestingBackground() }
    }

    private var isLifted: Bool = false
    private let backgroundLayer = CALayer()

    private var metalDevice: MTLDevice?
    private var metalView: MTKView?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
        setupMetal()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        clipsToBounds = false
        layer.masksToBounds = false

        layer.addSublayer(backgroundLayer)
    }

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        self.metalDevice = device
        self.commandQueue = device.makeCommandQueue()

        let metalView = MTKView(frame: bounds, device: device)
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.framebufferOnly = true
        metalView.isOpaque = false
        metalView.backgroundColor = .clear
        metalView.layer.isOpaque = false
        metalView.clipsToBounds = false
        self.metalView = metalView
        addSubview(metalView)

        setupPipeline(device: device)
        setupSampler(device: device)
    }

    private func setupPipeline(device: MTLDevice) {
        guard let library = metalLibrary(device: device),
              let vertexFunction = library.makeFunction(name: "liquidGlassVertex"),
              let fragmentFunction = library.makeFunction(name: "liquidGlassTabBarFragment") else {
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func setupSampler(device: MTLDevice) {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: descriptor)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()

        backgroundLayer.frame = bounds
        backgroundLayer.cornerRadius = bounds.height / 2
        metalView?.frame = bounds
    }

    private func updateRestingBackground() {
        backgroundLayer.backgroundColor = restingBackgroundColor?.cgColor
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

        alongsideAnimations?()
        completion?(true)
    }
}
