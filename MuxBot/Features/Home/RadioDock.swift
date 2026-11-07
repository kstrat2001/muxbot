import SwiftUI
import SwiftData

/// Bottom dock: type a request to Radio, review its plan, then Approve or
/// Cancel. The mic is a placeholder until speech input lands.
struct RadioDock: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Environment(RadioPlanner.self) private var radio
    @Query(sort: \MuxRole.createdAt) private var roles: [MuxRole]

    @State private var draft = ""
    @FocusState private var focused: Bool

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
                TextField("Ask Radio for new work", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($focused)
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
        .onChange(of: router.focusRadio) {
            if router.focusRadio { focused = true; router.focusRadio = false }
        }
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        let summaries = roles.map(\.summary)
        Task { await radio.submit(text, roles: summaries) }
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
                    Text("Add a new role: \(draft.name)").font(AppFont.headline())
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
