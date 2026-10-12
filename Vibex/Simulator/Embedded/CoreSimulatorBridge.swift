import AppKit
import Darwin
import os

/// Objective-C views of the private CoreSimulator / SimulatorKit objects we talk to. The objects are
/// remoting proxies, so they are messaged through these protocols with `unsafeBitCast`, never typed.
@objc protocol SimDisplayRenderableProxy {
    @objc(framebufferSurface) var framebufferSurface: AnyObject? { get }
    @objc(maskedFramebufferSurface) var maskedFramebufferSurface: AnyObject? { get }
    @objc(ioSurface) var ioSurface: AnyObject? { get }
    @objc(state) var state: AnyObject? { get }
    @objc(displaySize) var displaySize: CGSize { get }
    @objc(registerCallbackWithUUID:ioSurfacesChangeCallback:)
    func registerSurfaces(uuid: UUID, callback: @escaping (AnyObject?) -> Void)
    @objc(registerCallbackWithUUID:damageRectanglesCallback:)
    func registerDamage(uuid: UUID, callback: @escaping ([NSValue]?) -> Void)
    @objc(unregisterIOSurfacesChangeCallbackWithUUID:) func unregisterSurfaces(uuid: UUID)
    @objc(unregisterDamageRectanglesCallbackWithUUID:) func unregisterDamage(uuid: UUID)
    @objc(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:)
    func registerScreen(
        uuid: UUID,
        queue: DispatchQueue,
        frame: @escaping () -> Void,
        surfaces: @escaping (AnyObject?, AnyObject?) -> Void,
        properties: @escaping (AnyObject?) -> Void
    )
    @objc(unregisterScreenCallbacksWithUUID:) func unregisterScreen(uuid: UUID)
}

@objc protocol SimDisplayDescriptorStateProxy {
    @objc(displayClass) var displayClass: UInt16 { get }
}

@objc protocol SimHIDClientProxy {
    @objc(sendWithMessage:freeWhenDone:completionQueue:completion:)
    func send(message: UnsafeMutableRawPointer, freeWhenDone: Bool, completionQueue: DispatchQueue, completion: @escaping (Error?) -> Void)
}

enum CoreSimulatorError: Error, LocalizedError {
    case frameworkMissing(String)
    case classMissing(String)
    case symbolMissing(String)
    case serviceContextUnavailable
    case deviceNotFound(String)
    case noMainDisplay
    case hidClientFailed

    var errorDescription: String? {
        switch self {
        case let .frameworkMissing(name): "Could not load \(name). Vibex needs Xcode with an iOS simulator runtime (found: \(Toolchain.developerDir))."
        case let .classMissing(name): "CoreSimulator class \(name) not found"
        case let .symbolMissing(name): "SimulatorKit symbol \(name) not found"
        case .serviceContextUnavailable: "CoreSimulator service unavailable"
        case let .deviceNotFound(udid): "Simulator \(udid) not found"
        case .noMainDisplay: "The simulator has no main display yet"
        case .hidClientFailed: "Could not open the simulator's input channel"
        }
    }
}

/// Loads Xcode's private CoreSimulator and SimulatorKit frameworks and hands out the handful of objects
/// Vibex needs: devices, their main display, an input client, and the Indigo HID message builders.
/// This is the same machinery Simulator.app and idb use; nothing here needs Simulator.app running.
final class CoreSimulatorBridge {
    typealias MouseMessageFn = @convention(c) (UnsafeMutablePointer<CGPoint>?, UnsafeMutablePointer<CGPoint>?, UInt32, UInt, CGSize, UInt32) -> UnsafeMutableRawPointer
    typealias KeyboardMessageFn = @convention(c) (AnyObject) -> UnsafeMutableRawPointer?
    typealias ButtonMessageFn = @convention(c) (Int32, Int32, Int32) -> UnsafeMutableRawPointer
    typealias KeyboardArbitraryFn = @convention(c) (Int32, Int32) -> UnsafeMutableRawPointer

    static var developerDir: String { Toolchain.developerDir }

    nonisolated(unsafe) private static var cached: Result<CoreSimulatorBridge, Error>?

    static func shared() throws -> CoreSimulatorBridge {
        if let cached { return try cached.get() }
        let result = Result { try CoreSimulatorBridge() }
        cached = result
        return try result.get()
    }

    let mouseMessage: MouseMessageFn
    let keyboardMessage: KeyboardMessageFn
    let buttonMessage: ButtonMessageFn
    let keyboardArbitrary: KeyboardArbitraryFn

    private let deviceSet: AnyObject
    private let hidClientClass: AnyClass
    private let renderableProtocol: Protocol

    private init() throws {
        let coreSimulator = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
        guard dlopen(coreSimulator, RTLD_NOW) != nil else { throw CoreSimulatorError.frameworkMissing("CoreSimulator") }
        let simulatorKitPath = "\(Self.developerDir)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
        guard let simulatorKit = dlopen(simulatorKitPath, RTLD_NOW) else { throw CoreSimulatorError.frameworkMissing("SimulatorKit") }

        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let address = dlsym(simulatorKit, name) else { throw CoreSimulatorError.symbolMissing(name) }
            return unsafeBitCast(address, to: type)
        }
        mouseMessage = try symbol("IndigoHIDMessageForMouseNSEvent", as: MouseMessageFn.self)
        keyboardMessage = try symbol("IndigoHIDMessageForKeyboardNSEvent", as: KeyboardMessageFn.self)
        buttonMessage = try symbol("IndigoHIDMessageForButton", as: ButtonMessageFn.self)
        keyboardArbitrary = try symbol("IndigoHIDMessageForKeyboardArbitrary", as: KeyboardArbitraryFn.self)

        guard let contextClass = NSClassFromString("SimServiceContext") else { throw CoreSimulatorError.classMissing("SimServiceContext") }
        guard let context = Self.perform(contextClass as AnyObject, "sharedServiceContextForDeveloperDir:error:", Self.developerDir, nil),
              let set = Self.perform(context, "defaultDeviceSetWithError:", nil)
        else { throw CoreSimulatorError.serviceContextUnavailable }
        deviceSet = set

        guard let hidClass = NSClassFromString("SimulatorKit.SimDeviceLegacyHIDClient") ?? NSClassFromString("SimDeviceLegacyHIDClient") else {
            throw CoreSimulatorError.classMissing("SimDeviceLegacyHIDClient")
        }
        hidClientClass = hidClass
        guard let proto = NSProtocolFromString("SimDisplayIOSurfaceRenderable") else { throw CoreSimulatorError.classMissing("SimDisplayIOSurfaceRenderable") }
        renderableProtocol = proto
        Log.simulator.info("CoreSimulator bridge ready")
    }

    // MARK: - Devices

    /// CoreSimulator's device proxy is safe to use from any thread; the accessibility reader needs it off main.
    nonisolated struct Device: @unchecked Sendable {
        nonisolated(unsafe) let object: AnyObject
        let udid: String
        let name: String
        /// Pixels.
        let screenSize: CGSize
        let screenScale: CGFloat

        /// CoreSimulator state: 3 is booted.
        var isBooted: Bool { (object.value(forKey: "state") as? UInt64) == 3 }
    }

    func device(udid: String) throws -> Device {
        let devices = deviceSet.value(forKey: "devices") as? [AnyObject] ?? []
        guard let object = devices.first(where: { ($0.value(forKey: "UDID") as? UUID)?.uuidString == udid }) else {
            throw CoreSimulatorError.deviceNotFound(udid)
        }
        let type = object.value(forKey: "deviceType") as AnyObject
        let size = (type.value(forKey: "mainScreenSize") as? NSValue)?.sizeValue ?? CGSize(width: 1179, height: 2556)
        let scale = CGFloat(type.value(forKey: "mainScreenScale") as? Float ?? 3)
        return Device(object: object, udid: udid, name: object.value(forKey: "name") as? String ?? udid, screenSize: size, screenScale: scale)
    }

    /// The renderable for the device's main display (display class 0), once the booted device has one.
    func mainDisplay(of device: Device) throws -> SimDisplayRenderableProxy {
        guard let io = device.object.value(forKey: "io") as AnyObject?, let ports = Self.perform(io, "ioPorts") as? [AnyObject] else {
            throw CoreSimulatorError.noMainDisplay
        }
        for port in ports {
            guard let descriptor = Self.perform(port, "descriptor"), descriptor.conforms(to: renderableProtocol),
                  descriptor.responds(to: NSSelectorFromString("state")), let state = Self.perform(descriptor, "state")
            else { continue }
            let displayClass = unsafeBitCast(state, to: SimDisplayDescriptorStateProxy.self).displayClass
            if displayClass == 0 {
                return unsafeBitCast(descriptor, to: SimDisplayRenderableProxy.self)
            }
        }
        throw CoreSimulatorError.noMainDisplay
    }

    func makeHIDClient(for device: Device) throws -> SimHIDClientProxy {
        guard let allocated = (hidClientClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let client = allocated.perform(NSSelectorFromString("initWithDevice:error:"), with: device.object, with: nil)?.takeRetainedValue()
        else { throw CoreSimulatorError.hidClientFailed }
        return unsafeBitCast(client, to: SimHIDClientProxy.self)
    }

    // MARK: - Helpers

    private static func perform(_ object: AnyObject, _ selectorName: String, _ a: Any? = nil, _ b: Any? = nil) -> AnyObject? {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector) else { return nil }
        if a == nil, b == nil { return object.perform(selector)?.takeUnretainedValue() }
        if b == nil { return object.perform(selector, with: a)?.takeUnretainedValue() }
        return object.perform(selector, with: a, with: b)?.takeUnretainedValue()
    }
}
