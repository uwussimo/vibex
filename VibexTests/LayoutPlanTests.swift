import CoreGraphics
import Foundation
import Testing
@testable import Vibex

@Suite struct LayoutPlanTests {
    @Test func `watch mode hides the simulator and favours the browser`() {
        let widths = LayoutPlan.widths(mode: .watch, available: 1880, simulatorWidth: 400, manual: nil)
        #expect(widths.simulator == 0)
        #expect(widths.browser >= LayoutPlan.watchBrowserMin)
        #expect(widths.terminal >= LayoutPlan.minTerminal)
        #expect(widths.total == 1880)
    }

    @Test func `build mode keeps the simulator at its natural width with a mini player`() {
        let widths = LayoutPlan.widths(mode: .build, available: 1880, simulatorWidth: 398, manual: nil)
        #expect(widths.simulator == 398)
        #expect(widths.browser == LayoutPlan.miniPlayerWidth)
        #expect(widths.total == 1880)
    }

    @Test func `balanced mode preserves the user's terminal/browser ratio`() {
        let manual = ColumnWidths(terminal: 1000, simulator: 400, browser: 500)
        let widths = LayoutPlan.widths(mode: .balanced, available: 1600, simulatorWidth: 400, manual: manual)
        #expect(widths.simulator == 400)
        #expect(abs(widths.terminal / (widths.terminal + widths.browser) - 2.0 / 3.0) < 0.01)
        #expect(widths.total == 1600)
    }

    @Test func `an empty simulator column keeps room for its empty state`() {
        let widths = LayoutPlan.widths(mode: .balanced, available: 1880, simulatorWidth: 0, manual: nil)
        #expect(widths.simulator == LayoutPlan.emptyColumnWidth)
        let watch = LayoutPlan.widths(mode: .watch, available: 1880, simulatorWidth: 0, manual: nil)
        #expect(watch.simulator == 0)
    }

    @Test func `narrow windows never push columns below their minimums`() {
        for mode in LayoutMode.allCases {
            let widths = LayoutPlan.widths(mode: mode, available: 900, simulatorWidth: 500, manual: nil)
            #expect(widths.terminal >= LayoutPlan.minTerminal)
            #expect(widths.browser >= 0)
            #expect(widths.total == 900)
        }
    }
}

@Suite struct SpringTests {
    @Test func `critically damped spring settles without overshoot`() {
        let spring = Spring(response: 0.35, dampingRatio: 1)
        var state = Spring.State(value: 0)
        var maxValue = 0.0
        var steps = 0
        while !spring.isSettled(state, target: 100), steps < 1000 {
            spring.advance(&state, toward: 100, dt: 1.0 / 240)
            maxValue = max(maxValue, state.value)
            steps += 1
        }
        #expect(steps < 1000)
        #expect(maxValue <= 100.5)
        #expect(Double(steps) / 240 < 1.0)
    }
}

@Suite struct SimctlTests {
    @Test(arguments: [
        ("com.apple.CoreSimulator.SimRuntime.iOS-26-5", "iOS 26.5"),
        ("com.apple.CoreSimulator.SimRuntime.iOS-18-0", "iOS 18.0"),
        ("com.apple.CoreSimulator.SimRuntime.watchOS-11-2", "watchOS 11.2"),
        ("weird", "weird"),
    ])
    func `runtime identifiers become readable names`(input: String, expected: String) {
        #expect(Simctl.runtimeName(input) == expected)
    }

    @Test func `device window title matches Simulator's format`() {
        let device = SimDevice(udid: "x", name: "iPhone 17 Pro Max", runtime: "iOS 26.5", state: "Booted")
        #expect(device.windowTitle == "iPhone 17 Pro Max – iOS 26.5")
    }
}

@Suite struct WebViewFactoryTests {
    @Test func `typed input becomes a sensible URL`() {
        #expect(WebViewFactory.url(forInput: "netflix.com")?.absoluteString == "https://netflix.com")
        #expect(WebViewFactory.url(forInput: "http://localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(WebViewFactory.url(forInput: "localhost:3000")?.absoluteString == "https://localhost:3000")
        #expect(WebViewFactory.url(forInput: "swift concurrency")?.host() == "www.google.com")
        #expect(WebViewFactory.url(forInput: "   ") == nil)
    }
}

@Suite struct SimslimTests {
    @Test func `list json parses slim state and memory`() throws {
        let json = """
        [{"udid":"A","name":"iPhone 17 Pro Max","state":"Booted","platform":"iOS","osVersion":"26.5","set":"default",
          "managedDisabled":120,"managedTotal":168,"memory":{"processes":60,"bytes":900000000,"cpu":12.5}},
         {"udid":"B","name":"iPad","state":"Shutdown","platform":"iOS","osVersion":"26.5","set":"default","managedTotal":168}]
        """
        let result = try Simslim.parseList(Data(json.utf8))
        #expect(result["A"]?.isSlim == true)
        #expect(result["A"]?.processes == 60)
        #expect(result["A"]?.memoryText?.isEmpty == false)
        #expect(result["B"]?.isSlim == false)
        #expect(result["B"]?.memoryBytes == nil)
    }
}

@Suite struct SimulatorDisplayGeometryTests {
    @Test func `screen is aspect-fitted and centered`() {
        // Height-limited: the column is wider than the phone needs.
        let rect = SimulatorDisplayGeometry.fitRect(screen: CGSize(width: 1320, height: 2868), in: CGRect(x: 0, y: 0, width: 600, height: 1000), inset: 8)
        #expect(rect.height == 984)
        #expect(abs(rect.width - 984 * 1320 / 2868) <= 1)
        #expect(abs(rect.midX - 300) <= 1)
        #expect(abs(rect.midY - 500) <= 1)
        // Width-limited: a narrow column shrinks the phone.
        let narrow = SimulatorDisplayGeometry.fitRect(screen: CGSize(width: 1320, height: 2868), in: CGRect(x: 0, y: 0, width: 400, height: 1000), inset: 8)
        #expect(narrow.width == 384)
        #expect(abs(narrow.height - 384 * 2868 / 1320) <= 1)
    }

    @Test func `points map to clamped ratios`() {
        let rect = CGRect(x: 50, y: 20, width: 300, height: 600)
        #expect(SimulatorDisplayGeometry.ratio(for: CGPoint(x: 50, y: 20), in: rect) == CGPoint(x: 0, y: 0))
        #expect(SimulatorDisplayGeometry.ratio(for: CGPoint(x: 200, y: 320), in: rect) == CGPoint(x: 0.5, y: 0.5))
        #expect(SimulatorDisplayGeometry.ratio(for: CGPoint(x: 1000, y: -5), in: rect) == CGPoint(x: 1, y: 0))
    }

    @Test func `preferred width follows the device aspect`() {
        let width = SimulatorDisplayGeometry.preferredWidth(screen: CGSize(width: 1320, height: 2868), height: 900, gutter: 8, minimum: 280)
        #expect(width == (900 * 1320 / 2868 + 16).rounded())
        #expect(SimulatorDisplayGeometry.preferredWidth(screen: .zero, height: 900, gutter: 8, minimum: 280) == 280)
    }
}

@Suite struct IndigoEnvelopeTests {
    @Test func `single touch envelope matches the Indigo wire layout`() {
        var contact = [UInt8](repeating: 0, count: IndigoEnvelope.touchSize)
        contact[0] = 0xAA
        contact[8] = 0xCC
        contact[IndigoEnvelope.touchSize - 1] = 0xBB
        let message = contact.withUnsafeBytes { IndigoEnvelope.singleTouch(contact: $0) }
        defer { free(message) }
        #expect(message.load(fromByteOffset: 0x18, as: UInt32.self) == 0x90)
        #expect(message.load(fromByteOffset: 0x1c, as: UInt8.self) == 2)
        #expect(message.load(fromByteOffset: 0x20, as: UInt32.self) == 0xB)
        #expect(message.load(fromByteOffset: 0x30, as: UInt8.self) == 0xAA)
        #expect(message.load(fromByteOffset: 0x30 + IndigoEnvelope.touchSize - 1, as: UInt8.self) == 0xBB)
        // Second payload is a copy of the first, with field1/field2 marked as the repeated contact.
        #expect(message.load(fromByteOffset: 0xC0, as: UInt32.self) == 1)
        #expect(message.load(fromByteOffset: 0xC4, as: UInt32.self) == 2)
        #expect(message.load(fromByteOffset: 0xC8, as: UInt8.self) == 0xCC)
        #expect(message.load(fromByteOffset: 0xB0 + 0x10 + IndigoEnvelope.touchSize - 1, as: UInt8.self) == 0xBB)
    }
}
