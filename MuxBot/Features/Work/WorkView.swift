import SwiftUI
import SwiftData

/// Read-only view of the work your bots started: runs grouped by bot, then
/// mission, in progress first, then what needs you, then finished. Machines
/// and models appear only as run details. Nothing here acts; "Ask <bot>
/// about this" opens that bot's thread.
struct WorkView: View {
    @Environment(BotBrain.self) private var brain
    @Environment(AppRouter.self) private var router
    @Query(sort: \Bot.createdAt) private var bots: [Bot]

    private var fleet: FleetSnapshot { brain.fleet }

    var body: some View {
        List {
            if !fleet.isConnected {
                Label("Fleet not connected. This is sample data.", systemImage: "wifi.slash")
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
            }
            ForEach(botNames, id: \.self) { botName in
                Section {
                    ForEach(missions(for: botName), id: \.self) { mission in
                        Text(mission)
                            .font(AppFont.subheadline(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(runs(for: botName, in: mission)) { run in
                            RunRow(run: run, askBot: bot(named: run.botName).map { b in
                                { router.ask(.bot(b.id), draft: "About “\(run.title)”: ") }
                            })
                        }
                    }
                } header: {
                    Label(botName, systemImage: bot(named: botName)?.systemImage ?? "sparkles")
                }
            }
        }
        .navigationTitle("Work")
    }

    private func ordered(_ names: [String], by urgency: (String) -> Int) -> [String] {
        names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.sorted { urgency($0) < urgency($1) }
    }

    /// Bots ordered by their most urgent run, so live work comes first.
    private var botNames: [String] {
        ordered(fleet.runs.map(\.botName)) { name in fleet.runs.filter { $0.botName == name }.map(\.status.urgency).min() ?? .max }
    }

    private func missions(for botName: String) -> [String] {
        let mine = fleet.runs.filter { $0.botName == botName }
        return ordered(mine.map(\.mission)) { m in mine.filter { $0.mission == m }.map(\.status.urgency).min() ?? .max }
    }

    private func runs(for botName: String, in mission: String) -> [FleetRun] {
        fleet.runs.filter { $0.botName == botName && $0.mission == mission }.sorted { $0.status.urgency < $1.status.urgency }
    }

    private func bot(named name: String) -> Bot? {
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
                StatusBadge(kind: run.status.kind)
            }
            Label("\(run.crew.name) · \(run.machine) · \(run.model) · \(run.minutesElapsed) min", systemImage: run.crew.systemImage)
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
            if let askBot {
                Button("Ask \(run.botName) about this", action: askBot)
                    .font(AppFont.footnote(.semibold))
                    .buttonStyle(.borderless)
            }
        }
    }
}
