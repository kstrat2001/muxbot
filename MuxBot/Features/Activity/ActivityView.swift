import SwiftUI
import SwiftData

/// The work your bots started: what needs you, what's running, what
/// recently finished. Read-only apart from Stop; tapping a run opens its
/// bot's conversation at the run's card, where Keep / Tweak / Discard live.
struct ActivityView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Environment(BotBrain.self) private var brain
    @Query private var runs: [BotRun]

    var body: some View {
        let sections = ActivitySections(runs: runs)
        Group {
            if sections.isEmpty {
                EmptyStateView(systemImage: "waveform.path.ecg", title: "Nothing running",
                               message: "Ask a bot to start something.")
            } else {
                #if os(macOS)
                ActivityTable(sections: sections)
                #else
                List {
                    section(sections.needsYou, kind: .needsYou)
                    section(sections.running, kind: .running)
                    section(sections.finished, kind: .done)
                }
                #endif
            }
        }
        .navigationTitle("Activity")
    }

    @ViewBuilder private func section(_ items: [BotRun], kind: StatusKind) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { run in
                    Button { router.open(run) } label: { ActivityRow(run: run) }
                        .buttonStyle(.plain)
                }
            } header: {
                StatusBadge(kind: kind).accessibilityLabel(kind.accessibilityLabel)
            }
        }
    }
}

#if os(macOS)
/// Mac: a sortable table. Default order: needs you, running, finished,
/// newest first in each.
private struct ActivityTable: View {
    let sections: ActivitySections

    @Environment(AppRouter.self) private var router
    @State private var selection: BotRun.ID?
    @State private var sortOrder: [KeyPathComparator<BotRun>] = [
        KeyPathComparator(\.statusRank), KeyPathComparator(\.createdAt, order: .reverse),
    ]

    private var rows: [BotRun] {
        (sections.needsYou + sections.running + sections.finished).sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("", value: \.statusRank) { run in StatusBadge(kind: ActivityRow.kind(of: run)) }
                .width(28)
            TableColumn("Task", value: \.task) { run in Text(run.task).lineLimit(1) }
            TableColumn("Bot", value: \.botName) { run in Text(run.botName) }
                .width(min: 90, ideal: 130)
            TableColumn("Role", value: \.crewName) { run in
                Label(run.crew.name, systemImage: run.crew.systemImage)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Machine") { run in Text(ActivityRow.machine(for: run)).foregroundStyle(Color.secondaryText) }
                .width(min: 80, ideal: 110)
            TableColumn("Started", value: \.createdAt) { run in
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(ActivityTime.started(run.startedAt ?? run.createdAt, now: context.date))
                        .monospacedDigit()
                        .foregroundStyle(Color.secondaryText)
                }
                .help((run.startedAt ?? run.createdAt).formatted(date: .complete, time: .standard))
            }
            .width(min: 100, ideal: 130)
            TableColumn("Duration", value: \.durationSort) { run in
                if run.phase == .running {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(run.durationSeconds.map(ActivityTime.duration) ?? "").monospacedDigit()
                    }
                } else {
                    Text(run.durationSeconds.map(ActivityTime.duration) ?? "").monospacedDigit().foregroundStyle(Color.secondaryText)
                }
            }
            .width(min: 60, ideal: 70)
            TableColumn("") { run in
                if run.phase == .running { StopButton(run: run) }
            }
            .width(28)
        }
        .onChange(of: selection) {
            guard let id = selection, let run = rows.first(where: { $0.id == id }) else { return }
            router.open(run)
            selection = nil
        }
    }
}

private struct StopButton: View {
    let run: BotRun
    @Environment(\.modelContext) private var context
    @Environment(BotBrain.self) private var brain
    @State private var confirm = false

    var body: some View {
        Button("Stop this run", systemImage: "stop.circle") { confirm = true }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .confirmationDialog("Stop this run?", isPresented: $confirm) {
                Button("Stop", role: .destructive) { Task { await brain.runs.stop(run, store: BotStore(context: context)) } }
                Button("Keep running", role: .cancel) {}
            }
    }
}
#endif

struct ActivityRow: View {
    let run: BotRun

    @Environment(\.modelContext) private var context
    @Environment(BotBrain.self) private var brain
    @State private var confirmStop = false

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: run.crew.systemImage)
                .foregroundStyle(Color.brandGreen)
                .frame(width: 22)
                .accessibilityLabel(run.crew.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.task).lineLimit(1)
                HStack(spacing: Spacing.xs) {
                    Text(run.bot?.name ?? "")
                    Text("·")
                    Text(ActivityTime.started(run.startedAt ?? run.createdAt))
                    if run.phase == .running {
                        Text("·")
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Self.elapsed(from: Self.timerStart(run), to: context.date)).monospacedDigit()
                        }
                    }
                }
                .font(AppFont.caption())
                .foregroundStyle(Color.secondaryText)
            }
            Spacer(minLength: 0)
            StatusBadge(kind: kind)
            if run.phase == .running {
                Button("Stop this run", systemImage: "stop.circle") { confirmStop = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .confirmationDialog("Stop this run?", isPresented: $confirmStop) {
                        Button("Stop", role: .destructive) { Task { await brain.runs.stop(run, store: BotStore(context: context)) } }
                        Button("Keep running", role: .cancel) {}
                    }
            }
        }
        .contentShape(Rectangle())
    }

    private var kind: StatusKind { Self.kind(of: run) }

    /// The badge: Needs you only for what waits on you here (a hidden one
    /// doesn't); a committed result is done.
    static func kind(of run: BotRun) -> StatusKind {
        if NeedsYou.isWaiting(run) { return .needsYou }
        switch run.phase {
        case .running: return .running
        case .failed, .discarded, .canceled: return .failed
        default: return .done
        }
    }

    /// This Mac's name, looked up once (the lookup is slow).
    @MainActor static let thisMac = FleetConnection.machineName

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s >= 3600 ? "\(s / 3600)h \((s % 3600) / 60)m" : "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}

extension ActivityRow {
    /// A running run's timer counts from when it started, not from when its
    /// card was proposed.
    @MainActor static func timerStart(_ run: BotRun) -> Date { run.startedAt ?? run.createdAt }

    /// The Mac the run is on: the bot's work copy's for one started here,
    /// else another Mac (its own runs aren't followed from here).
    @MainActor static func machine(for run: BotRun) -> String {
        guard run.startedHere else { return String(localized: "Another Mac") }
        return run.bot?.workspaceMachine ?? thisMac
    }
}
