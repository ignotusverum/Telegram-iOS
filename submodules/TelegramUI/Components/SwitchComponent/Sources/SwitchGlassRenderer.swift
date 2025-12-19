import MetalKit
import simd

private var switchMetalLibraryValue: MTLLibrary?
private func switchMetalLibrary(device: MTLDevice) -> MTLLibrary? {
    if let switchMetalLibraryValue {
        return switchMetalLibraryValue
    }

    let mainBundle = Bundle(for: SwitchGlassRenderer.self)
    guard let path = mainBundle.path(forResource: "SwitchComponentBundle", ofType: "bundle") else {
        return nil
    }
    guard let bundle = Bundle(path: path) else {
        return nil
    }
    guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
        return nil
    }

    switchMetalLibraryValue = library
    return library
}

public struct SwitchGlassUniforms {
    public var viewSize: SIMD2<Float> = .zero
    public var glassOrigin: SIMD2<Float> = .zero
    public var glassSize: SIMD2<Float> = .zero
    public var cornerRadius: Float = 0
    public var refractionStrength: Float = 10
    public var specularIntensity: Float = 0.2
    public var refractionZonePercent: Float = 0.45
    public var scrollVelocity: SIMD2<Float> = .zero
    public var time: Float = 0
    public var edgeIntensity: Float = 1.0
    public var refractionScaleX: Float = 1.0
    public var refractionScaleY: Float = 0.5
    public var chromaticScaleX: Float = 1.0
    public var chromaticScaleY: Float = 0.25
    public var borderOuter: Float = 0
    public var borderInner: Float = 0
    public var backdropUVOffset: SIMD2<Float> = .zero
    public var backdropUVScale: SIMD2<Float> = SIMD2<Float>(1, 1)
    public var uvOffset: SIMD2<Float> = .zero

    public init() {}
}

public final class SwitchGlassRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?

    private var glassBuffer: MTLBuffer?

    public var backdropTexture: MTLTexture? {
        didSet { hasValidBackdrop = backdropTexture != nil }
    }
    public private(set) var hasValidBackdrop: Bool = false

    public var glassUniforms = SwitchGlassUniforms()

    public var onUpdate: (() -> Void)?

    public init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        super.init()
        setupPipeline()
        setupBuffers()
        setupSampler()
    }

    private func setupPipeline() {
        guard let library = switchMetalLibrary(device: device),
              let vertex = library.makeFunction(name: "switchGlassVertex"),
              let fragment = library.makeFunction(name: "switchGlassFragment") else {
            return
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        pipelineState = try? device.makeRenderPipelineState(descriptor: desc)
    }

    private func setupBuffers() {
        glassBuffer = device.makeBuffer(length: MemoryLayout<SwitchGlassUniforms>.stride, options: .storageModeShared)
    }

    private func setupSampler() {
        let desc = MTLSamplerDescriptor()
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: desc)
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        onUpdate?()

        guard hasValidBackdrop,
              let backdrop = backdropTexture,
              let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor,
              let pipeline = pipelineState,
              let cmdBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        passDesc.colorAttachments[0].loadAction = .clear

        guard let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        if let buffer = glassBuffer {
            memcpy(buffer.contents(), &glassUniforms, MemoryLayout<SwitchGlassUniforms>.stride)
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(backdrop, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setFragmentBuffer(glassBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }
}

extension SwitchGlassRenderer {

    /// Updates uniforms based on backdrop capture rect
    public func updateForBackdrop(unionRect: CGRect, glassFrame: CGRect, screenScale: CGFloat) {
        glassUniforms.viewSize = SIMD2<Float>(
            Float(unionRect.width * screenScale),
            Float(unionRect.height * screenScale)
        )

        glassUniforms.glassOrigin = SIMD2<Float>(
            Float((glassFrame.origin.x - unionRect.origin.x) * screenScale),
            Float((glassFrame.origin.y - unionRect.origin.y) * screenScale)
        )

        glassUniforms.glassSize = SIMD2<Float>(
            Float(glassFrame.width * screenScale),
            Float(glassFrame.height * screenScale)
        )
    }

    /// For switch/drag: offset UVs virtually without new capture
    public func setVirtualOffset(_ offset: CGPoint, screenScale: CGFloat) {
        glassUniforms.uvOffset = SIMD2<Float>(
            Float(offset.x * screenScale),
            Float(offset.y * screenScale)
        )
    }
}
