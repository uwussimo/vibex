import AppKit
import SwiftUI

/// Untitled UI line icons (24pt grid, 2pt stroke), fetched at build time into Icons.xcassets by
/// scripts/fetch-icons.sh. The cases match scripts/icons.txt.
enum Icon: String, CaseIterable, Sendable {
    case terminal
    case phone
    case tablet
    case globe
    case branch
    case merge
    case commit
    case pullRequest
    case sparkles
    case skills
    case agents
    case settings
    case plus
    case minus
    case close
    case check
    case checkCircle
    case folder
    case files
    case folderPlus
    case refresh
    case search
    case trash
    case copy
    case file
    case fileCode
    case lock
    case unlock
    case home
    case play
    case stop
    case dots
    case alert
    case info
    case chevronLeft
    case chevronRight
    case chevronUp
    case chevronDown
    case arrowUp
    case arrowDown
    case arrowUpRight
    case external
    case undo
    case upload
    case download
    case bell
    case bellRinging
    case book
    case cpu
    case zap
    case dollar
    case columns
    case layout
    case power
    case feather
    case grid
    case inbox
    case dataflow
    case compare
    case camera
    case image
    case puzzle
    case server
    case hardDrive
    case package
    case eye
    case key
    case message
    case hourglass
    case clock
    case command
    case browser
    case tv
    case activity
    case barChart
    case lineChart
    case codeBrowser
    case users
    case rocket
    case target
    case flag

    var assetName: String { "uui.\(rawValue)" }
}

/// An icon at a point size, tinted by the foreground style. SF Symbols size with the font; these
/// are drawn into a square frame instead.
struct IconView: View {
    let icon: Icon
    var size: CGFloat = 16

    init(_ icon: Icon, size: CGFloat = 16) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Image(icon.assetName)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension NSImage {
    /// A template copy of an icon for menus and AppKit buttons.
    static func icon(_ icon: Icon, size: CGFloat = 16) -> NSImage? {
        guard let image = (NSImage(named: icon.assetName)?.copy() as? NSImage) else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}
