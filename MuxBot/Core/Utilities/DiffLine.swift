import Foundation

/// One line of a unified diff, for coloring.
enum DiffLine {
    enum Kind: Equatable { case added, removed, hunk, meta, context }

    static func kind(of line: String) -> Kind {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { return .meta }
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        return .context
    }
}
