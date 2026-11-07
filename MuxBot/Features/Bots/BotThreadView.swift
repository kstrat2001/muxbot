import SwiftUI
import SwiftData

/// One bot's thread (or the lead bot's). You type in the shared `BotBar`,
/// which follows navigation here; this view shows the conversation.
struct BotThreadView: View {
    let context: ChatContext

    @Environment(\.modelContext) private var modelContext
    @Environment(BotBrain.self) private var brain
    @Query private var conversations: [ChatConversation]
    @Query private var matches: [Bot]
    @State private var showInfo = false

    init(context: ChatContext) {
        self.context = context
        let roleId = context.botId
        _conversations = Query(filter: #Predicate<ChatConversation> { $0.roleId == roleId })
        // The lead bot is not stored, so its lookup matches nothing.
        let botId = roleId ?? UUID()
        _matches = Query(filter: #Predicate<Bot> { $0.id == botId })
    }

    private var bot: Bot? { matches.first }
    private var title: String { context.botId == nil ? LeadBot.name : (bot?.name ?? "Bot") }

    @Environment(AppRouter.self) private var router
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isWide: Bool { sizeClass == .regular }
    #else
    private let isWide = true
    #endif

    private var previewURL: URL? { bot?.previewURL }

    /// The viewports the bot's preview recipe lists, if it's loaded.
    private var recipeViewports: [String]? {
        for repo in bot?.repoSlugs ?? [] {
            if case let .ready(manifest, _)? = brain.recipes[repo] { return manifest.viewports }
        }
        return nil
    }

    var body: some View {
        Group {
            if let url = previewURL, router.showPreview {
                let panel = PreviewPanel(url: url, recipeViewports: recipeViewports) {
                    router.showPreview = false
                    router.previewFullScreen = false
                }
                if router.previewFullScreen {
                    panel.safeAreaInset(edge: .bottom) { BotBar() }
                } else if isWide {
                    #if os(macOS)
                    HSplitView {
                        chat.frame(minWidth: 320, idealWidth: 480)
                        panel.frame(minWidth: 360, maxWidth: .infinity)
                    }
                    #else
                    HStack(spacing: 0) {
                        chat.frame(minWidth: 320)
                        Divider()
                        panel.frame(minWidth: 360, maxWidth: .infinity)
                    }
                    #endif
                } else {
                    VStack(spacing: 0) {
                        panel.frame(height: 340)
                        Divider()
                        chat
                    }
                }
            } else {
                chat
            }
        }
        .navigationTitle(title)
        .toolbar {
            if bot != nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    if previewURL != nil {
                        // A panel symbol; the toggle's highlight shows it's open.
                        @Bindable var router = router
                        Toggle(isOn: $router.showPreview) {
                            Label("Preview", systemImage: isWide ? "sidebar.right" : "rectangle.tophalf.inset.filled")
                        }
                        .toggleStyle(.button)
                        .help(router.showPreview ? "Hide preview" : "Show preview")
                    }
                    Button("Bot info", systemImage: "info.circle") { showInfo = true }
                        .help("Bot info and resources")
                }
            }
        }
        .onAppear { markRead() }
        .onChange(of: conversations.first?.messages?.count) { markRead() }
        .task {
            greetIfNew()
            for repo in bot?.repoSlugs ?? [] {
                await brain.loadRecipe(for: repo, localWorkdir: bot.flatMap(FleetConnection.workdir(for:)))
            }
        }
        .sheet(isPresented: $showInfo) {
            if let bot { NavigationStack { BotInfoView(bot: bot) } }
        }
    }

    /// The transcript with the chat bar pinned under it. Each screen pins
    /// the bar itself: on macOS a bar attached to the navigation stack
    /// does not carry into pushed views.
    private var chat: some View {
        Group {
            if context.botId != nil && bot == nil {
                EmptyStateView(systemImage: "questionmark.circle", title: "Bot not found", message: "It may have been removed.")
            } else if let conversation = conversations.first {
                ChatView(conversation: conversation, isThinking: brain.isThinking)
            } else {
                ProgressView()
            }
        }
        .safeAreaInset(edge: .bottom) { BotBar() }
    }

    private func markRead() {
        guard let thread = conversations.first else { return }
        thread.lastReadAt = .now
        try? modelContext.save()
    }

    private func greetIfNew() {
        let store = BotStore(context: modelContext)
        if context.botId != nil && bot == nil { return }
        let conversation = store.conversation(for: context)
        guard (conversation.messages ?? []).isEmpty else { return }
        let hello = bot.map { "Hi, I'm \($0.name). \($0.instructions)" }
            ?? "Hi, I'm \(LeadBot.name). Tell me what needs doing and I'll get the right bot on it."
        store.append(.assistant, hello, to: conversation)
    }
}
