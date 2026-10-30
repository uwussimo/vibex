import Foundation
import AppKit
import Testing
@testable import Vibex

@MainActor @Suite struct MCPServersTests {
    @Test func `stdio servers become claude mcp add with env vars`() {
        let spec = MCPServerSpec(name: "postgres", title: "Postgres", summary: "",
                                 kind: .stdio(command: ["npx", "-y", "pg-mcp@1.0"], environment: [
                                     MCPInputField(name: "DATABASE_URL", isSecret: true, isRequired: true),
                                     MCPInputField(name: "EMPTY", isSecret: false, isRequired: false),
                                 ]), homepage: nil)
        #expect(spec.addArguments(scope: "user", values: ["DATABASE_URL": "postgres://x", "EMPTY": ""])
            == ["mcp", "add", "postgres", "--scope", "user", "--env", "DATABASE_URL=postgres://x", "--", "npx", "-y", "pg-mcp@1.0"])
    }

    @Test func `remote servers fill header templates`() {
        let github = MCPFeatured.servers.first { $0.name == "github" }!
        #expect(github.addArguments(scope: "project", values: ["Authorization": "ghp_123"])
            == ["mcp", "add", "github", "https://api.githubcopilot.com/mcp/", "--transport", "http", "--scope", "project", "--header", "Authorization: Bearer ghp_123"])
        let sentry = MCPFeatured.servers.first { $0.name == "sentry" }!
        #expect(sentry.addArguments(scope: "user", values: [:]) == ["mcp", "add", "sentry", "https://mcp.sentry.dev/mcp", "--transport", "http", "--scope", "user"])
    }

    @Test func `registry entries parse to installable servers`() throws {
        let json = """
        {"servers": [
          {"server": {"name": "io.github.acme/weather-mcp", "description": "Weather", "repository": {"url": "https://github.com/acme/weather"},
                      "packages": [{"registryType": "npm", "identifier": "@acme/weather", "version": "2.1.0", "transport": {"type": "stdio"},
                                    "environmentVariables": [{"name": "API_KEY", "isRequired": true, "isSecret": true, "description": "Key"}]}]},
           "_meta": {"io.modelcontextprotocol.registry/official": {"isLatest": true}}},
          {"server": {"name": "io.github.acme/weather-mcp", "description": "Old"}, "_meta": {"io.modelcontextprotocol.registry/official": {"isLatest": false}}},
          {"server": {"name": "com.example/remote", "title": "Remote One", "remotes": [{"type": "streamable-http", "url": "https://x.dev/mcp",
                      "headers": [{"name": "X-Key", "value": "{key}", "isRequired": true}]}]}},
          {"server": {"name": "ai.smithery/proxy", "remotes": [{"type": "streamable-http", "url": "https://s/mcp"}]}},
          {"server": {"name": "com.example/docker-only", "packages": [{"registryType": "oci", "identifier": "x"}]}}
        ]}
        """
        let specs = MCPRegistry.parse(Data(json.utf8))
        #expect(specs.map(\.name) == ["weather-mcp", "remote"])
        #expect(specs[0].kind == .stdio(command: ["npx", "-y", "@acme/weather@2.1.0"], environment: [MCPInputField(name: "API_KEY", summary: "Key", isSecret: true, isRequired: true)]))
        #expect(specs[0].homepage?.absoluteString == "https://github.com/acme/weather")
        #expect(specs[1].title == "Remote One")
        #expect(specs[1].addArguments(scope: "user", values: ["X-Key": "abc"]).contains("X-Key: abc"))
    }

    @Test func `installed servers come from every scope`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let claudeJSON = folder.appendingPathComponent("claude.json")
        let config: [String: Any] = [
            "mcpServers": ["vibex": ["type": "http", "url": "http://127.0.0.1:5150/mcp"], "playwright": ["command": "npx", "args": ["@playwright/mcp"]]],
            "projects": [folder.path: ["mcpServers": ["db": ["command": "uvx", "args": ["pg"]]]]],
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: claudeJSON)
        try Data(#"{"mcpServers": {"linear": {"type": "http", "url": "https://mcp.linear.app/mcp"}}}"#.utf8).write(to: folder.appendingPathComponent(".mcp.json"))
        let servers = MCPServersStore.installed(project: folder, claudeJSON: claudeJSON)
        #expect(servers.map(\.id) == ["user|playwright", "user|vibex", "local|db", "project|linear"])
        #expect(servers[0].detail == "npx @playwright/mcp")
        #expect(servers[1].isVibex)
    }

    @Test func `claude mcp list output becomes health`() {
        let output = """
        Checking MCP server health…

        claude.ai Claude Docs: https://api.anthropic.com/v1/pages/mcp - ✔ Connected
        plugin:posthog:posthog: https://mcp.posthog.com/mcp (HTTP) - ! Needs authentication
        clickup: https://mcp.clickup.com/mcp (HTTP) - ✔ Connected
        weather: npx -y @acme/weather - ⏸ Pending approval (run `claude` to approve)
        broken: npx -y nothing-here - ✗ Failed to connect
        """
        let rows = MCPHealth.parse(output)
        #expect(rows.map(\.name) == ["claude.ai Claude Docs", "plugin:posthog:posthog", "clickup", "weather", "broken"])
        #expect(rows.map(\.health) == [.connected, .needsSignIn, .connected, .waitingForApproval, .failed])
        #expect(rows[2].target == "https://mcp.clickup.com/mcp")
        #expect(InstalledMCPServer(name: "plugin:posthog:posthog", scope: .user, detail: "", origin: "Plugin").displayName == "posthog")
        #expect(InstalledMCPServer(name: "claude.ai Claude Docs", scope: .user, detail: "", origin: "claude.ai").displayName == "Claude Docs")
    }

    @Test func `names and logos`() {
        #expect(MCPServerSpec.shortName("io.github.microsoft/playwright-mcp") == "playwright-mcp")
        #expect(MCPServerSpec.shortName("com.Example/My Server!") == "my-server")
        #expect(BrandLogo.forServer("chrome-devtools") == .chrome)
        #expect(BrandLogo.forServer("postgres-mcp") == .postgresql)
        #expect(BrandLogo.forServer("context7") == nil)
    }

    /// The real CLI: project scope only writes the temp folder's .mcp.json.
    @Test func `installs and removes through claude`() async throws {
        guard ClaudeCodeRegistrar.findClaude() != nil else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let spec = MCPFeatured.servers.first { $0.name == "sentry" }!
        try await MCPServersStore.claude(spec.addArguments(scope: "project", values: [:]), in: folder)
        // Keys and headers used to swallow the name ("Invalid environment variable format").
        let keyed = MCPServerSpec(name: "weather", title: "", summary: "", kind: .stdio(command: ["npx", "-y", "weather-mcp"], environment: [
            MCPInputField(name: "API_KEY", isSecret: true, isRequired: true),
        ]), homepage: nil)
        try await MCPServersStore.claude(keyed.addArguments(scope: "project", values: ["API_KEY": "abc"]), in: folder)
        let github = MCPFeatured.servers.first { $0.name == "github" }!
        try await MCPServersStore.claude(github.addArguments(scope: "project", values: ["Authorization": "x"]), in: folder)
        #expect(MCPServersStore.installed(project: folder, claudeJSON: folder.appendingPathComponent("none.json")).map(\.id) == ["project|github", "project|sentry", "project|weather"])
        let config = try String(contentsOf: folder.appendingPathComponent(".mcp.json"), encoding: .utf8)
        #expect(config.contains("\"API_KEY\": \"abc\""))
        #expect(config.contains("Bearer x"))
        for name in ["github", "weather"] { try await MCPServersStore.claude(["mcp", "remove", name, "--scope", "project"], in: folder) }
        try await MCPServersStore.claude(["mcp", "remove", "sentry", "--scope", "project"], in: folder)
        #expect(MCPServersStore.installed(project: folder, claudeJSON: folder.appendingPathComponent("none.json")).isEmpty)
    }
}

@MainActor @Suite struct ServerFaviconTests {
    @Test func `root domains come from urls and commands`() {
        #expect(ServerDomain.root(in: "https://mcp.clickup.com/mcp") == "clickup.com")
        #expect(ServerDomain.root(in: "https://mcp.posthog.com/mcp") == "posthog.com")
        #expect(ServerDomain.root(in: "npx -y mcp-remote https://api.example.co.uk/sse") == "example.co.uk")
        #expect(ServerDomain.root(in: "https://my-tool.vercel.app/mcp") == "my-tool.vercel.app")
    }

    @Test func `local servers and plain commands have no domain`() {
        #expect(ServerDomain.root(in: "http://127.0.0.1:5150/mcp") == nil)
        #expect(ServerDomain.root(in: "http://localhost:3000/mcp") == nil)
        #expect(ServerDomain.root(in: "npx -y @upstash/context7-mcp") == nil)
    }

    @Test func `marketplace entries skip code hosts and read verified registry names`() {
        func spec(_ kind: MCPServerSpec.Kind, homepage: String?, registry: String? = nil) -> MCPServerSpec {
            MCPServerSpec(name: "x", title: "x", summary: "", kind: kind, homepage: homepage.flatMap(URL.init(string:)), registryName: registry)
        }
        let npm = MCPServerSpec.Kind.stdio(command: ["npx", "x"], environment: [])
        #expect(ServerDomain.root(for: spec(.remote(transport: "http", url: "https://mcp.sentry.dev/mcp", headers: []), homepage: "https://docs.sentry.io")) == "sentry.dev")
        #expect(ServerDomain.root(for: spec(npm, homepage: "https://github.com/acme/x")) == nil)
        #expect(ServerDomain.root(for: spec(npm, homepage: "https://docs.acme.io/mcp")) == "acme.io")
        #expect(ServerDomain.root(for: spec(npm, homepage: "https://github.com/acme/x", registry: "com.stripe/mcp")) == "stripe.com")
        #expect(ServerDomain.root(for: spec(npm, homepage: nil, registry: "io.github.acme/x")) == nil)
    }

    @Test func `page icons are ranked with the sharpest first`() throws {
        let page = """
        <link rel="icon" href="/small.png" sizes="16x16"><link rel="mask-icon" href="/mask.svg">
        <link href='/touch.png' rel='apple-touch-icon' sizes='180x180'/><link rel="stylesheet" href="/a.css">
        <link rel="shortcut icon" href="https://cdn.x.com/a.png?w=96&amp;h=96" sizes="96x96">
        """
        let urls = FaviconStore.links(inPage: page, base: try #require(URL(string: "https://x.com/home")))
        #expect(urls.map(\.absoluteString) == ["https://x.com/touch.png", "https://cdn.x.com/a.png?w=96&h=96", "https://x.com/small.png"])
    }

    @Test func `dark marks get a light plate and opaque squares fill the tile`() {
        func image(_ fill: NSColor, inset: CGFloat) -> NSImage {
            NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
                fill.setFill()
                rect.insetBy(dx: inset, dy: inset).fill()
                return true
            }
        }
        let mark = FaviconStore.favicon(image(.black, inset: 8))
        #expect(mark.isDark && !mark.fillsTile)
        let tile = FaviconStore.favicon(image(.systemBlue, inset: 0))
        #expect(!tile.isDark && tile.fillsTile)
        #expect(!FaviconStore.favicon(image(.white, inset: 8)).isDark)
    }
}
