import Foundation
import Testing
@testable import MuxBot

private let heading = PickedElement(label: "> Human_Models", selector: "main > section.container > div > h1", tag: "h1",
                                    url: "/pricing", viewport: 819, left: 40, right: 40, width: 739, height: 58,
                                    paddingLeft: "0px", paddingRight: "0px", marginLeft: "0px", marginRight: "0px",
                                    x: 40, y: 120, fontSize: "48px", fontWeight: "700", color: "rgb(0, 255, 65)", fontFamily: "JetBrains Mono")
private let tagline = PickedElement(label: "Don't let your vibes break production.", selector: "main > section > p", tag: "p",
                                    url: "/", viewport: 390, left: 20, right: 20, width: 350, height: 30,
                                    paddingLeft: "0px", paddingRight: "0px", marginLeft: "0px", marginRight: "0px",
                                    x: 20, y: 300, fontSize: "24px", fontWeight: "400", color: "rgb(150, 150, 150)", fontFamily: "Inter")

struct ElementExplainerTests {
    @Test(arguments: ["what's this?", "What is this", "whats that?", "explain this", "what am I looking at?"])
    func whatsThisQuestions(text: String) {
        #expect(ElementExplainer.isWhatsThis(text))
    }

    @Test func otherMessagesAreNotWhatsThis() {
        #expect(!ElementExplainer.isWhatsThis("make this bigger"))
    }

    @Test func explainsTheHeadingFromItsFacts() {
        let text = ElementExplainer.explain(heading, pageFile: "inertia/pages/{page}.tsx")
        #expect(text.contains("the page's main heading"))
        #expect(text.contains("Human_Models"))
        #expect(text.contains("/pricing"))
        #expect(text.contains("inertia/pages/pricing.tsx"))
        #expect(text.contains("48px"))
        #expect(text.contains("819px"))
        #expect(text.hasSuffix("Want me to change it, or report a problem with it?"))
        #expect(!text.localizedCaseInsensitiveContains("code review"))
        #expect(!text.localizedCaseInsensitiveContains("css selector"))
    }

    @Test func explainsTheTaglineFromItsFacts() {
        let text = ElementExplainer.explain(tagline, pageFile: "inertia/pages/{page}.tsx")
        #expect(text.contains("paragraph"))
        #expect(text.contains("inertia/pages/home.tsx"))
        #expect(text.contains("390px"))
    }
}

@Suite(.serialized) @MainActor
struct ElementQuestionFlowTests {
    @Test func whatsThisWithAChipExplainsTheElementWithoutAModel() async throws {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website")
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        await brain.send("what's this?", in: .bot(bot.id), store: store, element: heading)
        let reply = try #require((store.conversation(for: .bot(bot.id)).messages ?? []).last { $0.role == .assistant }?.content)
        #expect(reply.contains("the page's main heading"))
        #expect(bot.runs?.isEmpty ?? true)
    }
}
