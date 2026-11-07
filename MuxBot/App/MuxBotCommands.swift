import SwiftUI
import SwiftData

/// Menu commands and shortcuts (macOS menu bar; iPad hardware keyboard).
struct MuxBotCommands: Commands {
    let router: AppRouter

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Bot…") { router.showNewBot = true }
                .keyboardShortcut("n")
        }
        CommandGroup(after: .textEditing) {
            Button("Search Bots and Messages…") { router.showSearch = true }
                .keyboardShortcut("f")
        }
        CommandMenu("Bot") {
            Button("Message the Bot") { router.focusBarRequest += 1 }
                .keyboardShortcut("l")
            Button(router.showPreview ? "Hide Preview" : "Show Preview") { router.showPreview.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            #if os(macOS)
            Button("Bot Info…") { router.showInfo() }
                .keyboardShortcut("i")
                .disabled(!router.canShowInfo)
            #endif
            Divider()
            Button("Pair with darkmux…") { router.showPairing = true }
        }
        CommandMenu("Go") {
            Button(LeadBot.name) { router.tab = .bots; router.navigate(to: .lead) }
                .keyboardShortcut("1")
            Button("Activity") { router.tab = .activity; router.sidebar = .activity }
                .keyboardShortcut("2")
        }
    }
}

#if os(macOS)
/// The menu bar item: what's running and what waits on you, a click away.
struct MenuBarRuns: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \BotRun.createdAt, order: .reverse) private var runs: [BotRun]

    private var waiting: [BotRun] { runs.filter(\.needsYou) }
    private var running: [BotRun] { runs.filter { $0.phase == .running } }

    var body: some View {
        if waiting.isEmpty && running.isEmpty {
            Text("Nothing running or waiting")
        }
        if !waiting.isEmpty {
            Section("Needs you") { ForEach(waiting.prefix(8)) { item($0) } }
        }
        if !running.isEmpty {
            Section("Running") { ForEach(running.prefix(8)) { item($0) } }
        }
        Divider()
        Button("Open Activity") { show { router.tab = .activity; router.sidebar = .activity } }
        Button("Open Mux Bot") { show {} }
    }

    private func item(_ run: BotRun) -> some View {
        Button("\(run.botName): \(run.task)") { show { router.open(run) } }
    }

    private func show(_ then: () -> Void) {
        then()
        openWindow(id: "main")
        NSApplication.shared.activate()
    }
}

/// The menu bar icon: busy while something runs, a count when work waits.
struct MenuBarLabel: View {
    @Query private var runs: [BotRun]

    var body: some View {
        let waiting = runs.filter(\.needsYou).count
        let running = runs.contains { $0.phase == .running }
        if waiting > 0 {
            Label("\(waiting)", systemImage: "exclamationmark.bubble.fill").labelStyle(.titleAndIcon)
        } else {
            Image(systemName: running ? "waveform.path.ecg" : "bubble.left.and.bubble.right")
        }
    }
}
#endif
