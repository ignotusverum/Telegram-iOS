import UIKit
import Metal
import QuartzCore

public final class BackdropCoordinator {

    public static let shared = BackdropCoordinator()

    private struct WeakClient {
        weak var client: BackdropClient?
    }

    private let device: MTLDevice?
    private lazy var texturePool: DoubleBufferedTexturePool? = {
        guard let device = device else { return nil }
        return DoubleBufferedTexturePool(device: device)
    }()

    private var clients: [UUID: WeakClient] = [:]
    private var needsCapture: Bool = false
    private var lastCaptureTime: CFTimeInterval = 0
    private let throttleInterval: CFTimeInterval = 1.0 / 30.0

    private init() {
        self.device = MTLCreateSystemDefaultDevice()
    }

    public func register(_ client: BackdropClient) {
        clients[client.backdropClientID] = WeakClient(client: client)
    }

    public func unregister(_ client: BackdropClient) {
        clients.removeValue(forKey: client.backdropClientID)
        cleanupStaleClients()
    }

    public func setNeedsCapture() {
        needsCapture = true
    }

    public func captureIfNeeded() {
        guard needsCapture else { return }

        let now = CACurrentMediaTime()
        guard now - lastCaptureTime >= throttleInterval else { return }

        capture()
        needsCapture = false
        lastCaptureTime = now
    }

    private func capture() {
        let activeClients = clients.values.compactMap { $0.client }.filter { $0.needsBackdrop }
        guard !activeClients.isEmpty else { return }

        guard let window = activeClients.first?.backdropWindow else { return }
        let screenScale = window.screen.scale
        let screenBounds = window.screen.bounds

        var unionRect = CGRect.null
        for client in activeClients {
            let paddedFrame = client.captureFrame.insetBy(
                dx: -client.capturePadding,
                dy: -client.capturePadding
            )
            unionRect = unionRect.union(paddedFrame)
        }

        unionRect = unionRect.intersection(CGRect(origin: .zero, size: screenBounds.size))
        guard !unionRect.isEmpty && !unionRect.isNull else { return }

        for client in activeClients {
            client.prepareForCapture()
        }

        guard let texturePool = texturePool,
              let ctx = texturePool.getBackBuffer(size: unionRect.size, scale: screenScale) else {
            for client in activeClients {
                client.restoreAfterCapture()
            }
            return
        }

        ctx.saveGState()
        ctx.translateBy(x: -unionRect.origin.x * screenScale, y: -unionRect.origin.y * screenScale)
        ctx.scaleBy(x: screenScale, y: screenScale)
        window.layer.render(in: ctx)
        ctx.restoreGState()

        texturePool.unlockBackBuffer()

        for client in activeClients {
            client.restoreAfterCapture()
        }

        guard let texture = texturePool.swapAndGetTexture() else { return }

        for client in activeClients {
            client.didReceiveBackdrop(texture, unionRect: unionRect, screenScale: screenScale)
        }
    }

    private func cleanupStaleClients() {
        for key in clients.keys where clients[key]?.client == nil {
            clients.removeValue(forKey: key)
        }
    }
}
