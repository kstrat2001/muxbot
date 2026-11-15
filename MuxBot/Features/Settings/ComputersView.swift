import SwiftUI

/// Settings › Computers: the computers whose darkmux runs your bots' work,
/// each with whether it answers now and a ⋯ menu. Today that's darkmux on
/// this Mac; other Macs join the list when darkmux can pair over your
/// tailnet.
struct ComputersView: View {
    @Environment(FleetConnection.self) private var connection
    @Environment(BotBrain.self) private var brain
    @State private var answers: Bool?
    /// What darkmux said about itself last (capabilities, the tailnet).
    @State private var whoami: DarkmuxClient.Whoami?
    /// A refusal about the tailnet, in plain words, with darkmux's own for
    /// Show details.
    @State private var refusal: (sentence: String, details: String?)?
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
            } else if let whoami {
                OtherDevicesSection(access: RemoteAccess.of(whoami))
            }
            #else
            if !connection.isPaired {
                Section {
                    Text("Pair this device with your Mac over your tailnet. You approve it on the Mac; you can unpair any time.")
                        .foregroundStyle(Color.secondaryText)
                    Button("Pair with your Mac", systemImage: "link") { showPairing = true }
                }
            }
            #endif
            if let refusal {
                Section {
                    Label(refusal.sentence, systemImage: "exclamationmark.triangle").foregroundStyle(Color.secondaryText)
                    if let details = refusal.details { TechnicalDetails(text: details) }
                }
            }
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
        .task(id: connection.isPaired) { await watch() }
    }

    private var status: ComputerStatus {
        #if os(macOS)
        ComputerStatus.of(paired: connection.isPaired, answers: answers)
        #else
        connection.isRemote ? ComputerStatus.of(paired: true, answers: answers, overTailnet: true) : .runsFromMac
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
            #if os(iOS)
            if connection.isPaired {
                Menu {
                    Button("Unpair", systemImage: "xmark.circle", role: .destructive) { confirmUnpair = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More for \(name)")
            }
            #endif
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
        whoami = nil
        refusal = nil
        while !Task.isCancelled, connection.isPaired, let token = connection.token {
            do {
                whoami = try await connection.client.whoami(token: token)
                answers = true
                refusal = nil
            } catch is CancellationError {
                return
            } catch let error as URLError {
                if error.code == .cancelled { return }
                answers = false
            } catch {
                answers = true
                // A tailnet refusal is said plainly; the token is kept
                // (only a 401 forgets it, through the client).
                if let client = error as? DarkmuxClient.ClientError, let sentence = RemotePairing.sentence(client.code) {
                    refusal = (sentence, DarkmuxPlain.details(error))
                }
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

    /// Your Mac, reached over the tailnet from this device.
    case tailnet(online: Bool?)

    static func of(paired: Bool, answers: Bool?, overTailnet: Bool = false) -> ComputerStatus {
        guard paired else { return .notPaired }
        if overTailnet { return .tailnet(online: answers) }
        switch answers {
        case nil: return .checking
        case true?: return .online
        case false?: return .notAnswering
        }
    }

    var isOnline: Bool { self == .online || self == .tailnet(online: true) }

    var line: String {
        switch self {
        case .checking: String(localized: "This Mac · Checking…")
        case .online: String(localized: "This Mac · Online now")
        case .notAnswering: String(localized: "This Mac · darkmux isn't answering")
        case .notPaired: String(localized: "This Mac · Not paired")
        case .runsFromMac: String(localized: "Mac · Runs start from the Mac app for now")
        case .tailnet(online: nil): String(localized: "Over your tailnet · Checking…")
        case .tailnet(online: true?): String(localized: "Over your tailnet · Online now")
        case .tailnet(online: false?): String(localized: "Over your tailnet · Not answering")
        }
    }
}

/// Settings › Computers on the Mac: whether your iPhone or iPad can pair with
/// this Mac over your tailnet, and the QR code and address it pairs at. Shown
/// only when darkmux says it knows about remote use (`capabilities`).
struct OtherDevicesSection: View {
    let access: RemoteAccess

    var body: some View {
        switch access {
        case .notSupported:
            EmptyView()
        case let .available(mac):
            Section {
                HStack(alignment: .top, spacing: Spacing.md) {
                    if let code = RemotePairing.qrCode(RemotePairing.link(for: mac).absoluteString) {
                        Image(decorative: code, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 140, height: 140)
                            .padding(Spacing.xs)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: CornerRadius.sm))
                            .accessibilityLabel("Code to scan with your iPhone")
                    }
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Scan this with your iPhone's camera, or send it the address. Your iPhone then shows a code: approve it in darkmux on this Mac only if darkmux shows the same code.")
                            .foregroundStyle(Color.secondaryText)
                        ShareLink(item: mac) { Label("Send the address", systemImage: "square.and.arrow.up") }
                    }
                }
            } header: {
                Text("Use Mux Bot on your iPhone")
            } footer: {
                Text("Runs still start from this Mac for now.")
            }
        case .off:
            Section {
                Text("To pair your iPhone with this Mac over your tailnet, turn on remote use in darkmux's setup on this Mac. darkmux's guide shows how.")
                    .foregroundStyle(Color.secondaryText)
                Link(destination: DarkmuxLinks.remote) { Label("darkmux guide", systemImage: "safari") }.font(AppFont.footnote())
            } header: {
                Text("Use Mux Bot on your iPhone")
            }
        case let .unavailable(reason):
            Section {
                Label("darkmux couldn't put this Mac on your tailnet, so your iPhone can't reach it yet. darkmux's guide shows what it needs.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.secondaryText)
                if let reason { TechnicalDetails(text: reason) }
                Link(destination: DarkmuxLinks.remote) { Label("darkmux guide", systemImage: "safari") }.font(AppFont.footnote())
            } header: {
                Text("Use Mux Bot on your iPhone")
            }
        case .needsNewerDarkmux:
            Section {
                Text("This Mac is on your tailnet, but this darkmux can't pair other devices yet. A newer darkmux can.")
                    .foregroundStyle(Color.secondaryText)
                Link(destination: DarkmuxLinks.guide) { Label("darkmux guide", systemImage: "safari") }.font(AppFont.footnote())
            } header: {
                Text("Use Mux Bot on your iPhone")
            }
        }
    }
}
