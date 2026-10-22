import SwiftUI

/// Live transcript of the conversation (PRD F4). Scrolls to the newest text.
struct TranscriptView: View {
    let turns: [TranscriptTurn]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(turns) { turn in
                        TurnBubble(turn: turn)
                            .id(turn.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .overlay {
                if turns.isEmpty {
                    ContentUnavailableView("No conversation yet", systemImage: "waveform",
                                           description: Text("Tap Start, then just talk."))
                }
            }
            .onChange(of: turns.last?.text) {
                guard let last = turns.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

private struct TurnBubble: View {
    let turn: TranscriptTurn

    private var isUser: Bool { turn.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(turn.text.isEmpty ? "…" : turn.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isUser ? Color.accentColor : Color(.secondarySystemBackground),
                                in: .rect(cornerRadius: 18))
                    .foregroundStyle(isUser ? .white : .primary)
                if turn.wasInterrupted {
                    Label("Interrupted", systemImage: "hand.raised")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !isUser { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isUser ? "You said" : "Assistant said")
        .accessibilityValue(turn.text)
    }
}

#Preview {
    TranscriptView(turns: [
        TranscriptTurn(id: "1", role: .user, text: "Tell me a story", isFinal: true),
        TranscriptTurn(id: "2", role: .assistant, text: "Once upon a time…", isFinal: true, wasInterrupted: true),
    ])
    .padding()
}
