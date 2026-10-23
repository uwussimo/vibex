import AppKit
import Observation
import SwiftUI

/// Which view the sidebar shows, VS Code style: clicking an activity bar item opens its view, and
/// clicking it again hides the sidebar.
@Observable
final class SidebarModel {
    enum Panel: String { case sourceControl, agents, skills, mcp }

    var panel: Panel = .sourceControl
    var isVisible = false

    func isShowing(_ panel: Panel) -> Bool { isVisible && self.panel == panel }
}

struct SidebarView: View {
    let sidebar: SidebarModel
    let sourceControl: SourceControlModel
    let skills: SkillsModel
    let agents: AgentsModel
    let agentActions: AgentActions
    let mcpServers: MCPServersModel
    let window: () -> NSWindow?
    let browseSkills: () -> Void
    let browseMCP: () -> Void

    var body: some View {
        Group {
            switch sidebar.panel {
            case .sourceControl:
                SourceControlSidebar(model: sourceControl, window: window)
            case .agents:
                AgentsSidebar(model: agents, attention: .shared, actions: agentActions)
            case .skills:
                SkillsSidebar(model: skills, browse: browseSkills)
            case .mcp:
                MCPServersSidebar(model: mcpServers, browse: browseMCP)
            }
        }
        // Solid, like the landing page, instead of the translucent sidebar material.
        .background(Theme.surface)
    }
}
