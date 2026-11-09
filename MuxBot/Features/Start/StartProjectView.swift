import SwiftUI

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
    /// Shown in place (Home or the window with no bots yet), not as a sheet.
    var inline = false

    @State private var entries: [TemplateEntry] = []
    @State private var details: [String: TemplateDetails] = [:]
    private var playbooks: [String: Playbook] { details.compactMapValues(\.playbook) }
    @State private var picked: TemplateEntry?
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
                        .disabled(!answers.canStart || starting)
                }
            }
        }
        .task { await load() }
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
                        Button { picked = entry } label: { tile(entry) }
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
                    BotAvatarView(look: look(playbook), size: 44)
                    Text(playbook.pitch).font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                }
            }
            Section {
                TextField(question(playbook, 0, String(localized: "Name")).label, text: $answers.name)
                field(question(playbook, 1, String(localized: "What is it for?")), text: $answers.purpose)
                field(question(playbook, 2, String(localized: "How should it feel?")), text: $answers.style)
            } footer: {
                if connection.isPaired {
                    Text("darkmux makes the project on this Mac from the template, on its own. It stays on this Mac until you put it on GitHub.")
                } else {
                    Text("darkmux makes the project on your Mac, so pair Mux Bot with darkmux first. You can still make the bot now.")
                }
            }
            if starting {
                Section { Label("Setting it up…", systemImage: "hourglass") }
            }
        }
        .formStyle(.grouped)
    }

    /// The playbook's nth question (its label and suggestions), else a plain one.
    private func question(_ playbook: Playbook, _ index: Int, _ fallback: String) -> PlaybookQuestion {
        PlaybookQuestion(playbook.questions.indices.contains(index) ? playbook.questions[index] : fallback)
    }

    /// A question's field, with its examples as suggestions you tap.
    @ViewBuilder private func field(_ question: PlaybookQuestion, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            TextField(question.label, text: text, axis: .vertical)
                .lineLimit(1...3)
            if !question.suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(question.suggestions, id: \.self) { suggestion in
                            Button(suggestion) { text.wrappedValue = PlaybookQuestion.adding(suggestion, to: text.wrappedValue) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityHint("Adds “\(suggestion)” to your answer")
                        }
                    }
                }
            }
        }
    }

    private func look(_ playbook: Playbook) -> BotLook {
        let suggested = BotLook.suggested(for: answers.name)
        return BotLook(animal: playbook.animal ?? suggested.animal, bodyHex: playbook.bodyHex ?? suggested.bodyHex,
                       eyeHex: playbook.eyeHex ?? suggested.eyeHex)
    }

    private func load() async {
        let registry = TemplateRegistry.shared
        entries = await registry.templates()
        for entry in entries where details[entry.id] == nil {
            details[entry.id] = await registry.template(for: entry)
        }
    }

    private func start(_ entry: TemplateEntry, _ playbook: Playbook) async {
        starting = true
        let store = BotStore(context: context)
        let bot = await StartProject.start(entry, playbook: playbook, answers: answers, store: store, runs: brain.runs)
        starting = false
        if inline { picked = nil } else { dismiss() }
        router.navigate(to: .bot(bot.id))
        if bot.workspaceName != nil {
            router.showPreview = true
            await brain.runs.ensurePreview(for: bot)
        }
    }
}
