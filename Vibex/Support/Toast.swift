import AppKit
import SwiftUI

/// A transient message at the top of the window. Springs in, sits for a few seconds, springs out.
@Observable
final class ToastModel {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String?
    }

    private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(title: String, message: String?, seconds: Double = 4) {
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            current = Toast(title: title, message: message)
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

struct ToastView: View {
    let model: ToastModel

    var body: some View {
        VStack {
            if let toast = model.current {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(toast.title)
                            .font(.system(size: 13, weight: .semibold))
                        if let message = toast.message, !message.isEmpty {
                            Text(message)
                                .font(.system(size: 12))
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
                .onTapGesture { model.dismiss() }
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toast.id)
            }
            Spacer()
        }
        .padding(.top, 12)
        .allowsHitTesting(model.current != nil)
    }
}
