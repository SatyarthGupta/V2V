import SwiftUI

/// Hidden diagnostics panel, toggled by triple-tapping the orb (D-022).
/// Shows what the session is doing so a live demo problem can be diagnosed in seconds.
struct DebugOverlay: View {
    let info: DebugInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("State", info.state)
            row("Route", info.route)
            row("Reply latency", info.latency)
            if let error = info.lastError {
                row("Last error", error)
                    .foregroundStyle(.red)
            }
            Divider()
            Text("Recent events")
                .font(.caption.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(info.events.reversed().enumerated()), id: \.offset) { _, event in
                        Text(event)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
        }
        .font(.caption.monospaced())
        .padding(12)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("debugOverlay")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label + ":")
                .fontWeight(.semibold)
            Text(value)
                .lineLimit(2)
        }
    }
}

#Preview {
    DebugOverlay(info: DebugInfo(
        state: "aiSpeaking", route: "Saty's buds (Bluetooth)",
        events: ["session.created", "session.updated", "response.created", "speech_started", "response.done (cancelled)"],
        lastError: nil, latency: "812 ms"))
    .padding()
}
