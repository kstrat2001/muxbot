import Foundation
import Observation
import Synchronization
import Testing
@testable import MuxBot

/// LocalBotState is read and written from more than one thread (the
/// schema migration writes it off the main actor): an update is one
/// read-modify-write, and observers are told outside its lock. Each test
/// uses its own file, never `.shared`.
struct LocalBotStateConcurrencyTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("local-bots-\(UUID().uuidString).json")
    }

    @Test func concurrentUpdatesLoseNothing() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let local = LocalBotState(fileURL: file)
        let id = UUID()
        let count = 200
        DispatchQueue.concurrentPerform(iterations: count) { i in
            local.update(id) { $0.dismissedRuns = ($0.dismissedRuns ?? []) + ["run-\(i)"] }
        }
        #expect(Set(local[id]?.dismissedRuns ?? []).count == count)
        #expect(Set(LocalBotState(fileURL: file)[id]?.dismissedRuns ?? []).count == count, "and the file has every one")
    }

    /// An observer that reads the state when told it changed (as SwiftUI
    /// does) must not find the lock still held.
    @Test func anObserverCanReadDuringTheChange() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let local = LocalBotState(fileURL: file)
        let id = UUID()
        let told = Mutex(0)
        withObservationTracking { _ = local[id] } onChange: {
            _ = local[id]
            told.withLock { $0 += 1 }
        }
        local.update(id) { $0.workspaceName = "hcr-1" }
        #expect(told.withLock { $0 } == 1)
        #expect(local[id]?.workspaceName == "hcr-1")
    }
}
