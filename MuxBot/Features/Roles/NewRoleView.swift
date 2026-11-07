import SwiftUI

struct NewRoleView: View {
    @Environment(RoleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: MuxRole.Kind = .builder

    var body: some View {
        Form {
            Section("Name") {
                TextField("e.g. Release helper", text: $name)
            }
            Section("Kind") {
                Picker("Kind", selection: $kind) {
                    ForEach(MuxRole.Kind.allCases, id: \.self) { kind in
                        Label(kind.label, systemImage: kind.systemImage).tag(kind)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                Text("New roles start idle. Give them work through Radio.")
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("New role")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    store.add(name: name.trimmingCharacters(in: .whitespaces), kind: kind)
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
