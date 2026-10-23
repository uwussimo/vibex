import Foundation
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
            == ["mcp", "add", "--scope", "user", "--env", "DATABASE_URL=postgres://x", "postgres", "--", "npx", "-y", "pg-mcp@1.0"])
    }

    @Test func `remote servers fill header templates`() {
        let github = MCPFeatured.servers.first { $0.name == "github" }!
        #expect(github.addArguments(scope: "project", values: ["Authorization": "ghp_123"])
            == ["mcp", "add", "--transport", "http", "--scope", "project", "--header", "Authorization: Bearer ghp_123", "github", "https://api.githubcopilot.com/mcp/"])
        let sentry = MCPFeatured.servers.first { $0.name == "sentry" }!
        #expect(sentry.addArguments(scope: "user", values: [:]).suffix(2) == ["sentry", "https://mcp.sentry.dev/mcp"])
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
        #expect(MCPServersStore.installed(project: folder, claudeJSON: folder.appendingPathComponent("none.json")).map(\.id) == ["project|sentry"])
        try await MCPServersStore.claude(["mcp", "remove", "sentry", "--scope", "project"], in: folder)
        #expect(MCPServersStore.installed(project: folder, claudeJSON: folder.appendingPathComponent("none.json")).isEmpty)
    }
}
