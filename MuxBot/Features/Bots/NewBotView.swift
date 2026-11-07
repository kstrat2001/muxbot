import SwiftUI

struct NewBotView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var instructions = ""
    @State private var modelName = ""
    @State private var resource = ""

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
                TextField("GitHub URL, folder or link (optional)", text: $resource)
                    .autocorrectionDisabled()
            } header: {
                Text("Resource")
            } footer: {
                Text("Add more later from the bot's info.")
            }
            Section("Model") {
                TextField("Default model", text: $modelName)
                    .autocorrectionDisabled()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("New bot")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let store = BotStore(context: context)
                    let bot = store.add(name: name, instructions: instructions, modelName: modelName)
                    let value = resource.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { store.addResource(ResourceKind.guess(for: value), value, to: bot) }
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }
}
