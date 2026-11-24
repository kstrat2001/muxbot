import Foundation

/// The work copy's git, through darkmux (darkmux #3681): plain git on the
/// Mac that holds the work copy, from a short list of verbs. The app never
/// builds commits or trees itself; GitHub's product side (pull requests,
/// review, merge) stays in the app.
extension DarkmuxClient {
    /// The work copy as darkmux's git has it, from its local refs only.
    struct GitStatus: Decodable, Sendable, Equatable {
        struct Upstream: Decodable, Sendable, Equatable {
            var ref: String
            var head: String
        }
        struct Busy: Decodable, Sendable, Equatable {
            var holder: String
            var workId: String?
            enum CodingKeys: String, CodingKey { case holder, workId = "work_id" }
        }
        var branch: String
        var head: String?
        /// `github.com/owner/name`; nil for a project never pushed.
        var origin: String?
        var defaultBranch: String?
        var base: String?
        /// Commits in this task the project's main version lacks.
        var pending: Int
        var upstream: Upstream?
        /// Commits here the task's branch on GitHub lacks (nil: never sent).
        var ahead: Int?
        var behind: Int?
        var behindMain: Int?
        var dirty: Bool
        var busy: Busy?

        enum CodingKeys: String, CodingKey {
            case branch, head, origin, base, pending, upstream, ahead, behind, dirty, busy
            case defaultBranch = "default_branch", behindMain = "behind_main"
        }

        /// The repo this work copy pushes to, as `owner/name`.
        var repo: String? {
            origin.flatMap { $0.hasPrefix("github.com/") ? String($0.dropFirst("github.com/".count)) : nil }
        }
    }

    struct GitPushed: Decodable, Sendable, Equatable {
        var branch: String
        var head: String
        var remote: String
        var addedOrigin: Bool
        enum CodingKeys: String, CodingKey { case branch, head, remote, addedOrigin = "added_origin" }
    }

    struct GitMerged: Decodable, Sendable, Equatable {
        var head: String
        var upToDate: Bool
        var fastForward: Bool
        enum CodingKeys: String, CodingKey { case head, upToDate = "up_to_date", fastForward = "fast_forward" }
    }

    /// (darkmux #3684) `new_task`: whether the work copy moved onto the
    /// next task, and how many changes made after the merge came along.
    struct GitNewTask: Decodable, Sendable, Equatable {
        var moved: Bool
        var branch: String
        var head: String?
        var carried: Int
    }

    struct FileResult: Decodable, Sendable, Equatable {
        var path: String
        var workId: String?
        var commit: String?
        var branch: String?
        enum CodingKeys: String, CodingKey { case path, commit, branch, workId = "work_id" }
    }

    /// One git verb on `workspace`, its `result` decoded.
    private func git<T: Decodable>(_ verb: String, token: String, workspace: String,
                                   args: [String: String] = [:], timeout: TimeInterval = 30) async throws -> T {
        let data = try await send("POST", "/client/workspaces/\(workspace)/git", body: GitBody(verb: verb, args: args),
                                  headers: ["Authorization": "Bearer \(token)"], timeout: timeout)
        return try JSONDecoder().decode(GitReply<T>.self, from: data).result
    }

    func gitStatus(token: String, workspace: String) async throws -> GitStatus {
        try await git("status", token: token, workspace: workspace)
    }

    /// Fetches the remote's branches; GitHub's token for this one call
    /// only (darkmux never keeps it).
    func gitFetch(token: String, workspace: String, github: String?) async throws -> GitStatus {
        try await git("fetch", token: token, workspace: workspace, args: github.map { ["token": $0] } ?? [:], timeout: 300)
    }

    /// Sends the task's branch to GitHub, fast-forward only. `repo` is the
    /// empty repository a project made from a template goes to the first
    /// time.
    func gitPush(token: String, workspace: String, github: String?, repo: String? = nil) async throws -> GitPushed {
        var args: [String: String] = [:]
        if let github { args["token"] = github }
        if let repo { args["repo"] = repo }
        return try await git("push", token: token, workspace: workspace, args: args, timeout: 300)
    }

    /// Brings the project's main version (as last fetched) into the task.
    func gitMergeMain(token: String, workspace: String) async throws -> GitMerged {
        try await git("merge_main", token: token, workspace: workspace, timeout: 120)
    }

    /// After GitHub merged the task (`mergedHead`, by merge commit
    /// `mergeSHA`): the work copy moves onto the next task, from the merged
    /// main, as last fetched (darkmux #3684).
    func gitNewTask(token: String, workspace: String, mergedHead: String, mergeSHA: String) async throws -> GitNewTask {
        try await git("new_task", token: token, workspace: workspace, args: ["merged_head": mergedHead, "merge_sha": mergeSHA], timeout: 120)
    }

    /// Commits a file you approved into the work copy (darkmux #3688).
    func addFile(token: String, workspace: String, path: String, data: Data) async throws -> FileResult {
        struct Body: Encodable { var path: String; var data: String }
        let reply = try await send("POST", "/client/workspaces/\(workspace)/file", body: Body(path: path, data: data.base64EncodedString()),
                                   headers: ["Authorization": "Bearer \(token)"], timeout: 60)
        return try JSONDecoder().decode(FileResult.self, from: reply)
    }
}

/// The git route's body and reply (darkmux #3681).
private struct GitBody: Encodable { var verb: String; var args: [String: String] }
private struct GitReply<R: Decodable>: Decodable { var result: R }
