import Combine
import SwiftUI

/// Title-bar dot: green when a client talked to the MCP server recently, grey when idle, red when down.
struct MCPStatusView: View {
    let service: MCPService
    @State private var now = Date()

    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(service.isRunning ? "mcp :" + String(service.port) : "mcp off")
                .font(.vibexCode(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .padding(.trailing, 10)
        .help(service.registration)
        .onReceive(timer) { now = $0 }
    }

    private var color: Color {
        guard service.isRunning else { return .red }
        if let last = service.lastActivity, now.timeIntervalSince(last) < 120 { return .green }
        return .secondary.opacity(0.5)
    }
}
