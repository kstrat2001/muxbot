import Testing
import Foundation
@testable import MuxBot

@MainActor
struct SettingsPagesTests {
    @Test func theOldTabNamesOpenTheirNewPages() {
        #expect(SettingsTab.stored("darkmux") == .computers)
        #expect(SettingsTab.stored("notifications") == .general)
        #expect(SettingsTab.stored("model") == .general)
        #expect(SettingsTab.stored("models") == .models)
        #expect(SettingsTab.stored("github") == .github)
        #expect(SettingsTab.stored("") == .general)
    }

    @Test func aComputerIsOnlineOnlyWhenPairedAndAnswering() {
        #expect(ComputerStatus.of(paired: false, answers: true) == .notPaired)
        #expect(ComputerStatus.of(paired: true, answers: nil) == .checking)
        #expect(ComputerStatus.of(paired: true, answers: true) == .online)
        #expect(ComputerStatus.of(paired: true, answers: false) == .notAnswering)
        #expect(ComputerStatus.online.isOnline)
        #expect(!ComputerStatus.notAnswering.isOnline)
    }

}
