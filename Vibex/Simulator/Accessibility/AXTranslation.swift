import AppKit
import Darwin
import os

/// Reads a booted simulator's accessibility tree on the host, the way Simulator.app's Accessibility
/// Inspector does: the private AccessibilityPlatformTranslation framework translates iOS elements
/// into `NSAccessibilityElement`s, and each attribute it needs is fetched from the device through
/// CoreSimulator's accessibility XPC channel. Ported from idb's FBSimulatorAX.
///
/// The translator is a process-wide, single-threaded singleton, so every call goes through one
/// serial queue, and the synchronous XPC waits never run on the main thread.
nonisolated final class AXTranslation: @unchecked Sendable {
    enum Failure: Error, LocalizedError {
        case frameworkUnavailable
        case noFrontmostApplication
        case noElement

        var errorDescription: String? {
            switch self {
            case .frameworkUnavailable: "AccessibilityPlatformTranslation is unavailable"
            case .noFrontmostApplication: "The simulator reported no frontmost application (is it booted and unlocked?)"
            case .noElement: "No accessibility element at that position"
            }
        }
    }

    @objc nonisolated private protocol SimDeviceAXProxy {
        @objc(sendAccessibilityRequestAsync:completionQueue:completionHandler:)
        func sendAccessibilityRequest(_ request: AnyObject?, completionQueue: DispatchQueue, completionHandler: @escaping (AnyObject?) -> Void)
    }

    @objc nonisolated private protocol TranslatorProxy {
        @objc(frontmostApplicationWithDisplayId:bridgeDelegateToken:) func frontmostApplication(displayId: UInt32, token: String) -> AnyObject?
        @objc(macPlatformElementFromTranslation:) func macPlatformElement(fromTranslation: AnyObject) -> AnyObject?
        @objc(objectAtPoint:displayId:bridgeDelegateToken:) func object(atPoint: CGPoint, displayId: UInt32, token: String) -> AnyObject?
    }

    /// Answers the translator's attribute requests by round-tripping them through the device.
    nonisolated private final class TokenDelegate: NSObject, @unchecked Sendable {
        let callbackQueue = DispatchQueue(label: "com.yusuf.vibex.ax.callback")
        nonisolated(unsafe) var device: AnyObject?
        let timeout: TimeInterval = 5

        @objc(accessibilityTranslationDelegateBridgeCallbackWithToken:)
        func callback(withToken token: String) -> (AnyObject?) -> AnyObject? {
            return { [self] request in
                guard let device else { return nil }
                let group = DispatchGroup()
                group.enter()
                nonisolated(unsafe) var response: AnyObject?
                unsafeBitCast(device, to: SimDeviceAXProxy.self).sendAccessibilityRequest(request, completionQueue: callbackQueue) { r in
                    response = r
                    group.leave()
                }
                if group.wait(timeout: .now() + timeout) == .timedOut {
                    Log.simulator.error("accessibility request timed out")
                    return nil
                }
                return response
            }
        }

        @objc(accessibilityTranslationConvertPlatformFrameToSystem:withToken:)
        func convertFrame(_ rect: CGRect, withToken token: String) -> CGRect { rect }

        @objc(accessibilityTranslationRootParentWithToken:)
        func rootParent(withToken token: String) -> AnyObject? { nil }
    }

    nonisolated(unsafe) private static var cached: Result<AXTranslation, Error>?

    static func shared() throws -> AXTranslation {
        if let cached { return try cached.get() }
        let result = Result { try AXTranslation() }
        cached = result
        return try result.get()
    }

    private let translator: AnyObject
    private let proxy: TranslatorProxy
    private let delegate = TokenDelegate()
    private let workQueue = DispatchQueue(label: "com.yusuf.vibex.ax.work", qos: .userInitiated)

    private init() throws {
        let path = "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation"
        guard dlopen(path, RTLD_NOW) != nil, let translatorClass = NSClassFromString("AXPTranslator") as AnyObject?,
              let translator = translatorClass.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue()
        else { throw Failure.frameworkUnavailable }
        self.translator = translator
        proxy = unsafeBitCast(translator, to: TranslatorProxy.self)
        translator.setValue(delegate, forKey: "bridgeTokenDelegate")
        Log.simulator.info("accessibility translator ready")
    }

    /// The frontmost application's tree, in screen points. Runs on the translator queue.
    func frontmostTree(device: CoreSimulatorBridge.Device, maxNodes: Int = 600) async throws -> AXNode {
        return try await withCheckedThrowingContinuation { continuation in
            workQueue.async { [self] in
                delegate.device = device.object
                defer { delegate.device = nil }
                let token = UUID().uuidString
                guard let translation = proxy.frontmostApplication(displayId: 0, token: token) else {
                    continuation.resume(throwing: Failure.noFrontmostApplication)
                    return
                }
                translation.setValue(token, forKey: "bridgeDelegateToken")
                guard let element = proxy.macPlatformElement(fromTranslation: translation) as? NSAccessibilityElement else {
                    continuation.resume(throwing: Failure.noElement)
                    return
                }
                (element.value(forKey: "translation") as AnyObject?)?.setValue(token, forKey: "bridgeDelegateToken")
                var budget = maxNodes
                continuation.resume(returning: Self.node(from: element, budget: &budget))
            }
        }
    }

    /// The element under a point, in screen points.
    func element(at point: CGPoint, device: CoreSimulatorBridge.Device) async throws -> AXNode {
        return try await withCheckedThrowingContinuation { continuation in
            workQueue.async { [self] in
                delegate.device = device.object
                defer { delegate.device = nil }
                let token = UUID().uuidString
                guard let translation = proxy.object(atPoint: point, displayId: 0, token: token) else {
                    continuation.resume(throwing: Failure.noElement)
                    return
                }
                translation.setValue(token, forKey: "bridgeDelegateToken")
                guard let element = proxy.macPlatformElement(fromTranslation: translation) as? NSAccessibilityElement else {
                    continuation.resume(throwing: Failure.noElement)
                    return
                }
                (element.value(forKey: "translation") as AnyObject?)?.setValue(token, forKey: "bridgeDelegateToken")
                var budget = 1
                continuation.resume(returning: Self.node(from: element, budget: &budget))
            }
        }
    }

    private static func node(from element: NSAccessibilityElement, budget: inout Int) -> AXNode {
        budget -= 1
        var node = AXNode(
            role: element.accessibilityRole()?.rawValue ?? "AXUnknown",
            label: element.accessibilityLabel() ?? "",
            value: element.accessibilityValue().map { "\($0)" } ?? "",
            identifier: element.accessibilityIdentifier() ?? "",
            frame: element.accessibilityFrame(),
            isEnabled: element.isAccessibilityEnabled(),
            children: []
        )
        guard budget > 0 else { return node }
        for child in element.accessibilityChildren() ?? [] {
            guard budget > 0, let childElement = child as? NSAccessibilityElement else { break }
            node.children.append(Self.node(from: childElement, budget: &budget))
        }
        return node
    }
}
