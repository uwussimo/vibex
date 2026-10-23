import AppKit
import os
import SwiftUI
import WebKit

/// Netflix-first mini browser: a slim toolbar and one web view per tab. Its tabs are shown in the
/// editor area's tab strip; background tabs stay alive (and keep playing) while out of the view hierarchy.
final class BrowserPaneViewController: NSViewController, NSMenuItemValidation {
    let session: ProjectSession
    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedID: UUID?

    private let toolbarModel = BrowserToolbarModel()
    /// Tabs were added, removed, retitled or started/stopped loading.
    var onTabsChange: () -> Void = {}
    /// A tab became the selected one (by click, by a link opening a new tab, or by Run).
    var onSelect: (UUID) -> Void = { _ in }
    private let container = NSView()
    private var hasRestored = false

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedID } }
    /// The web view of the selected tab, for focus and the responder chain.
    var webView: WKWebView? { selectedTab?.webView }

    init(session: ProjectSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        let toolbarActions = BrowserToolbarActions(
            back: { [weak self] in self?.webView?.goBack() },
            forward: { [weak self] in self?.webView?.goForward() },
            reloadOrStop: { [weak self] in self?.reloadOrStop() },
            home: { [weak self] in self?.load(WebViewFactory.homeURL) },
            navigate: { [weak self] text in self?.navigate(to: text) },
            focusWebView: { [weak self] in self?.focusWebView() }
        )
        let toolbar = NSHostingView(rootView: BrowserToolbar(model: toolbarModel, actions: toolbarActions))
        toolbar.sizingOptions = []
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        root.addSubview(toolbar)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 40),
            container.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        restoreTabs()
        observeSelectedTab()
    }

    // MARK: - Tabs

    @discardableResult
    func openTab(url: URL?, select shouldSelect: Bool = true) -> BrowserTab {
        let tab = BrowserTab()
        tab.webView.navigationDelegate = self
        tab.webView.uiDelegate = self
        tabs.append(tab)
        if let url { tab.load(url) } else { tab.loadStartPage() }
        if shouldSelect { select(tab.id) } else { syncStrip() }
        persistTabs()
        return tab
    }

    func select(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedID = id
        for subview in container.subviews where subview !== tab.webView {
            subview.removeFromSuperview()
        }
        if tab.webView.superview == nil {
            tab.webView.frame = container.bounds
            tab.webView.autoresizingMask = [.width, .height]
            container.addSubview(tab.webView)
        }
        syncStrip()
        syncToolbar()
        persistTabs()
        onSelect(id)
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        tab.webView.removeFromSuperview()
        tab.tearDown()
        if tabs.isEmpty {
            openTab(url: nil)
            return
        }
        if selectedID == id {
            select(tabs[min(index, tabs.count - 1)].id)
        } else {
            syncStrip()
            persistTabs()
        }
    }

    func tab(withID id: UUID?) -> BrowserTab? {
        guard let id else { return selectedTab }
        return tabs.first { $0.id == id }
    }

    private func restoreTabs() {
        guard !hasRestored else { return }
        hasRestored = true
        let urls = session.state.browserTabURLs.compactMap(URL.init(string:))
        if urls.isEmpty {
            openTab(url: nil)
        } else {
            for url in urls { openTab(url: url, select: false) }
            let index = min(max(session.state.browserSelectedTab, 0), tabs.count - 1)
            select(tabs[index].id)
        }
    }

    private func persistTabs() {
        guard hasRestored else { return }
        let urls = tabs.map { $0.url?.absoluteString ?? "" }.filter { $0.hasPrefix("http") }
        let index = selectedID.flatMap { id in tabs.firstIndex { $0.id == id } } ?? 0
        session.update {
            $0.browserTabURLs = urls
            $0.browserSelectedTab = index
        }
    }

    private func syncStrip() {
        onTabsChange()
    }

    private func syncToolbar() {
        guard let tab = selectedTab else { return }
        toolbarModel.urlText = tab.url?.absoluteString ?? ""
        toolbarModel.host = tab.url.map { $0.scheme == "about" || $0.scheme == nil ? "" : tab.hostTitle } ?? ""
        toolbarModel.canGoBack = tab.canGoBack
        toolbarModel.canGoForward = tab.canGoForward
        toolbarModel.isLoading = tab.isLoading
        toolbarModel.isSecure = tab.isSecure
    }

    /// Re-syncs toolbar and strip whenever any tab's observed state changes.
    private func observeSelectedTab() {
        withObservationTracking {
            for tab in tabs {
                _ = tab.title
                _ = tab.url
                _ = tab.isLoading
                _ = tab.canGoBack
                _ = tab.canGoForward
                _ = tab.isSecure
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncStrip()
                self?.syncToolbar()
                self?.persistTabs()
                self?.observeSelectedTab()
            }
        }
    }

    // MARK: - Navigation

    func load(_ url: URL, in tab: BrowserTab? = nil) {
        (tab ?? selectedTab)?.load(url)
    }

    private func navigate(to text: String) {
        guard let url = WebViewFactory.url(forInput: text) else { return }
        load(url)
    }

    private func reloadOrStop() {
        guard let webView else { return }
        if webView.isLoading { webView.stopLoading() } else { webView.reload() }
    }

    func focusWebView() {
        guard let webView else { return }
        view.window?.makeFirstResponder(webView)
    }

    // MARK: - Menu actions (responder chain; same selectors as the terminal pane)

    @objc func newTab(_ sender: Any?) {
        openTab(url: nil)
        toolbarModel.focusRequest += 1
    }

    @objc func closeTab(_ sender: Any?) {
        guard let selectedID else { return }
        close(selectedID)
    }

    @objc func nextTab(_ sender: Any?) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        select(tabs[(index + 1) % tabs.count].id)
    }

    @objc func previousTab(_ sender: Any?) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        select(tabs[(index - 1 + tabs.count) % tabs.count].id)
    }

    @objc func openLocation(_ sender: Any?) {
        toolbarModel.focusRequest += 1
    }

    @objc func reloadPage(_ sender: Any?) { webView?.reload() }
    @objc func goBack(_ sender: Any?) { webView?.goBack() }
    @objc func goForward(_ sender: Any?) { webView?.goForward() }
    @objc func goHome(_ sender: Any?) { load(WebViewFactory.homeURL) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return webView?.canGoBack ?? false
        case #selector(goForward(_:)): return webView?.canGoForward ?? false
        case #selector(nextTab(_:)), #selector(previousTab(_:)): return tabs.count > 1
        default: return true
        }
    }

    func prepareForTermination() {
        persistTabs()
    }
}

extension BrowserPaneViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme else { return .allow }
        if ["http", "https", "about", "blob", "data"].contains(scheme) { return .allow }
        NSWorkspace.shared.open(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Log.browser.error("navigation failed: \(error.localizedDescription, privacy: .public)")
    }
}

extension BrowserPaneViewController: WKUIDelegate {
    /// Links that want a new window open a new tab.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            openTab(url: url)
        }
        return nil
    }
}
