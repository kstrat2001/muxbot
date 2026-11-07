import SwiftUI
import SwiftData

/// Read-only view of the fleet: machines and the runs your bots started.
/// Nothing here acts; "Ask <bot> about this" opens that bot's thread.
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
            Section("Machines") {
                ForEach(fleet.machines) { machine in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack {
                            Text(machine.name).font(AppFont.headline())
                            Text(machine.chip).font(AppFont.caption()).foregroundStyle(.secondary)
                            Spacer()
                            Text(machine.isOnline ? "\(machine.freeMemoryGB) of \(machine.memoryGB) GB free" : "Offline")
                                .font(AppFont.footnote())
                                .foregroundStyle(machine.isOnline ? Color.secondary : Color.brandRed)
                        }
                        if machine.isOnline {
                            Text(machine.loadedModels.isEmpty ? "No models loaded" : machine.loadedModels.joined(separator: ", "))
                                .font(AppFont.caption())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            ForEach(missions, id: \.self) { mission in
                Section(mission) {
                    ForEach(fleet.runs.filter { $0.mission == mission }) { run in
                        RunRow(run: run, askBot: bot(named: run.botName).map { b in
                            { router.ask(.bot(b.id), draft: "About “\(run.title)”: ") }
                        })
                    }
                }
            }
        }
        .navigationTitle("Fleet")
    }

    private var missions: [String] {
        fleet.runs.reduce(into: [String]()) { if !$0.contains($1.mission) { $0.append($1.mission) } }
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
