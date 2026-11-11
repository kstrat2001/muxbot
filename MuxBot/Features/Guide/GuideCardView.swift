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
                case let .pageFits(text)?: PageFitsCardView(text: text)
                case nil: Text(message.content).font(AppFont.body())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Links and text buttons in a card read at 4.5:1 (the brand green
            // is about 2:1 on a light card).
            .tint(Color.accentText)
        }
        .chatColumn(alignment: .leading)
    }
}

// MARK: - Setup checklist

/// The live checklist: looks again every few seconds while it's on screen
/// and ticks off each step once it works.
/// A link to a page, drawn in SwiftUI (the accent color, dimmed while
/// pressed), so it looks like a Link and renders in screenshots too.
struct PageLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.accentText)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

struct SetupChecklistView: View {
    @Environment(FleetConnection.self) private var connection
    @Environment(BotBrain.self) private var brain
    @Environment(AppRouter.self) private var router
    @Environment(GitHubAuth.self) private var github
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @Environment(\.openURL) private var openURL
    var isLive = true
    @State private var facts: SetupFacts?
    /// Shown as given, never probed (screenshots of each state).
    private var fixed = false

    init(isLive: Bool = true) { self.isLive = isLive }

    init(facts: SetupFacts) {
        isLive = false
        fixed = true
        _facts = State(initialValue: facts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            let steps = facts.map { SetupCheck.steps($0) } ?? []
            HStack {
                Label("Setup check", systemImage: "checklist").font(AppFont.headline())
                Spacer()
                if facts == nil { ProgressView().controlSize(.small) } else { Text(SetupCheck.summary(steps)).font(AppFont.footnote()).foregroundStyle(Color.secondaryText) }
            }
            ForEach(steps) { step in row(step) }
            #if os(iOS)
            ShareLink(item: SetupCheck.shareText(), subject: Text("Set up Mux Bot on your Mac")) {
                Label("Send the steps to your Mac", systemImage: "square.and.arrow.up")
            }
            #endif
        }
        .task(id: isLive) {
            guard !fixed else { return }
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
                HStack(spacing: Spacing.md) {
                    if let action = step.action { button(action) }
                    if let link = step.link {
                        // A button that opens the page (same look as a Link; it also renders in screenshots).
                        Button { openURL(link) } label: { Label(step.linkTitle ?? link.host() ?? "Open", systemImage: "safari") }
                            .buttonStyle(PageLinkStyle()).font(AppFont.footnote())
                    }
                }
            }
        }
    }

    @ViewBuilder private func button(_ action: SetupStep.Action) -> some View {
        switch action {
        case .pair:
            Button("Pair with darkmux", systemImage: "link") { router.showPairing = true }.buttonStyle(.borderedProminent).tint(Color.brandGreen).controlSize(.small)
        case .gitHubSignIn:
            #if os(macOS)
            Button("Sign in with GitHub", systemImage: "person.badge.key") { SettingsTab.select(.github); openSettings() }.buttonStyle(.bordered).controlSize(.small)
            #else
            Button("Sign in with GitHub", systemImage: "person.badge.key") { router.showPairing = true }.buttonStyle(.bordered).controlSize(.small)
            #endif
        case .confirmDocker:
            Button("Docker is running") {
                UserDefaults.standard.set(true, forKey: SetupProbe.dockerKey)
                facts?.dockerConfirmed = true
            }
            .buttonStyle(.bordered).controlSize(.small)
        case .openDocker, .openLMStudio:
            #if os(macOS)
            let docker = action == .openDocker
            Button(docker ? "Open Docker" : "Open LM Studio", systemImage: "arrow.up.forward.app") {
                SetupProbe.openApp(bundleID: docker ? SetupCheck.dockerBundleID : SetupCheck.lmStudioBundleID)
            }
            .buttonStyle(.borderedProminent).tint(Color.brandGreen).controlSize(.small)
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
        case .optional: "circle.dashed"
        }
    }

    private func color(_ state: SetupStep.State) -> Color {
        switch state {
        case .done: .brandGreen
        case .todo: .brandOrange
        case .unknown, .manual, .needsMac: .brandBlue
        case .later, .optional: .secondary
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
        case .optional: String(localized: "Optional")
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
                Button(NewEntry.menuTitle, systemImage: "plus") { router.showStartProject = true }.buttonStyle(.borderedProminent).tint(Color.brandGreen)
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
    @Environment(NotificationService.self) private var notifications
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
            if brain.runs.knownMachine == nil {
                Text(brain.runs.modelsWaitingLine)
                    .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
            }
            Picker("On \(brain.runs.machinePhrase)", selection: Binding(get: { mode }, set: { set($0) })) {
                Text("Auto").tag(ModelMode.auto)
                Text("Always ask").tag(ModelMode.ask)
                ForEach(listed.map(\.name), id: \.self) { name in Text("Always \(name)").tag(ModelMode.model(name)) }
                if case let .model(name) = mode, !listed.contains(where: { $0.name == name }) { Text("Always \(name)").tag(mode) }
            }
            .disabled(brain.runs.knownMachine == nil)
        case .notifications:
            Toggle("Tell me when a run has a result or didn't finish", isOn: Binding(get: { notify }, set: {
                notify = $0
                changed = NotificationService.cardText(enabled: $0, denied: notifications.isDenied)
            }))
            .tint(Color.brandGreen)
            if notify && notifications.isDenied {
                Label(NotificationService.cardText(enabled: true, denied: true), systemImage: "bell.slash").font(AppFont.footnote())
                Button("Open System Settings") { notifications.openSystemSettings() }.buttonStyle(.bordered).controlSize(.small)
            }
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
        guard GuideSettings.setModelMode(new, runs: brain.runs) else { return }
        mode = new
        changed = String(localized: "Set to \(GuideSettings.describe(new)) on \(brain.runs.machinePhrase).")
    }

    private func load() async {
        switch id {
        case .modelMode:
            listed = await brain.runs.listedProfiles()
            mode = brain.runs.currentModelSettings().mode
        case .darkmuxModels:
            guard let token = connection.token else {
                darkmuxValue = String(localized: "Pair Mux Bot to see this")
                return
            }
            let who: DarkmuxClient.Whoami
            do {
                who = try await connection.client.whoami(token: token)
            } catch {
                darkmuxValue = Self.whoamiFailure(error)
                return
            }
            darkmuxValue = who.profiles.map { $0.joined(separator: ", ") } ?? String(localized: "Any model that runs on this Mac")
        case .notifications:
            await notifications.checkAuthorizationStatus()
        case .sync:
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

/// Help text: paragraphs as inline Markdown (never a command to run).
struct HelpText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, block in
                Text((try? AttributedString(markdown: block, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block))
                    .font(AppFont.body())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - The page fits

/// "The page itself fits": the measurement found nothing wider than the
/// screen, so the preview panel may be what looks cut off.
struct PageFitsCardView: View {
    let text: String
    @Environment(PreviewController.self) private var preview

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(text).font(AppFont.body())
            Button("Reload the preview", systemImage: "arrow.clockwise") { preview.reload() }
                .buttonStyle(.bordered)
        }
    }
}

extension SettingCardView {
    /// A revoked pairing (401) says to pair again, never "can't reach".
    static func whoamiFailure(_ error: any Error) -> String {
        if let client = error as? DarkmuxClient.ClientError, client.status == 401 { return FleetConnection.revokedMessage }
        return String(localized: "Can't reach darkmux")
    }
}
