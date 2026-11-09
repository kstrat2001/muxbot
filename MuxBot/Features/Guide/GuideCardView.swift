import SwiftUI

/// A card from Mux Bot, the guide, drawn from live state each time.
struct GuideCardView: View {
    let message: ChatMessage
    /// Only the newest setup check keeps looking; older ones are history.
    var isLatest = true

    var body: some View {
        CardView {
            Group {
                switch message.guideCard {
                case .setup?: SetupChecklistView(isLive: isLatest)
                case .firstBot?: FirstBotCardView()
                case let .setting(id)?: SettingCardView(id: id)
                case let .answer(text, articles, onDevice)?: AnswerCardView(text: text, articles: articles, onDevice: onDevice)
                case nil: Text(message.content).font(AppFont.body())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .chatColumn(alignment: .leading)
    }
}

// MARK: - Setup checklist

/// The live checklist: looks again every few seconds while it's on screen
/// and ticks off each step once it works.
struct SetupChecklistView: View {
    @Environment(FleetConnection.self) private var connection
    @Environment(BotBrain.self) private var brain
    @Environment(AppRouter.self) private var router
    @Environment(GitHubAuth.self) private var github
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    var isLive = true
    @State private var facts: SetupFacts?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            let steps = facts.map { SetupCheck.steps($0, serveCommand: connection.serveCommand) } ?? []
            HStack {
                Label("Setup check", systemImage: "checklist").font(AppFont.headline())
                Spacer()
                if facts == nil { ProgressView().controlSize(.small) } else { Text(SetupCheck.summary(steps)).font(AppFont.footnote()).foregroundStyle(Color.secondaryText) }
            }
            if let block = SetupCheck.setupBlock(steps) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Everything to install, in one go").font(AppFont.body(.semibold))
                    Text("Paste this into Terminal. It needs Homebrew (brew.sh). \(block.estimate)")
                        .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    CommandBox(command: block.command)
                }
            }
            ForEach(steps) { step in row(step) }
            #if os(iOS)
            ShareLink(item: SetupCheck.shareText(), subject: Text("Set up Mux Bot on your Mac")) {
                Label("Send the steps to your Mac", systemImage: "square.and.arrow.up")
            }
            #endif
        }
        .task(id: isLive) {
            await SetupProbe.watch(isLive: isLive, every: .seconds(4),
                                   probe: { await SetupProbe.facts(connection: connection, runs: brain.runs, githubSignedIn: github.token != nil) },
                                   show: { facts = $0 })
        }
    }

    private func row(_ step: SetupStep) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: icon(step.state))
                .foregroundStyle(color(step.state))
                .frame(width: 20)
                .accessibilityLabel(stateLabel(step.state))
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(step.title).font(AppFont.body(.semibold))
                Text(step.detail).font(AppFont.footnote()).foregroundStyle(Color.secondaryText).fixedSize(horizontal: false, vertical: true)
                if let command = step.command { CommandBox(command: command) }
                HStack(spacing: Spacing.md) {
                    if let action = step.action { button(action) }
                    if let link = step.link { Link(destination: link) { Label(link.host() ?? "Open", systemImage: "safari") }.font(AppFont.footnote()) }
                }
            }
        }
    }

    @ViewBuilder private func button(_ action: SetupStep.Action) -> some View {
        switch action {
        case .pair:
            Button("Pair with darkmux", systemImage: "link") { router.showPairing = true }.buttonStyle(.borderedProminent).controlSize(.small)
        case .gitHubSignIn:
            #if os(macOS)
            Button("Sign in with GitHub", systemImage: "person.badge.key") { openSettings() }.buttonStyle(.bordered).controlSize(.small)
            #else
            Button("Sign in with GitHub", systemImage: "person.badge.key") { router.showPairing = true }.buttonStyle(.bordered).controlSize(.small)
            #endif
        case .confirmDocker:
            Button("Docker is running") {
                UserDefaults.standard.set(true, forKey: SetupProbe.dockerKey)
                facts?.dockerConfirmed = true
            }
            .buttonStyle(.bordered).controlSize(.small)
        case .openTerminal:
            #if os(macOS)
            Button("Open Terminal", systemImage: "terminal") {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                                   configuration: NSWorkspace.OpenConfiguration())
            }
            .buttonStyle(.bordered).controlSize(.small)
            #else
            EmptyView()
            #endif
        }
    }

    private func icon(_ state: SetupStep.State) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .todo: "circle"
        case .unknown: "questionmark.circle"
        case .manual: "hand.raised.circle"
        case .later: "circle.dotted"
        case .needsMac: "laptopcomputer"
        }
    }

    private func color(_ state: SetupStep.State) -> Color {
        switch state {
        case .done: .brandGreen
        case .todo: .brandOrange
        case .unknown, .manual, .needsMac: .brandBlue
        case .later: .secondary
        }
    }

    private func stateLabel(_ state: SetupStep.State) -> String {
        switch state {
        case .done: String(localized: "Done")
        case .todo: String(localized: "To do")
        case .unknown: String(localized: "Not known yet")
        case .manual: String(localized: "Check it yourself")
        case .later: String(localized: "After an earlier step")
        case .needsMac: String(localized: "Needs a Mac")
        }
    }
}

// MARK: - First bot

struct FirstBotCardView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label("Make your first bot", systemImage: "plus.bubble").font(AppFont.headline())
            Text("Start something new from a template, paste a GitHub link in the bar below, or make one for code you have.")
                .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
            HStack {
                Button("Start a project…", systemImage: "sparkles") { router.showStartProject = true }.buttonStyle(.borderedProminent)
                Button("New bot…", systemImage: "plus") { router.showNewBot = true }.buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Settings

/// A setting's live switch: flipping it is the approval and applies at once.
/// darkmux's own settings show their value, read-only.
struct SettingCardView: View {
    let id: GuideSettingID

    @Environment(BotBrain.self) private var brain
    @Environment(FleetConnection.self) private var connection
    @AppStorage(NotificationService.enabledKey) private var notify = true
    @State private var mode: ModelMode = .auto
    @State private var listed: [DarkmuxClient.ProfileInfo] = []
    @State private var changed: String?
    @State private var darkmuxValue: String?

    private var setting: GuideSetting { GuideSettings.setting(id) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label(setting.title, systemImage: setting.isDarkmux ? "terminal" : "gearshape").font(AppFont.headline())
            control
            if let changed { Label(changed, systemImage: "checkmark.circle").font(AppFont.footnote()).foregroundStyle(Color.secondaryText) }
        }
        .task { await load() }
    }

    @ViewBuilder private var control: some View {
        switch id {
        case .modelMode:
            Picker("On \(brain.runs.machine?.name ?? String(localized: "this Mac"))", selection: Binding(get: { mode }, set: { set($0) })) {
                Text("Auto").tag(ModelMode.auto)
                Text("Always ask").tag(ModelMode.ask)
                ForEach(listed.map(\.name), id: \.self) { name in Text("Always \(name)").tag(ModelMode.model(name)) }
                if case let .model(name) = mode, !listed.contains(where: { $0.name == name }) { Text("Always \(name)").tag(mode) }
            }
        case .notifications:
            Toggle("Tell me when a run has a result or didn't finish", isOn: Binding(get: { notify }, set: {
                notify = $0
                changed = $0 ? String(localized: "Notifications are on.") : String(localized: "Notifications are off.")
            }))
        case .sync:
            LabeledContent("iCloud sync", value: GuideSettings.syncIsOn ? String(localized: "On") : String(localized: "Off"))
            Text("Set when the app is built.").font(AppFont.caption()).foregroundStyle(Color.secondaryText)
        case .darkmuxModels:
            LabeledContent("Mux Bot may use", value: darkmuxValue ?? "…")
            Text("Changed in darkmux on your Mac, not here.").font(AppFont.caption()).foregroundStyle(Color.secondaryText)
        }
    }

    private func set(_ new: ModelMode) {
        guard new != mode else { return }
        mode = new
        GuideSettings.setModelMode(new, runs: brain.runs)
        changed = String(localized: "Set to \(GuideSettings.describe(new)) on \(brain.runs.machine?.name ?? String(localized: "this Mac")).")
    }

    private func load() async {
        switch id {
        case .modelMode:
            listed = await brain.runs.listedProfiles()
            mode = brain.runs.currentModelSettings().mode
        case .darkmuxModels:
            guard let token = connection.token, let who = try? await connection.client.whoami(token: token) else {
                darkmuxValue = String(localized: "Can't reach darkmux")
                return
            }
            darkmuxValue = who.profiles.map { $0.joined(separator: ", ") } ?? String(localized: "Any model that runs on this Mac")
        case .notifications, .sync:
            break
        }
    }
}

// MARK: - Answers

struct AnswerCardView: View {
    let text: String
    let articles: [String]
    let onDevice: Bool
    @State private var reading: HelpArticle?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HelpText(text: text)
            HStack(spacing: Spacing.sm) {
                Text(onDevice ? "From" : "From the help:").font(AppFont.caption()).foregroundStyle(Color.secondaryText)
                ForEach(articles, id: \.self) { id in
                    if let article = HelpLibrary.bundled.article(id) {
                        Button(article.title) { reading = article }.buttonStyle(.borderless).font(AppFont.caption())
                    }
                }
            }
        }
        .sheet(item: $reading) { HelpArticleView(article: $0) }
    }
}

struct HelpArticleView: View {
    let article: HelpArticle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    if !article.intro.isEmpty { HelpText(text: article.intro) }
                    ForEach(article.sections, id: \.heading) { section in
                        Text(section.heading).font(AppFont.headline())
                        HelpText(text: section.body)
                    }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: 560, alignment: .leading)
            }
            .navigationTitle(article.title)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

}

/// Help text: paragraphs as inline Markdown; indented lines are commands.
struct HelpText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, block in
                if block.hasPrefix("    ") {
                    CommandBox(command: block.components(separatedBy: "\n").map { String($0.drop { $0 == " " }) }.joined(separator: "\n"))
                } else {
                    Text((try? AttributedString(markdown: block, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block))
                        .font(AppFont.body())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
