import Foundation

/// Search across bots (name, persona) and thread messages; case-insensitive.
struct SearchResults {
    var bots: [Bot] = []
    var messages: [ChatMessage] = []

    var isEmpty: Bool { bots.isEmpty && messages.isEmpty }

    @MainActor
    static func find(_ query: String, bots: [Bot], messages: [ChatMessage], limit: Int = 50) -> SearchResults {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return SearchResults() }
        let hit = { (text: String) in text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return SearchResults(
            bots: bots.filter { hit($0.name) || hit($0.instructions) },
            messages: Array(messages.filter { $0.kind == .text && hit($0.content) }
                .sorted { $0.timestamp > $1.timestamp }.prefix(limit)))
    }
}
