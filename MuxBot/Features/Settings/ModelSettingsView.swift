import SwiftUI

/// Settings › Models: how runs pick their model on this Mac. Auto (the
/// app's order), a default model, or ask on every dispatch card; each bot
/// can override it in its info.
struct ModelSettingsView: View {
    @Environment(BotBrain.self) private var brain
    @State private var settings = ModelSettings()
    @State private var listed: [DarkmuxClient.ProfileInfo] = []

    var body: some View {
        Form {
            Section {
                Picker("Choosing the model", selection: modeBinding) {
                    Text("Auto").tag(ModelMode.auto)
                    Text("Always ask").tag(ModelMode.ask)
                    ForEach(names, id: \.self) { name in Text("Always \(name)").tag(ModelMode.model(name)) }
                }
                Text(explanation).font(AppFont.footnote()).foregroundStyle(.secondary)
            } header: {
                Text(brain.runs.machine.map { "On \($0.name)" } ?? "On this Mac")
            } footer: {
                Text("Each machine has its own models, so this is set per machine and shared with your other devices.").font(AppFont.caption())
            }
            Section("Auto order") {
                List {
                    ForEach(settings.order, id: \.self) { name in
                        HStack {
                            Text(name)
                            Spacer()
                            if let p = listed.first(where: { $0.name == name }) {
                                Text(p.reachable ? "running" : "not running").font(AppFont.caption()).foregroundStyle(.secondary)
                            } else if !listed.isEmpty {
                                Text("not on this Mac").font(AppFont.caption()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { settings.order.move(fromOffsets: $0, toOffset: $1); save() }
                    .onDelete { settings.order.remove(atOffsets: $0); save() }
                }
                let more = names.filter { !settings.order.contains($0) }
                if !more.isEmpty {
                    Menu("Add a model") {
                        ForEach(more, id: \.self) { name in Button(name) { settings.order.append(name); save() } }
                    }
                }
                Text("Fastest first. A run whose done-when wasn't met moves to the next one.")
                    .font(AppFont.footnote()).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            settings = brain.runs.currentModelSettings()
            listed = await brain.runs.listedProfiles()
        }
    }

    private var names: [String] { listed.map(\.name) }

    private func save() { brain.runs.settingsStore.save(settings, machine: brain.runs.machineKey) }

    private var modeBinding: Binding<ModelMode> {
        Binding(get: { settings.mode }, set: { settings.mode = $0; save() })
    }

    private var explanation: String {
        switch settings.mode {
        case .auto: String(localized: "Mux Bot picks: the first in the Auto order that's running.")
        case .ask: String(localized: "Each dispatch card asks, with Auto's pick ready.")
        case let .model(name): String(localized: "Every run uses \(name). If it isn't running, the card says so.")
        }
    }
}
