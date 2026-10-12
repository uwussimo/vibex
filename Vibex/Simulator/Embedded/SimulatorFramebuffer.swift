import Foundation
import IOSurface
import os

/// Subscribes to a simulator display and republishes its IOSurface and per-frame ticks on the main actor.
/// Frame ticks are coalesced: however fast the guest renders, the view uploads at most once per
/// main-loop pass, which keeps the terminal and video smooth next to it.
final class SimulatorFramebuffer {
    private(set) var surface: IOSurface?
    var onSurfaceChange: (IOSurface?) -> Void = { _ in }
    var onFrame: () -> Void = {}

    private let renderable: SimDisplayRenderableProxy
    private let token = UUID()
    private let usesScreenAPI: Bool
    private let callbackQueue = DispatchQueue(label: "com.yusuf.vibex.framebuffer", qos: .userInteractive)
    private let framePending = OSAllocatedUnfairLock(initialState: false)

    init(renderable: SimDisplayRenderableProxy) {
        self.renderable = renderable
        usesScreenAPI = (renderable as AnyObject).responds(to: NSSelectorFromString(
            "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:"))
        surface = Self.pick(masked: renderable.maskedFramebufferSurface, primary: renderable.framebufferSurface ?? renderable.ioSurface)

        let token = token
        let pending = framePending
        // These closures run on the callback queue; everything they touch is Sendable or locked.
        let frame: @Sendable () -> Void = { [weak self] in
            let shouldSchedule = pending.withLock { flag -> Bool in
                if flag { return false }
                flag = true
                return true
            }
            guard shouldSchedule else { return }
            DispatchQueue.main.async {
                pending.withLock { $0 = false }
                MainActor.assumeIsolated { self?.onFrame() }
            }
        }
        let surfaces: @Sendable (AnyObject?, AnyObject?) -> Void = { [weak self] primary, masked in
            let picked = Self.pick(masked: masked, primary: primary)
            // IOSurface is immutable identity-wise; handing it across is fine.
            let chosen = picked
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.surface = chosen
                    self.onSurfaceChange(chosen)
                }
            }
        }
        if usesScreenAPI {
            renderable.registerScreen(uuid: token, queue: callbackQueue, frame: frame, surfaces: surfaces, properties: { _ in })
        } else {
            renderable.registerSurfaces(uuid: token) { surfaces($0, nil) }
            renderable.registerDamage(uuid: token) { _ in frame() }
        }
        Log.simulator.info("framebuffer attached (\(self.usesScreenAPI ? "SimScreen" : "legacy", privacy: .public) callbacks)")
    }

    func stop() {
        if usesScreenAPI {
            renderable.unregisterScreen(uuid: token)
        } else {
            renderable.unregisterSurfaces(uuid: token)
            renderable.unregisterDamage(uuid: token)
        }
    }

    /// Prefer the corner/notch-masked surface so the phone's rounded screen shape comes for free.
    private nonisolated static func pick(masked: AnyObject?, primary: AnyObject?) -> IOSurface? {
        (masked as? IOSurface) ?? (primary as? IOSurface)
    }
}
