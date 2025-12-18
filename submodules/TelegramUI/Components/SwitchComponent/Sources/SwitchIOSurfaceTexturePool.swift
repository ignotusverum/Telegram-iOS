import Metal
import CoreVideo
import IOSurface

public final class SwitchIOSurfaceTexturePool {

    private let device: MTLDevice
    private var surface: IOSurfaceRef?
    private var texture: MTLTexture?
    private var context: CGContext?
    private var currentSize: CGSize = .zero

    public init(device: MTLDevice) {
        self.device = device
    }

    public func getContext(size: CGSize, scale: CGFloat) -> CGContext? {
        let pixelSize = CGSize(
            width: ceil(size.width * scale),
            height: ceil(size.height * scale)
        )

        if pixelSize != currentSize || context == nil {
            createSurface(size: pixelSize)
        }

        return context
    }

    public func getTexture() -> MTLTexture? {
        return texture
    }

    private func createSurface(size: CGSize) {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0 && height > 0 else { return }

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

        guard let newSurface = IOSurfaceCreate(properties as CFDictionary) else {
            return
        }

        IOSurfaceLock(newSurface, [], nil)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        )

        guard let newContext = CGContext(
            data: IOSurfaceGetBaseAddress(newSurface),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: IOSurfaceGetBytesPerRow(newSurface),
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            IOSurfaceUnlock(newSurface, [], nil)
            return
        }

        newContext.translateBy(x: 0, y: CGFloat(height))
        newContext.scaleBy(x: 1, y: -1)

        IOSurfaceUnlock(newSurface, [], nil)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .shared

        guard let newTexture = device.makeTexture(
            descriptor: desc,
            iosurface: newSurface,
            plane: 0
        ) else {
            return
        }

        self.surface = newSurface
        self.context = newContext
        self.texture = newTexture
        self.currentSize = size
    }

    public func lockForCPU() {
        if let surface = surface {
            IOSurfaceLock(surface, [], nil)
        }
    }

    public func unlockForCPU() {
        if let surface = surface {
            IOSurfaceUnlock(surface, [], nil)
        }
    }
}
