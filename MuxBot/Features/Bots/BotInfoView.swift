import SwiftUI
import SwiftData

/// A bot's details and the resources it works with: repos, folders,
/// preview recipes, links and notes. Bots can also propose resources in
/// conversation, behind an Approve card.
struct BotInfoView: View {
    let bot: Bot

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(BotBrain.self) private var brain
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
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(resource.value).textSelection(.enabled)
                            if resource.kind == .folder, resource.value.contains("/.darkmux/worktrees/") {
                                Text("Work copy · darkmux runs here")
                                    .font(AppFont.caption())
                                    .foregroundStyle(.secondary)
                            }
                            if resource.kind == .previewURL {
                                Text("Temporary test server, until darkmux reports each run's live URL.")
                                    .font(AppFont.caption())
                                    .foregroundStyle(.secondary)
                            }
                        }
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
            Section("Preview") {
                ForEach(bot.repoSlugs, id: \.self) { repo in
                    recipeRow(repo)
                }
                if bot.repoSlugs.isEmpty {
                    Text("Add a repo and I'll look for its preview recipe.").foregroundStyle(.secondary)
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
        .task {
            for repo in bot.repoSlugs { await brain.loadRecipe(for: repo, localWorkdir: FleetConnection.workdir(for: bot)) }
        }
        .navigationTitle(bot.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    @ViewBuilder private func recipeRow(_ repo: String) -> some View {
        switch brain.recipes[repo] {
        case let .ready(manifest, fromLocalCopy)?:
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label("Preview ready · from \(fromLocalCopy ? "the local copy" : "GitHub")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.brandGreen)
                Text(manifest.summary).font(AppFont.footnote()).foregroundStyle(.secondary)
                Text(repo).font(AppFont.caption()).foregroundStyle(.secondary)
            }
        case .missing?:
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("No preview recipe yet")
                    Text("\(repo) has no \(PreviewManifest.path)").font(AppFont.caption()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Draft one") {}
                    .disabled(true)
                    .help("Coming soon: a bot drafts the recipe for you to approve.")
            }
        case .failed(let message)?:
            Label("Couldn't check \(repo): \(message)", systemImage: "exclamationmark.triangle")
                .font(AppFont.footnote())
        case .loading?, nil:
            ProgressView().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
