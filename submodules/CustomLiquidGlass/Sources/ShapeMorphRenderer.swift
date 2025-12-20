import UIKit
import MetalKit
import simd

public struct MorphUniforms {
    public var viewSize: SIMD2<Float> = .zero
    public var morphProgress: Float = 0
    public var blendSoftness: Float = 30
    public var velocity: SIMD2<Float> = .zero
    public var uvOffset: SIMD2<Float> = .zero
    public var uvScale: SIMD2<Float> = SIMD2<Float>(1, 1)

    public init() {}
}

public struct MorphShapeDescriptor {
    public var center: SIMD2<Float> = .zero
    public var size: SIMD2<Float> = .zero
    public var cornerRadius: Float = 0
    public var _padding: Float = 0

    public init() {}

    public init(shape: MorphShape) {
        self.center = SIMD2<Float>(Float(shape.center.x), Float(shape.center.y))
        self.size = SIMD2<Float>(Float(shape.size.width), Float(shape.size.height))
        self.cornerRadius = Float(shape.cornerRadius)
    }
}

public final class ShapeMorphRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var morphPipelineState: MTLRenderPipelineState?
    private var singlePipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?

    private var uniformsBuffer: MTLBuffer?
    private var shape1Buffer: MTLBuffer?
    private var shape2Buffer: MTLBuffer?

    public var backdropTexture: MTLTexture? {
        didSet { hasValidBackdrop = backdropTexture != nil }
    }
    public private(set) var hasValidBackdrop: Bool = false

    public var morphUniforms = MorphUniforms()
    public var shape1 = MorphShapeDescriptor()
    public var shape2 = MorphShapeDescriptor()

    public var useSingleShape: Bool = false

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
        guard let library = metalLibrary(device: device) else { return }

        guard let vertex = library.makeFunction(name: "liquidGlassVertex"),
              let morphFragment = library.makeFunction(name: "liquidGlassMorphFragment"),
              let singleFragment = library.makeFunction(name: "liquidGlassMorphSingleFragment") else {
            return
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertex
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        desc.fragmentFunction = morphFragment
        morphPipelineState = try? device.makeRenderPipelineState(descriptor: desc)

        desc.fragmentFunction = singleFragment
        singlePipelineState = try? device.makeRenderPipelineState(descriptor: desc)
    }

    private func setupBuffers() {
        uniformsBuffer = device.makeBuffer(length: MemoryLayout<MorphUniforms>.stride, options: .storageModeShared)
        shape1Buffer = device.makeBuffer(length: MemoryLayout<MorphShapeDescriptor>.stride, options: .storageModeShared)
        shape2Buffer = device.makeBuffer(length: MemoryLayout<MorphShapeDescriptor>.stride, options: .storageModeShared)
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

    public func updateForBackdrop(unionRect: CGRect, clientCaptureFrame: CGRect, screenScale: CGFloat) {
        guard unionRect.width > 0 && unionRect.height > 0 else { return }

        let uvOffsetX = Float((clientCaptureFrame.minX - unionRect.minX) / unionRect.width)
        let uvOffsetY = Float((clientCaptureFrame.minY - unionRect.minY) / unionRect.height)
        morphUniforms.uvOffset = SIMD2<Float>(uvOffsetX, uvOffsetY)

        let uvScaleX = Float(clientCaptureFrame.width / unionRect.width)
        let uvScaleY = Float(clientCaptureFrame.height / unionRect.height)
        morphUniforms.uvScale = SIMD2<Float>(uvScaleX, uvScaleY)
    }

    public func setShapes(_ s1: MorphShape, _ s2: MorphShape) {
        shape1 = MorphShapeDescriptor(shape: s1)
        shape2 = MorphShapeDescriptor(shape: s2)
    }

    public func setShape(_ shape: MorphShape) {
        shape1 = MorphShapeDescriptor(shape: shape)
        useSingleShape = true
    }

    public func draw(in view: MTKView) {
        onUpdate?()

        guard hasValidBackdrop,
              let backdrop = backdropTexture,
              let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor else {
            return
        }

        let pipeline = useSingleShape ? singlePipelineState : morphPipelineState
        guard let pipeline = pipeline,
              let cmdBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        passDesc.colorAttachments[0].loadAction = .clear

        guard let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        if let buffer = uniformsBuffer {
            memcpy(buffer.contents(), &morphUniforms, MemoryLayout<MorphUniforms>.stride)
        }
        if let buffer = shape1Buffer {
            memcpy(buffer.contents(), &shape1, MemoryLayout<MorphShapeDescriptor>.stride)
        }
        if !useSingleShape, let buffer = shape2Buffer {
            memcpy(buffer.contents(), &shape2, MemoryLayout<MorphShapeDescriptor>.stride)
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(backdrop, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(shape1Buffer, offset: 0, index: 1)
        if !useSingleShape {
            encoder.setFragmentBuffer(shape2Buffer, offset: 0, index: 2)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }
}

private var metalLibraryCache: MTLLibrary?
private func metalLibrary(device: MTLDevice) -> MTLLibrary? {
    if let metalLibraryCache {
        return metalLibraryCache
    }

    let mainBundle = Bundle(for: ShapeMorphRenderer.self)
    guard let path = mainBundle.path(forResource: "CustomLiquidGlassBundle", ofType: "bundle") else {
        return nil
    }
    guard let bundle = Bundle(path: path) else {
        return nil
    }
    guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
        return nil
    }

    metalLibraryCache = library
    return library
}
