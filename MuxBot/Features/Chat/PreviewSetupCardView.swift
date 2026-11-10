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
    /// The pending write of your edits into the card (debounced).
    @State private var keeping: Task<Void, Never>?

    var body: some View {
        content
            // Edits are written back into the card, so leaving the thread
            // never loses them.
            .onChange(of: setup) { keep() }
            .onDisappear { keeping?.cancel(); save() }
    }

    private func keep() {
        keeping?.cancel()
        keeping = Task { try? await Task.sleep(for: .milliseconds(500)); if !Task.isCancelled { save() } }
    }

    private func save() {
        BotStore(context: context).updateAction(message, to: .setUpPreview(setup))
    }

    private var content: some View {
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
        if let why = CheckoutWrite.approve(data, at: PreviewSetup.path, bot: bot, folderName: setup.folderName) {
            problem = why
            return
        }
        // The card keeps exactly what was written.
        message.actionJSON = (try? JSONEncoder().encode(BotAction.setUpPreview(setup))).flatMap { String(data: $0, encoding: .utf8) }
        brain.resolve(message, approve: true, store: BotStore(context: context))
    }
    #endif
}

#if os(macOS)
/// Writing an approved file into your checkout: you choose its folder (the
/// bookmark Mux Bot keeps is read-only), it must be the bot's checkout, and
/// the file is written only as a new file. Returns why it wasn't written.
@MainActor
enum CheckoutWrite {
    static func approve(_ data: Data, at path: String, bot: Bot, folderName: String) -> String? {
        let checkout = bot.folderBookmark.flatMap(RunCoordinator.resolve(bookmark:))
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = checkout?.deletingLastPathComponent()
        panel.message = String(localized: "Choose \(folderName) to let Mux Bot write \(path) into it.")
        panel.prompt = String(localized: "Write here")
        guard panel.runModal() == .OK, let chosen = panel.url else { return String(localized: "Nothing was written.") }
        if let checkout, !PreviewSetup.sameFolder(chosen, checkout) {
            return PreviewSetup.WriteError.notYourCheckout(folderName).localizedDescription
        }
        let accessing = chosen.startAccessingSecurityScopedResource()
        defer { if accessing { chosen.stopAccessingSecurityScopedResource() } }
        do {
            try PreviewSetup.writeNew(data, at: path, into: chosen)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
#endif
