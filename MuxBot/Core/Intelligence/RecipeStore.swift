import Foundation

/// Each repo's `.darkmux/preview.json`: from the bot's workspace through
/// darkmux when it can, else read-only from GitHub. The recipe's hints
/// (conventions, page_file) go into run briefs.
@MainActor @Observable
final class RecipeStore {
    enum RecipeState: Equatable {
        case loading, ready(PreviewManifest, fromLocalCopy: Bool), missing, failed(String)
    }

    /// `.darkmux/preview.json` per repo: from the bot's workspace when
    /// darkmux lets this app read it, else read-only from GitHub.
    var recipes: [String: RecipeState] = [:]
    /// The app's hints per repo (template schema 2 keeps them in PLAYBOOK.md):
    /// the template's playbook for a bot made from one, else the repo's own.
    var hints: [String: RepoHints] = [:]
    /// A template's playbook by use case id (tests); else the registry.
    @ObservationIgnored var templatePlaybook: ((String) async -> Playbook?)?

    func load(for repo: String, workspace: String? = nil, connection: FleetConnection?, github: any GitHubClient,
              useCaseId: String = "") async {
        if hints[repo] == nil { await loadHints(for: repo, useCaseId: useCaseId, github: github) }
        if case .ready? = recipes[repo] { return }
        recipes[repo] = .loading
        if let workspace, let connection, let token = connection.token,
           let local = try? await connection.client.recipe(token: token, workspace: workspace) {
            recipes[repo] = .ready(local, fromLocalCopy: true)
            return
        }
        guard !repo.hasPrefix("workspace:") else {
            recipes[repo] = .missing
            return
        }
        do {
            guard let data = try await github.file(repo: repo, path: PreviewManifest.path) else {
                recipes[repo] = .missing
                return
            }
            recipes[repo] = .ready(try JSONDecoder().decode(PreviewManifest.self, from: data), fromLocalCopy: false)
        } catch {
            recipes[repo] = .failed(error.localizedDescription)
        }
    }

    private func loadHints(for repo: String, useCaseId: String, github: any GitHubClient) async {
        var playbook: Playbook?
        if !useCaseId.isEmpty {
            playbook = await (templatePlaybook ?? Self.registryPlaybook)(useCaseId)
        }
        if playbook == nil, !repo.hasPrefix("workspace:"),
           let data = try? await github.file(repo: repo, path: PlaybookSetup.path) {
            playbook = try? Playbook.parse(String(decoding: data, as: UTF8.self))
        }
        hints[repo] = playbook?.hints ?? RepoHints()
    }

    private static func registryPlaybook(_ id: String) async -> Playbook? {
        let registry = TemplateRegistry.shared
        guard let entry = await registry.templates().first(where: { $0.id == id }) else { return nil }
        return await registry.template(for: entry).playbook
    }

    /// The recipe already read for a bot's repo (or, for a project with no
    /// repo yet, its workspace), with the hints from its playbook, if any.
    func recipe(for bot: Bot) -> PreviewManifest? {
        guard let key = Self.key(for: bot) else { return nil }
        let hint = hints[key].flatMap { $0.isEmpty ? nil : $0 }
        if case let .ready(manifest, _)? = recipes[key] { return manifest.with(hint) }
        // No recipe darkmux will run, but the hints still go into briefs.
        return hint.map { PreviewManifest(command: "", conventions: $0.conventions, pageFile: $0.pageFile).with($0) }
    }

    /// Recipes are kept by repo; a local project (started from a template,
    /// no GitHub repo yet) by its workspace.
    static func key(for bot: Bot) -> String? {
        bot.repoSlugs.first ?? bot.workspaceName.map { "workspace:\($0)" }
    }

}
