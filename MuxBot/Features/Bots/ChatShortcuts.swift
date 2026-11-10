import SwiftUI

/// A shortcut chip above the chat bar: one of the core things you do in the
/// thread on screen. Tapping one sends its message at once (the bot answers,
/// or proposes work behind its usual Approve card), or for a view, opens it.
/// Chips come from data: the guide, the template list and the bot's skills.
struct ChatShortcut: Identifiable, Equatable {
    enum Action: Equatable {
        /// Sent as your message.
        case send(String)
        case startProject
        case showPreview
        /// Turns on Pick in the preview.
        case pick
    }

    var id: String
    var title: String
    var systemImage: String
    var action: Action
}

enum ChatShortcuts {
    /// Mux Bot's thread (and Home).
    static func lead() -> [ChatShortcut] {
        [
            ChatShortcut(id: "start", title: String(localized: "Start a project"), systemImage: "sparkles", action: .startProject),
            ChatShortcut(id: "setup", title: String(localized: "Check my setup"), systemImage: "checklist", action: .send("Check my setup")),
            ChatShortcut(id: "settings", title: String(localized: "Change a setting"), systemImage: "gearshape", action: .send("Change a setting")),
            ChatShortcut(id: "how", title: String(localized: "How does this work?"), systemImage: "questionmark.circle", action: .send("How does Mux Bot work?")),
        ]
    }

    struct BotFacts: Equatable {
        var hasRepo: Bool
        var canPreview: Bool
        var skills: [String]
    }

    /// A bot's thread: one chip per skill (the bot asks for specifics), its
    /// preview and Pick when it has one; a bot with no skills and a repo gets
    /// its issues.
    static func bot(_ facts: BotFacts) -> [ChatShortcut] {
        var chips = facts.skills.map {
            ChatShortcut(id: "skill:\($0)", title: $0, systemImage: "wand.and.stars", action: .send($0))
        }
        if facts.canPreview {
            chips.append(ChatShortcut(id: "preview", title: String(localized: "Show preview"), systemImage: "play.rectangle", action: .showPreview))
            chips.append(ChatShortcut(id: "pick", title: String(localized: "Point at something"), systemImage: "scope", action: .pick))
        }
        if facts.skills.isEmpty, facts.hasRepo {
            chips.append(ChatShortcut(id: "issues", title: String(localized: "Open issues"), systemImage: "list.bullet.rectangle", action: .send("Show open issues")))
            chips.append(ChatShortcut(id: "fix", title: String(localized: "Fix an issue"), systemImage: "hammer", action: .send("Which open issues need fixing?")))
        }
        return chips
    }

    /// Whether the row shows: not while you're typing, tweaking or pointing,
    /// and not while a card in this thread waits for Approve.
    /// Mux Bot's chips stay while you type in his thread (Start a project
    /// is what you're likely after); only a card waiting for Approve hides them.
    static func showsRow(draft: String, tweaking: Bool, picked: Bool, waitingCard: Bool, lead: Bool) -> Bool {
        lead ? !waitingCard : showsRow(draft: draft, tweaking: tweaking, picked: picked, waitingCard: waitingCard)
    }

    static func showsRow(draft: String, tweaking: Bool, picked: Bool, waitingCard: Bool) -> Bool {
        draft.isEmpty && !tweaking && !picked && !waitingCard
    }

    /// Runs a chip: a message is sent exactly once; a view opens.
    @MainActor
    static func run(_ chip: ChatShortcut, in chat: ChatContext, brain: BotBrain, store: BotStore,
                    router: AppRouter, preview: PreviewController?) async {
        switch chip.action {
        case let .send(text):
            guard !brain.isThinking else { return }
            await brain.send(text, in: chat, store: store)
        case .startProject:
            router.showStartProject = true
        case .showPreview:
            router.showPreview = true
        case .pick:
            router.showPreview = true
            // Picking starts once that bot's page has loaded.
            if let preview, !preview.isPicking { preview.startPicking(for: chat.botId) }
        }
    }
}

/// The chips in one horizontally scrolling line above the chat bar.
struct ChatShortcutRow: View {
    let chips: [ChatShortcut]
    let run: (ChatShortcut) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(chips) { chip in
                    Button { run(chip) } label: {
                        Label(chip.title, systemImage: chip.systemImage)
                            .font(AppFont.caption(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.xs + 2)
                            .background(Capsule().fill(Color.brandBlue.opacity(0.12)))
                            .overlay(Capsule().strokeBorder(Color.brandBlue.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(chip.title)
                    .accessibilityHint(hint(chip))
                }
            }
        }
        .scrollClipDisabled()
        .accessibilityLabel("Shortcuts")
    }

    private func hint(_ chip: ChatShortcut) -> String {
        switch chip.action {
        case .send: String(localized: "Sends it to the bot now")
        case .startProject, .showPreview, .pick: String(localized: "Opens it")
        }
    }
}
