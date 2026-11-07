import SwiftUI
import UniformTypeIdentifiers

struct NewBotView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(BotBrain.self) private var brain
    @State private var name = ""
    @State private var instructions = ""
    @State private var resource = ""
    @State private var folder: URL?
    @State private var pickingFolder = false
    @State private var look = BotLook.suggested(for: "")

    /// Step 1 is the bot itself (face and name); step 2 is what it works on.
    @State private var onDetails = false

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Group {
            if onDetails { details } else { face }
        }
        .navigationTitle(onDetails ? name : "New bot")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if onDetails { Button("Back") { onDetails = false } } else { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                if onDetails {
                    Button("Create") { create() }.disabled(!canSave)
                } else {
                    Button("Next") { onDetails = true }.disabled(!canSave)
                }
            }
        }
    }

    /// The avatar first: a big live preview, the name, then animal and colors.
    private var face: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                BotAvatarView(look: look, mood: .idle, size: 150)
                TextField("Name your bot", text: $name)
                    .multilineTextAlignment(.center)
                    .font(AppFont.headline())
                    .textFieldStyle(.plain)
                    .padding(Spacing.md)
                    .background(RoundedRectangle(cornerRadius: CornerRadius.md).strokeBorder(.secondary.opacity(0.4)))
                    .onSubmit { if canSave { onDetails = true } }
                BotLookPicker(look: $look, showsPreview: false)
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }

    private var details: some View {
        Form {
            Section {
                HStack(spacing: Spacing.md) {
                    BotAvatarView(look: look, size: 44)
                    Text(name).font(AppFont.headline())
                }
            }
            Section {
                TextField("What this bot is about", text: $instructions, axis: .vertical)
                    .lineLimit(3...6)
            } header: {
                Text("About")
            } footer: {
                Text("\(LeadBot.name) reads this to send the right work here. You can change it later in the bot's info.")
            }
            Section {
                #if os(macOS)
                HStack {
                    Button(folder == nil ? "Add folder…" : "Change folder…", systemImage: "folder.badge.plus") { pickingFolder = true }
                    if let folder { Text(folder.lastPathComponent).foregroundStyle(.secondary) }
                }
                #endif
                TextField("GitHub URL or link (optional)", text: $resource)
                    .autocorrectionDisabled()
            } header: {
                Text("Code and links")
            } footer: {
                Text("A project folder you already have, or a GitHub repo. Add more later from the bot's info.")
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { folder = url }
        }
    }

    private func create() {
        let store = BotStore(context: context)
        let bot = store.add(name: name, instructions: instructions)
        bot.look = look
        try? context.save()
        let value = resource.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            let kind = ResourceKind.guess(for: value)
            store.addResource(ResourceKind.addable.contains(kind) ? kind : .note, value, to: bot)
        }
        if let folder { Task { await brain.runs.addFolder(folder, to: bot, store: store) } }
        dismiss()
    }
}
