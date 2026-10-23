import AppKit
import os
import WebKit

struct ConsoleEntry: Sendable {
    let level: String
    let text: String
    let date: Date
}

struct RequestEntry: Sendable {
    let method: String
    let url: String
    let status: Int
    let milliseconds: Int
    let kind: String
    let error: String?
    let date: Date
}

/// One browser tab: a web view plus what it has logged.
@Observable
final class BrowserTab: NSObject {
    let id = UUID()
    let number: Int
    let webView: WKWebView

    nonisolated(unsafe) private static var nextNumber = 1

    private(set) var title = "New Tab"
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isSecure = true
    private(set) var console: [ConsoleEntry] = []
    private(set) var requests: [RequestEntry] = []

    static let bufferLimit = 500

    private var observations: [NSKeyValueObservation] = []

    override init() {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: BrowserScripts.capture, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WebViewFactory.make(contentController: controller)
        number = Self.nextNumber
        Self.nextNumber += 1
        super.init()
        controller.add(self, name: "vibexConsole")
        controller.add(self, name: "vibexNetwork")
        observe()
    }

    func tearDown() {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.stopLoading()
        observations = []
    }

    var hostTitle: String {
        guard let url, !NewTabPage.isNewTab(url) else { return "New Tab" }
        return url.host()?.replacingOccurrences(of: "www.", with: "") ?? "New Tab"
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func loadStartPage() {
        load(NewTabPage.url)
    }

    func clearConsole() { console = [] }
    func clearRequests() { requests = [] }

    private func observe() {
        func onMain(_ body: @escaping @MainActor (WKWebView) -> Void) -> @Sendable (WKWebView, Any) -> Void {
            { web, _ in MainActor.assumeIsolated { body(web) } }
        }
        observations = [
            webView.observe(\.url, options: [.initial, .new], changeHandler: onMain { [weak self] web in
                self?.url = web.url
                if let web = self?.webView, web.title?.isEmpty ?? true { self?.title = self?.hostTitle ?? "New Tab" }
            }),
            webView.observe(\.title, options: [.initial, .new], changeHandler: onMain { [weak self] web in
                guard let self else { return }
                title = (web.title?.isEmpty == false) ? web.title! : hostTitle
            }),
            webView.observe(\.canGoBack, options: [.initial, .new], changeHandler: onMain { [weak self] web in self?.canGoBack = web.canGoBack }),
            webView.observe(\.canGoForward, options: [.initial, .new], changeHandler: onMain { [weak self] web in self?.canGoForward = web.canGoForward }),
            webView.observe(\.isLoading, options: [.initial, .new], changeHandler: onMain { [weak self] web in self?.isLoading = web.isLoading }),
            webView.observe(\.hasOnlySecureContent, options: [.initial, .new], changeHandler: onMain { [weak self] web in self?.isSecure = web.hasOnlySecureContent }),
        ]
    }
}

extension BrowserTab: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch message.name {
        case "vibexConsole":
            let entry = ConsoleEntry(level: body["level"] as? String ?? "log", text: body["text"] as? String ?? "", date: Date())
            console.append(entry)
            if console.count > Self.bufferLimit { console.removeFirst(console.count - Self.bufferLimit) }
        case "vibexNetwork":
            let entry = RequestEntry(
                method: body["method"] as? String ?? "GET",
                url: body["url"] as? String ?? "",
                status: body["status"] as? Int ?? 0,
                milliseconds: body["ms"] as? Int ?? 0,
                kind: body["type"] as? String ?? "fetch",
                error: body["error"] as? String,
                date: Date()
            )
            requests.append(entry)
            if requests.count > Self.bufferLimit { requests.removeFirst(requests.count - Self.bufferLimit) }
        default:
            break
        }
    }
}
