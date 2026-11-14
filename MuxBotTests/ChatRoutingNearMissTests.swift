import Testing
@testable import MuxBot

/// Phrasings that were misrouted, or nearly could be, and where each must
/// go. The rules: with something picked, a request is a change for Coder
/// (with the picked words) unless it names where things sit (measured) or
/// asks a question; an app action needs its own words only; the issues
/// list needs a question about issues; anything unsure is never measured.
@MainActor
struct ChatRoutingNearMissTests {
    @Test(arguments: [
        // Kain, 2026-11-14: each of these was misread.
        ("We shouldn't use brand names", true, Intent.fix),
        ("Offer a better list", true, .fix),
        ("change \"logic flaws\" to a different security issue", true, .fix),
        // Content changes, picked.
        ("a shorter headline", true, .fix),
        ("this price is wrong", true, .fix),
        ("the date is missing", true, .fix),
        ("too wordy", true, .fix),
        ("friendlier please", true, .fix),
        ("the font feels too corporate", true, .fix),
        ("the borders look too thin", true, .fix),
        ("mention the free trial", true, .fix),
        ("list three more security issues", true, .fix),
        ("show the price per month", true, .fix),
        ("the issue list should be shorter", true, .fix),
        ("open the link in a new tab", true, .fix),
        // Layout, picked: measured.
        ("this is cut off", true, .bug),
        ("no gutter on the sides", true, .bug),
        ("overlaps the footer", true, .bug),
        ("too close to the edge", true, .bug),
        ("it runs off the screen on phones", true, .bug),
        // Questions, picked.
        ("what font is this", true, .ask),
        ("why is this cut off?", true, .bug),
        ("is this the right price?", true, .ask),
        // Nothing picked.
        ("change the security issue to SSRF", false, .fix),
        ("add a section about bugs we fixed", false, .fix),
        ("rename the issues page", false, .fix),
        ("any open issues?", false, .issues),
        ("which bugs need fixing?", false, .issues),
        ("show open issues", false, .issues),
        ("the cards overlap the footer on phone", false, .bug),
    ])
    func whereItGoes(text: String, picked: Bool, intent: Intent) {
        #expect(Intent.infer(text, hasElement: picked) == intent, "\(text)")
    }

    /// Remarks with nothing picked that aren't about where things sit go to
    /// the conversation, never a layout measurement.
    @Test(arguments: ["the font feels too corporate", "the colors are a bit dull", "the headline looks boring",
                      "this security issue is wrong", "the price is missing"])
    func remarksAreNeverMeasured(text: String) {
        #expect(Intent.infer(text, hasElement: false) != .bug, "\(text)")
        #expect(Intent.infer(text, hasElement: false) != .issues, "\(text)")
    }

    /// Content that happens to hold an action's word is never that action.
    @Test(arguments: ["change the phone number", "merge the two cards", "review the copy on the pricing page",
                      "save the date section", "undo the header color", "delete the project section",
                      "stop the animation", "remove the info box", "make the preview text bigger",
                      "show the details section", "clear the history section", "put the pricing online section first"])
    func contentIsNeverAnAppAction(text: String) {
        #expect(AppAction.match(text) == nil, "\(text)")
    }

    /// The real actions still match.
    @Test(arguments: [("start the preview", AppAction.openPreview), ("hide the preview", .hidePreview),
                      ("create a PR", .startReview), ("undo that", .undoLast), ("stop the run", .stopRun),
                      ("show it on a phone", .phoneView), ("clear the chat", .clearConversation)])
    func actionsStillMatch(text: String, action: AppAction) {
        #expect(AppAction.match(text) == action, "\(text)")
    }
}
