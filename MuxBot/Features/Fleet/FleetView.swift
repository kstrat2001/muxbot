import SwiftUI
import SwiftData

/// Read-only view of the work your bots started: runs grouped by mission,
/// in progress first, then what needs you, then finished. Work comes first; machines appear only on a run (and
/// in conversation with bots), never as a section to manage. Nothing here
/// acts; "Ask <bot> about this" opens that bot's thread.
struct FleetView: View {
    @Environment(BotBrain.self) private var brain
    @Environment(AppRouter.self) private var router
    @Query(sort: \MuxRole.createdAt) private var bots: [MuxRole]

    private var fleet: FleetSnapshot { brain.fleet }

    var body: some View {
        List {
            if !fleet.isConnected {
                Label("Fleet not connected. This is sample data.", systemImage: "wifi.slash")
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
            }
            ForEach(missions, id: \.self) { mission in
                Section(mission) {
                    ForEach(runs(in: mission)) { run in
                        RunRow(run: run, askBot: bot(named: run.botName).map { b in
                            { router.ask(.bot(b.id), draft: "About “\(run.title)”: ") }
                        })
                    }
                }
            }
        }
        .navigationTitle("Fleet")
    }

    /// Missions ordered by their most urgent run, so live work comes first.
    private var missions: [String] {
        let names = fleet.runs.reduce(into: [String]()) { if !$0.contains($1.mission) { $0.append($1.mission) } }
        return names.sorted { urgency($0) < urgency($1) }
    }

    private func runs(in mission: String) -> [FleetRun] {
        fleet.runs.filter { $0.mission == mission }.sorted { $0.status.urgency < $1.status.urgency }
    }

    private func urgency(_ mission: String) -> Int {
        runs(in: mission).first?.status.urgency ?? .max
    }

    private func bot(named name: String) -> MuxRole? {
        bots.first { $0.name == name }
    }
}

private struct RunRow: View {
    let run: FleetRun
    let askBot: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(run.title).font(AppFont.body(.semibold))
                Spacer()
                Text(run.status.label)
                    .font(AppFont.caption(.semibold))
                    .foregroundStyle(tint)
            }
            Text("\(run.botName) · \(run.machine) · \(run.model) · \(run.minutesElapsed) min")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
            if let askBot {
                Button("Ask \(run.botName) about this", action: askBot)
                    .font(AppFont.footnote(.semibold))
                    .buttonStyle(.borderless)
            }
        }
    }

    private var tint: Color {
        switch run.status {
        case .running: .brandBlue
        case .queued: .secondary
        case .needsYou: .brandOrange
        case .done: .brandGreenAccessible
        case .failed: .brandRed
        }
    }
}
