import Foundation
import Testing
@testable import Vibex

@Suite struct CodexRegistrarTests {
    private let registrar = CodexRegistrar(url: "http://127.0.0.1:5150/mcp", token: "abc123")

    @Test func `the block is added to a config without one, and to an empty one`() {
        let config = "model = \"gpt\"\n\n[features]\njs_repl = false\n"
        let updated = CodexRegistrar.updating(config, with: registrar.block)
        #expect(updated.hasPrefix(config))
        #expect(updated.hasSuffix(registrar.block + "\n"))
        #expect(CodexRegistrar.updating("", with: registrar.block) == registrar.block + "\n")
    }

    @Test func `only Vibex's own block changes, sub-tables and neighbours stay`() {
        let config = """
        model = "gpt"

        \(CodexRegistrar(url: "http://127.0.0.1:5151/mcp", token: "old").block)

        [mcp_servers.vibex.tools.simulator_tap]
        approval_mode = "approve"

        [mcp_servers.node_repl]
        command = "node"

        """
        let updated = CodexRegistrar.updating(config, with: registrar.block)
        #expect(updated.contains("url = \"http://127.0.0.1:5150/mcp\""))
        #expect(updated.contains("Bearer abc123"))
        #expect(!updated.contains("5151"))
        #expect(!updated.contains("Bearer old"))
        // A table the user set up under Vibex's server is the user's, and stays.
        #expect(updated.contains("[mcp_servers.vibex.tools.simulator_tap]\napproval_mode = \"approve\""))
        #expect(updated.contains("[mcp_servers.node_repl]\ncommand = \"node\""))
        #expect(updated.hasPrefix("model = \"gpt\"\n\n"))
        #expect(updated.components(separatedBy: CodexRegistrar.header).count == 2)
        // Writing it again changes nothing.
        #expect(CodexRegistrar.updating(updated, with: registrar.block) == updated)
    }

    @Test func `settings the user added to the block stay`() {
        let config = CodexRegistrar(url: "http://127.0.0.1:5151/mcp", token: "old").block + "\ndefault_tools_approval_mode = \"approve\"\n"
        let updated = CodexRegistrar.updating(config, with: registrar.block)
        #expect(updated == registrar.block + "\ndefault_tools_approval_mode = \"approve\"\n")
        #expect(CodexRegistrar.updating(updated, with: registrar.block) == updated)
    }

    @Test func `a block the user typed by hand is taken over, without its note`() {
        let config = "[mcp_servers.vibex]\nurl = \"http://localhost:9/mcp\"\n\n[features]\nx = 1\n"
        let updated = CodexRegistrar.updating(config, with: registrar.block)
        #expect(updated == registrar.block + "\n\n[features]\nx = 1\n")
    }
}
