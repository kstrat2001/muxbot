import SwiftUI

/// Sign in with GitHub (device flow): a short code to approve on github.com.
/// The token stays on this device.
struct GitHubSignInView: View {
    @Environment(GitHubAuth.self) private var github
    @Environment(\.openURL) private var openURL
    @State private var signing: Task<Void, Never>?

    var body: some View {
        Form {
            switch github.state {
            case .signedOut, .failed:
                Section {
                    Text("Sign in so bots can read your private repos and open pull requests. The sign-in stays on this device.")
                        .foregroundStyle(Color.secondaryText)
                    if case let .failed(why) = github.state {
                        Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(Color.secondaryText)
                    }
                    Button("Sign in with GitHub", systemImage: "person.badge.key") { start() }
                        .disabled(!github.isConfigured)
                }
            case let .waiting(code, url):
                Section("Approve on GitHub") {
                    Text("Enter this code at \(url.host() ?? "github.com")\(url.path()):")
                    HStack {
                        Text(code).font(.system(.title2, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(code) }
                    }
                    Button("Open GitHub", systemImage: "safari") { openURL(url) }
                    HStack { ProgressView().controlSize(.small); Text("Waiting for your approval…").foregroundStyle(Color.secondaryText) }
                    Button("Cancel") { signing?.cancel(); github.signOut() }
                }
            case let .signedIn(login):
                Section {
                    Label("Signed in as \(login)", systemImage: "checkmark.circle.fill").foregroundStyle(Color.brandGreen)
                    Button("Sign out", role: .destructive) { github.signOut() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("GitHub")
    }

    private func start() {
        signing = Task {
            await github.signIn { code, url in
                Clipboard.copy(code)
                openURL(url)
            }
        }
    }
}
