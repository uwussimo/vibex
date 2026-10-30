import AppKit
import SwiftUI

/// A transient message at the top of the window. Springs in, sits for a few seconds, springs out.
@Observable
final class ToastModel {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String?
        var action: (() -> Void)?
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    /// `action` runs when the toast is clicked; without one a click just dismisses it.
    func show(title: String, message: String?, seconds: Double = 4, action: (() -> Void)? = nil) {
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            current = Toast(title: title, message: message, action: action)
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
            current = nil
        }
    }
}

/// Hosted in a view that hugs the card, so with no toast it has no size: a hosting view takes every
/// click inside its frame, even where SwiftUI has nothing to hit.
struct ToastView: View {
    let model: ToastModel

    var body: some View {
        VStack {
            if let toast = model.current {
                HStack(alignment: .top, spacing: 10) {
                    IconView(.info, size: 16)
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(toast.title)
                            .font(.vibex(size: 13, weight: .semibold))
                        if let message = toast.message, !message.isEmpty {
                            Text(message)
                                .font(.vibex(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(width: 360, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                .onTapGesture {
                    toast.action?()
                    model.dismiss()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toast.id)
                .padding(.top, 12)
            }
        }
    }
}
