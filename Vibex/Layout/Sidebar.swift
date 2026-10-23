import AppKit
import Observation
import SwiftUI

/// Which view the sidebar shows, VS Code style: clicking an activity bar item opens its view, and
/// clicking it again hides the sidebar.
@Observable
final class SidebarModel {
    enum Panel: String { case sourceControl, skills }

    var panel: Panel = .sourceControl
    var isVisible = false

    func isShowing(_ panel: Panel) -> Bool { isVisible && self.panel == panel }
}

struct SidebarView: View {
    let sidebar: SidebarModel
    let sourceControl: SourceControlModel
    let skills: SkillsModel
    let window: () -> NSWindow?
    let browseSkills: () -> Void

    var body: some View {
        Group {
            switch sidebar.panel {
            case .sourceControl:
                SourceControlSidebar(model: sourceControl, window: window)
            case .skills:
                SkillsSidebar(model: skills, browse: browseSkills)
            }
        }
        // Solid, like the landing page, instead of the translucent sidebar material.
        .background(Theme.surface)
    }
}
