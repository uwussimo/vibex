import AppKit
import Observation

/// Works out whose site an MCP server belongs to, so its row can show that site's icon.
nonisolated enum ServerDomain {
    /// "https://mcp.clickup.com/mcp" → "clickup.com". Finds the URL inside a command line too, as in
    /// `npx mcp-remote https://mcp.linear.app/sse`. Nil for local servers and commands without a URL.
    static func root(in text: String) -> String? {
        for word in text.split(whereSeparator: \.isWhitespace) where word.hasPrefix("http://") || word.hasPrefix("https://") {
            if let host = URL(string: String(word))?.host(), let root = root(ofHost: host) { return root }
        }
        return nil
    }

    static func root(ofHost host: String) -> String? {
        let host = host.lowercased()
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2, labels.last?.allSatisfy(\.isNumber) == false, !host.hasSuffix(".local"), !host.contains(":") else { return nil }
        // Sites on a shared host are their owner's, not the host's.
        let two = labels.suffix(2).joined(separator: ".")
        if sharedHosts.contains(two) { return labels.count > 2 ? host : nil }
        return labels.count > 2 && countrySuffixes.contains(two) ? labels.suffix(3).joined(separator: ".") : two
    }

    /// The site for a marketplace entry: where it connects to, else its website. A code host says
    /// nothing about who made the server, so it doesn't count. Reverse-DNS registry names are
    /// verified by the registry: "com.stripe/mcp" → "stripe.com".
    static func root(for spec: MCPServerSpec) -> String? {
        if let site = spec.site { return site }
        if case let .remote(_, url, _) = spec.kind, let root = root(in: url) { return root }
        if let homepage = spec.homepage?.absoluteString, let root = root(in: homepage), !codeHosts.contains(root) { return root }
        return spec.registryName.flatMap(root(ofRegistryName:))
    }

    static func root(ofRegistryName name: String) -> String? {
        guard let namespace = name.split(separator: "/").first else { return nil }
        let labels = namespace.split(separator: ".").map(String.init)
        guard labels.count >= 2, !namespace.hasPrefix("io.github."), !namespace.hasPrefix("ai.smithery") else { return nil }
        return root(ofHost: labels.reversed().joined(separator: "."))
    }

    private static let codeHosts: Set = ["github.com", "gitlab.com", "bitbucket.org", "npmjs.com", "pypi.org"]
    private static let sharedHosts: Set = [
        "vercel.app", "workers.dev", "herokuapp.com", "github.io", "onrender.com", "fly.dev", "netlify.app",
        "pages.dev", "railway.app", "deno.dev", "modal.run", "amazonaws.com", "cloudfront.net", "azurewebsites.net", "web.app",
    ]
    private static let countrySuffixes: Set = [
        "co.uk", "org.uk", "ac.uk", "com.au", "net.au", "co.nz", "co.jp", "ne.jp", "co.kr", "com.br", "com.cn",
        "co.in", "com.mx", "com.tr", "com.sg", "co.za", "com.ua", "co.il",
    ]
}

/// A site's icon, and how to show it on Vibex's dark tiles.
struct ServerFavicon: Equatable {
    var image: NSImage
    /// A dark mark needs a light plate to be seen.
    var isDark: Bool
    /// An opaque square is already a tile; a mark floats inside one.
    var fillsTile: Bool
}

/// Fetches icons straight from each site (no third-party favicon service learns what's installed) and
/// remembers them on disk, including that a site has none.
@Observable
final class FaviconStore {
    static let shared = FaviconStore()

    private(set) var icons: [String: ServerFavicon] = [:]
    @ObservationIgnored private var requested = Set<String>()
    @ObservationIgnored private let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Vibex/favicons", isDirectory: true)

    func load(_ domain: String) {
        guard requested.insert(domain).inserted else { return }
        let cache = cache
        Task {
            guard let data = await Self.data(for: domain, cache: cache), let image = NSImage(data: data) else { return }
            icons[domain] = Self.favicon(image)
        }
    }

    @concurrent private static func data(for domain: String, cache: URL) async -> Data? {
        let file = cache.appendingPathComponent(domain)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path), let date = attributes[.modificationDate] as? Date,
           let saved = try? Data(contentsOf: file) {
            // "None" may have been a bad connection, so it's asked again sooner than a real icon is.
            let age = -date.timeIntervalSinceNow
            if age < (saved.isEmpty ? 24 : 30 * 24) * 3600 { return saved.isEmpty ? nil : saved }
        }
        let found = await fetch(domain)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? (found ?? Data()).write(to: file)
        return found
    }

    @concurrent private static func fetch(_ domain: String) async -> Data? {
        guard let home = URL(string: "https://\(domain)/") else { return nil }
        var candidates: [URL] = []
        if let (data, response) = try? await get(home) {
            let page = String(decoding: data.prefix(4_000_000), as: UTF8.self)
            candidates = links(inPage: page, base: response.url ?? home)
        }
        candidates.append(contentsOf: [URL(string: "/favicon.ico", relativeTo: home)?.absoluteURL].compactMap(\.self))
        for url in candidates {
            guard let (data, response) = try? await get(url), (response as? HTTPURLResponse)?.statusCode == 200,
                  response.mimeType?.hasPrefix("text/html") != true, !data.isEmpty, data.count < 2_000_000,
                  NSImage(data: data)?.isValid == true else { continue }
            return data
        }
        return nil
    }

    @concurrent private static func get(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        // Plenty of sites turn away anything that doesn't look like a browser.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        return try await URLSession.shared.data(for: request)
    }

    /// The page's icons, best first: big ones for a sharp tile, then vectors, then whatever is left.
    nonisolated static func links(inPage page: String, base: URL) -> [URL] {
        struct Candidate { var url: URL; var score: Int }
        var found: [Candidate] = []
        for match in page.matches(of: /<link\b[^>]*>/.ignoresCase()) {
            let tag = String(match.output)
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon"), !rel.contains("mask"),
                  let href = attribute("href", in: tag)?.replacingOccurrences(of: "&amp;", with: "&"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            let side = attribute("sizes", in: tag)?.split(separator: "x").first.flatMap { Int($0) } ?? 0
            let isVector = url.path().hasSuffix(".svg") || attribute("type", in: tag)?.contains("svg") == true
            let score = isVector ? 150 : (rel.contains("apple") ? max(side, 180) : side)
            found.append(Candidate(url: url, score: score))
        }
        return found.sorted { $0.score > $1.score }.map(\.url)
    }

    nonisolated private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
        }
        return nil
    }

    /// Looks at the icon's pixels to decide how it should sit on a dark tile.
    static func favicon(_ image: NSImage) -> ServerFavicon {
        let side = 24
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return ServerFavicon(image: image, isDark: false, fillsTile: false) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var brightness = 0.0, weight = 0.0
        for x in 0..<side {
            for y in 0..<side {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                brightness += color.brightnessComponent * color.alphaComponent
                weight += color.alphaComponent
            }
        }
        let corners = [(0, 0), (side - 1, 0), (0, side - 1), (side - 1, side - 1)]
        let opaqueCorners = corners.filter { (bitmap.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 0) > 0.9 }.count
        let fills = opaqueCorners >= 3
        return ServerFavicon(image: image, isDark: !fills && weight > 0 && brightness / weight < 0.3, fillsTile: fills)
    }
}
