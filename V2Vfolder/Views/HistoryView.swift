import SwiftData
import SwiftUI

/// Past conversations, newest first; swipe to delete (PRD F8).
struct HistoryView: View {
    let viewModel: HistoryViewModel
    @Query(sort: \ConversationRecord.startedAt, order: .reverse) private var conversations: [ConversationRecord]

    var body: some View {
        List {
            ForEach(conversations) { conversation in
                NavigationLink(value: conversation) {
                    HistoryRow(conversation: conversation)
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    viewModel.delete(conversations[index])
                }
            }
        }
        .overlay {
            if conversations.isEmpty {
                ContentUnavailableView("No conversations yet", systemImage: "clock",
                                       description: Text("Conversations are saved here when you tap End."))
            }
        }
        .navigationTitle("History")
        .navigationDestination(for: ConversationRecord.self) { conversation in
            ConversationDetailView(conversation: conversation)
        }
        .accessibilityIdentifier("historyList")
    }
}

private struct HistoryRow: View {
    let conversation: ConversationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title)
                .font(.headline)
                .lineLimit(2)
            Text("\(conversation.persona.displayName) · \(conversation.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(conversation.turns.count) turns")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Read-only transcript of a saved conversation.
struct ConversationDetailView: View {
    let conversation: ConversationRecord

    var body: some View {
        TranscriptView(turns: conversation.orderedTurns.map(\.transcriptTurn))
            .padding(.horizontal)
            .navigationTitle(conversation.persona.displayName)
            .navigationBarTitleDisplayMode(.inline)
    }
}
