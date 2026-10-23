import AppKit
import SwiftUI

/// Before and after: two simulator screenshots, either overlaid with a divider to drag across or side
/// by side. Starts with the two newest; any two from the history can be picked.
struct CompareView: View {
    let history: SnapshotHistory
    @State private var beforeID: UUID?
    @State private var afterID: UUID?
    @State private var sideBySide = false
    @State private var split: CGFloat = 0.5

    private var before: SnapshotHistory.Snapshot? { history.snapshots.first { $0.id == beforeID } ?? history.latestPair?.before }
    private var after: SnapshotHistory.Snapshot? { history.snapshots.first { $0.id == afterID } ?? history.latestPair?.after }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.line).frame(height: 1)
            if let before, let after, let left = history.image(of: before), let right = history.image(of: after) {
                Group {
                    if sideBySide { sideBySideView(left, right) } else { sliderView(left, right) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
        }
        .background(Theme.background)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            picker(title: "Before", selection: $beforeID, current: before)
            IconView(.arrowUpRight, size: 13).rotationEffect(.degrees(45)).foregroundStyle(Theme.faint)
            picker(title: "After", selection: $afterID, current: after)
            Spacer()
            Picker("Layout", selection: $sideBySide) {
                Text("Slider").tag(false)
                Text("Side by Side").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            ToolbarIconButton(icon: .copy, help: "Copy both, side by side", isEnabled: before != nil && after != nil, action: copyPair)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Theme.surface)
    }

    private func picker(title: String, selection: Binding<UUID?>, current: SnapshotHistory.Snapshot?) -> some View {
        Menu {
            ForEach(history.snapshots.reversed()) { snapshot in
                Button(Self.describe(snapshot)) { selection.wrappedValue = snapshot.id }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title).foregroundStyle(Theme.faint)
                Text(current.map(Self.describe) ?? "None").foregroundStyle(Theme.text).lineLimit(1)
                IconView(.chevronDown, size: 11).foregroundStyle(Theme.muted)
            }
            .font(.vibex(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// "After run · 16:04"
    static func describe(_ snapshot: SnapshotHistory.Snapshot) -> String {
        "\(snapshot.label) · \(snapshot.date.formatted(date: Calendar.current.isDateInToday(snapshot.date) ? .omitted : .abbreviated, time: .shortened))"
    }

    private func sliderView(_ left: NSImage, _ right: NSImage) -> some View {
        GeometryReader { geometry in
            let frame = Self.fit(left.size, in: geometry.size)
            ZStack(alignment: .topLeading) {
                // After underneath; Before shows to the left of the divider, so time reads left to right.
                Image(nsImage: right).resizable().frame(width: frame.width, height: frame.height)
                Image(nsImage: left).resizable().frame(width: frame.width, height: frame.height)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: frame.width * split).frame(maxWidth: .infinity, alignment: .leading)
                    }
                // The divider: a hairline and a knob, draggable anywhere on the image.
                Rectangle().fill(Color.white).frame(width: 2, height: frame.height)
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .offset(x: frame.width * split - 1)
                Circle().fill(Color.white).frame(width: 30, height: 30)
                    .overlay(IconView(.columns, size: 14).foregroundStyle(Theme.background))
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                    .offset(x: frame.width * split - 15, y: frame.height / 2 - 15)
                label("Before", alignment: .topLeading).opacity(split > 0.15 ? 1 : 0)
                label("After", alignment: .topTrailing).frame(width: frame.width, alignment: .trailing).opacity(split < 0.85 ? 1 : 0)
            }
            .frame(width: frame.width, height: frame.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                split = min(1, max(0, value.location.x / frame.width))
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .help("Drag to compare")
        }
    }

    private func label(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .font(.vibex(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.55)))
            .padding(10)
    }

    private func sideBySideView(_ left: NSImage, _ right: NSImage) -> some View {
        HStack(spacing: 20) {
            column("Before", left, before)
            column("After", right, after)
        }
    }

    private func column(_ title: String, _ image: NSImage, _ snapshot: SnapshotHistory.Snapshot?) -> some View {
        VStack(spacing: 10) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(title).font(.vibex(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            if let snapshot { Text(Self.describe(snapshot)).font(.vibex(size: 11)).foregroundStyle(Theme.muted) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            IconView(.compare, size: 30).foregroundStyle(Theme.faint)
            Text("Compare before and after").font(.vibex(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            Text("Take a screenshot with the camera in the simulator header, change something, and take another. Running the app adds one too, and Claude can with simulator_snapshot.")
                .font(.vibex(size: 12))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func fit(_ size: NSSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// Both screenshots next to each other as one PNG on the pasteboard, ready to paste into a PR.
    private func copyPair() {
        guard let before, let after, let left = history.image(of: before), let right = history.image(of: after) else { return }
        let gap: CGFloat = 40
        let height = max(left.size.height, right.size.height)
        let size = NSSize(width: left.size.width + right.size.width + gap, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor(hex: 0x0C0C0F).setFill()
            NSRect(origin: .zero, size: size).fill()
            left.draw(in: NSRect(x: 0, y: 0, width: left.size.width, height: left.size.height))
            right.draw(in: NSRect(x: left.size.width + gap, y: 0, width: right.size.width, height: right.size.height))
            return true
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}
