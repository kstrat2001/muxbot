import Foundation

/// A machine in the darkmux fleet, as bots and the Fleet tab see it.
struct FleetMachine: Identifiable, Sendable, Equatable {
    var id: String { name }
    var name: String
    var chip: String
    var memoryGB: Int
    var freeMemoryGB: Int
    var loadedModels: [String]
    var isOnline: Bool
}

enum RunStatus: String, Sendable, CaseIterable {
    case running, queued, needsYou, done, failed

    /// Display order: work in progress first, then what needs you, then
    /// finished work.
    var urgency: Int {
        switch self {
        case .running: 0
        case .queued: 1
        case .needsYou: 2
        case .failed: 3
        case .done: 4
        }
    }

    var label: String {
        switch self {
        case .running: "Running"
        case .queued: "Queued"
        case .needsYou: "Needs you"
        case .done: "Done"
        case .failed: "Failed"
        }
    }
}

/// One darkmux run inside a mission, and the bot that started it.
struct FleetRun: Identifiable, Sendable, Equatable {
    var id: String
    var mission: String
    var title: String
    var botName: String
    var crew: CrewRole
    var machine: String
    var model: String
    var status: RunStatus
    var minutesElapsed: Int
}

/// What the fleet is doing. Read-only in the app: bots act, the Fleet tab
/// watches. Today it is sample data; the tailnet connection comes next.
struct FleetSnapshot: Sendable, Equatable {
    var isConnected: Bool
    var machines: [FleetMachine]
    var runs: [FleetRun]

    /// The online machine with the most free memory.
    var roomiestMachine: FleetMachine? {
        machines.filter(\.isOnline).max { $0.freeMemoryGB < $1.freeMemoryGB }
    }

    /// Plain-text briefing a bot reads before answering.
    var briefing: String {
        let source = isConnected ? "Fleet" : "Fleet (sample data, not connected yet)"
        let machineLines = machines.map { m in
            m.isOnline
                ? "- \(m.name) (\(m.chip)): \(m.freeMemoryGB) of \(m.memoryGB) GB free, loaded: \(m.loadedModels.isEmpty ? "nothing" : m.loadedModels.joined(separator: ", "))"
                : "- \(m.name): offline"
        }
        let runLines = runs.map { "- \($0.title) [\($0.status.label)] for \($0.botName), \($0.crew.name) on \($0.machine), \($0.model)" }
        return ([source + ":", "Machines:"] + machineLines + ["Runs:"] + runLines).joined(separator: "\n")
    }

    static let sample = FleetSnapshot(
        isConnected: false,
        machines: [
            FleetMachine(name: "MacBook Pro", chip: "M5 Max", memoryGB: 128, freeMemoryGB: 74,
                         loadedModels: ["qwen3-coder-30b"], isOnline: true),
            FleetMachine(name: "Mac mini", chip: "M4 Pro", memoryGB: 64, freeMemoryGB: 12,
                         loadedModels: ["gemma-3-27b", "qwen3-8b"], isOnline: true),
            FleetMachine(name: "Mac Studio", chip: "M3 Ultra", memoryGB: 256, freeMemoryGB: 0,
                         loadedModels: [], isOnline: false),
        ],
        runs: [
            FleetRun(id: "r1", mission: "Pricing page copy", title: "Rewrite the tier blurbs", botName: "humancodereader",
                     crew: .coder, machine: "MacBook Pro", model: "qwen3-coder-30b", status: .running, minutesElapsed: 14),
            FleetRun(id: "r2", mission: "Pricing page copy", title: "Review the copy diff", botName: "humancodereader",
                     crew: .reviewer, machine: "Mac mini", model: "gemma-3-27b", status: .queued, minutesElapsed: 0),
            FleetRun(id: "r3", mission: "Context-length sweep", title: "Eval 8 of 10", botName: "darkmux",
                     crew: .evalRunner, machine: "Mac mini", model: "qwen3-8b", status: .needsYou, minutesElapsed: 42),
            FleetRun(id: "r4", mission: "Context-length sweep", title: "Baseline eval", botName: "darkmux",
                     crew: .evalRunner, machine: "MacBook Pro", model: "qwen3-coder-30b", status: .done, minutesElapsed: 31),
            FleetRun(id: "r5", mission: "Local AI thread", title: "Research a week of local-model news", botName: "Personal brand",
                     crew: .researcher, machine: "MacBook Pro", model: "qwen3-coder-30b", status: .done, minutesElapsed: 9),
        ]
    )
}
