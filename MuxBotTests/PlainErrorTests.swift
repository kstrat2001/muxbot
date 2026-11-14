import Foundation
import Testing
@testable import MuxBot

/// What a user reads when something fails is a plain sentence about what
/// happened and what to do; the raw output is behind "Show details" (#42).
struct PreviewFailureTests {
    static let rolldownLog = """
        npm warn EBADENGINE Unsupported engine {
        npm warn EBADENGINE   package: 'vite@8.3.6',
        npm warn EBADENGINE   required: { node: '^20.19.0 || >=22.12.0' },
        npm warn EBADENGINE   current: { node: 'v20.15.1', npm: '10.9.1' }
        Error: Cannot find module './rolldown-binding.linux-arm64-musl.node'
        Require stack:
        - /workspace/node_modules/rolldown/dist/shared/rolldown-runtime-DYf_mQCB.mjs
            at file:///workspace/node_modules/rolldown/dist/shared/binding-BXYS21Tf.mjs:487:18
        """

    /// No paths, stack frames, env var names or exit codes in what a user reads.
    static func isPlain(_ text: String) -> Bool {
        let banned = ["/workspace", "node_modules", "at file://", "exit status", "EBADENGINE", "Require stack",
                      "schema_version", ".json", "PORT", "{port}", "  at "]
        return !banned.contains { text.contains($0) }
    }

    @Test func aNodeThatsTooOldSaysSoInPlainWords() {
        let f = PreviewFailure(reason: "the dev server exited (exit status: 1)", log: Self.rolldownLog)
        #expect(f.kind == .nodeTooOld, "the engine mismatch is the cause, not the missing module")
        #expect(f.headline == "The preview couldn't start.")
        #expect(f.explanation.contains("newer version of Node"))
        #expect(Self.isPlain(f.headline + " " + f.explanation))
        #expect(f.details.contains("rolldown-binding"), "the raw output is still there, behind Show details")
    }

    @Test(arguments: [
        ("the dev server exited (exit status: 1)", "Error: Cannot find module 'x'\nRequire stack:\n- /workspace/a.js", PreviewFailure.Kind.installFailed),
        ("install failed (exit status: 1)", "npm error code ERESOLVE", .installFailed),
        ("the dev server exited (exit status: 1)", "Error: listen EADDRINUSE: address already in use 0.0.0.0:4100", .portInUse),
        (".darkmux/preview.json: `schema_version` is missing; it is not one this darkmux reads (write \"1.0\")", "", .settings),
        ("it didn't start within 3 minutes", "", .tooSlow),
        ("the dev server exited (exit status: 1)", "something odd", .serverStopped),
        ("config.json does not parse", "", .other),
    ])
    func eachKnownFailureHasItsOwnPlainSentence(reason: String, log: String, kind: PreviewFailure.Kind) {
        let f = PreviewFailure(reason: reason, log: log)
        #expect(f.kind == kind)
        #expect(Self.isPlain(f.headline + " " + f.explanation), "\(f.explanation)")
        #expect(f.details.contains(reason))
    }

    @Test func theStatusLineIsPlainToo() {
        let text = LivePreview.Status.failed("the dev server exited (exit status: 1)").text
        #expect(text == "The preview couldn't start.")
        #expect(Self.isPlain(text))
    }

    @Test func previewsOffNoLongerSaysItRunsOutsideTheSandbox() {
        let detail = LivePreview.Unavailable.previewsOff.detail(repo: nil, folder: nil)
        #expect(!detail.contains("outside darkmux's sandbox"))
        // No container wording (Kain, 2026-11-12): it runs on this Mac.
        #expect(detail.contains("on this Mac"))
    }
}

@Suite(.serialized) @MainActor
struct GitHubSignInPlainErrorTests {
    private func auth() -> GitHubAuth {
        GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: MemoryKeychain(), sleep: { _ in })
    }

    @Test func deviceFlowTurnedOffSaysWhatToDo() async {
        GitHubStub.reset()
        GitHubStub.on("POST /login/device/code", 400, #"{"error":"device_flow_disabled","error_description":"Device Flow must be explicitly enabled for this App","error_uri":"https://docs.github.com"}"#)
        let a = auth()
        await a.signIn { _, _ in }
        guard case let .failed(why) = a.state else { Issue.record("expected failed"); return }
        #expect(!why.contains("400"), "no status codes in what a user reads")
        #expect(why.contains("Device Flow"))
        #expect(a.failureDetails?.contains("device_flow_disabled") == true)
    }

    @Test func anyOtherFailureIsPlainWithTheDetailsKept() async {
        GitHubStub.reset()
        GitHubStub.on("POST /login/device/code", 503, #"{"message":"Service Unavailable"}"#)
        let a = auth()
        await a.signIn { _, _ in }
        guard case let .failed(why) = a.state else { Issue.record("expected failed"); return }
        #expect(why == "GitHub sign-in didn't work. Try again in a moment.")
        #expect(a.failureDetails?.contains("503") == true)
    }

    @Test func aPollErrorIsPlainToo() async {
        GitHubStub.reset()
        GitHubStub.on("POST /login/device/code", 200, #"{"device_code":"dc1","user_code":"AAAA-BBBB","verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}"#)
        GitHubStub.on("POST /login/oauth/access_token", 200, #"{"error":"unsupported_grant_type"}"#)
        let a = auth()
        await a.signIn { _, _ in }
        guard case let .failed(why) = a.state else { Issue.record("expected failed"); return }
        #expect(!why.contains("unsupported"), "\(why)")
        #expect(a.failureDetails?.contains("unsupported_grant_type") == true)
    }
}
