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

/// One browser tab: a web view plus what it has logged. A tab left alone goes to sleep: its web view
/// and the memory behind it are released, and the first use brings the page back where it was.
@Observable
final class BrowserTab: NSObject {
    let id = UUID()
    let number: Int
    /// Using a sleeping tab wakes it, so nothing outside this class has to know about sleep.
    var webView: WKWebView {
        lastUsed = .now
        wake()
        return liveWebView!
    }

    /// Set by the pane; every web view this tab creates gets them.
    weak var navigationDelegate: WKNavigationDelegate? {
        didSet { liveWebView?.navigationDelegate = navigationDelegate }
    }
    weak var uiDelegate: WKUIDelegate? {
        didSet { liveWebView?.uiDelegate = uiDelegate }
    }

    nonisolated(unsafe) private static var nextNumber = 1

    private(set) var title = "New Tab"
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isSecure = true
    private(set) var console: [ConsoleEntry] = []
    private(set) var requests: [RequestEntry] = []
    private(set) var isAsleep = false
    /// Awake again, and the page hasn't finished coming back yet.
    private(set) var isWaking = false

    static let bufferLimit = 500
    /// How long a tab can sit unused before it sleeps.
    static let idleLimit: TimeInterval = 15 * 60
    /// A page reports playback every 20 seconds, so this long without a report means it stopped.
    private static let mediaLimit: TimeInterval = 2 * 60

    @ObservationIgnored private var liveWebView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var lastUsed = Date.now
    @ObservationIgnored private(set) var lastMedia: Date?
    /// The user typed into this page. A reload would lose it, so the tab stays awake.
    @ObservationIgnored private(set) var hasUserInput = false
    /// Back/forward list and scroll position, kept for waking.
    @ObservationIgnored private var sleepState: Any?
    @ObservationIgnored private var wakeHasStartedLoading = false

    /// With a URL, the tab starts asleep on that page: restored tabs cost nothing until they're opened.
    init(asleepAt url: URL? = nil) {
        number = Self.nextNumber
        Self.nextNumber += 1
        super.init()
        if let url {
            self.url = url
            title = hostTitle
            isAsleep = true
        } else {
            makeWebView()
        }
    }

    private func makeWebView() {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: BrowserScripts.capture, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let web = WebViewFactory.make(contentController: controller)
        for name in ["vibexConsole", "vibexNetwork", "vibexMedia", "vibexInput"] { controller.add(self, name: name) }
        web.navigationDelegate = navigationDelegate
        web.uiDelegate = uiDelegate
        liveWebView = web
        observe()
    }

    func tearDown() {
        releaseWebView()
    }

    private func releaseWebView() {
        liveWebView?.configuration.userContentController.removeAllScriptMessageHandlers()
        liveWebView?.stopLoading()
        liveWebView?.removeFromSuperview()
        observations = []
        liveWebView = nil
    }

    // MARK: - Sleep

    /// The tab just stopped being the one in view: its idle time starts now.
    func markUsed(at date: Date = .now) { lastUsed = date }

    /// Sleeping must cost the user nothing they'd notice: not a video, a call or something half typed.
    func canSleep(at now: Date = .now) -> Bool {
        guard let liveWebView, url != nil, !isLoading, !hasUserInput else { return false }
        guard liveWebView.cameraCaptureState == .none, liveWebView.microphoneCaptureState == .none else { return false }
        if let lastMedia, now.timeIntervalSince(lastMedia) < Self.mediaLimit { return false }
        return now.timeIntervalSince(lastUsed) >= Self.idleLimit
    }

    func sleep() {
        guard let liveWebView else { return }
        sleepState = liveWebView.interactionState
        releaseWebView()
        isAsleep = true
    }

    private func wake() {
        guard isAsleep else { return }
        isWaking = true
        wakeHasStartedLoading = false
        makeWebView()
        isAsleep = false
        if let sleepState, let liveWebView {
            liveWebView.interactionState = sleepState
        }
        sleepState = nil
        if liveWebView?.url == nil, let url { liveWebView?.load(URLRequest(url: url)) }
    }

    /// For tools that read the page straight after waking it.
    func finishWaking() async {
        let deadline = Date.now.addingTimeInterval(10)
        while isWaking, Date.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        isWaking = false
    }

    var hostTitle: String {
        guard let url, !NewTabPage.isNewTab(url) else { return "New Tab" }
        return url.host()?.replacingOccurrences(of: "www.", with: "") ?? "New Tab"
    }

    /// "https://www.acme.com/orders/42?tab=items" → "acme.com/orders/42?tab=items", so the address bar
    /// says which route a page is on. A dev server keeps its port; hash routes stay too.
    nonisolated static func address(_ url: URL) -> String {
        guard let host = url.host(), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        var text = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let port = components.port { text += ":\(port)" }
        let path = components.percentEncodedPath
        if path != "/" { text += path.removingPercentEncoding ?? path }
        if let query = components.percentEncodedQuery { text += "?" + (query.removingPercentEncoding ?? query) }
        if let fragment = components.percentEncodedFragment { text += "#" + (fragment.removingPercentEncoding ?? fragment) }
        return text
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
        guard let liveWebView else { return }
        func onMain(_ body: @escaping @MainActor (WKWebView) -> Void) -> @Sendable (WKWebView, Any) -> Void {
            { web, _ in MainActor.assumeIsolated { body(web) } }
        }
        observations = [
            liveWebView.observe(\.url, options: [.initial, .new], changeHandler: onMain { [weak self] web in
                guard let self else { return }
                // A web view that has just woken is empty until its page returns.
                if web.url == nil, isWaking { return }
                url = web.url
                if web.title?.isEmpty ?? true { title = hostTitle }
            }),
            liveWebView.observe(\.title, options: [.initial, .new], changeHandler: onMain { [weak self] web in
                guard let self else { return }
                if web.title?.isEmpty ?? true, isWaking { return }
                title = (web.title?.isEmpty == false) ? web.title! : hostTitle
            }),
            liveWebView.observe(\.canGoBack, options: [.initial, .new], changeHandler: onMain { [weak self] web in self?.canGoBack = web.canGoBack }),
            liveWebView.observe(\.canGoForward, options: [.initial, .new], changeHandler: onMain { [weak self] web in self?.canGoForward = web.canGoForward }),
            liveWebView.observe(\.isLoading, options: [.initial, .new], changeHandler: onMain { [weak self] web in
                guard let self else { return }
                isLoading = web.isLoading
                // A new document: anything typed into the last one is gone already.
                if web.isLoading { hasUserInput = false }
                if web.isLoading { wakeHasStartedLoading = true } else if wakeHasStartedLoading { isWaking = false }
            }),
            liveWebView.observe(\.hasOnlySecureContent, options: [.initial, .new], changeHandler: onMain { [weak self] web in self?.isSecure = web.hasOnlySecureContent }),
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
        case "vibexMedia":
            lastMedia = .now
        case "vibexInput":
            hasUserInput = true
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
