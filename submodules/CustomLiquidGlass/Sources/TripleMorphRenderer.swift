import UIKit
import MetalKit
import simd

public struct TripleMorphUniforms {
    public var viewSize: SIMD2<Float> = .zero
    public var blendSoftness: Float = 25
    public var _pad1: Float = 0
    public var velocity1: SIMD2<Float> = .zero
    public var velocity2: SIMD2<Float> = .zero
    public var velocity3: SIMD2<Float> = .zero
    public var scale1: Float = 1
    public var scale2: Float = 1
    public var scale3: Float = 1
    public var _pad2: Float = 0
    public var uvOffset: SIMD2<Float> = .zero
    public var uvScale: SIMD2<Float> = SIMD2<Float>(1, 1)

    public init() {}
}

public final class TripleMorphRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?

    private var uniformsBuffer: MTLBuffer?
    private var shape1Buffer: MTLBuffer?
    private var shape2Buffer: MTLBuffer?
    private var shape3Buffer: MTLBuffer?

    public var uniforms = TripleMorphUniforms()
    public var shape1 = MorphShapeDescriptor()
    public var shape2 = MorphShapeDescriptor()
    public var shape3 = MorphShapeDescriptor()

    public var onUpdate: (() -> Void)?

    public init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        super.init()
        setupPipeline()
        setupBuffers()
    }

    private func setupPipeline() {
        guard let library = tripleMorphMetalLibrary(device: device) else {
            print("[TripleMorphRenderer] Failed to load metal library")
            return
        }

        guard let vertex = library.makeFunction(name: "liquidGlassVertex"),
              let fragment = library.makeFunction(name: "liquidGlassTripleMorphNoBackdropFragment") else {
            print("[TripleMorphRenderer] Failed to create shader functions")
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

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("[TripleMorphRenderer] Failed to create pipeline: \(error)")
        }
    }

    private func setupBuffers() {
        uniformsBuffer = device.makeBuffer(length: MemoryLayout<TripleMorphUniforms>.stride, options: .storageModeShared)
        shape1Buffer = device.makeBuffer(length: MemoryLayout<MorphShapeDescriptor>.stride, options: .storageModeShared)
        shape2Buffer = device.makeBuffer(length: MemoryLayout<MorphShapeDescriptor>.stride, options: .storageModeShared)
        shape3Buffer = device.makeBuffer(length: MemoryLayout<MorphShapeDescriptor>.stride, options: .storageModeShared)
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func setShapes(_ s1: MorphShape, _ s2: MorphShape, _ s3: MorphShape) {
        shape1 = MorphShapeDescriptor(shape: s1)
        shape2 = MorphShapeDescriptor(shape: s2)
        shape3 = MorphShapeDescriptor(shape: s3)
    }

    public func draw(in view: MTKView) {
        onUpdate?()

        guard let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor,
              let pipeline = pipelineState,
              let cmdBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        passDesc.colorAttachments[0].loadAction = .clear

        guard let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        if let buffer = uniformsBuffer {
            memcpy(buffer.contents(), &uniforms, MemoryLayout<TripleMorphUniforms>.stride)
        }
        if let buffer = shape1Buffer {
            memcpy(buffer.contents(), &shape1, MemoryLayout<MorphShapeDescriptor>.stride)
        }
        if let buffer = shape2Buffer {
            memcpy(buffer.contents(), &shape2, MemoryLayout<MorphShapeDescriptor>.stride)
        }
        if let buffer = shape3Buffer {
            memcpy(buffer.contents(), &shape3, MemoryLayout<MorphShapeDescriptor>.stride)
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(shape1Buffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(shape2Buffer, offset: 0, index: 2)
        encoder.setFragmentBuffer(shape3Buffer, offset: 0, index: 3)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }
}

private var tripleMorphLibraryCache: MTLLibrary?
private func tripleMorphMetalLibrary(device: MTLDevice) -> MTLLibrary? {
    if let tripleMorphLibraryCache {
        return tripleMorphLibraryCache
    }

    let mainBundle = Bundle(for: TripleMorphRenderer.self)
    guard let path = mainBundle.path(forResource: "CustomLiquidGlassBundle", ofType: "bundle") else {
        print("[TripleMorphRenderer] Bundle not found")
        return nil
    }
    guard let bundle = Bundle(path: path) else {
        print("[TripleMorphRenderer] Failed to load bundle")
        return nil
    }
    guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
        print("[TripleMorphRenderer] Failed to create library from bundle")
        return nil
    }

    tripleMorphLibraryCache = library
    return library
}
