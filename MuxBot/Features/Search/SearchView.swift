import SwiftUI
import SwiftData

/// Search bots and threads (⌘F); a result opens where it is.
struct SearchView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Bot.createdAt) private var bots: [Bot]
    @Query private var messages: [ChatMessage]
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: SearchResults { SearchResults.find(query, bots: bots, messages: messages) }

    var body: some View {
        NavigationStack {
            List {
                if !results.bots.isEmpty {
                    Section("Bots") {
                        ForEach(results.bots) { bot in
                            Button { open(.bot(bot.id)) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(bot.name, systemImage: bot.systemImage)
                                    Text(bot.instructions).font(AppFont.caption()).foregroundStyle(Color.secondaryText).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !results.messages.isEmpty {
                    Section("Messages") {
                        ForEach(results.messages) { message in
                            Button { open(message.conversation?.roleId.map { Route.bot($0) } ?? .lead) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(message.conversation?.title ?? LeadBot.name).font(AppFont.caption(.semibold))
                                    Text(message.content).lineLimit(2)
                                    Text(message.timestamp, style: .date).font(AppFont.caption()).foregroundStyle(Color.secondaryText)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !query.trimmingCharacters(in: .whitespaces).isEmpty && results.isEmpty {
                    Text("Nothing found.").foregroundStyle(Color.secondaryText)
                }
            }
            .safeAreaInset(edge: .top) {
                TextField("Search bots and messages", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .padding()
            }
            .navigationTitle("Search")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear { focused = true }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }

    private func open(_ route: Route) {
        router.tab = .bots
        router.navigate(to: route)
        dismiss()
    }
}
