import SwiftUI
import SwiftData

/// The one Radio dock, owned by the root view so it stays on screen across
/// navigation. On a role's chat it talks about that role. Type a request,
/// review the plan, then Approve or Cancel. The mic is a placeholder.
struct RadioDock: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Environment(RadioPlanner.self) private var radio
    @Query(sort: \MuxRole.createdAt) private var roles: [MuxRole]

    @State private var draft = ""

    private var contextRole: MuxRole? {
        guard let id = router.context.roleId else { return nil }
        return roles.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: Spacing.md) {
            if let plan = radio.plan {
                PlanCard(plan: plan, note: radio.fallbackNote,
                         approve: { radio.approve(in: RoleStore(context: context)) },
                         cancel: { radio.cancel() })
            } else if radio.isThinking {
                ProgressView("Radio is thinking…")
                    .font(AppFont.footnote())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: Spacing.sm) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(Color.brandGreen)
                    .accessibilityHidden(true)
                TextField(contextRole.map { "Ask Radio about \($0.name)…" } ?? "Ask Radio for new work", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                    .accessibilityLabel("Ask Radio")
                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || radio.isThinking)
                Button("Talk to Radio (coming soon)", systemImage: "mic.fill") {}
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .disabled(true)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(.bar)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        let summaries = roles.map(\.summary)
        let focus = contextRole?.id
        Task { await radio.submit(text, roles: summaries, focus: focus) }
    }
}

private struct PlanCard: View {
    let plan: RadioPlan
    let note: String?
    let approve: () -> Void
    let cancel: () -> Void

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                switch plan {
                case let .assign(_, roleName, task, why):
                    Text("Give \(roleName) this task").font(AppFont.headline())
                    Text(task).font(AppFont.body())
                    Text(why).font(AppFont.footnote()).foregroundStyle(.secondary)
                case let .newRole(draft, why):
                    Text("New bot: \(draft.name)").font(AppFont.headline())
                    Text(draft.instructions).font(AppFont.body())
                    Text(why).font(AppFont.footnote()).foregroundStyle(.secondary)
                }
                if let note {
                    Label(note, systemImage: "info.circle")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Cancel", role: .cancel, action: cancel).buttonStyle(.bordered)
                    Spacer()
                    Button("Approve", action: approve).buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
