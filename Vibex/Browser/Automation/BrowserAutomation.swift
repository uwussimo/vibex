import AppKit
import Foundation
import WebKit

/// What the browser tools call. Thin, main-actor, and tab-addressed.
final class BrowserAutomation {
    private let pane: BrowserPaneViewController

    init(pane: BrowserPaneViewController) {
        self.pane = pane
    }

    func tab(_ number: Int?) throws -> BrowserTab {
        if let number {
            guard let tab = pane.tabs.first(where: { $0.number == number }) else { throw ToolError("no tab #\(number); call browser_tabs") }
            return tab
        }
        guard let tab = pane.selectedTab else { throw ToolError("no browser tab is open") }
        return tab
    }

    func describeTabs() -> String {
        pane.tabs.map { tab in
            let marker = tab.id == pane.selectedID ? "*" : " "
            return "\(marker) #\(tab.number)  \(tab.title)  \(tab.url?.absoluteString ?? "")"
        }.joined(separator: "\n")
    }

    func newTab(url: URL?) -> BrowserTab {
        pane.openTab(url: url)
    }

    func close(_ tab: BrowserTab) { pane.close(tab.id) }
    func select(_ tab: BrowserTab) { pane.select(tab.id) }

    // MARK: - Page interaction

    @discardableResult
    func evaluate(_ script: String, in tab: BrowserTab) async throws -> Any? {
        do {
            return try await tab.webView.evaluateJavaScript(script)
        } catch {
            throw ToolError("JavaScript failed: \(error.localizedDescription)")
        }
    }

    func snapshot(_ tab: BrowserTab) async throws -> String {
        _ = try await evaluate(SnapshotScript.actions, in: tab)
        let result = try await evaluate(SnapshotScript.source, in: tab)
        return result as? String ?? "(empty page)"
    }

    private func ensureActions(_ tab: BrowserTab) async throws {
        let ready = try await evaluate("Boolean(window.__vibex && window.__vibex.click)", in: tab) as? Bool ?? false
        if !ready { _ = try await evaluate(SnapshotScript.actions, in: tab) }
    }

    func click(ref: String, in tab: BrowserTab) async throws -> String {
        try await ensureActions(tab)
        let before = tab.url
        let result = try await evaluate("window.__vibex.click(\(Self.literal(ref)))", in: tab) as? String ?? "clicked"
        // Give a navigation a moment to start, then settle, so the reply says where the page is now.
        try? await Task.sleep(for: .milliseconds(250))
        if tab.isLoading || tab.url != before {
            return "\(result); now at \(try await waitForLoad(tab, timeout: 10))"
        }
        return result
    }

    func type(ref: String, text: String, submit: Bool, in tab: BrowserTab) async throws -> String {
        try await ensureActions(tab)
        return try await evaluate("window.__vibex.type(\(Self.literal(ref)), \(Self.literal(text)), \(submit))", in: tab) as? String ?? "typed"
    }

    func press(key: String, in tab: BrowserTab) async throws -> String {
        try await ensureActions(tab)
        return try await evaluate("window.__vibex.press(\(Self.literal(key)))", in: tab) as? String ?? "pressed"
    }

    func scroll(ref: String?, dx: Double, dy: Double, in tab: BrowserTab) async throws -> String {
        try await ensureActions(tab)
        let refLiteral = ref.map(Self.literal) ?? "null"
        return try await evaluate("window.__vibex.scroll(\(refLiteral), \(dx), \(dy))", in: tab) as? String ?? "scrolled"
    }

    func pageText(_ tab: BrowserTab) async throws -> String {
        try await ensureActions(tab)
        return try await evaluate("window.__vibex.text()", in: tab) as? String ?? ""
    }

    /// Runs arbitrary JS, returning a JSON-ish string. Promises are awaited.
    /// Uses callAsyncJavaScript: evaluateJavaScript would hand back the Promise object itself,
    /// which WebKit rejects as "a result of an unsupported type".
    func run(javaScript: String, in tab: BrowserTab) async throws -> String {
        let body = """
        try {
            const value = await (async () => { return eval(\(Self.literal(javaScript))); })();
            if (value === undefined) return "undefined";
            try { return JSON.stringify(value, null, 1); } catch (e) { return String(value); }
        } catch (error) {
            return "Error: " + (error && (error.stack || error.message) || String(error));
        }
        """
        let result: Any?
        do {
            result = try await tab.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
        } catch {
            throw ToolError("JavaScript failed: \(error.localizedDescription)")
        }
        let text = result as? String ?? String(describing: result ?? "null")
        return String(text.prefix(60_000))
    }

    func navigate(_ url: URL, in tab: BrowserTab) async throws -> String {
        tab.load(url)
        return try await waitForLoad(tab, timeout: 15)
    }

    /// Waits until the tab finishes loading (or the timeout passes), then reports where it is.
    func waitForLoad(_ tab: BrowserTab, timeout: Double) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(150))
        while tab.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return "\(tab.title) — \(tab.url?.absoluteString ?? "")"
    }

    func wait(ms: Int?, selector: String?, text: String?, in tab: BrowserTab, timeout: Double) async throws -> String {
        if let ms { try? await Task.sleep(for: .milliseconds(ms)) }
        guard selector != nil || text != nil else { return "waited" }
        let deadline = Date().addingTimeInterval(timeout)
        let probe: String
        if let selector {
            probe = "Boolean(document.querySelector(\(Self.literal(selector))))"
        } else {
            probe = "(document.body && document.body.innerText || '').includes(\(Self.literal(text ?? "")))"
        }
        while Date() < deadline {
            if try await evaluate(probe, in: tab) as? Bool ?? false { return "found" }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw ToolError("timed out waiting for \(selector ?? text ?? "")")
    }

    func screenshot(_ tab: BrowserTab, maxWidth: Int) async throws -> Data {
        try await screenshotImage(tab, maxWidth: maxWidth)
    }

    private func screenshotImage(_ tab: BrowserTab, maxWidth: Int) async throws -> Data {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image: NSImage
        do {
            image = try await tab.webView.takeSnapshot(configuration: configuration)
        } catch {
            throw ToolError("snapshot failed: \(error.localizedDescription)")
        }
        return try ImageEncoding.jpeg(from: image, maxWidth: maxWidth)
    }

    static func literal(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [string])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

/// Screenshot encoding with downscaling, shared by browser and simulator tools. JPEG keeps the
/// payload small; the model reads pixels, not bytes.
enum ImageEncoding {
    static func jpeg(from image: NSImage, maxWidth: Int, quality: Double = 0.8) throws -> Data {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ToolError("could not read image") }
        return try jpeg(from: cgImage, maxWidth: maxWidth, quality: quality)
    }

    static func jpeg(from cgImage: CGImage, maxWidth: Int, quality: Double = 0.8) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: try scaled(cgImage, maxWidth: maxWidth))
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { throw ToolError("could not encode JPEG") }
        return data
    }

    static func scaled(_ cgImage: CGImage, maxWidth: Int) throws -> CGImage {
        var output = cgImage
        if cgImage.width > maxWidth, maxWidth > 0 {
            let scale = Double(maxWidth) / Double(cgImage.width)
            let width = maxWidth
            let height = max(1, Int(Double(cgImage.height) * scale))
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw ToolError("could not scale image") }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { throw ToolError("could not scale image") }
            output = scaled
        }
        return output
    }
}
