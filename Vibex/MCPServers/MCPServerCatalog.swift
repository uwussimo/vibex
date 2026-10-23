import Foundation

/// Something to fill in before an MCP server can start: an API key, a token, a header value.
nonisolated struct MCPInputField: Equatable, Sendable, Hashable {
    var name: String
    var summary: String?
    var isSecret: Bool
    var isRequired: Bool
    /// For headers: the value with `{field}` placeholders, e.g. "Bearer {token}".
    var template: String?

    init(name: String, summary: String? = nil, isSecret: Bool, isRequired: Bool, template: String? = nil) {
        self.name = name
        self.summary = summary
        self.isSecret = isSecret
        self.isRequired = isRequired
        self.template = template
    }
}

/// How to install an MCP server: a command Claude Code starts, or a remote URL it connects to.
nonisolated struct MCPServerSpec: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case stdio(command: [String], environment: [MCPInputField])
        case remote(transport: String, url: String, headers: [MCPInputField])
    }

    /// The name Claude Code knows it by: short, lowercase.
    var name: String
    var title: String
    var summary: String
    var kind: Kind
    /// Where it came from, for "More info".
    var homepage: URL?
    var id: String { name }

    var inputs: [MCPInputField] {
        switch kind {
        case let .stdio(_, environment): environment
        case let .remote(_, _, headers): headers
        }
    }

    var kindLabel: String {
        switch kind {
        case let .stdio(command, _): command.first == "npx" ? "npm" : (command.first ?? "command")
        case .remote: "Remote"
        }
    }

    /// The arguments for `claude mcp add` in the given scope ("user", "project" or "local").
    func addArguments(scope: String, values: [String: String]) -> [String] {
        switch kind {
        case let .stdio(command, environment):
            var arguments = ["mcp", "add", "--scope", scope]
            for field in environment {
                if let value = values[field.name], !value.isEmpty { arguments += ["--env", "\(field.name)=\(value)"] }
            }
            return arguments + [name, "--"] + command
        case let .remote(transport, url, headers):
            var arguments = ["mcp", "add", "--transport", transport, "--scope", scope]
            for field in headers {
                guard let value = values[field.name], !value.isEmpty else { continue }
                let filled = field.template.map { Self.fill($0, with: values) } ?? value
                arguments += ["--header", "\(field.name): \(filled)"]
            }
            return arguments + [name, url]
        }
    }

    /// "Bearer {token}" with `token` from `values`.
    static func fill(_ template: String, with values: [String: String]) -> String {
        var result = template
        for (key, value) in values { result = result.replacingOccurrences(of: "{\(key)}", with: value) }
        return result
    }

    /// "io.github.microsoft/playwright-mcp" → "playwright-mcp"
    static func shortName(_ registryName: String) -> String {
        let last = registryName.split(separator: "/").last.map(String.init) ?? registryName
        let cleaned = last.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// Well-known servers that work without the registry, so the marketplace is useful when it's slow.
nonisolated enum MCPFeatured {
    static let servers: [MCPServerSpec] = [
        MCPServerSpec(name: "playwright", title: "Playwright", summary: "Drive a real browser: navigate, click, fill forms and read pages.",
                      kind: .stdio(command: ["npx", "-y", "@playwright/mcp@latest"], environment: []), homepage: URL(string: "https://github.com/microsoft/playwright-mcp")),
        MCPServerSpec(name: "context7", title: "Context7", summary: "Up-to-date library docs and code examples, pulled into the prompt.",
                      kind: .stdio(command: ["npx", "-y", "@upstash/context7-mcp"], environment: []), homepage: URL(string: "https://github.com/upstash/context7")),
        MCPServerSpec(name: "chrome-devtools", title: "Chrome DevTools", summary: "Inspect, debug and profile pages in Chrome.",
                      kind: .stdio(command: ["npx", "-y", "chrome-devtools-mcp@latest"], environment: []), homepage: URL(string: "https://github.com/ChromeDevTools/chrome-devtools-mcp")),
        MCPServerSpec(name: "github", title: "GitHub", summary: "Issues, pull requests, code search and Actions on GitHub.",
                      kind: .remote(transport: "http", url: "https://api.githubcopilot.com/mcp/", headers: [
                          MCPInputField(name: "Authorization", summary: "A GitHub personal access token", isSecret: true, isRequired: true, template: "Bearer {Authorization}"),
                      ]), homepage: URL(string: "https://github.com/github/github-mcp-server")),
        MCPServerSpec(name: "sentry", title: "Sentry", summary: "Errors, issues and releases from Sentry. Signs in with OAuth.",
                      kind: .remote(transport: "http", url: "https://mcp.sentry.dev/mcp", headers: []), homepage: URL(string: "https://docs.sentry.io/product/sentry-mcp/")),
        MCPServerSpec(name: "linear", title: "Linear", summary: "Find, create and update Linear issues. Signs in with OAuth.",
                      kind: .remote(transport: "http", url: "https://mcp.linear.app/mcp", headers: []), homepage: URL(string: "https://linear.app/docs/mcp")),
        MCPServerSpec(name: "notion", title: "Notion", summary: "Search and edit your Notion pages and databases. Signs in with OAuth.",
                      kind: .remote(transport: "http", url: "https://mcp.notion.com/mcp", headers: []), homepage: URL(string: "https://developers.notion.com/docs/mcp")),
        MCPServerSpec(name: "supabase", title: "Supabase", summary: "Manage Supabase projects, tables and migrations. Signs in with OAuth.",
                      kind: .remote(transport: "http", url: "https://mcp.supabase.com/mcp", headers: []), homepage: URL(string: "https://supabase.com/docs/guides/getting-started/mcp")),
        MCPServerSpec(name: "stripe", title: "Stripe", summary: "Customers, payments and the Stripe docs. Signs in with OAuth.",
                      kind: .remote(transport: "http", url: "https://mcp.stripe.com", headers: []), homepage: URL(string: "https://docs.stripe.com/mcp")),
        MCPServerSpec(name: "figma", title: "Figma", summary: "Designs from the Figma desktop app's Dev Mode server.",
                      kind: .remote(transport: "http", url: "http://127.0.0.1:3845/mcp", headers: []), homepage: URL(string: "https://help.figma.com/hc/en-us/articles/32132100833559")),
    ]
}

/// The official MCP registry (registry.modelcontextprotocol.io).
nonisolated enum MCPRegistry {
    enum Failure: Error, LocalizedError {
        case unreachable
        var errorDescription: String? { "Couldn't reach the MCP registry. It may be busy; try again in a moment." }
    }

    @concurrent static func search(_ query: String) async throws -> [MCPServerSpec] {
        var components = URLComponents(string: "https://registry.modelcontextprotocol.io/v0/servers")!
        components.queryItems = [URLQueryItem(name: "search", value: query), URLQueryItem(name: "limit", value: "60")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.unreachable }
        return parse(data)
    }

    /// The latest version of each server, skipping ones Vibex can't install (Docker images, proxies that need an account).
    static func parse(_ data: Data) -> [MCPServerSpec] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["servers"] as? [[String: Any]] else { return [] }
        var specs: [MCPServerSpec] = []
        var seen = Set<String>()
        for entry in entries {
            guard let server = entry["server"] as? [String: Any], let registryName = server["name"] as? String else { continue }
            let official = (entry["_meta"] as? [String: Any])?["io.modelcontextprotocol.registry/official"] as? [String: Any]
            if let latest = official?["isLatest"] as? Bool, !latest { continue }
            if registryName.hasPrefix("ai.smithery/") { continue }
            guard let kind = kind(of: server) else { continue }
            var name = MCPServerSpec.shortName(registryName)
            if seen.contains(name) { name = MCPServerSpec.shortName(registryName.replacingOccurrences(of: "/", with: "-")) }
            guard seen.insert(name).inserted else { continue }
            let repository = (server["repository"] as? [String: Any])?["url"] as? String
            specs.append(MCPServerSpec(
                name: name,
                title: (server["title"] as? String) ?? name,
                summary: (server["description"] as? String) ?? "",
                kind: kind,
                homepage: ((server["websiteUrl"] as? String) ?? repository).flatMap(URL.init(string:))
            ))
        }
        return specs
    }

    private static func kind(of server: [String: Any]) -> MCPServerSpec.Kind? {
        for package in server["packages"] as? [[String: Any]] ?? [] {
            guard let identifier = package["identifier"] as? String else { continue }
            let transport = (package["transport"] as? [String: Any])?["type"] as? String ?? "stdio"
            guard transport == "stdio" else { continue }
            let environment = (package["environmentVariables"] as? [[String: Any]] ?? []).compactMap(field)
            switch package["registryType"] as? String {
            case "npm":
                let version = (package["version"] as? String).map { "@\($0)" } ?? ""
                return .stdio(command: ["npx", "-y", identifier + version], environment: environment)
            case "pypi":
                return .stdio(command: ["uvx", identifier], environment: environment)
            default:
                continue
            }
        }
        for remote in server["remotes"] as? [[String: Any]] ?? [] {
            guard let url = remote["url"] as? String, let type = remote["type"] as? String else { continue }
            let headers = (remote["headers"] as? [[String: Any]] ?? []).compactMap(field)
            return .remote(transport: type == "sse" ? "sse" : "http", url: url, headers: headers)
        }
        return nil
    }

    private static func field(_ object: [String: Any]) -> MCPInputField? {
        guard let name = object["name"] as? String else { return nil }
        let value = object["value"] as? String
        return MCPInputField(
            name: name,
            summary: object["description"] as? String,
            isSecret: object["isSecret"] as? Bool ?? false,
            isRequired: object["isRequired"] as? Bool ?? false,
            // "Bearer {api_key}" asks for the key; the field's own name stands in for the placeholder.
            template: value.map { $0.replacingOccurrences(of: #"\{[^}]+\}"#, with: "{\(name)}", options: .regularExpression) }
        )
    }
}
