import MetalKit
import simd

private var metalLibraryValue: MTLLibrary?
private func metalLibrary(device: MTLDevice) -> MTLLibrary? {
    if let metalLibraryValue {
        return metalLibraryValue
    }

    let mainBundle = Bundle(for: LegacyLensRenderer.self)
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

struct LegacyGlassUniforms {
    var viewSize: SIMD2<Float> = .zero
    var glassOrigin: SIMD2<Float> = .zero
    var glassSize: SIMD2<Float> = .zero
    var cornerRadius: Float = 0
    var refractionStrength: Float = 6
    var specularIntensity: Float = 0.2
    var refractionZonePercent: Float = 0.4
    var scrollVelocity: SIMD2<Float> = .zero
    var time: Float = 0
    var edgeIntensity: Float = 0.8
    var refractionScaleX: Float = 1.0
    var refractionScaleY: Float = 0.5
    var chromaticScaleX: Float = 1.0
    var chromaticScaleY: Float = 0.25
}

// EXACTLY matches SdfUniforms in original shader
struct LegacySdfUniforms {
    var position: SIMD2<Float> = .zero
    var size: SIMD2<Float> = .zero
    var intensity: Float = 0
    var _padding: Float = 0
}

// EXACTLY matches TabUniforms in original shader
struct LegacyTabUniforms {
    var positions: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>,
                    SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) =
        (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    var sizes: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>,
                SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) =
        (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    var deformX: (Float, Float, Float, Float, Float, Float, Float, Float) =
        (0, 0, 0, 0, 0, 0, 0, 0)
    var fillAlpha: (Float, Float, Float, Float, Float, Float, Float, Float) =
        (0, 0, 0, 0, 0, 0, 0, 0)
    var count: Int32 = 0
    var selectedIndex: Int32 = 0
    var fillRadius: Float = 0
    var fillOpacity: Float = 0
}

final class LegacyLensRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?

    private var glassBuffer: MTLBuffer?
    private var sdf1Buffer: MTLBuffer?
    private var sdf2Buffer: MTLBuffer?
    private var tabsBuffer: MTLBuffer?

    var backdropTexture: MTLTexture? {
        didSet { hasValidBackdrop = backdropTexture != nil }
    }
    private(set) var hasValidBackdrop: Bool = false

    var glassUniforms = LegacyGlassUniforms()
    private var sdf1Uniforms = LegacySdfUniforms()
    private var sdf2Uniforms = LegacySdfUniforms()
    private var tabUniforms = LegacyTabUniforms()

    var onUpdate: (() -> Void)?

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        super.init()
        setupPipeline()
        setupBuffers()
        setupSampler()
    }

    private func setupPipeline() {
        guard let library = metalLibrary(device: device),
              let vertex = library.makeFunction(name: "liquidGlassVertex"),
              let fragment = library.makeFunction(name: "liquidGlassTabBarFragment") else {
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
        glassBuffer = device.makeBuffer(length: MemoryLayout<LegacyGlassUniforms>.stride, options: .storageModeShared)
        sdf1Buffer = device.makeBuffer(length: MemoryLayout<LegacySdfUniforms>.stride, options: .storageModeShared)
        sdf2Buffer = device.makeBuffer(length: MemoryLayout<LegacySdfUniforms>.stride, options: .storageModeShared)
        tabsBuffer = device.makeBuffer(length: MemoryLayout<LegacyTabUniforms>.stride, options: .storageModeShared)
    }

    private func setupSampler() {
        let desc = MTLSamplerDescriptor()
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: desc)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
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
            memcpy(buffer.contents(), &glassUniforms, MemoryLayout<LegacyGlassUniforms>.stride)
        }
        if let buffer = sdf1Buffer {
            memcpy(buffer.contents(), &sdf1Uniforms, MemoryLayout<LegacySdfUniforms>.stride)
        }
        if let buffer = sdf2Buffer {
            memcpy(buffer.contents(), &sdf2Uniforms, MemoryLayout<LegacySdfUniforms>.stride)
        }
        if let buffer = tabsBuffer {
            memcpy(buffer.contents(), &tabUniforms, MemoryLayout<LegacyTabUniforms>.stride)
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(backdrop, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setFragmentBuffer(glassBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(sdf1Buffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(sdf2Buffer, offset: 0, index: 2)
        encoder.setFragmentBuffer(tabsBuffer, offset: 0, index: 3)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }
}
