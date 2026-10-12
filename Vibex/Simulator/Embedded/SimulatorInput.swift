import AppKit
import Darwin
import os

/// Builds Indigo HID messages and sends them to a simulator. Touch messages follow idb's recipe: take
/// a touch contact from SimulatorKit's mouse builder and wrap it in a single-touch envelope.
final class SimulatorInput {
    enum Button: Int32 {
        case home = 0
        case lock = 1
    }

    private let bridge: CoreSimulatorBridge
    private let client: SimHIDClientProxy
    private let queue = DispatchQueue(label: "com.yusuf.vibex.hid", qos: .userInteractive)

    init(bridge: CoreSimulatorBridge, device: CoreSimulatorBridge.Device) throws {
        self.bridge = bridge
        client = try bridge.makeHIDClient(for: device)
    }

    /// `ratio` is 0…1 from the top-left of the screen. A move is a `down` at the new position.
    func touch(ratio: CGPoint, down: Bool) {
        var point = CGPoint(x: min(max(ratio.x, 0), 1), y: min(max(ratio.y, 0), 1))
        let source = bridge.mouseMessage(&point, nil, 0x32, UInt(down ? 1 : 2), CGSize(width: 1, height: 1), 0)
        source.storeBytes(of: Double(point.x), toByteOffset: 0x3c, as: Double.self)
        source.storeBytes(of: Double(point.y), toByteOffset: 0x44, as: Double.self)
        let message = IndigoEnvelope.singleTouch(contact: UnsafeRawBufferPointer(start: source + 0x30, count: IndigoEnvelope.touchSize))
        free(source)
        send(message)
    }

    func key(_ event: NSEvent) {
        guard let message = bridge.keyboardMessage(event) else { return }
        send(message)
    }

    /// One HID usage down or up, with an optional shift.
    func keyStroke(_ stroke: HIDKeyboard.Stroke, down: Bool) {
        if stroke.shift, down { send(bridge.keyboardArbitrary(Int32(HIDKeyboard.leftShift), 1)) }
        send(bridge.keyboardArbitrary(Int32(bitPattern: stroke.usage), down ? 1 : 2))
        if stroke.shift, !down { send(bridge.keyboardArbitrary(Int32(HIDKeyboard.leftShift), 2)) }
    }

    /// Types text with the US layout. Returns the characters it could not type.
    func type(_ text: String) async -> String {
        var skipped = ""
        for character in text {
            guard let stroke = HIDKeyboard.stroke(for: character) else { skipped.append(character); continue }
            keyStroke(stroke, down: true)
            try? await Task.sleep(for: .milliseconds(12))
            keyStroke(stroke, down: false)
            try? await Task.sleep(for: .milliseconds(12))
        }
        return skipped
    }

    func pressKey(named name: String) async -> Bool {
        guard let stroke = HIDKeyboard.stroke(forKeyName: name) else { return false }
        keyStroke(stroke, down: true)
        try? await Task.sleep(for: .milliseconds(30))
        keyStroke(stroke, down: false)
        return true
    }

    func button(_ button: Button, down: Bool) {
        send(bridge.buttonMessage(button.rawValue, down ? 1 : 2, 0x33))
    }

    func press(_ button: Button) {
        self.button(button, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.button(button, down: false) }
    }

    private func send(_ message: UnsafeMutableRawPointer) {
        client.send(message: message, freeWhenDone: true, completionQueue: queue) { error in
            if let error { Log.simulator.error("HID send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}

/// The Indigo single-touch wire envelope (see idb's Indigo.h). Pure bytes, so it is unit-testable.
nonisolated enum IndigoEnvelope {
    static let payloadSize = 0x90
    static let touchSize = 0x70
    static let messageSize = 0x20 + payloadSize * 2

    /// Wraps a 0x70-byte IndigoTouch contact into a 0x140-byte single-touch message (malloc'd).
    static func singleTouch(contact: UnsafeRawBufferPointer) -> UnsafeMutableRawPointer {
        precondition(contact.count == touchSize)
        let message = calloc(1, messageSize)!
        message.storeBytes(of: UInt32(payloadSize), toByteOffset: 0x18, as: UInt32.self)
        message.storeBytes(of: UInt8(2), toByteOffset: 0x1c, as: UInt8.self)          // IndigoEventTypeTouch
        message.storeBytes(of: UInt32(0xB), toByteOffset: 0x20, as: UInt32.self)      // eventKind
        var timestamp = mach_absolute_time()
        memcpy(message + 0x24, &timestamp, 8)                                         // packed, unaligned
        memcpy(message + 0x30, contact.baseAddress!, touchSize)
        memcpy(message + 0x20 + payloadSize, message + 0x20, payloadSize)             // repeated contact
        message.storeBytes(of: UInt32(1), toByteOffset: 0x20 + payloadSize + 0x10, as: UInt32.self)
        message.storeBytes(of: UInt32(2), toByteOffset: 0x20 + payloadSize + 0x14, as: UInt32.self)
        return message
    }
}
