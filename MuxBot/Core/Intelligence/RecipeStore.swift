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

    func load(for repo: String, workspace: String? = nil, connection: FleetConnection?, github: any GitHubClient) async {
        if case .ready? = recipes[repo] { return }
        recipes[repo] = .loading
        if let workspace, let connection, let token = connection.token,
           let local = try? await connection.client.recipe(token: token, workspace: workspace) {
            recipes[repo] = .ready(local, fromLocalCopy: true)
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

    /// The recipe already read for a bot's repo, if any.
    func recipe(for bot: Bot) -> PreviewManifest? {
        guard let repo = bot.repoSlugs.first, case let .ready(manifest, _)? = recipes[repo] else { return nil }
        return manifest
    }

}
