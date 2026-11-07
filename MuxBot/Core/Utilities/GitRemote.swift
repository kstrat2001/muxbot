import Foundation

/// Reads a picked folder's git remote straight from its config files (the
/// sandboxed app can't run git): is it a checkout, and which GitHub repo is
/// its `origin`.
enum GitRemote {
    /// The folder's `.git` directory: itself, or for a worktree the shared
    /// one its `gitdir:` file points to (through `commondir`).
    static func gitDirectory(of folder: URL) -> URL? {
        let dotGit = folder.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dotGit }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitdir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path).standardizedFileURL
        if let common = try? String(contentsOf: gitdir.appendingPathComponent("commondir"), encoding: .utf8) {
            let c = common.trimmingCharacters(in: .whitespacesAndNewlines)
            return (c.hasPrefix("/") ? URL(fileURLWithPath: c) : gitdir.appendingPathComponent(c)).standardizedFileURL
        }
        return gitdir
    }

    static func isRepository(_ folder: URL) -> Bool {
        gitDirectory(of: folder) != nil
    }

    /// `origin`'s URL from the config, as written.
    static func originURL(of folder: URL) -> String? {
        guard let dir = gitDirectory(of: folder),
              let config = try? String(contentsOf: dir.appendingPathComponent("config"), encoding: .utf8) else { return nil }
        var inOrigin = false
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inOrigin = line == #"[remote "origin"]"#; continue }
            guard inOrigin, line.hasPrefix("url") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { return parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// "owner/repo" when `origin` is on GitHub (https or ssh).
    static func originSlug(of folder: URL) -> String? {
        guard let url = originURL(of: folder) else { return nil }
        let normalized = url.hasPrefix("git@github.com:")
            ? "github.com/" + url.dropFirst("git@github.com:".count)
            : url
        guard normalized.contains("github.com/") else { return nil }
        return GitHubIssue.repoSlug(from: normalized)
    }
}
