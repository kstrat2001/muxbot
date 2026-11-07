import Foundation
import Testing
@testable import MuxBot

struct BlinkScheduleTests {
    private let a = UUID(uuidString: "C289195E-DF50-4D69-A1BF-83DCA920EBD2")!
    private let b = UUID(uuidString: "0B6F1D2A-1111-4C2E-9D7A-2F0C9E5B7A10")!

    @Test func eachBotHasItsOwnScheduleAndKeepsIt() {
        let start = 800_000_000.0
        #expect(BlinkSchedule(id: a).blinks(from: start, to: start + 60) != BlinkSchedule(id: b).blinks(from: start, to: start + 60))
        #expect(BlinkSchedule(id: a).blinks(from: start, to: start + 60) == BlinkSchedule(id: a).blinks(from: start, to: start + 60))
        // Stable across launches: derived from the id's bytes, not hashValue.
        #expect(BlinkSchedule(id: a).seed == BlinkSchedule(id: UUID(uuidString: a.uuidString)!).seed)
    }

    @Test func blinksComeEvery4To9SecondsWithTheOddDoubleBlink() {
        let start = 800_000_000.0
        for id in (0..<20).map({ _ in UUID() }) {
            let s = BlinkSchedule(id: id)
            let times = s.blinks(from: start, to: start + 600)
            let firsts = times.filter { !$0.isSecond }.map(\.time)
            for (x, y) in zip(firsts, firsts.dropFirst()) {
                #expect((4.0...9.0).contains(y - x), "gap \(y - x)")
            }
            #expect(times.contains { $0.isSecond } || firsts.count < 40, "doubles happen sometimes")
        }
    }

    @Test func theEyesCloseOnlyDuringABlink() {
        let s = BlinkSchedule(id: a)
        let start = 800_000_000.0
        let first = s.blinks(from: start, to: start + 20)[0].time
        #expect(s.openness(at: first + 0.05) < 0.5)
        #expect(s.openness(at: first - 0.5) == 1)
        #expect(s.openness(at: first + 1.0) == 1 || s.blinks(from: first + 0.2, to: first + 1.2).contains { $0.isSecond })
    }
}
