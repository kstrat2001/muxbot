import SwiftUI
import SwiftData

/// "What do you want to get done?": pick a use case (a template), answer the
/// playbook's questions, and Mux Bot makes the bot and its project on this
/// Mac. Shown even with one choice; everything on it comes from the
/// template registry and the template's PLAYBOOK.md.
struct StartProjectView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(BotBrain.self) private var brain
    @Environment(FleetConnection.self) private var connection
    @Environment(AppRouter.self) private var router
    @Environment(GitHubAuth.self) private var github
    @State private var problem: String?
    @State private var signingIn = false
    /// Shown in place (Home or the window with no bots yet), not as a sheet.
    var inline = false

    @State private var entries: [TemplateEntry] = []
    @State private var details: [String: TemplateDetails] = [:]
    private var playbooks: [String: Playbook] { details.compactMapValues(\.playbook) }
    @State private var picked: TemplateEntry?
    /// The new bot's look: fresh when a template is picked, rerolled with
    /// Shuffle, and exactly what the bot gets.
    @State private var look = BotLook.fresh(avoiding: [])
    @Query private var bots: [Bot]
    @State private var answers = StartProject.Answers(name: "")
    @State private var starting = false
    /// "Work on a project I already have" is open.
    @State private var existing = false

    var body: some View {
        if existing {
            ExistingProjectView(inline: inline) { existing = false }
        } else {
            templates
        }
    }

    private var templates: some View {
        Group {
            if let picked, let playbook = playbooks[picked.id] {
                questions(picked, playbook)
            } else {
                chooser
            }
        }
        .navigationTitle(picked.map(\.title) ?? String(localized: "Start a project"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if picked != nil { Button("Back") { picked = nil } } else if !inline { Button("Cancel") { dismiss() } }
            }
            if let picked, let playbook = playbooks[picked.id] {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { Task { await start(picked, playbook) } }
                        .disabled(!answers.canStart || starting || (answers.backUpToGitHub && github.token == nil))
                }
            }
        }
        .task { await load() }
        // A fresh look each time a template is picked.
        .onChange(of: picked?.id) { if picked != nil { look = BotLook.fresh(avoiding: bots.map(\.look)) } }
        .sheet(isPresented: $signingIn) {
            NavigationStack {
                GitHubSignInView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { signingIn = false } } }
            }
            .onChange(of: github.token != nil) { if github.token != nil { signingIn = false } }
        }
    }

    private var chooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("What do you want to get done?").font(AppFont.title2())
                if entries.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Spacing.md)], spacing: Spacing.md) {
                    ForEach(entries) { entry in
                        Button { pick(entry) } label: { tile(entry) }
                            .buttonStyle(.plain)
                            .disabled(playbooks[entry.id] == nil)
                    }
                    // Built in, not fetched: your own code, no template.
                    Button { existing = true } label: { existingTile }
                        .buttonStyle(.plain)
                }
                if inline {
                    // Mux Bot, the guide, helps with setup first.
                    Button { router.navigate(to: .lead) } label: {
                        Label("Setting up darkmux? Ask \(LeadBot.name)", systemImage: "questionmark.bubble")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(Spacing.xl)
        }
    }

    private var existingTile: some View {
        CardView {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Image(systemName: ExistingProject.icon).font(.title).foregroundStyle(Color.brandBlue)
                Text(ExistingProject.title).font(AppFont.headline())
                Text(ExistingProject.summary)
                    .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                    .lineLimit(3, reservesSpace: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func tile(_ entry: TemplateEntry) -> some View {
        CardView {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Image(systemName: playbooks[entry.id]?.icon ?? entry.icon)
                    .font(.title)
                    .foregroundStyle(Color.brandBlue)
                Text(entry.title).font(AppFont.headline())
                if case let .refused(why)? = details[entry.id] {
                    Label(why, systemImage: "exclamationmark.triangle")
                        .font(AppFont.footnote()).foregroundStyle(.orange)
                        .lineLimit(3, reservesSpace: true)
                } else {
                    Text(playbooks[entry.id]?.pitch ?? entry.summary ?? "")
                        .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                        .lineLimit(3, reservesSpace: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func questions(_ entry: TemplateEntry, _ playbook: Playbook) -> some View {
        Form {
            Section {
                HStack(spacing: Spacing.md) {
                    BotAvatarView(look: look, size: 44)
                    Button("Shuffle the look", systemImage: "shuffle") { look = BotLook.fresh(avoiding: bots.map(\.look)) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Shuffle the look")
                    Text(playbook.pitch).font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                }
            }
            Section {
                QuestionField(question: question(playbook, 0, String(localized: "Name")), text: $answers.name, lines: 1...1)
                QuestionField(question: question(playbook, 1, String(localized: "What is it for?")), text: $answers.purpose)
                QuestionField(question: question(playbook, 2, String(localized: "How should it feel?")), text: $answers.style)
            } footer: {
                if connection.isPaired {
                    Text("darkmux makes the project on this Mac from the template, on its own. It stays on this Mac until you put it on GitHub.")
                } else {
                    #if os(iOS)
                    Text("darkmux makes the project on your Mac, from the template, when you open this bot in Mux Bot there. You can make the bot now.")
                    #else
                    Text("darkmux makes the project on your Mac, so pair Mux Bot with darkmux first. You can still make the bot now.")
                    #endif
                }
            }
            Section {
                Toggle("Back up to GitHub", isOn: $answers.backUpToGitHub)
                if !answers.backUpToGitHub {
                    Text("Your project stays on this Mac. You can put it on GitHub later from its info.")
                        .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                } else if github.token == nil {
                    Text("The project gets its own repo in your GitHub account, so sign in first.")
                        .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                    Button("Sign in with GitHub", systemImage: "person.badge.key") { signingIn = true }
                } else {
                    QuestionField(question: PlaybookQuestion(String(localized: "Name of the GitHub repo")),
                                  text: $answers.repoName, lines: 1...1)
                    if answers.repoName.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Left blank, it's \(GitHubRepoMaker.slug(answers.name)); if you already have one by that name, the next free one.")
                            .font(AppFont.caption()).foregroundStyle(Color.secondaryText)
                    }
                    Toggle("Public", isOn: $answers.isPublic)
                    Text(answers.isPublic
                         ? "Anyone can see a public repo. Mux Bot puts the template's files in it as the first commit."
                         : "Private: only you can see it. Mux Bot puts the template's files in it as the first commit.")
                        .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                }
            } header: {
                Text("On GitHub")
            }
            if starting {
                Section { Label("Making the repo on GitHub, then the project on this Mac…", systemImage: "hourglass") }
            }
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle").fixedSize(horizontal: false, vertical: true) }
            }
        }
        .formStyle(.grouped)
    }

    /// The playbook's nth question (its label and suggestions), else a plain one.
    private func question(_ playbook: Playbook, _ index: Int, _ fallback: String) -> PlaybookQuestion {
        PlaybookQuestion(playbook.questions.indices.contains(index) ? playbook.questions[index] : fallback)
    }



    private func load() async {
        let registry = TemplateRegistry.shared
        entries = await registry.templates()
        // Opened for a named template ("write a book"): its form.
        if let id = router.startTemplateId {
            pick(entries.first { $0.id == id })
            router.startTemplateId = nil
        }
        // A template that couldn't be read is tried again each time you
        // come back here.
        for entry in entries where details[entry.id]?.retriesOnAppear ?? true {
            details[entry.id] = await registry.template(for: entry)
        }
        #if DEBUG
        // `-startTemplate <id>` opens that template's questions (layout checks).
        if let id = UserDefaults.standard.string(forKey: "startTemplate"), picked == nil {
            picked = entries.first { $0.id == id }
            answers.name = UserDefaults.standard.string(forKey: "startName") ?? ""
        }
        #endif
    }

    /// A template's form starts empty: never the previous project's answers.
    private func pick(_ entry: TemplateEntry?) {
        picked = entry
        answers = StartProject.Answers(name: "")
        problem = nil
    }

    private func start(_ entry: TemplateEntry, _ playbook: Playbook) async {
        if answers.backUpToGitHub, github.token == nil { signingIn = true; return }
        starting = true
        problem = nil
        let store = BotStore(context: context)
        let bot: Bot
        do {
            bot = try await StartProject.start(entry, playbook: playbook, answers: answers, look: look, github: github.token.map { GitHubRepoMaker(token: $0) },
                                               store: store, runs: brain.runs)
        } catch {
            // Nothing was made on this Mac; the form says why.
            starting = false
            problem = error.localizedDescription
            return
        }
        starting = false
        answers = StartProject.Answers(name: "")
        if inline { picked = nil } else { dismiss() }
        router.navigate(to: .bot(bot.id))
        if bot.workspaceName != nil {
            router.showPreview = true
            await brain.runs.ensurePreview(for: bot)
        }
    }
}
