import Foundation

/// A bot's live preview as darkmux runs it (from the repo's
/// `.darkmux/preview.json`), and which URL the preview panel shows.
struct LivePreview: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case waiting, starting, installing, ready, stopped
        case failed(String)

        var isFailed: Bool { if case .failed = self { true } else { false } }

        var text: String {
            switch self {
            case .waiting: "Waiting for darkmux…"
            case .starting: "Starting the preview…"
            case .installing: "Installing the project's dependencies (first time only)…"
            case .ready: "Preview ready."
            case .stopped: "The preview is stopped."
            case let .failed(why): "The preview didn't start: \(why)\(why.hasSuffix(".") ? "" : ".")"
            }
        }
    }

    var status: Status
    var url: URL?
    /// The dev server's last lines, when it failed.
    var log: String?

    /// darkmux's preview once it's ready; nothing while it starts or after
    /// it failed (the panel shows why); your own preview link otherwise.
    static func url(darkmux: LivePreview?, resource: URL?) -> URL? {
        switch darkmux?.status {
        case .ready?: darkmux?.url
        case .waiting?, .starting?, .installing?, .failed?: nil
        case .stopped?, nil: resource
        }
    }
}
