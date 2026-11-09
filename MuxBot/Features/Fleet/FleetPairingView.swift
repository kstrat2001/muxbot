import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Pair this app with darkmux on this Mac. The app shows a code; you approve
/// it on the Mac with `darkmux client approve`. Until then runs can't start.
struct FleetPairingView: View {
    @Environment(FleetConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @Query private var bots: [Bot]
    @State private var justPaired = false

    var body: some View {
        Form {
            switch connection.state {
            case .unpaired, .failed:
                #if os(iOS)
                Section {
                    NavigationLink { GitHubSignInView() } label: { Label("GitHub sign-in", systemImage: "person.badge.key") }
                }
                Section {
                    Label("On iPhone and iPad, runs start from the Mac app for now.", systemImage: "laptopcomputer")
                    Text("Pair Mux Bot on the Mac where darkmux runs. Pairing your phone over your tailnet comes later.")
                        .foregroundStyle(Color.secondaryText)
                }
                #else
                Section {
                    Text("Pairing lets this app send work to darkmux on this Mac. You approve it once in Terminal; you can revoke it any time.")
                        .foregroundStyle(Color.secondaryText)
                }
                if case let .failed(message) = connection.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Color.secondaryText)
                        CommandBox(command: connection.serveCommand)
                    }
                }
                Section {
                    Button("Pair with darkmux", systemImage: "link") { connection.pair() }
                } footer: {
                    Text("darkmux's app connection has to be running on this Mac (the command above starts it).")
                }
                #endif
            case let .waiting(code, expires):
                Section {
                    #if os(macOS)
                    step(1, "Open Terminal on this Mac.") {
                        Button("Open Terminal", systemImage: "terminal") { openTerminal() }
                            .controlSize(.small)
                    }
                    #else
                    step(1, "Open Terminal on your Mac.") { EmptyView() }
                    #endif
                    step(2, "Paste this command and press Return.") { EmptyView() }
                    CommandBox(command: connection.approveCommand)
                    step(3, "Check that darkmux shows this code, then type y and press Return.") { EmptyView() }
                    Text(code)
                        .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .textSelection(.enabled)
                        .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(expires.timeIntervalSince(context.date)))
                        HStack(spacing: Spacing.sm) {
                            if left > 0 { ProgressView().controlSize(.small) }
                            Text(left > 0 ? "Waiting for you to approve… code expires in \(left / 60):\(String(format: "%02d", left % 60))"
                                          : "The code expired. Cancel and pair again.")
                                .foregroundStyle(Color.secondaryText)
                        }
                    }
                } header: {
                    Text("Approve this app on your Mac")
                }
                Section {
                    DisclosureGroup("darkmux says there's nothing to approve?") {
                        Text("darkmux's local endpoint must be running on this Mac. In another Terminal window, run:")
                            .font(AppFont.footnote())
                        CommandBox(command: connection.serveCommand)
                    }
                }
            case let .paired(name):
                Section {
                    Label("Paired as \(name)", systemImage: "checkmark.circle.fill")
                        .font(AppFont.headline())
                        .foregroundStyle(Color.brandGreen)
                    Text("darkmux on this Mac decides which models apps may use.")
                        .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                }
                Section {
                    Button("Unpair this app", role: .destructive) { connection.unpair() }
                } footer: {
                    VStack(alignment: .leading) {
                        Text("You can also revoke it in Terminal:")
                        CommandBox(command: "\(connection.cliCommand) client revoke \(name)")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            Link("Don't have darkmux yet? Install it", destination: URL(string: "https://github.com/kstrat2001/darkmux#readme")!)
                .font(AppFont.footnote())
                .padding(.bottom, Spacing.md)
        }
        .navigationTitle("Pair with darkmux")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if case .waiting = connection.state {
                    Button("Cancel") { connection.cancelPairing() }
                } else {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onChange(of: connection.isPaired) {
            // Show the checkmark a moment, then close.
            guard connection.isPaired, justPaired else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                dismiss()
                // Paired with no bots yet: on to "What do you want to get done?".
                router.continueAfterPairing(botCount: bots.count)
            }
        }
        .onChange(of: connection.state) {
            if case .waiting = connection.state { justPaired = true }
        }
    }

    #if os(macOS)
    private func openTerminal() {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
    #endif

    private func step(_ number: Int, _ text: String, @ViewBuilder trailing: () -> some View) -> some View {
        Label {
            HStack {
                Text(text)
                Spacer()
                trailing()
            }
        } icon: {
            Text("\(number)")
                .font(AppFont.caption(.bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.brandGreen.opacity(0.25)))
        }
    }
}

/// A command in monospace with a Copy button.
struct CommandBox: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                Clipboard.copy(command)
                copied = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(Spacing.sm)
        .background(RoundedRectangle(cornerRadius: CornerRadius.sm).fill(Color.elevatedBackground))
    }
}
