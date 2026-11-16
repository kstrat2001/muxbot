import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Pair this app with darkmux on this Mac. The app shows a code; you approve
/// it in darkmux on the Mac (darkmux's guide shows how; never a command
/// here). Until then runs can't start.
struct FleetPairingView: View {
    @Environment(FleetConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @Query private var bots: [Bot]
    @State private var justPaired = false
    /// The Mac's tailnet address, typed, pasted or from its QR code.
    @State private var address = ""

    var body: some View {
        Form {
            switch connection.state {
            case .unpaired, .failed:
                #if os(iOS)
                // Pairing with your Mac over the tailnet, then GitHub sign-in.
                Section {
                    Text("On your Mac, open Mux Bot's Settings, then Computers, and scan the code there with this device's camera. Or paste the address it shows.")
                        .foregroundStyle(Color.secondaryText)
                    TextField("Your Mac's address", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Pair with your Mac", systemImage: "link") {
                        if let mac = RemotePairing.mac(from: address) { connection.pair(over: mac) }
                    }
                    .disabled(RemotePairing.mac(from: address) == nil)
                    if !address.isEmpty, RemotePairing.mac(from: address) == nil {
                        Text("That isn't the address your Mac shows. Copy it from Mux Bot's Settings on the Mac.")
                            .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                    }
                } header: {
                    Text("Pair with your Mac over your tailnet")
                } footer: {
                    Text("Runs still start from the Mac app for now.")
                }
                if case let .failed(message) = connection.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Color.secondaryText)
                        if let details = connection.failureDetails { TechnicalDetails(text: details) }
                    }
                }
                Section {
                    NavigationLink { GitHubSignInView() } label: { Label("GitHub sign-in", systemImage: "person.badge.key") }
                }
                #else
                Section {
                    Text("Pairing lets this app send work to darkmux on this Mac. You approve it once in darkmux on this Mac; you can unpair any time.")
                        .foregroundStyle(Color.secondaryText)
                }
                if case let .failed(message) = connection.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Color.secondaryText)
                        Link(destination: DarkmuxLinks.guide) { Label("darkmux guide", systemImage: "safari") }
                    }
                }
                Section {
                    Button("Pair with darkmux", systemImage: "link") { connection.pair() }
                } footer: {
                    Text("darkmux's app connection has to be running on this Mac.")
                }
                #endif
            case let .waiting(code, expires) where connection.pairingRemotely:
                // Over the tailnet the code is how the operator tells this
                // request from a forged one: it's large, and first, for the
                // whole pairing.
                Section {
                    Self.codeText(code)
                    step(1, String(localized: "On your Mac, darkmux asks you to approve this device.")) { EmptyView() }
                    step(2, String(localized: "Approve it only if darkmux shows this same code.")) { EmptyView() }
                    waiting(until: expires)
                } header: {
                    Text("Approve this device on your Mac")
                }
            case let .waiting(code, expires):
                Section {
                    step(1, Self.approveStep) {
                        Link(destination: DarkmuxLinks.guide) { Label("darkmux guide", systemImage: "safari") }.font(AppFont.footnote())
                    }
                    step(2, "Check that darkmux shows this code.") { EmptyView() }
                    Self.codeText(code)
                    waiting(until: expires)
                } header: {
                    Text("Approve this app on your Mac")
                }
                Section {
                    DisclosureGroup("darkmux says there's nothing to approve?") {
                        Text("darkmux's app connection must be running on this Mac. darkmux's guide shows how to start it.")
                            .font(AppFont.footnote())
                        Link(destination: DarkmuxLinks.guide) { Label("darkmux guide", systemImage: "safari") }.font(AppFont.footnote())
                    }
                }
            case let .paired(name):
                Section {
                    Label("Paired as \(name)", systemImage: "checkmark.circle.fill")
                        .font(AppFont.headline())
                        .labelStyle(.tintedIcon(Color.brandGreen))
                    Text(connection.isRemote ? "Paired with your Mac over your tailnet. Runs still start from the Mac app for now."
                                             : "darkmux on this Mac decides which models apps may use.")
                        .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                }
                Section {
                    Button("Unpair this app", role: .destructive) { connection.unpair() }
                }
            }
            // Part of the form, after everything else: an overlay pinned to
            // the bottom drew over the code when the sheet was short.
            Section {
            } footer: {
                Link("Don't have darkmux yet? Get it", destination: DarkmuxLinks.install)
                    .font(AppFont.footnote())
                    .tint(Color.accentText)
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle(Self.title(onPhone: true))
        #else
        .navigationTitle(Self.title(onPhone: false))
        #endif
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
        .onAppear(perform: takeOfferedAddress)
        .onChange(of: connection.offeredRemoteURL) { takeOfferedAddress() }
    }

    /// A Mac's QR code opened the app: its address goes in the field.
    private func takeOfferedAddress() {
        guard let mac = connection.offeredRemoteURL else { return }
        address = mac.absoluteString
        connection.offeredRemoteURL = nil
    }

    /// The pairing code, large: you compare it with darkmux's on the Mac.
    static func codeText(_ code: String) -> some View {
        Text(code)
            .font(.system(size: 56, weight: .bold, design: .monospaced))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .textSelection(.enabled)
            .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
    }

    private func waiting(until expires: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(expires.timeIntervalSince(context.date)))
            HStack(spacing: Spacing.sm) {
                if left > 0 { ProgressView().controlSize(.small) }
                Text(left > 0 ? "Waiting for you to approve… code expires in \(left / 60):\(String(format: "%02d", left % 60))"
                              : "The code expired. Cancel and pair again.")
                    .foregroundStyle(Color.secondaryText)
            }
        }
    }

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

extension FleetPairingView {
    /// A phone pairs with your Mac over the tailnet (runs still start on the
    /// Mac): its sheet is about your Mac and GitHub.
    static func title(onPhone: Bool) -> String {
        onPhone ? String(localized: "Your Mac and GitHub") : String(localized: "Pair with darkmux")
    }
}

extension FleetPairingView {
    /// Step 1 of approving, on its own: darkmux has no window, so the
    /// approval is part of darkmux's own setup, which its guide covers.
    static var approveStep: String {
        String(localized: "darkmux has no window to click: it approves new apps from its own setup on this Mac. Its guide shows how.")
    }
}
