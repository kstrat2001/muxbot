import Foundation

/// How long to wait before the next status check: 3 s while darkmux
/// answers, doubling on each miss up to 30 s. Three misses in a row means
/// darkmux can't be reached (the app says so, and keeps trying).
struct PollBackoff: Sendable, Equatable {
    private(set) var misses = 0

    var delay: Double { min(3 * pow(2, Double(misses)), 30) }
    var isUnreachable: Bool { misses >= 3 }

    mutating func failed() { misses += 1 }
    mutating func succeeded() { misses = 0 }
}
