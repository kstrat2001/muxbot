import SwiftUI
import SwiftData

/// One bot's thread (or the lead bot's). You type in the shared `BotBar`,
/// which follows navigation here; this view shows the conversation.
struct BotThreadView: View {
    let context: ChatContext

    @Environment(\.modelContext) private var modelContext
    @Environment(BotBrain.self) private var brain
    @Environment(GitHubAuth.self) private var github
    @Environment(FleetConnection.self) private var connection
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

    private var previewURL: URL? { bot.flatMap(brain.runs.previewURL(for:)) }
    /// darkmux's preview while it starts or after it failed (no URL yet).
    private var pendingPreview: LivePreview? {
        guard previewURL == nil, let bot else { return nil }
        return brain.runs.livePreviews[bot.id]
    }

    /// The viewports the bot's preview recipe lists, if it's loaded.
    private var recipeViewports: [String]? {
        for repo in bot?.repoSlugs ?? [] {
            if case let .ready(manifest, _)? = brain.runs.recipes.recipes[repo] { return manifest.viewports }
        }
        return nil
    }

    var body: some View {
        Group {
            #if os(macOS)
            if router.showPreview, previewURL != nil || pendingPreview != nil {
                // One layout per size class whose structure never changes:
                // the preview stays at the same place in the tree, so its
                // web view is never rebuilt. (Swapping layouts made SwiftUI
                // build a second WebView for the same WebPage, which traps.)
                let full = router.previewFullScreen
                let panel = Group {
                    if let url = previewURL {
                        PreviewPanel(url: url, recipeViewports: recipeViewports, botId: bot?.id) {
                            router.showPreview = false
                            router.previewFullScreen = false
                        }
                    } else if let pending = pendingPreview, let bot {
                        PreviewStatusView(preview: pending, retry: { Task { await brain.runs.ensurePreview(for: bot) } })
                    }
                }
                .safeAreaInset(edge: .bottom) { if full { BotBar() } }
                if isWide {
                    // Native split view: AppKit drives the divider. The chat is
                    // the optional pane, so the preview keeps its place.
                    HSplitView {
                        if !full {
                            chat.frame(minWidth: 300, idealWidth: 440, maxWidth: 900)
                        }
                        panel.frame(minWidth: 360, maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        panel.frame(maxHeight: full ? .infinity : 340)
                        if !full {
                            Divider()
                            chat
                        }
                    }
                }
            } else {
                chat
            }
            #else
            // iPhone and iPad: the preview is a full-screen cover, never a panel.
            chat
            #endif
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if bot != nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    if let bot, brain.runs.canPreview(bot) {
                        // A panel symbol; the toggle's highlight shows it's open.
                        @Bindable var router = router
                        Toggle(isOn: $router.showPreview) {
                            #if os(macOS)
                            Label("Preview", systemImage: "sidebar.right")
                            #else
                            Label("Preview", systemImage: "safari")
                            #endif
                        }
                        .toggleStyle(.button)
                        .help(router.showPreview ? "Hide preview" : "Show preview")
                    }
                    if let bot, brain.runs.canOpenPR(bot, store: BotStore(context: modelContext), github: github) {
                        if brain.runs.openingPR.contains(bot.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Open PR", systemImage: "arrow.triangle.pull") {
                                Task { await brain.runs.openPR(for: bot, store: BotStore(context: modelContext), github: github) }
                            }
                            .help("Open a pull request with this bot's committed changes")
                        }
                    }
                    #if !os(macOS)
                    // On the Mac, info is the (i) on the bot's sidebar row (and ⌘I).
                    Button("Bot info", systemImage: "info.circle") { showInfo = true }
                        .help("Bot info and resources")
                    #endif
                }
            }
        }
        .onAppear { markRead() }
        .task(id: "\(router.showPreview)-\(connection.isPaired)-\(brain.connection != nil)") {
            // darkmux runs the preview from the repo's recipe when you open it
            // (again once the darkmux connection is ready at launch).
            if router.showPreview, let bot { await brain.runs.ensurePreview(for: bot) }
        }
        .onChange(of: conversations.first?.messages?.count) { markRead() }
        #if DEBUG
        .task {
            // `-useFolder <path>`: set up this bot's work copy from a local
            // checkout, as Add folder does, without the Open panel.
            guard let path = UserDefaults.standard.string(forKey: "useFolder"), let bot, bot.workspaceName == nil || bot.folderName == nil else { return }
            bot.folderName = (path as NSString).lastPathComponent
            await brain.runs.setUpWorkCopy(for: bot, store: BotStore(context: modelContext), sourcePath: (path as NSString).expandingTildeInPath)
        }
        .task {
            // `-toggleFullWindowAfter 2`: flip the preview's full-window mode
            // twice, for reproducing layout switches without clicking.
            let delay = UserDefaults.standard.double(forKey: "toggleFullWindowAfter")
            guard delay > 0 else { return }
            for _ in 0..<4 {
                try? await Task.sleep(for: .seconds(delay))
                #if os(macOS)
                router.previewFullScreen.toggle()
                #else
                router.showPreview.toggle()   // iOS: present and dismiss the full-screen preview
                #endif
            }
        }
        #endif
        .task {
            // Opening a bot that needs you goes to the card that's waiting.
            if router.focusRunId == nil,
               let waiting = NeedsYou.waiting(bot?.runs ?? []).max(by: { $0.createdAt < $1.createdAt }) {
                router.focusRunId = waiting.id
            }
            greetIfNew()
            for repo in bot?.repoSlugs ?? [] {
                await brain.runs.recipes.load(for: repo, workspace: bot?.workspaceName, connection: brain.connection, github: brain.github)
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(get: { router.showPreview && previewURL != nil },
                                              set: { router.showPreview = $0 })) {
            if let url = previewURL { PhonePreviewScreen(url: url, bot: bot) }
        }
        #endif
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
                    .safeAreaInset(edge: .top) { needsYouBanner }
            } else {
                ProgressView()
            }
        }
        .safeAreaInset(edge: .bottom) { BotBar() }
    }

    /// Pinned at the top: runs waiting for Approve or with a question. A tap
    /// goes to the card; × hides it until something new needs you.
    @ViewBuilder private var needsYouBanner: some View {
        let items = NeedsYou.banner(bot?.runs ?? [])
        if let first = items.last {
            HStack(spacing: Spacing.sm) {
                StatusBadge(kind: .needsYou)
                Button {
                    router.focusRunId = first.id
                } label: {
                    Text(items.count == 1
                         ? (first.phase == .proposed ? "Waiting for your Approve: \(first.task)" : "\(first.crew.name) has a question: \(first.task)")
                         : "\(items.count) things need you")
                        .font(AppFont.footnote(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                Button("Hide", systemImage: "xmark") { NeedsYou.dismiss(items) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Hide this here (and its badge) until something new needs you; it stays in Activity")
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(.bar)
        }
    }

    private func markRead() {
        guard let thread = conversations.first else { return }
        thread.lastReadAt = .now
        BotStore(context: modelContext).save()
    }

    private func greetIfNew() {
        let store = BotStore(context: modelContext)
        if context.botId != nil && bot == nil { return }
        let conversation = store.conversation(for: context)
        guard (conversation.messages ?? []).isEmpty else { return }
        let hello = bot.map { "Hi, I'm \($0.name). \($0.instructions)" }
            ?? (Guide.isEnabled
                ? String(localized: "Hi, I'm \(LeadBot.name). I help you set up darkmux and your models, make your first bot from a repo, and answer questions about Mux Bot and darkmux. Try “check my setup”.")
                : "Hi, I'm \(LeadBot.name). Tell me what needs doing and I'll get the right bot on it.")
        store.append(.assistant, hello, to: conversation)
    }
}
