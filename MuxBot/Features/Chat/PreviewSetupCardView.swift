import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The "set up the preview" card: the recipe worked out from the project's
/// own files, each value editable with where it was found. Approve asks you
/// to confirm your checkout's folder (Mux Bot's bookmark is read-only),
/// writes exactly this file there, uncommitted, never over one that exists,
/// then keeps it for the next pull request.
struct PreviewSetupCardView: View {
    let message: ChatMessage
    @State var setup: PreviewSetup

    @Environment(\.modelContext) private var context
    @Environment(BotBrain.self) private var brain
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label(setup.framework.map { "Set up the preview (\($0))" } ?? "Set up the preview", systemImage: "play.rectangle")
                .font(AppFont.headline())
            if message.actionState == .waiting {
                field("Command", text: $setup.command.value, source: setup.command.source)
                field("Install", text: $setup.install.value, source: setup.install.source)
                field("Environment", text: $setup.env.value, source: setup.env.source)
                field("Ready when this page answers", text: $setup.ready.value, source: setup.ready.source)
                if !setup.hotReload.value.isEmpty {
                    LabeledContent("Hot reload", value: setup.hotReload.value).font(AppFont.footnote())
                    if let source = setup.hotReload.source { note(source) }
                }
                if !setup.envFromSource.isEmpty {
                    note(String(localized: "Copies \(setup.envFromSource.joined(separator: ", ")) from your checkout into darkmux's copy (never committed)."))
                }
                Text("Approve writes \(PreviewSetup.path) into your folder \(setup.folderName), uncommitted, and adds it to this bot's next pull request. It never replaces a file that's already there.")
                    .font(AppFont.footnote()).fixedSize(horizontal: false, vertical: true)
                if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(AppFont.footnote()) }
                HStack {
                    Button("Cancel", role: .cancel) { brain.resolve(message, approve: false, store: BotStore(context: context)) }
                        .buttonStyle(.bordered)
                    Spacer()
                    #if os(macOS)
                    Button("Approve") { approve() }
                        .buttonStyle(.borderedProminent)
                        .disabled(setup.recipeData == nil)
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

    private func field(_ label: LocalizedStringKey, text: Binding<String>, source: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(label, text: text, prompt: Text("Not found: fill it in"))
                .font(.system(.footnote, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            note(source ?? String(localized: "Not found in the project's files."))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(AppFont.caption()).foregroundStyle(Color.secondaryText).fixedSize(horizontal: false, vertical: true)
    }

    #if os(macOS)
    private func approve() {
        guard let bot = message.conversation?.roleId.flatMap({ BotStore(context: context).bot(id: $0) }),
              let data = setup.recipeData else { return }
        let checkout = bot.folderBookmark.flatMap(RunCoordinator.resolve(bookmark:))
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = checkout?.deletingLastPathComponent()
        panel.message = String(localized: "Choose \(setup.folderName) to let Mux Bot write \(PreviewSetup.path) into it.")
        panel.prompt = String(localized: "Write here")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        if let checkout, !PreviewSetup.sameFolder(chosen, checkout) {
            problem = PreviewSetup.WriteError.notYourCheckout(setup.folderName).localizedDescription
            return
        }
        let accessing = chosen.startAccessingSecurityScopedResource()
        defer { if accessing { chosen.stopAccessingSecurityScopedResource() } }
        do {
            try PreviewSetup.write(data, into: chosen)
        } catch {
            problem = error.localizedDescription
            return
        }
        // The card keeps exactly what was written.
        message.actionJSON = (try? JSONEncoder().encode(BotAction.setUpPreview(setup))).flatMap { String(data: $0, encoding: .utf8) }
        brain.resolve(message, approve: true, store: BotStore(context: context))
    }
    #endif
}
