import Foundation
import SwiftUI
import Testing
@testable import MuxBot

/// The avatar picker names each animal and lets you preview the face in
/// each state (UI only, never saved on the bot); a state stays picked
/// while you compare animals.
struct AvatarPickerTests {
    @Test func everyAnimalHasAName() {
        let names = BotAnimal.allCases.map(\.name)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == names.count, "no two alike")
        #expect(BotAnimal.fox.name == "Fox")
    }

    @Test func everyStateIsSelectableAndNamed() {
        var preview = AvatarPreview(look: BotLook.lead)
        for mood in AvatarMood.allCases {
            preview.show(mood)
            #expect(preview.mood == mood)
            #expect(!mood.name.isEmpty)
        }
        #expect(AvatarMood.allCases.map(\.name) == ["Idle", "Thinking", "Working", "Needs you", "Done"])
    }

    @Test func aStateSurvivesPickingAnotherAnimal() {
        var preview = AvatarPreview(look: BotLook(animal: .fox, bodyHex: "0e9f8e", eyeHex: "ffffff"))
        preview.show(.needsYou)
        preview.pick(.owl)
        #expect(preview.mood == .needsYou)
        #expect(preview.look == BotLook(animal: .owl, bodyHex: "0e9f8e", eyeHex: "ffffff"), "only the animal changes")
    }

    /// The picker as it looks at phone width, for review.
    @MainActor @Test func renderThePicker() throws {
        let view = AvatarPickerSnapshot().frame(width: 390).background(Color.white)
        let png = try renderPNG(view)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-picker.png")
        try png.write(to: url)
        #expect(png.count > 10_000)
    }
}

/// The picker with a state picked, as the render test draws it.
private struct AvatarPickerSnapshot: View {
    @State private var look = BotLook(animal: .fox, bodyHex: "0e9f8e", eyeHex: "ffffff")
    @State private var mood = AvatarMood.needsYou
    var body: some View { BotLookPicker(look: $look, mood: $mood).padding(16) }
}
