import SwiftUI

/// Settings › Models: how runs pick their model on this Mac. Auto (the
/// app's order), a default model, or ask on every dispatch card; each bot
/// can override it in its info.
struct ModelSettingsView: View {
    @Environment(BotBrain.self) private var brain
    @State private var settings = ModelSettings()
    @State private var listed: [DarkmuxClient.ProfileInfo] = []
    #if os(iOS)
    @State private var editMode = EditMode.inactive
    #endif

    var body: some View {
        Form {
            Section {
                Picker("Choosing the model", selection: modeBinding) {
                    Text("Auto").tag(ModelMode.auto)
                    Text("Always ask").tag(ModelMode.ask)
                    ForEach(names, id: \.self) { name in Text("Always \(row(name).line)").tag(ModelMode.model(name)) }
                    // A saved model this Mac doesn't list keeps a row, so the picker shows it.
                    if let name = ModelMode.unlistedModel(settings.mode, listed: names) {
                        if let line = ModelLabel.line(name, in: listed) { Text("Always \(line)").tag(ModelMode.model(name)) }
                        else if brain.runs.listing == .listed { Text("Always a model this Mac doesn't list").tag(ModelMode.model(name)) }
                        else { Text("Always the model you chose").tag(ModelMode.model(name)) }
                    }
                }
                .disabled(brain.runs.knownMachine == nil)
                Text(explanation).font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                if brain.runs.knownMachine == nil {
                    Text("These are saved for darkmux's machine, so they wait until darkmux on your Mac has answered once.")
                        .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                }
                listingNote
            } header: {
                Text("On \(brain.runs.machinePhrase)")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Each machine has its own models, so this is set per machine and shared with your other devices.")
                    if !brain.runs.fitOrder.isEmpty {
                        Link("Listed by fit: how each model did on Macs like this one", destination: EvalsFit.site)
                    }
                }
                .font(AppFont.caption())
            }
            Section {
                ForEach(Array(settings.order.enumerated()), id: \.element) { index, name in
                    orderRow(row(name), index: index)
                }
                .onMove { settings.order.move(fromOffsets: $0, toOffset: $1); save() }
                .onDelete { settings.order.remove(atOffsets: $0); save() }
                let more = names.filter { name in !settings.order.contains(name) && !orderHasModel(of: name) }
                if !more.isEmpty {
                    Menu("Add a model", systemImage: "plus") {
                        ForEach(more, id: \.self) { name in
                            Button(row(name).line) { settings.order.append(name); save() }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Auto order")
                    #if os(iOS)
                    Spacer()
                    EditButton()
                    #endif
                }
            } footer: {
                Text("Fastest first. A run whose done-when wasn't met moves to the next one.")
                    .font(AppFont.caption())
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .environment(\.editMode, $editMode)
        #endif
        .task { await load() }
    }

    @ViewBuilder private var listingNote: some View {
        switch brain.runs.listing {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Looking at this Mac's models…").font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
            }
        case let .failed(reason):
            HStack(alignment: .firstTextBaseline) {
                Label("Couldn't get this Mac's models from darkmux: \(reason)", systemImage: "exclamationmark.triangle")
                    .font(AppFont.footnote()).labelStyle(.tintedIcon(Color.brandOrange))
                Spacer()
                Button("Try again") { Task { await load() } }
            }
        case .listed:
            EmptyView()
        }
    }

    private func orderRow(_ r: ModelRow, index: Int) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).lineLimit(1)
                if let engine = r.subtitle {
                    Text(engine).font(AppFont.caption()).foregroundStyle(Color.secondaryText).lineLimit(1)
                }
            }
            .help(r.detail ?? r.line)
            Spacer()
            if let label = r.status.label { badge(label, r.status) }
            #if os(macOS)
            Button("Move up", systemImage: "chevron.up") { move(index, by: -1) }
                .disabled(index == 0)
            Button("Move down", systemImage: "chevron.down") { move(index, by: 1) }
                .disabled(index == settings.order.count - 1)
            Button("Remove", systemImage: "minus.circle") { settings.order.remove(at: index); save() }
            #endif
        }
        #if os(macOS)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        #endif
    }

    private func badge(_ label: String, _ status: ModelRow.Status) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color(status)).frame(width: 7, height: 7)
            Text(label).font(AppFont.caption())
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(color(status).opacity(0.12), in: Capsule())
    }

    private func color(_ status: ModelRow.Status) -> Color {
        switch status {
        case .running: .green
        case .loadsWhenUsed: .blue
        case .notRunning: .orange
        case .notHere, .unknown: .secondary
        }
    }

    /// The order already has this model and engine under another profile.
    private func orderHasModel(of name: String) -> Bool {
        let line = row(name).line
        return settings.order.contains { saved in row(saved).line == line && listed.contains { $0.name == saved } }
    }

    private func row(_ name: String) -> ModelRow { ModelRow(name: name, listed: listed, listing: brain.runs.listing) }

    /// One per model and engine (darkmux lists a profile per lab setup).
    private var names: [String] { brain.runs.modelChoices(listed).map(\.name) }

    private func load() async {
        brain.runs.listing = .loading
        async let fit: Void = brain.runs.loadFitOrder()
        listed = await brain.runs.listedProfiles()
        await fit
        // The listing names the machine; its settings are keyed by it.
        settings = brain.runs.currentModelSettings()
    }

    private func move(_ index: Int, by step: Int) {
        let to = index + step
        guard settings.order.indices.contains(to) else { return }
        settings.order.swapAt(index, to)
        save()
    }

    /// Saved for darkmux's machine only once it's known (never a placeholder).
    private func save() {
        guard let machine = brain.runs.knownMachine else { return }
        brain.runs.settingsStore.save(settings, machine: machine.id)
    }

    private var modeBinding: Binding<ModelMode> {
        Binding(get: { settings.mode }, set: { settings.mode = $0; save() })
    }

    private var explanation: String {
        switch settings.mode {
        case .auto: String(localized: "Mux Bot picks: the first in the Auto order that's running.")
        case .ask: String(localized: "Each dispatch card asks, with Auto's pick ready.")
        case let .model(name): String(localized: "Every run uses \(row(name).line). If it isn't running, the card says so.")
        }
    }
}
