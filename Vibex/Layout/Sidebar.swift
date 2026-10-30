import AppKit
import Observation
import SwiftUI

/// Which view the sidebar shows, VS Code style: clicking an activity bar item opens its view, and
/// clicking it again hides the sidebar.
@Observable
final class SidebarModel {
    enum Panel: String { case explorer, sourceControl, skills, mcp, servers }

    var panel: Panel = .sourceControl
    var isVisible = false

    func isShowing(_ panel: Panel) -> Bool { isVisible && self.panel == panel }
}

struct SidebarView: View {
    let sidebar: SidebarModel
    let sourceControl: SourceControlModel
    let skills: SkillsModel
    let mcpServers: MCPServersModel
    let explorer: ExplorerModel
    let openFile: (URL, _ keep: Bool) -> Void
    let viewSkill: (InstalledSkill) -> Void
    let window: () -> NSWindow?
    let browseSkills: () -> Void
    let browseMCP: () -> Void
    let openClaude: () -> Void
    let connectServer: (ServerProfile) -> Void

    var body: some View {
        Group {
            switch sidebar.panel {
            case .explorer:
                ExplorerSidebar(model: explorer, open: openFile)
            case .sourceControl:
                SourceControlSidebar(model: sourceControl, window: window)
            case .skills:
                SkillsSidebar(model: skills, browse: browseSkills, view: viewSkill)
            case .mcp:
                MCPServersSidebar(model: mcpServers, browse: browseMCP, openClaude: openClaude)
            case .servers:
                ServersSidebar(model: .shared, connect: connectServer)
            }
        }
        // Solid, like the landing page, instead of the translucent sidebar material.
        .background(Theme.surface)
    }
}
