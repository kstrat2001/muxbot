import Foundation

/// A darkmux role as the app shows it. Named `MuxRole` to avoid clashing
/// with `ChatRole`. The app owns its role store; for now it is sample data.
struct MuxRole: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case builder, researcher, benchmarker, ideas

        var systemImage: String {
            switch self {
            case .builder: "hammer"
            case .researcher: "magnifyingglass"
            case .benchmarker: "gauge"
            case .ideas: "lightbulb"
            }
        }

        var label: String {
            switch self {
            case .builder: "Builder"
            case .researcher: "Researcher"
            case .benchmarker: "Benchmarker"
            case .ideas: "Ideas"
            }
        }
    }

    enum Status: String, CaseIterable, Sendable {
        case needsYou, working, ready

        var label: String {
            switch self {
            case .needsYou: "Needs you"
            case .working: "Working"
            case .ready: "Ready"
            }
        }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    var status: Status
    var summary: String
}

/// In-memory role store with sample data. No darkmux calls yet.
@MainActor @Observable
final class RoleStore {
    var roles: [MuxRole] = RoleStore.sample
    var latestUpdate = "Researcher finished the model sweep. 3 results ready."

    func roles(with status: MuxRole.Status) -> [MuxRole] {
        roles.filter { $0.status == status }
    }

    func role(id: UUID) -> MuxRole? {
        roles.first { $0.id == id }
    }

    func add(name: String, kind: MuxRole.Kind) {
        roles.append(MuxRole(name: name, kind: kind, status: .ready, summary: "New role. Ask Radio to give it work."))
    }

    static let sample: [MuxRole] = [
        MuxRole(name: "Builder", kind: .builder, status: .needsYou, summary: "Wants a yes on the refactor plan."),
        MuxRole(name: "Researcher", kind: .researcher, status: .working, summary: "Reading three papers on context length."),
        MuxRole(name: "Benchmarker", kind: .benchmarker, status: .working, summary: "Running the lab workload, 4 of 10."),
        MuxRole(name: "Ideas", kind: .ideas, status: .ready, summary: "Idle. Ready for new work."),
    ]
}
