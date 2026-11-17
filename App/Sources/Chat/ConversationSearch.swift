import Foundation
import Observation

/// A message with the search text in it (`SearchHit` in search.ts). The snippet is in three parts so the row can mark
/// the match.
struct SearchHit: Decodable, Identifiable, Hashable, Sendable {
    let conversationId: Int
    /// The conversation's title when the search ran.
    let title: String
    /// The message's entry: the transcript opens at its row.
    let messageId: Int
    /// `user` or `pi`.
    let role: String
    var timestamp: Double?
    let before: String
    let matched: String
    let after: String

    var id: String { "\(conversationId):\(messageId)" }
    var fromPi: Bool { role == "pi" }
    var date: Date? { timestamp.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

/// The conversation list's search through what was said. The search itself is JS's (`Chat.search`), so that a search
/// tool for the agent can use the same one; this asks for it at each pause in typing and holds the answer.
@MainActor
@Observable
final class ConversationSearch {
    /// Newest conversation first, and within one its newest matching messages first.
    private(set) var hits: [SearchHit] = []
    /// An answer is on its way.
    private(set) var searching = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Searches for `query`; an empty one ends the search.
    func update(_ query: String, store: ChatStore) {
        task?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            task = nil
            hits = []
            searching = false
            return
        }
        searching = true
        task = Task {
            // Typing: wait for a pause.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let found = await store.searchConversations(text)
            // A newer search took over while this one ran.
            guard !Task.isCancelled else { return }
            hits = found ?? []
            searching = false
        }
    }
}
