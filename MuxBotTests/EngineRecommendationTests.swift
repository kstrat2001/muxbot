import Testing
@testable import MuxBot

/// muxbot#103: with no usable engine, Mux Bot suggests Flint on a Mac that
/// meets rec's stated needs, else a hosted model, and never a command.
struct EngineRecommendationTests {
    func facts(silicon: Bool = true, memory: Int = 64, disk: Int? = 200) -> SetupFacts {
        var f = SetupFacts(platform: .mac, appleSilicon: silicon, memoryGB: memory)
        f.freeDiskGB = disk
        return f
    }

    @Test func flintOnAQualifyingMac() {
        #expect(EngineRecommendation.for(facts()) == .flint)
        #expect(EngineRecommendation.for(facts(memory: 48, disk: 30)) == .flint)
        // Disk unknown: memory decides.
        #expect(EngineRecommendation.for(facts(disk: nil)) == .flint)
    }

    @Test func hostedWhenTheMacDoesNotQualify() {
        #expect(EngineRecommendation.for(facts(silicon: false)) == .hosted(.notAppleSilicon))
        #expect(EngineRecommendation.for(facts(memory: 36)) == .hosted(.memory))
        #expect(EngineRecommendation.for(facts(disk: 29)) == .hosted(.disk))
    }

    @Test func linesSayTheTradeOffAndNoCommand() {
        let flint = EngineRecommendation.flint.line
        #expect(flint.contains("21 GB") && flint.contains("privately"))
        let hosted = EngineRecommendation.hosted(.memory).line
        #expect(hosted.contains("48 GB") && hosted.contains("sent to its provider"))
        for line in [flint, hosted, EngineRecommendation.hosted(.disk).line, EngineRecommendation.hosted(.notAppleSilicon).line] {
            #expect(!line.contains("curl") && !line.contains("rec pull") && !line.contains("`"))
        }
    }

    @Test func modelsStepUsesTheRecommendation() {
        var f = facts(memory: 16)
        f.endpointUp = true
        f.paired = true
        f.listing = .listed
        let step = SetupCheck.steps(f)[.models]
        #expect(step?.state == .todo)
        #expect(step?.detail == EngineRecommendation.hosted(.memory).line)
    }
}
