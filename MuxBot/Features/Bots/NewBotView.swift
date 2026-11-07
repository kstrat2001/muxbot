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

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Form {
            Section("Name") {
                TextField("e.g. Life coach, my website, Daily update", text: $name)
            }
            Section {
                TextField("What this bot is about", text: $instructions, axis: .vertical)
                    .lineLimit(3...6)
            } header: {
                Text("About")
            } footer: {
                Text("\(LeadBot.name) reads this to send the right work here.")
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
        .navigationTitle("New bot")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let store = BotStore(context: context)
                    let bot = store.add(name: name, instructions: instructions, modelName: "")
                    let value = resource.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        let kind = ResourceKind.guess(for: value)
                        store.addResource(ResourceKind.addable.contains(kind) ? kind : .note, value, to: bot)
                    }
                    if let folder { Task { await brain.addFolder(folder, to: bot, store: store) } }
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }
}
