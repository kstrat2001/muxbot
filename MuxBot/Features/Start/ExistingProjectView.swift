import SwiftUI
import SwiftData

/// "Work on a project I already have": pick where the code is (a folder on
/// this Mac, or a repo on your GitHub), then name the bot and say what the
/// project is. darkmux makes its own work copy; your files aren't touched.
struct ExistingProjectView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(BotBrain.self) private var brain
    @Environment(GitHubAuth.self) private var github
    @Environment(FleetConnection.self) private var connection
    @Environment(AppRouter.self) private var router
    @Query(sort: \Bot.createdAt) private var bots: [Bot]

    var inline = false
    /// Back to the use cases.
    var onBack: () -> Void

    private enum Step: Equatable { case source, repos, details }
    @State private var step = Step.source
    @State private var source: ExistingProject.Source?
    @State private var name = ""
    @State private var purpose = ""
    @State private var repos: [GitHubRepoSummary] = []
    @State private var truncated = false
    @State private var listing = false
    @State private var listError: String?
    @State private var search = ""
    @State private var projectPlaybook: String?
    @State private var pickingFolder = false
    @State private var starting = false

    var body: some View {
        Group {
            switch step {
            case .source: sourceStep
            case .repos: repoStep
            case .details: detailsStep
            }
        }
        .navigationTitle(ExistingProject.title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") {
                    switch step {
                    case .source: onBack()
                    case .repos: step = .source
                    case .details: step = source.map { if case .folder = $0 { return .source } else { return .repos } } ?? .source
                    }
                }
            }
            if step == .details {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { Task { await start() } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || starting)
                }
            }
        }
        #if os(macOS)
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }
            source = .folder(url)
            name = url.lastPathComponent
            projectPlaybook = Self.readPlaybook(in: url)
            step = .details
        }
        #endif
    }

    private var sourceStep: some View {
        Form {
            Section {
                #if os(macOS)
                Button { pickingFolder = true } label: {
                    Label("A folder on this Mac", systemImage: "folder")
                }
                #endif
                Button { step = .repos; Task { await loadRepos() } } label: {
                    Label("A repo on my GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            } header: {
                Text("Where is the code?")
            } footer: {
                #if os(macOS)
                Text("darkmux makes its own copy on a new branch, so your files aren't touched. A preview runs only from your own checkout, so a folder on this Mac gets one; a repo darkmux clones doesn't.")
                #else
                Text("darkmux works on your Mac, so pick a repo here and finish setting it up on your Mac once Mux Bot there is paired.")
                #endif
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var repoStep: some View {
        if github.token == nil {
            GitHubSignInView()
                .onChange(of: github.state) { if github.token != nil { Task { await loadRepos() } } }
        } else {
            List {
                if listing { HStack { ProgressView().controlSize(.small); Text("Reading your repos…") } }
                if let listError {
                    Label(listError, systemImage: "exclamationmark.triangle")
                    Button("Try again") { Task { await loadRepos() } }
                }
                ForEach(filtered) { repo in
                    Button { pick(repo) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(repo.fullName).font(AppFont.body(.semibold))
                                if repo.isPrivate { Image(systemName: "lock").foregroundStyle(Color.secondaryText).accessibilityLabel("Private") }
                            }
                            if let about = repo.description, !about.isEmpty {
                                Text(about).font(AppFont.footnote()).foregroundStyle(Color.secondaryText).lineLimit(2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if truncated {
                    Text("Showing your first \(repos.count) repos. Search narrows these.")
                        .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                }
            }
            .searchable(text: $search, prompt: "Search your repos")
        }
    }

    private var detailsStep: some View {
        Form {
            Section {
                TextField("What should the bot be called?", text: $name)
                TextField("What is this project, in a sentence?", text: $purpose, axis: .vertical)
                    .lineLimit(1...3)
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(projectPlaybook == nil
                         ? "This project has no PLAYBOOK.md, so the bot starts with general skills."
                         : "The bot's skills come from this project's PLAYBOOK.md.")
                    if case let .github(repo, checkout) = source {
                        if let checkout {
                            Text("Using your checkout of \(repo) (\(checkout.folderName)) on this Mac, so it gets a preview.")
                        } else {
                            Text("darkmux clones \(repo). A clone gets no preview: darkmux runs a preview only from your own checkout. You can add yours later with Add folder.")
                        }
                    }
                    if !connection.isPaired {
                        Text("darkmux makes the work copy once Mux Bot is paired with it on your Mac. You can make the bot now.")
                    }
                }
            }
            if starting { Section { Label("Setting it up…", systemImage: "hourglass") } }
        }
        .formStyle(.grouped)
    }

    private var filtered: [GitHubRepoSummary] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return repos }
        return repos.filter { $0.fullName.localizedCaseInsensitiveContains(q) || ($0.description ?? "").localizedCaseInsensitiveContains(q) }
    }

    private func loadRepos() async {
        guard github.token != nil, !listing else { return }
        listing = true
        listError = nil
        defer { listing = false }
        do {
            (repos, truncated) = try await github.myRepos()
        } catch {
            listError = error.localizedDescription
        }
    }

    private func pick(_ repo: GitHubRepoSummary) {
        source = .github(repo: repo.fullName, checkout: ExistingProject.knownCheckout(for: repo.fullName, among: bots))
        name = ExistingProject.suggestedName(repo: repo.fullName)
        projectPlaybook = nil
        step = .details
        Task {
            let data = try? await brain.github.file(repo: repo.fullName, path: "PLAYBOOK.md")
            projectPlaybook = data.flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// The folder's own PLAYBOOK.md, read through the Open panel's access.
    nonisolated static func readPlaybook(in folder: URL) -> String? {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let file = folder.appendingPathComponent("PLAYBOOK.md")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Playbook.maxBytes else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    private func start() async {
        guard let source else { return }
        starting = true
        let (bot, problem) = await ExistingProject.start(source, name: name, purpose: purpose, projectPlaybook: projectPlaybook,
                                                         store: BotStore(context: context), runs: brain.runs)
        starting = false
        // A folder that can't be used: the bot is made; its thread says why.
        if let problem { BotStore(context: context).append(.system, problem, to: BotStore(context: context).conversation(for: .bot(bot.id))) }
        if !inline { dismiss() }
        router.navigate(to: .bot(bot.id))
        if bot.workspaceName != nil, bot.folderBookmark != nil {
            router.showPreview = true
            await brain.runs.ensurePreview(for: bot)
        }
    }
}
