import Metal
import CoreVideo
import IOSurface

final class DoubleBufferedTexturePool {

    private struct Buffer {
        let surface: IOSurfaceRef
        let texture: MTLTexture
        let context: CGContext
    }

    private let device: MTLDevice
    private var buffers: [Buffer?] = [nil, nil]
    private var currentIndex: Int = 0
    private var currentSize: CGSize = .zero

    init(device: MTLDevice) {
        self.device = device
    }

    func getBackBuffer(size: CGSize, scale: CGFloat) -> CGContext? {
        let pixelSize = CGSize(
            width: ceil(size.width * scale),
            height: ceil(size.height * scale)
        )

        if pixelSize != currentSize || buffers[0] == nil {
            createBuffers(size: pixelSize)
        }

        let backIndex = (currentIndex + 1) % 2
        guard let buffer = buffers[backIndex] else { return nil }

        IOSurfaceLock(buffer.surface, [], nil)
        return buffer.context
    }

    func unlockBackBuffer() {
        let backIndex = (currentIndex + 1) % 2
        if let buffer = buffers[backIndex] {
            IOSurfaceUnlock(buffer.surface, [], nil)
        }
    }

    func swapAndGetTexture() -> MTLTexture? {
        currentIndex = (currentIndex + 1) % 2
        return buffers[currentIndex]?.texture
    }

    func getCurrentTexture() -> MTLTexture? {
        return buffers[currentIndex]?.texture
    }

    func reset() {
        buffers = [nil, nil]
        currentSize = .zero
        currentIndex = 0
    }

    private func createBuffers(size: CGSize) {
        buffers = [nil, nil]

        for i in 0..<2 {
            if let buffer = createSingleBuffer(size: size) {
                buffers[i] = buffer
            }
        }

        currentSize = size
        currentIndex = 0
    }

    private func createSingleBuffer(size: CGSize) -> Buffer? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0 && height > 0 else { return nil }

        let bytesPerPixel = 4
        let alignment = 16
        let bytesPerRow = ((width * bytesPerPixel + alignment - 1) / alignment) * alignment

        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: bytesPerPixel,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA
        ]

        guard let surface = IOSurfaceCreate(properties as CFDictionary) else {
            return nil
        }

        IOSurfaceLock(surface, [], nil)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        )

        guard let context = CGContext(
            data: IOSurfaceGetBaseAddress(surface),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: IOSurfaceGetBytesPerRow(surface),
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            IOSurfaceUnlock(surface, [], nil)
            return nil
        }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        IOSurfaceUnlock(surface, [], nil)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .shared

        guard let texture = device.makeTexture(
            descriptor: desc,
            iosurface: surface,
            plane: 0
        ) else {
            return nil
        }

        return Buffer(surface: surface, texture: texture, context: context)
    }
}
