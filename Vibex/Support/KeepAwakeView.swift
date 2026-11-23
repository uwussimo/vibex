import SwiftUI

/// Settings › Keep Awake: one switch, the lengths as chips (click one to start, again to stop), and
/// the options under them. The lid-closed mode is apart from the rest because it changes a system
/// setting and costs battery.
struct KeepAwakePage: View {
    @Bindable var model: KeepAwake
    @State private var isPickingTime = false
    @State private var until = Calendar.current.date(byAdding: .hour, value: 2, to: Date()) ?? Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(footer: "Click a length to start. Click it again to stop.") {
                SettingsRow(title: model.isActive ? "Keeping your Mac awake" : "Keep your Mac awake", caption: model.isActive ? model.summary : "The display and the Mac stay on while you read, build or wait on Claude.") {
                    Toggle("", isOn: Binding(
                        get: { model.length != nil },
                        set: { $0 ? model.begin(.indefinitely) : model.stop() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                chips.padding(16)
            }
            SettingsGroup(title: "Options") {
                SettingsRow(title: "While Claude Code works", caption: "Stays awake from the moment you send Claude a prompt until it stops, in any Vibex terminal. Needs Approval alerts (Get Started).") {
                    Toggle("", isOn: $model.whileClaudeWorks).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Let the display sleep", caption: "The screen turns off as usual; the Mac keeps running.") {
                    Toggle("", isOn: $model.allowDisplaySleep).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Start when Vibex opens") {
                    Toggle("", isOn: $model.startWithVibex).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsGroup(title: "Lid closed", footer: model.lidModeMessage) {
                SettingsRow(title: "Keep going with the lid closed", caption: model.isLidModeOn
                    ? "Sleep is fully off. Mind the battery and the heat in a bag."
                    : "Turns system sleep off until Keep Awake stops. macOS asks for your password.") {
                    Toggle("", isOn: Binding(get: { model.isLidModeOn }, set: { model.setLidMode($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Theme.orange)
                }
            }
        }
    }

    private var chips: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(KeepAwake.presets) { length in
                Chip(label: length.label, isOn: model.length == length) { model.toggle(length) }
            }
            Chip(label: untilLabel, glyph: "clock", isOn: isUntil) {
                if isUntil { model.stop() } else { isPickingTime = true }
            }
            .popover(isPresented: $isPickingTime, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Keep awake until").font(.vibex(size: 13, weight: .semibold))
                    DatePicker("", selection: $until, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                    Button("Start") {
                        model.begin(.until(until))
                        isPickingTime = false
                    }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(16)
                .frame(width: 200)
            }
        }
    }

    private var isUntil: Bool {
        if case .until = model.length { return true }
        return false
    }

    private var untilLabel: String {
        if case let .until(date) = model.length { return date.formatted(date: .omitted, time: .shortened) }
        return "Until…"
    }
}

private struct Chip: View {
    let label: String
    var glyph: String?
    let isOn: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let glyph { Image(systemName: glyph).font(.system(size: 11, weight: .medium)) }
                Text(label).font(.vibex(size: 13, weight: .semibold))
            }
            .foregroundStyle(isOn ? Theme.onAccent : Theme.text)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isOn ? Theme.accent : (isHovering ? Theme.raised : Theme.surface))
            )
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(isOn ? Color.clear : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}
