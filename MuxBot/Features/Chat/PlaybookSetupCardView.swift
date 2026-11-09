import SwiftUI

/// The "add a PLAYBOOK.md" card: the project's persona and skills, all
/// editable, with the parts the on-device model drafted marked. Approve
/// asks you to confirm your checkout's folder, writes exactly this file
/// there, uncommitted, never over one that exists, and keeps it for the
/// next pull request.
struct PlaybookSetupCardView: View {
    let message: ChatMessage
    @State var setup: PlaybookSetup

    @Environment(\.modelContext) private var context
    @Environment(BotBrain.self) private var brain
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label("Add a PLAYBOOK.md", systemImage: "book.closed").font(AppFont.headline())
            if message.actionState == .waiting {
                if setup.drafted {
                    Label("The persona and conventions are drafted on this device from your README. Check them.", systemImage: "sparkles")
                        .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                }
                TextField("What is this project?", text: $setup.purpose, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder)
                Text("Persona").font(AppFont.caption(.semibold))
                editor($setup.persona)
                ForEach($setup.skills, id: \.name) { $skill in
                    DisclosureGroup(skill.name) { editor($skill.body) }
                        .font(AppFont.footnote())
                }
                Text("Approve writes \(PlaybookSetup.path) into your folder \(setup.folderName), uncommitted, and adds it to this bot's next pull request. It never replaces a file that's already there.")
                    .font(AppFont.footnote()).fixedSize(horizontal: false, vertical: true)
                if setup.parsed == nil {
                    Label("It needs a persona and at least one skill.", systemImage: "exclamationmark.triangle").font(AppFont.footnote())
                }
                if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(AppFont.footnote()) }
                HStack {
                    Button("Cancel", role: .cancel) { brain.resolve(message, approve: false, store: BotStore(context: context)) }
                        .buttonStyle(.bordered)
                    Spacer()
                    #if os(macOS)
                    Button("Approve") { approve() }
                        .buttonStyle(.borderedProminent)
                        .disabled(setup.parsed == nil)
                    #else
                    Text("Approve it in Mux Bot on your Mac.").font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                    #endif
                }
            } else {
                Label(message.actionState == .approved ? "Written into \(setup.folderName)" : "Canceled",
                      systemImage: message.actionState == .approved ? "checkmark.circle" : "xmark.circle")
                    .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
            }
        }
    }

    private func editor(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(.footnote))
            .frame(minHeight: 70, maxHeight: 160)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(Color.secondaryText.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    #if os(macOS)
    private func approve() {
        guard let bot = message.conversation?.roleId.flatMap({ BotStore(context: context).bot(id: $0) }), setup.parsed != nil else { return }
        if let why = CheckoutWrite.approve(setup.data, at: PlaybookSetup.path, bot: bot, folderName: setup.folderName) {
            problem = why
            return
        }
        message.actionJSON = (try? JSONEncoder().encode(BotAction.setUpPlaybook(setup))).flatMap { String(data: $0, encoding: .utf8) }
        brain.resolve(message, approve: true, store: BotStore(context: context))
    }
    #endif
}
