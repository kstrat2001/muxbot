import SwiftUI
import SwiftData

/// The work your bots started: what needs you, what's running, what
/// recently finished. Read-only apart from Stop; tapping a run opens its
/// bot's conversation at the run's card, where Keep / Tweak / Discard live.
struct WorkView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Environment(BotBrain.self) private var brain
    @Query private var runs: [BotRun]

    var body: some View {
        let sections = WorkSections(runs: runs)
        Group {
            if sections.isEmpty {
                EmptyStateView(systemImage: "checklist", title: "Nothing running",
                               message: "Ask a bot to start something.")
            } else {
                List {
                    section(sections.needsYou, kind: .needsYou)
                    section(sections.running, kind: .running)
                    section(sections.finished, kind: .done)
                }
            }
        }
        .navigationTitle("Work")
    }

    @ViewBuilder private func section(_ items: [BotRun], kind: StatusKind) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { run in
                    Button { router.open(run) } label: { WorkRow(run: run) }
                        .buttonStyle(.plain)
                }
            } header: {
                StatusBadge(kind: kind).accessibilityLabel(kind.accessibilityLabel)
            }
        }
    }
}

private struct WorkRow: View {
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
                    Text(Self.machine)
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

    private var kind: StatusKind {
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
