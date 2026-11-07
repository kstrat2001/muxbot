import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// A role as Radio sees it: a plain value, safe to hand to the model.
struct RoleSummary: Sendable, Equatable {
    var id: UUID
    var name: String
    var instructions: String
    var state: RoleState
}

/// A new role Radio proposes. Saved only when the user approves.
struct RoleDraft: Sendable, Equatable {
    var name: String
    var instructions: String
    var modelName: String = ""
    var systemImage: String = "sparkles"
}

/// What Radio proposes for one request.
enum RadioPlan: Sendable, Equatable {
    case assign(roleId: UUID, roleName: String, task: String, why: String)
    case newRole(RoleDraft, why: String)
}

// MARK: - Keyword fallback

/// Routes by word overlap with each role's name and instructions. Used when
/// the on-device model is unavailable or returns an unusable plan.
enum KeywordRouter {
    private static let newRolePhrases = ["new bot", "create a bot", "add a bot", "make a bot", "new role", "create a role", "add a role", "make a role"]
    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "from", "into", "about", "please",
        "can", "you", "our", "your", "some", "out", "all", "are", "was", "will", "what",
    ]

    /// `focus` is the role whose screen the user is on: it gets the work
    /// unless the request names another role or asks for a new one.
    static func plan(for request: String, roles: [RoleSummary], focus: UUID? = nil) -> RadioPlan {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        if roles.isEmpty || newRolePhrases.contains(where: lower.contains) {
            return .newRole(draft(from: text), why: "You asked for a new bot.")
        }

        if let named = roles.first(where: { $0.id != focus && lower.contains($0.name.lowercased()) }) {
            return .assign(roleId: named.id, roleName: named.name, task: text, why: "You named \(named.name).")
        }
        if let focus, let here = roles.first(where: { $0.id == focus }) {
            return .assign(roleId: here.id, roleName: here.name, task: text, why: "You're on \(here.name)'s screen.")
        }

        let words = tokens(lower)
        var best: (role: RoleSummary, hits: [String])?
        for role in roles {
            let vocabulary = tokens("\(role.name) \(role.instructions)".lowercased())
            let hits = words.filter { word in vocabulary.contains { $0.hasPrefix(word) || word.hasPrefix($0) } }
            if hits.count > (best?.hits.count ?? 0) { best = (role, hits) }
        }

        if let best {
            let matched = best.hits.prefix(2).map { "\"\($0)\"" }.joined(separator: " and ")
            return .assign(roleId: best.role.id, roleName: best.role.name, task: text,
                           why: "Matched \(matched) to what \(best.role.name) does.")
        }
        let pick = roles.first { $0.state == .ready } ?? roles[0]
        return .assign(roleId: pick.id, roleName: pick.name, task: text,
                       why: "No keyword matched, so \(pick.name) gets it\(pick.state == .ready ? " (it's ready)" : "").")
    }

    /// Words of four letters or more, minus filler. Short words like "pr"
    /// stay out so they cannot prefix-match everything.
    static func tokens(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 && !stopwords.contains($0) }
    }

    /// "New bot called Release helper that tags releases" → name + instructions.
    static func draft(from text: String) -> RoleDraft {
        var name = "New bot"
        var instructions = text
        for marker in [" called ", " named "] {
            guard let range = text.range(of: marker, options: .caseInsensitive) else { continue }
            let rest = text[range.upperBound...]
            let cut = rest.range(of: " that ", options: .caseInsensitive)
                ?? rest.range(of: " to ", options: .caseInsensitive)
                ?? rest.range(of: " who ", options: .caseInsensitive)
            name = String(rest[..<(cut?.lowerBound ?? rest.endIndex)])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if let cut { instructions = String(rest[cut.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
            break
        }
        return RoleDraft(name: name.isEmpty ? "New bot" : name, instructions: instructions)
    }
}

// MARK: - On-device planner

#if canImport(FoundationModels)
@Generable(description: "Radio's plan for one request")
struct GeneratedPlan {
    @Guide(description: "assign to give the work to an existing bot; newRole only if the user asks for a new bot or no bot fits at all")
    var action: GeneratedAction
    @Guide(description: "For assign: the exact name of the chosen bot from the list")
    var roleName: String
    @Guide(description: "The task for the bot, one short imperative sentence")
    var task: String
    @Guide(description: "One short line on why this bot or this new bot")
    var why: String
    @Guide(description: "For newRole: a short name for the new bot")
    var newRoleName: String
    @Guide(description: "For newRole: one sentence on what the new bot does")
    var newRoleInstructions: String
}

@Generable
enum GeneratedAction {
    case assign
    case newRole
}
#endif

/// Radio's brain: turns a request into a plan the user approves or cancels.
@MainActor @Observable
final class RadioPlanner {
    var isThinking = false
    var plan: RadioPlan?
    /// Shown under the plan when the keyword fallback made it.
    var fallbackNote: String?

    var onDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        SystemLanguageModel.default.isAvailable
        #else
        false
        #endif
    }

    func submit(_ request: String, roles: [RoleSummary], focus: UUID? = nil) async {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isThinking = true
        defer { isThinking = false }
        plan = nil
        fallbackNote = nil

        if onDeviceAvailable, let generated = await onDevicePlan(for: text, roles: roles, focus: focus) {
            plan = generated
            return
        }
        plan = KeywordRouter.plan(for: text, roles: roles, focus: focus)
        fallbackNote = onDeviceAvailable
            ? "The on-device model couldn't make a plan, so Radio used simple keyword matching."
            : "Apple Intelligence isn't available here, so Radio used simple keyword matching."
    }

    func cancel() {
        plan = nil
        fallbackNote = nil
    }

    /// Applies the plan to the store: records a task, or saves the drafted role.
    func approve(in store: RoleStore) {
        guard let plan else { return }
        switch plan {
        case let .assign(roleId, _, task, why):
            if let role = store.role(id: roleId) { store.assign(task: task, why: why, to: role) }
        case let .newRole(draft, _):
            store.add(name: draft.name, instructions: draft.instructions, modelName: draft.modelName, systemImage: draft.systemImage)
        }
        cancel()
    }

    private func onDevicePlan(for request: String, roles: [RoleSummary], focus: UUID?) async -> RadioPlan? {
        #if canImport(FoundationModels)
        let roster = roles.map { "- \($0.name) (\($0.state.label)): \($0.instructions)" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
            You are Radio, the dispatcher in Mux Bot. Pick which bot should do the user's request. \
            Prefer an existing bot. Only propose a new bot if the user asks for one or nothing fits.
            Bots:
            \(roster.isEmpty ? "(none yet)" : roster)
            \(roles.first { $0.id == focus }.map { "The user is on \($0.name)'s screen. Assign the request to \($0.name) unless it clearly names a different bot or asks for a new bot." } ?? "")
            """)
        do {
            let result = try await session.respond(to: request, generating: GeneratedPlan.self).content
            switch result.action {
            case .assign:
                let wanted = result.roleName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let role = roles.first(where: { $0.name.lowercased() == wanted }) else { return nil }
                let task = result.task.isEmpty ? request : result.task
                return .assign(roleId: role.id, roleName: role.name, task: task, why: result.why)
            case .newRole:
                guard !result.newRoleName.isEmpty else { return nil }
                return .newRole(RoleDraft(name: result.newRoleName, instructions: result.newRoleInstructions), why: result.why)
            }
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

extension MuxRole {
    var summary: RoleSummary {
        RoleSummary(id: id, name: name, instructions: instructions, state: state)
    }
}
