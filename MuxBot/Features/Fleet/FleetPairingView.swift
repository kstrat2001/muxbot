import SwiftUI

/// Pair this app with darkmux on this Mac. The app shows a code; you approve
/// it on the Mac with `darkmux client approve`. Until then runs are simulated.
struct FleetPairingView: View {
    @Environment(FleetConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @AppStorage("darkmux.pair.profile") private var profile = ""

    var body: some View {
        Form {
            switch connection.state {
            case .unpaired, .failed:
                Section {
                    TextField("Profile, e.g. flint-rec", text: $profile)
                        .autocorrectionDisabled()
                } header: {
                    Text("darkmux profile")
                } footer: {
                    Text("Runs from this app use this profile. darkmux shows it when you approve.")
                }
                if case let .failed(message) = connection.state {
                    Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                }
                Section {
                    Button("Pair with darkmux", systemImage: "link") { connection.pair(profile: profile.trimmingCharacters(in: .whitespaces)) }
                        .disabled(profile.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text("Needs `darkmux client serve` running on this Mac.")
                }
            case let .waiting(code):
                Section {
                    Text(code)
                        .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .textSelection(.enabled)
                    Text("On this Mac, run `darkmux client approve` and confirm this code.")
                        .foregroundStyle(.secondary)
                    ProgressView("Waiting for approval…")
                }
                Section { Button("Cancel", role: .cancel) { connection.cancelPairing() } }
            case let .paired(name, profiles):
                Section {
                    Label("Paired as \(name)", systemImage: "checkmark.seal.fill").foregroundStyle(Color.brandGreen)
                    Text("Profiles: \(profiles.joined(separator: ", ")) · work folders under ~/.darkmux/worktrees")
                        .font(AppFont.footnote()).foregroundStyle(.secondary)
                }
                Section {
                    Button("Unpair this app", role: .destructive) { connection.unpair() }
                } footer: {
                    Text("To revoke on the Mac: `darkmux client revoke \(name)`.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("darkmux")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
