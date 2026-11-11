import SwiftUI

/// Settings › Computers: the computers whose darkmux runs your bots' work,
/// each with whether it answers now and a ⋯ menu. Today that's darkmux on
/// this Mac; other Macs join the list when darkmux can pair over your
/// tailnet.
struct ComputersView: View {
    @Environment(FleetConnection.self) private var connection
    @Environment(BotBrain.self) private var brain
    @State private var answers: Bool?
    @State private var showPairing = false
    @State private var confirmUnpair = false

    var body: some View {
        Form {
            Section {
                row
            } header: {
                Text("Your computers")
            } footer: {
                Text("Your bots' work runs in darkmux on these computers.")
            }
            #if os(macOS)
            if !connection.isPaired {
                Section {
                    if case let .failed(message) = connection.state {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Color.secondaryText)
                    }
                    Text("Pairing lets this app send work to darkmux on this Mac. You approve it once in darkmux; you can unpair any time.")
                        .foregroundStyle(Color.secondaryText)
                    Button("Pair with darkmux", systemImage: "link") { showPairing = true }
                    Link("Don't have darkmux yet? Get it", destination: DarkmuxLinks.install)
                        .font(AppFont.footnote()).tint(Color.accentText)
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPairing) {
            NavigationStack { FleetPairingView() }
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 420)
                #endif
        }
        .confirmationDialog("Unpair this app from darkmux?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) { connection.unpair() }
        } message: {
            Text("Runs can't start until you pair again.")
        }
        #if os(macOS)
        .task(id: connection.isPaired) { await watch() }
        #endif
    }

    private var status: ComputerStatus {
        #if os(macOS)
        ComputerStatus.of(paired: connection.isPaired, answers: answers)
        #else
        .runsFromMac
        #endif
    }

    private var name: String {
        #if os(macOS)
        brain.runs.knownMachine?.name ?? FleetConnection.machineName
        #else
        brain.runs.knownMachine?.name ?? String(localized: "Your Mac")
        #endif
    }

    private var row: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundStyle(Color.secondaryText)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(AppFont.headline())
                HStack(spacing: Spacing.xs) {
                    Circle().fill(status.isOnline ? Color.brandGreen : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(status.line).font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            #if os(macOS)
            Menu {
                if connection.isPaired {
                    Button("Unpair", systemImage: "xmark.circle", role: .destructive) { confirmUnpair = true }
                } else {
                    Button("Pair with darkmux", systemImage: "link") { showPairing = true }
                }
                Link(destination: DarkmuxLinks.guide) { Label("darkmux guide", systemImage: "safari") }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More for \(name)")
            #endif
        }
        .padding(.vertical, Spacing.xs)
    }

    /// Asks darkmux every few seconds while the page is open. Any answer
    /// counts (an older darkmux may not know the question); only no answer
    /// at all is "not answering". A 401 unpairs through the client.
    private func watch() async {
        answers = nil
        while !Task.isCancelled, connection.isPaired, let token = connection.token {
            do {
                _ = try await connection.client.whoami(token: token)
                answers = true
            } catch is CancellationError {
                return
            } catch let error as URLError {
                if error.code == .cancelled { return }
                answers = false
            } catch {
                answers = true
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

/// How a computer in Settings › Computers is doing, in a few words beside
/// its dot.
enum ComputerStatus: Equatable {
    case checking, online, notAnswering, notPaired
    /// On iPhone and iPad: runs start from the Mac app for now.
    case runsFromMac

    static func of(paired: Bool, answers: Bool?) -> ComputerStatus {
        guard paired else { return .notPaired }
        switch answers {
        case nil: return .checking
        case true?: return .online
        case false?: return .notAnswering
        }
    }

    var isOnline: Bool { self == .online }

    var line: String {
        switch self {
        case .checking: String(localized: "This Mac · Checking…")
        case .online: String(localized: "This Mac · Online now")
        case .notAnswering: String(localized: "This Mac · darkmux isn't answering")
        case .notPaired: String(localized: "This Mac · Not paired")
        case .runsFromMac: String(localized: "Mac · Runs start from the Mac app for now")
        }
    }
}
