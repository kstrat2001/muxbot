import SwiftUI
import SwiftData

/// A bot's details and the resources it works with: repos, folders,
/// preview recipes, links and notes. Bots can also propose resources in
/// conversation, behind an Approve card.
struct BotInfoView: View {
    let bot: Bot

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var newValue = ""
    @State private var newKind = ResourceKind.repo

    var body: some View {
        Form {
            Section("About") {
                Label(bot.name, systemImage: bot.systemImage).font(AppFont.headline())
                Text(bot.instructions).foregroundStyle(.secondary)
            }
            Section("Resources") {
                ForEach(bot.sortedResources) { resource in
                    Label {
                        Text(resource.value).textSelection(.enabled)
                    } icon: {
                        Image(systemName: resource.kind.systemImage)
                    }
                    .accessibilityLabel("\(resource.kind.label): \(resource.value)")
                }
                .onDelete { offsets in
                    let store = BotStore(context: context)
                    offsets.map { bot.sortedResources[$0] }.forEach(store.remove)
                }
                if bot.sortedResources.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
            }
            Section("Add a resource") {
                Picker("Kind", selection: $newKind) {
                    ForEach(ResourceKind.allCases, id: \.self) { kind in
                        Label(kind.label, systemImage: kind.systemImage).tag(kind)
                    }
                }
                TextField("URL, path or note", text: $newValue)
                    .autocorrectionDisabled()
                    .onChange(of: newValue) { newKind = ResourceKind.guess(for: newValue) }
                Button("Add", systemImage: "plus") {
                    BotStore(context: context).addResource(newKind, newValue, to: bot)
                    newValue = ""
                }
                .disabled(newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(bot.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
}
