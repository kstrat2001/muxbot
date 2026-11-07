import SwiftUI

struct NewRoleView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var instructions = ""
    @State private var modelName = ""

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Form {
            Section("Name") {
                TextField("e.g. Release helper", text: $name)
            }
            Section {
                TextField("What this bot does", text: $instructions, axis: .vertical)
                    .lineLimit(3...6)
            } header: {
                Text("Role")
            } footer: {
                Text("Bots read this to decide who gets new work.")
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
                    RoleStore(context: context).add(name: name, instructions: instructions, modelName: modelName)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }
}
