import WebKit

enum WebViewFactory {
    static let homeURL = URL(string: "https://www.netflix.com/browse")!

    /// Netflix checks the user agent and needs FairPlay, which WebKit exposes to any WKWebView.
    /// Presenting as Safari keeps its player happy; the persistent data store keeps the login.
    static func make(contentController: WKUserContentController? = nil) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let contentController { configuration.userContentController = contentController }
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.setURLSchemeHandler(NewTabSchemeHandler.shared, forURLScheme: NewTabPage.scheme)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .black
        #if DEBUG
        webView.isInspectable = true
        #endif
        return webView
    }

    /// localhost, 127.0.0.1, a LAN address or a `.local` / `.test` name.
    static func isLocal(_ host: String) -> Bool {
        let name = host.split(separator: "/").first.map { String($0.split(separator: ":").first ?? "") } ?? host
        return name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") || name.hasSuffix(".test")
            || name.hasPrefix("127.") || name.hasPrefix("192.168.") || name.hasPrefix("10.") || name == "0.0.0.0"
    }

    /// Turns what the user typed into something loadable: a URL, a bare host, or a web search.
    static func url(forInput input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https", "file", "about"].contains(scheme) {
            return url
        }
        let looksLikeHost = !text.contains(" ") && (text.contains(".") || text.hasPrefix("localhost"))
        // Dev servers speak plain HTTP; everything else gets HTTPS.
        if looksLikeHost, let url = URL(string: "\(isLocal(text) ? "http" : "https")://\(text)") {
            return url
        }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url
    }
}
