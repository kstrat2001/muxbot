import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// A bot's details and the resources it works with: repos, folders,
/// preview recipes, links and notes. Bots can also propose resources in
/// conversation, behind an Approve card.
struct BotInfoView: View {
    let bot: Bot

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(BotBrain.self) private var brain
    @Environment(GitHubAuth.self) private var github
    @State private var putPublic = false
    @State private var putting = false
    @State private var putProblem: String?
    @State private var newValue = ""
    @State private var newKind = ResourceKind.repo
    @State private var pickingFolder = false
    @State private var folderProblem: String?
    @State private var branch: String?

    /// Renaming keeps the bot's look: a look still suggested from the old
    /// name is saved first, so the animal doesn't change with the name.
    private var nameBinding: Binding<String> {
        Binding(get: { bot.name }, set: { newName in
            let look = bot.look
            bot.name = newName
            bot.look = look
            try? context.save()
        })
    }

    private var aboutBinding: Binding<String> {
        Binding(get: { bot.instructions }, set: { bot.instructions = $0; try? context.save() })
    }

    /// The state the picker's face previews (not saved).
    @State private var previewMood = AvatarMood.idle

    var body: some View {
        Form {
            Section("About") {
                HStack(spacing: Spacing.md) {
                    BotAvatarView(look: bot.look, mood: AvatarMood(NeedsYou.shownState(bot)), size: 44, blinkId: bot.id)
                    TextField("Name", text: nameBinding).font(AppFont.headline())
                }
                TextField("What this bot is about", text: aboutBinding, axis: .vertical)
                    .lineLimit(2...6)
                    .foregroundStyle(Color.secondaryText)
            }
            Section("Look") {
                BotLookPicker(look: Binding(get: { bot.look }, set: { bot.look = $0; try? context.save() }), mood: $previewMood)
            }
            workCopySection
            if PutOnGitHub.canPut(bot) { putOnGitHubSection }
            Section {
                Picker("For this bot", selection: modelModeBinding) {
                    Text("Same as Settings").tag(String?.none)
                    Text("Auto").tag(Optional(ModelMode.auto.stored))
                    Text("Always ask").tag(Optional(ModelMode.ask.stored))
                    ForEach(brain.runs.lastListed.map(\.name), id: \.self) { name in
                        Text("Always \(name)").tag(Optional(ModelMode.model(name).stored))
                    }
                    // A saved model this Mac doesn't list keeps a row, so the picker shows it.
                    if let name = ModelMode.unlistedModel(ModelMode(stored: modelModeBinding.wrappedValue), listed: brain.runs.lastListed.map(\.name)) {
                        if brain.runs.listing == .listed { Text("Always \(name) (not on this Mac)").tag(Optional(ModelMode.model(name).stored)) }
                        else { Text("Always \(name)").tag(Optional(ModelMode.model(name).stored)) }
                    }
                }
            } header: {
                Text(brain.runs.machine.map { "Model on \($0.name)" } ?? "Model on this Mac")
            }
            if !bot.skills.isEmpty {
                Section {
                    ForEach(bot.skills, id: \.name) { skill in
                        DisclosureGroup(skill.name) {
                            HelpText(text: skill.body).font(AppFont.footnote())
                        }
                    }
                } header: {
                    Text("Skills")
                } footer: {
                    Text("From its template's playbook when it was made. The bot uses the one that fits each request.")
                }
            }
            Section("Resources") {
                ForEach(bot.sortedResources) { resource in
                    Label {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(resource.value).textSelection(.enabled)
                            if resource.kind == .previewURL {
                                Text("Your preview link, until darkmux runs previews itself.")
                                    .font(AppFont.caption())
                                    .foregroundStyle(Color.secondaryText)
                            }
                        }
                    } icon: {
                        Image(systemName: resource.kind.systemImage)
                    }
                    .accessibilityLabel("\(resource.kind.label): \(resource.value)")
                }
                .onDelete { offsets in
                    let store = BotStore(context: context)
                    offsets.map { bot.sortedResources[$0] }.forEach(store.remove)
                }
                if bot.sortedResources.isEmpty {
                    Text("None yet.").foregroundStyle(Color.secondaryText)
                }
            }
            Section("Preview") {
                if bot.workspaceName != nil, let live = brain.runs.livePreviews[bot.id] {
                    HStack {
                        Label(live.status.text, systemImage: live.status == .ready ? "play.circle.fill" : live.status.isFailed ? "exclamationmark.triangle" : live.status.isUnavailable ? "eye.slash" : "circle.dotted")
                        Spacer()
                        if live.status == .ready || live.status == .starting || live.status == .installing {
                            Button("Stop", systemImage: "stop.circle") { Task { await brain.runs.stopPreview(for: bot) } }
                        } else {
                            Button("Start", systemImage: "play") { Task { await brain.runs.ensurePreview(for: bot) } }
                        }
                    }
                }
                ForEach(bot.repoSlugs, id: \.self) { repo in
                    recipeRow(repo)
                }
                if bot.repoSlugs.isEmpty {
                    Text("Add a repo and I'll look for its preview recipe.").foregroundStyle(Color.secondaryText)
                }
            }
            Section("Add a resource") {
                Picker("Kind", selection: $newKind) {
                    ForEach(ResourceKind.addable, id: \.self) { kind in
                        Label(kind.label, systemImage: kind.systemImage).tag(kind)
                    }
                }
                TextField("URL or note", text: $newValue)
                    .autocorrectionDisabled()
                    .onChange(of: newValue) {
                        let guess = ResourceKind.guess(for: newValue)
                        newKind = ResourceKind.addable.contains(guess) ? guess : .note
                    }
                Button("Add", systemImage: "plus") {
                    BotStore(context: context).addResource(newKind, newValue, to: bot)
                    newValue = ""
                }
                .disabled(newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .formStyle(.grouped)
        .task { if brain.runs.lastListed.isEmpty { brain.runs.lastListed = await brain.runs.listedProfiles() } }
        .task {
            for repo in bot.repoSlugs { await brain.runs.recipes.load(for: repo, workspace: bot.workspaceName, connection: brain.connection, github: brain.github, useCaseId: bot.useCaseId) }
            if bot.repoSlugs.isEmpty, let key = RecipeStore.key(for: bot) {
                await brain.runs.recipes.load(for: key, workspace: bot.workspaceName, connection: brain.connection, github: brain.github, useCaseId: bot.useCaseId)
            }
            await refreshBranch()
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }
            Task {
                folderProblem = await brain.runs.addFolder(url, to: bot, store: BotStore(context: context))
                await refreshBranch()
            }
        }
        .navigationTitle(bot.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    /// Where darkmux works on this bot's code, on this Mac. Status only:
    /// darkmux owns the copy; the app knows its name, never a path.
    /// This bot's model mode on this machine (shared with your other devices).
    private var modelModeBinding: Binding<String?> {
        let machine = brain.runs.machineKey
        let store = brain.runs.settingsStore
        return Binding(get: { store.botMode(bot: bot.id, machine: machine)?.stored },
                       set: { store.setBotMode(ModelMode(stored: $0), bot: bot.id, machine: machine) })
    }

    /// A project that's on this Mac only: make its GitHub repo now.
    private var putOnGitHubSection: some View {
        Section {
            if github.token == nil {
                Text("This project is only on this Mac. Sign in with GitHub (Settings › GitHub) to put it there.")
                    .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
            } else {
                Toggle("Public", isOn: $putPublic)
                Text(putPublic ? "Anyone can see a public repo." : "Private: only you can see it.")
                    .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                Button(putting ? "Putting it on GitHub…" : "Put it on GitHub", systemImage: "arrow.up.circle") {
                    Task { await putOnGitHub() }
                }
                .disabled(putting)
            }
            if let putProblem { Label(putProblem, systemImage: "exclamationmark.triangle").font(AppFont.footnote()) }
        } header: {
            Text("GitHub")
        } footer: {
            Text("Makes a repo in your account with the template's files and this project's committed work, then backs up new work to it.")
        }
    }

    private func putOnGitHub() async {
        guard let token = github.token else { return }
        putting = true
        putProblem = nil
        defer { putting = false }
        do {
            _ = try await PutOnGitHub.run(bot, isPublic: putPublic, github: GitHubRepoMaker(token: token), pr: GitHubPR(token: token),
                                          store: BotStore(context: context), runs: brain.runs)
        } catch {
            putProblem = error.localizedDescription
        }
    }

    private var workCopySection: some View {
        Section {
            HStack(spacing: Spacing.sm) {
                switch (brain.runs.workCopySetup[bot.id], bot.workspaceName) {
                case (.settingUp?, _):
                    ProgressView().controlSize(.small)
                    Text("Setting up on \(FleetConnection.machineName)…")
                case let (.failed(why)?, _):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.brandOrange)
                    Text(why).font(AppFont.footnote())
                case (nil, _?):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.brandGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ready on \(bot.workspaceMachine ?? FleetConnection.machineName)")
                        if let branch, !branch.isEmpty {
                            Text("Branch \(branch)").font(AppFont.caption()).foregroundStyle(Color.secondaryText)
                        }
                    }
                case (nil, nil):
                    Image(systemName: "circle.dashed").foregroundStyle(Color.secondaryText)
                    Text(bot.folderBookmark == nil && bot.repoSlugs.isEmpty ? "No code yet" : "Not set up on this Mac yet")
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
            if let folder = bot.folderName {
                Label("From your folder \(folder)", systemImage: "folder").font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
            }
            if let folderProblem {
                Label(folderProblem, systemImage: "exclamationmark.triangle").font(AppFont.footnote())
            }
            #if os(macOS)
            HStack {
                Button(bot.folderBookmark == nil ? "Add folder…" : "Change folder…", systemImage: "folder.badge.plus") { pickingFolder = true }
                if bot.workspaceName == nil, brain.runs.workCopySetup[bot.id] != .settingUp,
                   bot.folderBookmark != nil || !bot.repoSlugs.isEmpty {
                    Button("Set up now") { Task { await brain.runs.setUpWorkCopy(for: bot, store: BotStore(context: context)); await refreshBranch() } }
                }
            }
            #endif
        } header: {
            Text("Work copy")
        } footer: {
            #if os(macOS)
            Text("Pick the project folder you already have. darkmux works on its own copy on a new branch, so your files and changes are never touched.")
            #else
            Text("Work copies are set up from the Mac app for now.")
            #endif
        }
    }

    private func refreshBranch() async {
        guard let name = bot.workspaceName, let connection = brain.connection, let token = connection.token else { return }
        branch = try? await connection.client.workspace(token: token, name: name).branch
    }

    @ViewBuilder private func recipeRow(_ repo: String) -> some View {
        switch brain.runs.recipes.recipes[repo] {
        case let .ready(manifest, fromLocalCopy)?:
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label("Preview ready · from \(fromLocalCopy ? "the local copy" : "GitHub")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.brandGreen)
                Text(manifest.summary).font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                Text(repo).font(AppFont.caption()).foregroundStyle(Color.secondaryText)
            }
        case .missing?:
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("No preview recipe yet")
                    Text("\(repo) has no \(PreviewManifest.path)").font(AppFont.caption()).foregroundStyle(Color.secondaryText)
                }
                Spacer()
                Button("Draft one") {}
                    .disabled(true)
                    .help("Coming soon: a bot drafts the recipe for you to approve.")
            }
        case .failed(let message)?:
            Label("Couldn't check \(repo): \(message)", systemImage: "exclamationmark.triangle")
                .font(AppFont.footnote())
        case .loading?, nil:
            ProgressView().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
