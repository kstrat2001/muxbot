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
            TableColumn("Machine") { _ in Text(ActivityRow.machine).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 110)
            TableColumn("Started", value: \.createdAt) { run in
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(ActivityTime.started(run.startedAt ?? run.createdAt, now: context.date))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
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
                    Text(run.durationSeconds.map(ActivityTime.duration) ?? "").monospacedDigit().foregroundStyle(.secondary)
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
                Button("Stop", role: .destructive) { Task { await brain.stop(run, store: BotStore(context: context)) } }
                Button("Keep running", role: .cancel) {}
            }
    }
}
#endif

private struct ActivityRow: View {
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
                            Text(Self.elapsed(from: run.createdAt, to: context.date)).monospacedDigit()
                        }
                    }
                }
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            StatusBadge(kind: kind)
            if run.phase == .running {
                Button("Stop this run", systemImage: "stop.circle") { confirmStop = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .confirmationDialog("Stop this run?", isPresented: $confirmStop) {
                        Button("Stop", role: .destructive) { Task { await brain.stop(run, store: BotStore(context: context)) } }
                        Button("Keep running", role: .cancel) {}
                    }
            }
        }
        .contentShape(Rectangle())
    }

    private var kind: StatusKind { Self.kind(of: run) }

    static func kind(of run: BotRun) -> StatusKind {
        switch run.phase {
        case .running: .running
        case .proposed, .result, .kept: .needsYou
        case .failed, .discarded: .failed
        case .canceled: .failed
        default: .done
        }
    }

    static var machine: String {
        ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s >= 3600 ? "\(s / 3600)h \((s % 3600) / 60)m" : "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}
