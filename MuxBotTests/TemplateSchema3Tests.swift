import Foundation
import Testing
@testable import MuxBot

/// Template schema 3: choice questions in PLAYBOOK.md, with optional
/// preview pictures in the registry repo.
struct TemplateSchema3Tests {
    static let playbook = """
        schema: 3
        title: Build a website
        icon: globe
        pitch: A site.
        previews: desktop, phone

        ## Questions

        - What's the site called?
        - What is it for, in a sentence?
        - How should it feel? (For example: warm, calm.)
        - Pick a design.
          key: design
          previews: desktop, phone
          - editorial: Editorial. Warm paper and a classic serif.
          - bold: Bold. Dark with huge poster type.
        - Pick a size.
          key: size
          - small: Small
          - large: Large

        ## Persona

        You look after {name}.

        ## First run

        Make {name} the site for {purpose}.
        Set `theme` in src/site.ts to {design}.
        Make it feel {feel}.

        ## Skill: Add a page

        When: a new page.
        """

    @Test func choicesAreReadApartFromTheWordQuestions() throws {
        let p = try Playbook.parse(Self.playbook)
        #expect(p.questions.count == 3)
        #expect(p.previews == [.desktop, .phone])
        #expect(p.choices.map(\.key) == ["design", "size"])
        let design = p.choices[0]
        #expect(design.label == "Pick a design.")
        #expect(design.previews == [.desktop, .phone])
        #expect(design.options == [.init(id: "editorial", title: "Editorial", detail: "Warm paper and a classic serif."),
                                   .init(id: "bold", title: "Bold", detail: "Dark with huge poster type.")])
        #expect(p.choices[1].previews.isEmpty, "pictures are optional: these are chips")
        #expect(p.choices[1].options.map(\.title) == ["Small", "Large"])
    }

    @Test func theFirstRunGetsThePick() throws {
        let p = try Playbook.parse(Self.playbook)
        let task = try #require(p.firstRunTask(name: "Cafe", purpose: "a cafe", feel: "", choices: ["design": "bold"]))
        #expect(task == "Make Cafe the site for a cafe. Set `theme` in src/site.ts to bold.")
        let untouched = try #require(p.firstRunTask(name: "Cafe", purpose: "a cafe", feel: "warm"))
        #expect(untouched.contains("to editorial."), "a choice you didn't touch is its first")
    }

    @Test func aChoiceWrittenWrongIsRefusedByName() {
        let noKey = Self.playbook.replacingOccurrences(of: "  key: size\n", with: "")
        #expect(throws: Playbook.ParseError.badChoice("Pick a size.")) { try Playbook.parse(noKey) }
        let oneOption = Self.playbook.replacingOccurrences(of: "  - large: Large\n", with: "")
        #expect(throws: Playbook.ParseError.badChoice("Pick a size.")) { try Playbook.parse(oneOption) }
        let badPreviews = Self.playbook.replacingOccurrences(of: "  previews: desktop, phone", with: "  previews: tablet")
        #expect(throws: Playbook.ParseError.badChoice("Pick a design.")) { try Playbook.parse(badPreviews) }
    }

    @Test func previewsArriveWithSchemaThree() {
        let two = Self.playbook.replacingOccurrences(of: "schema: 3", with: "schema: 2")
        #expect(throws: Playbook.ParseError.unknownKey("previews", closest: "crew")) { try Playbook.parse(two) }
    }

    @Test func picturesLiveInTheRegistry() {
        #expect(TemplatePreview.url(template: "website", choice: "bold", .phone)?.absoluteString
                == "https://raw.githubusercontent.com/kstrat2001/muxbot-templates/main/previews/website/bold-phone.jpg")
        #expect(TemplatePreview.url(template: "book", .desktop)?.absoluteString.hasSuffix("/previews/book/desktop.jpg") == true)
        #expect(TemplatePreview.url(template: "../x", .desktop) == nil)
    }
}
