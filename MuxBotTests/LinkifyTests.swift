import Foundation
import Testing
@testable import MuxBot

struct LinkifyTests {
    /// Visible text → link, for every linked run.
    private func links(_ a: AttributedString) -> [String: String] {
        var out: [String: String] = [:]
        for run in a.runs { if let url = run.link { out[String(a[run.range].characters)] = url.absoluteString } }
        return out
    }
    private let hcr = "kstrat2001/hcr"

    @Test func issueNumbersLinkToTheRepo() {
        let l = links(Linkify.attributed("Fix #8 with Coder? See also #12.", repo: hcr))
        #expect(l["#8"] == "https://github.com/kstrat2001/hcr/issues/8")
        #expect(l["#12"] == "https://github.com/kstrat2001/hcr/issues/12")
    }

    @Test func wordedReferencesLink() {
        let l = links(Linkify.attributed("PR 9 fixes issue 8; pull request #10 too.", repo: hcr))
        #expect(l["PR 9"] == "https://github.com/kstrat2001/hcr/issues/9")
        #expect(l["issue 8"] == "https://github.com/kstrat2001/hcr/issues/8")
        #expect(l["pull request #10"] == "https://github.com/kstrat2001/hcr/issues/10")
    }

    @Test func otherReposByName() {
        let l = links(Linkify.attributed("Blocked on kstrat2001/darkmux#2300.", repo: hcr))
        #expect(l["kstrat2001/darkmux#2300"] == "https://github.com/kstrat2001/darkmux/issues/2300")
        // Works without a bot repo too.
        #expect(links(Linkify.attributed("see kstrat2001/darkmux#1", repo: nil)).count == 1)
    }

    @Test func shortLabelsRoundTrip() {
        #expect(links(Linkify.attributed("hcr#9 is open", repo: hcr))["hcr#9"] == "https://github.com/kstrat2001/hcr/issues/9")
    }

    @Test func githubURLsGetShortLabels() {
        let a = Linkify.attributed("Opened https://github.com/kstrat2001/hcr/pull/9 and https://github.com/kstrat2001/hcr/commit/f34727fabc for it.", repo: nil)
        #expect(String(a.characters) == "Opened hcr#9 and hcr@f34727f for it.")
        let l = links(a)
        #expect(l["hcr#9"] == "https://github.com/kstrat2001/hcr/pull/9")
        #expect(l["hcr@f34727f"] == "https://github.com/kstrat2001/hcr/commit/f34727fabc")
    }

    @Test func otherURLsKeepTheirText() {
        let a = Linkify.attributed("Docs: https://example.com/a?b=1.", repo: nil)
        #expect(String(a.characters) == "Docs: https://example.com/a?b=1.")
        #expect(links(a)["https://example.com/a?b=1"] == "https://example.com/a?b=1")
    }

    @Test func commitSHAsInContext() {
        let l = links(Linkify.attributed("Built at commit f34727f, then `9a1b2c3d`.", repo: hcr))
        #expect(l["f34727f"] == "https://github.com/kstrat2001/hcr/commit/f34727f")
        #expect(l["9a1b2c3d"] == "https://github.com/kstrat2001/hcr/commit/9a1b2c3d")
        // A bare hex word without context is not a commit.
        #expect(links(Linkify.attributed("the word decade and 1234567", repo: hcr)).isEmpty)
    }

    @Test func filePathsOnlyWhenAsked() {
        let text = "Changed inertia/pages/pricing.tsx and app.css."
        #expect(links(Linkify.attributed(text, repo: hcr)).isEmpty)
        let l = links(Linkify.attributed(text, repo: hcr, linkPaths: true))
        #expect(l["inertia/pages/pricing.tsx"] == "https://github.com/kstrat2001/hcr/blob/HEAD/inertia/pages/pricing.tsx")
        let onBranch = links(Linkify.attributed(text, repo: hcr, ref: "fix/pricing", linkPaths: true))
        #expect(onBranch["inertia/pages/pricing.tsx"] == "https://github.com/kstrat2001/hcr/blob/fix/pricing/inertia/pages/pricing.tsx")
    }

    @Test func codeBlocksOnlyLinkWholeURLs() {
        let text = "Before #8\n```\nlet a = b#3 // #4 at commit abc1234 https://github.com/kstrat2001/hcr/pull/9\n```\nafter #5"
        let a = Linkify.attributed(text, repo: hcr, linkPaths: true)
        let l = links(a)
        #expect(Set(l.keys) == ["#8", "#5", "https://github.com/kstrat2001/hcr/pull/9"])
        // The URL in code keeps its text.
        #expect(String(a.characters).contains("https://github.com/kstrat2001/hcr/pull/9"))
    }

    @Test func noRepoLeavesNumbersAlone() {
        #expect(links(Linkify.attributed("Fix #8, PR 9", repo: nil)).isEmpty)
    }

    @Test func colorsAndAnchorsAreNotIssues() {
        #expect(links(Linkify.attributed("color #ff0000 and page#top and #3a", repo: hcr)).isEmpty)
    }

    @Test func markdownKeepsItsStyling() throws {
        let md = try AttributedString(markdown: "**Fixed** #8", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let a = Linkify.apply(to: md, repo: hcr)
        #expect(links(a)["#8"] != nil)
        #expect(a.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    }

    @Test func referencesForChips() {
        let refs = Linkify.references(in: "Fix #8: the gutter (kstrat2001/hcr), see https://github.com/kstrat2001/hcr/pull/9 and #8", repo: hcr)
        #expect(refs.map(\.label) == ["hcr#8", "hcr#9"])
        #expect(refs.last?.url.absoluteString == "https://github.com/kstrat2001/hcr/pull/9")
    }
}
